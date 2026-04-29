{
  config,
  lib,
  pkgs,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
  inherit (pkgs.mmell.lib.data) hostCerts;
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
          # SSHPOP enrollment presents the host's SSH cert as proof of possession,
          # so the cert must exist at build time.
          assertion = !hasTls || (hostCerts ? ${hostname});
          message = "fluent-bit-agent on '${hostname}' uses mTLS via SSHPOP, but no SSH host cert is registered at lib/common/data/host-certs/${hostname}-cert.pub. Sign one with: nix run .#ssh-host-cert-sign -- --sign ${hostname}";
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

          systemd.services.fleet-tls-bootstrap = {
            description = "Bootstrap fleet TLS client certificate via SSHPOP";
            wantedBy = ["fluent-bit.service"];
            before = ["fluent-bit.service"];
            after = ["network-online.target"];
            wants = ["network-online.target"];
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
              token=$(${pkgs.step-cli}/bin/step ca token "${hostname}.internal" \
                --provisioner fleet-sshpop \
                --ssh-pop \
                --ssh-pop-cert /etc/ssh/ssh_host_ed25519_key-cert.pub \
                --ssh-pop-key /etc/ssh/ssh_host_ed25519_key \
                --ca-url ${caUrl} --root ${caRoot})
              ${pkgs.step-cli}/bin/step ca certificate "${hostname}.internal" \
                /var/lib/fleet-tls/client.crt /var/lib/fleet-tls/client.key \
                --token "$token" \
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
          systemd.services.fluent-bit.after = ["fleet-tls-bootstrap.service"];

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
