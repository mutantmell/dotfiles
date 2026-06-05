{
  config,
  lib,
  pkgs,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
  inherit (pkgs.mmell.lib.data) hostCerts fleetEnrollmentCerts;
  inherit (pkgs.mmell.lib.data) pki;
  caUrl = "https://basel.internal";
  caRoot = pki.root;
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
          # X5C enrollment cert must be present for any host using fleet mTLS.
          # Gate on hasTls so a fresh host can deploy with tls.certFile = null for
          # the first pass, generate its enrollment key, then get the cert signed.
          assertion = !hasTls || (fleetEnrollmentCerts ? ${hostname});
          message = "fluent-bit-agent on '${hostname}' uses mTLS via X5C enrollment, but no enrollment cert is registered at lib/common/data/fleet-x5c-certs/${hostname}.crt. Register the key and sign: nix run .#fleet-x5c-cert-sign -- --sign ${hostname}";
        }
      ];

      fluent-bit-agent = {
        lokiUrl = lib.mkDefault "https://tharbad.internal:3100/loki/api/v1/push";
        metricsUrl = lib.mkDefault "https://tharbad.internal:8427/api/v1/write";
        tls.certFile = lib.mkDefault "/var/lib/fleet-tls/client.crt";
        tls.keyFile = lib.mkDefault "/var/lib/fleet-tls/client.key";
        tls.caFile = lib.mkDefault (pkgs.runCommand "internal-ca-bundle.crt" {} ''
          cat ${pki.root} ${pki.intermediate} > $out
        '');
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

          # Copy the fleet enrollment keypair from the static virtiofs share into the
          # writable state dir on first boot. The key is placed there by setup-guest.sh
          # before first deploy, so no on-host key generation is needed or desired.
          # Runs exactly once: ConditionPathExists guards re-runs after first boot.
          systemd.services.fleet-enrollment-key = {
            description = "Install fleet enrollment keypair from static share";
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
              if [ ! -f /static/fleet-tls/enrollment.key ]; then
                echo "fleet-enrollment-key: enrollment key not found."
                echo ""
                echo "For microvm guests: run setup-guest.sh — it places the key in the"
                echo "  static virtiofs share (/persist/guests/<guest>/static/fleet-tls/)."
                echo ""
                echo "For parent/bare-metal hosts: place the key at"
                echo "  <extra-files>/persist/var/lib/fleet-tls/enrollment.key"
                echo "  before deploy (nixos-anywhere --extra-files). Impermanence will"
                echo "  bind-mount it to /var/lib/fleet-tls/ before this service starts,"
                echo "  so ConditionPathExists will skip this service automatically."
                exit 1
              fi
              install -m 640 /static/fleet-tls/enrollment.key /var/lib/fleet-tls/enrollment.key
              ${pkgs.openssl}/bin/openssl pkey \
                -in /var/lib/fleet-tls/enrollment.key \
                -pubout -out /var/lib/fleet-tls/enrollment.pub 2>/dev/null
            '';
          };

          systemd.services.fleet-tls-bootstrap = {
            description = "Bootstrap fleet TLS client certificate via X5C enrollment";
            wantedBy = ["fluent-bit.service"];
            after = ["network-online.target" "fleet-enrollment-key.service"];
            wants = ["network-online.target" "fleet-enrollment-key.service"];
            unitConfig.ConditionPathExists = "!/var/lib/fleet-tls/client.crt";
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              Restart = "on-failure";
              RestartSec = "30s";
              # Without this, step ca certificate blocks on basel reachability
              # for the systemd default 90s. With microvm@<guest>.service's
              # 2-minute notify-ready window on the host, a basel-unreachable
              # boot tips phantasma's start past that limit and the host kills
              # the VM. Fail fast and let Restart=on-failure retry in the
              # background instead.
              TimeoutStartSec = "30s";
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
              chmod 640 /var/lib/fleet-tls/client.crt
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
              chmod 640 "$cert"
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

          # Don't try to start fluent-bit until the cert exists. /var/lib/fleet-tls
          # is persisted, so after the first successful bootstrap the cert is
          # present at boot and this condition passes immediately. On a cold deploy
          # where bootstrap hasn't yet written a cert (or basel is unreachable),
          # fluent-bit stays cleanly inactive instead of restart-looping on TLS
          # load errors — and crucially does not contribute to boot-time pressure.
          # StartLimitBurst kept high so post-cert restarts aren't rate-limited.
          systemd.services.fluent-bit = {
            unitConfig = {
              ConditionPathExists = "/var/lib/fleet-tls/client.crt";
              StartLimitBurst = 10000;
            };
          };

          # Watches for the cert that bootstrap writes. On a cold deploy where
          # the cert isn't yet provisioned, fluent-bit's ConditionPathExists
          # leaves it inactive at boot — this path unit kicks it once bootstrap
          # finally writes the cert, so no manual `systemctl start fluent-bit`
          # is needed.
          systemd.paths.fluent-bit-cert-watch = {
            description = "Trigger fluent-bit when fleet TLS cert appears";
            wantedBy = ["multi-user.target"];
            pathConfig = {
              PathExists = "/var/lib/fleet-tls/client.crt";
              Unit = "fluent-bit.service";
            };
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
