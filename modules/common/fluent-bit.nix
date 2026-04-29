{
  config,
  lib,
  pkgs,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
  inherit (pkgs.mmell.lib.data) hostCerts fleetEnrollmentCerts;
  caUrl = "https://basel.internal";
  caRoot = pkgs.mmell.lib.data.pki.root;
  hasTls = config.fluent-bit-agent.tls.certFile != null;
  hostname = config.networking.hostName;
in {
  config = lib.mkIf config.fluent-bit-agent.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = builtins.elem hostname net.monitoredHosts;
          message = "fluent-bit-agent.enable = true on '${hostname}' but it is not listed in network.monitoredHosts";
        }
        {
          # SSH host cert is still required for SSH authentication (independent of mTLS enrollment).
          assertion = !hasTls || (hostCerts ? ${hostname});
          message = "fluent-bit-agent on '${hostname}' requires an SSH host cert at lib/common/data/host-certs/${hostname}-cert.pub. Sign one with: nix run .#ssh-host-cert-sign -- --sign ${hostname}";
        }
        {
          # X5C enrollment cert must be present for fleet-tls-bootstrap to issue a client cert.
          # Gate on hasTls so a fresh host can deploy with fluent-bit-agent.tls.certFile = null
          # for the first pass, generate its enrollment key, get the cert signed, then re-enable.
          assertion = !hasTls || (fleetEnrollmentCerts ? ${hostname});
          message = "fluent-bit-agent on '${hostname}' uses mTLS via X5C enrollment, but no enrollment cert is registered at lib/common/data/fleet-x5c-certs/${hostname}.crt. Register the key and sign: nix run .#fleet-x5c-cert-sign -- --sign ${hostname}";
        }
      ];

      fluent-bit-agent = {
        lokiUrl = lib.mkDefault "https://tharbad.internal:3100/loki/api/v1/push";
        metricsUrl = lib.mkDefault "https://tharbad.internal:8427/api/v1/write";
        tls.certFile = lib.mkDefault "/var/lib/fleet-tls/client.crt";
        tls.keyFile = lib.mkDefault "/var/lib/fleet-tls/client.key";
      };
    }

    # TODO: use the simple common persistence check when that's more pervasively used
    (lib.mkIf (config.fileSystems ? "/persist") {
      environment.persistence."/persist".directories = [
        {
          directory = "/var/lib/fluent-bit";
          user = "fluent-bit";
          group = "fluent-bit";
          mode = "0750";
        }
      ];
    })

    # Fleet TLS client cert — only provisioned when fluent-bit uses mTLS.
    # Hosts that override tls.certFile = null (e.g. tharbad, which talks to
    # Loki/vmsingle over localhost) skip cert management entirely.
    (
      lib.mkIf hasTls (lib.mkMerge [
        {
          users.groups.fleet-tls = {};

          # Deploy the signed enrollment cert from the repo to /etc/fleet-tls/.
          # The enrollment private key lives in /var/lib/fleet-tls/enrollment.key
          # (generated on first boot by fleet-enrollment-key.service below).
          environment.etc."fleet-tls/enrollment.crt" = lib.mkIf (fleetEnrollmentCerts ? ${hostname}) {
            source = fleetEnrollmentCerts.${hostname};
            mode = "0444";
          };

          # Generate the enrollment Ed25519 keypair on first boot (analogous to sshd's
          # ssh_host_ed25519_key). Runs exactly once: ConditionPathExists guards re-runs.
          systemd.services.fleet-enrollment-key = {
            description = "Generate fleet enrollment keypair on first boot";
            wantedBy = ["fleet-tls-bootstrap.service"];
            before = ["fleet-tls-bootstrap.service"];
            after = ["local-fs.target"];
            unitConfig.ConditionPathExists = "!/var/lib/fleet-tls/enrollment.key";
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              StateDirectory = "fleet-tls";
              StateDirectoryMode = "0750";
              Group = "fleet-tls";
            };
            script = ''
              ${pkgs.step-cli}/bin/step crypto keypair \
                /var/lib/fleet-tls/enrollment.pub \
                /var/lib/fleet-tls/enrollment.key \
                --kty OKP --curve Ed25519 --no-password --insecure
              chmod 640 /var/lib/fleet-tls/enrollment.key
            '';
          };

          systemd.services.fleet-tls-bootstrap = {
            description = "Bootstrap fleet TLS client certificate via X5C enrollment";
            wantedBy = ["fluent-bit.service"];
            before = ["fluent-bit.service"];
            after = ["network-online.target" "fleet-enrollment-key.service"];
            wants = ["network-online.target" "fleet-enrollment-key.service"];
            unitConfig.ConditionPathExists = "!/var/lib/fleet-tls/client.crt";
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              Restart = "on-failure";
              RestartSec = "30s";
              # Creates /var/lib/fleet-tls owned by root:fleet-tls 0750. Files written
              # by step inherit the fleet-tls primary group, so fluent-bit (in that
              # group) can read the key after a chmod 640.
              StateDirectory = "fleet-tls";
              StateDirectoryMode = "0750";
              Group = "fleet-tls";
            };
            script = ''
              ${pkgs.step-cli}/bin/step ca certificate "${hostname}.internal" \
                /var/lib/fleet-tls/client.crt /var/lib/fleet-tls/client.key \
                --provisioner fleet-x5c \
                --x5c-cert /etc/fleet-tls/enrollment.crt \
                --x5c-key /var/lib/fleet-tls/enrollment.key \
                --san "${hostname}" --san "${hostname}.internal" \
                --ca-url ${caUrl} --root ${caRoot}
              chmod 640 /var/lib/fleet-tls/client.key
            '';
          };

          systemd.services.fleet-tls-renew = {
            description = "Renew fleet TLS client certificate";
            after = ["network-online.target"];
            wants = ["network-online.target"];
            serviceConfig = {
              Type = "oneshot";
              StateDirectory = "fleet-tls";
              StateDirectoryMode = "0750";
              Group = "fleet-tls";
            };
            script = ''
              cert=/var/lib/fleet-tls/client.crt
              key=/var/lib/fleet-tls/client.key
              if [[ ! -f $cert ]]; then
                echo "fleet-tls-renew: cert not found, waiting for bootstrap to issue"
                exit 0
              fi
              ${pkgs.step-cli}/bin/step ca renew --force \
                --ca-url ${caUrl} \
                --root ${caRoot} \
                "$cert" "$key"
              chmod 640 "$key"
            '';
          };

          systemd.timers.fleet-tls-renew = {
            description = "Fleet TLS certificate renewal";
            wantedBy = ["timers.target"];
            timerConfig = {
              OnCalendar = "daily";
              RandomizedDelaySec = "6h";
              Persistent = true;
            };
          };

          # Order fluent-bit after bootstrap, but don't make it a hard requirement:
          # if bootstrap is mid-retry, fluent-bit's own Restart=always (from upstream)
          # will retry until bootstrap eventually writes the cert. With Requires=,
          # systemd would not auto-start fluent-bit when bootstrap recovers.
          # StartLimitBurst is set high so fluent-bit keeps retrying during the
          # bootstrap window rather than giving up and entering start-limit-hit.
          systemd.services.fluent-bit = {
            after = ["fleet-tls-bootstrap.service"];
            unitConfig.StartLimitBurst = 10000;
          };

          users.users.fluent-bit.extraGroups = ["fleet-tls"];
        }

        (lib.mkIf (config.fileSystems ? "/persist") {
          environment.persistence."/persist".directories = lib.mkIf (config.fileSystems ? "/persist") [
            {
              directory = "/var/lib/fleet-tls";
              user = "root";
              group = "fleet-tls";
              mode = "0750";
            }
          ];
        })
      ])
    )
  ]);
}
