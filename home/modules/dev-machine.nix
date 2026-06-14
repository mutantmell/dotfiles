# Phase 3 + Phase 4 — devpod wiring, operator scripting, and the scoped git-push
# credential for the locked-down LLM dev machines
# (llm-notes/wip/ai-dev-machine-kubevirt-plan.md).
#
# Shipped as a standalone `dev-machine` package plus a Home Manager integration:
# `programs.dev-machine.enable` installs the package and writes operator-local
# config. devpod/virtctl/kubectl and the whole orchestration stay off the PATH
# *inside* the sandbox, so an agent in a dev machine can't see devpod,
# recursively spawn sandboxes, or reach the cluster. That is the core lockdown
# intent.
#
# Shape (plan "Start" path — SSH provider to a VM we create; a thin custom
# KubeVirt devpod provider is the documented graduation, only if the manual
# lifecycle ergonomics bite):
#
#   dev-machine up <repo>   creates a multus-only KubeVirt VirtualMachine from the
#                           base containerDisk (Phase 1.3) on a free VLAN-51
#                           dev slot (dev-1..dev-16; checklist D.4/D.5), injects the
#                           operator's SSH pubkey(s) via the guest agent (Phase 6:
#                           `sshPubKeys` may carry several — operator + mobile — so a
#                           phone can tssh in alongside the workstation), points a
#                           per-machine devpod ssh provider DIRECTLY at
#                           `dev-N.internal` (D.6 — the routable slot host, no
#                           port-forward), and `devpod up`s the repo's
#                           devcontainer.json inside the VM. For a creil
#                           repo it then mints a per-session SSH key on the `cc`
#                           bot account (Forgejo API) and injects it as the
#                           sandbox's ONLY git-push credential — pushes go out as
#                           `cc` (Phase 4).
#   dev-machine ssh  <name> drop into the running devcontainer (`devpod ssh`).
#                           `--recover` restarts a dead in-VM agent/container
#                           (`devpod up`) first — for a VM that crashed + rebooted.
#   dev-machine list        VMs + devpod workspaces.
#   dev-machine rescue <name> best-effort RECOVERY of a wedged-but-alive VM back
#                           to a working devcontainer (guest-side OOM reaped the
#                           agent/container but the OOM-protected sshd survived):
#                           takes a safety backup of the working tree (git bundle +
#                           patch + untracked, to $STATE/<name>/rescue/), then
#                           `devpod up`s the session back. `--no-revive` backs up
#                           only. Non-destructive. Detects + reports when the VMI was
#                           pod-restarted (emptyDisk scratch wiped — machine
#                           rebuildable, work gone); durable fix is a persistent-
#                           scratch PVC, deferred until iSCSI lands.
#   dev-machine down <name> tear the workspace + VM + secret down (freeing the
#                           VM's dev slot), and revoke the cc SSH key. `--no-agent`
#                           skips the in-VM
#                           devpod teardown when the VM is crashed/OOM-killed (the
#                           normal teardown blocks on the dead agent tunnel).
#   dev-machine publish-base (re)build + push the base containerDisk to creil
#                           (a prerequisite for `up`; run once / on base bumps).
#
# IMAGE FRESHNESS (workaround until CI lands, plan Phase 3): `up` rebuilds + pushes
# the base VM image and Phase-2.2 dev image to creil by default so the VM host's
# /nix store contains the same dev-tool closure the devcontainer's /bin symlinks
# reference after /nix is bind-mounted from the host. `--no-rebuild` skips this
# for fast iteration when both images are already in sync.
#
# PUSH CREDENTIAL (Phase 4): the sandbox holds EXACTLY ONE credential and it is
# NOT the operator identity — it is the **`cc` bot user**. `up` generates a fresh
# ed25519 keypair per session and registers the public half as an **SSH key on the
# cc account** (Forgejo `POST /user/keys`, authed with cc's own token — read from
# the file at `forgejoTokenFile`, a sops-decrypted tmpfs path that never enters the
# sandbox), then injects the private half into the devcontainer with git pinned to
# push forgejo over SSH. Pushes therefore authenticate **as cc**, so the blast
# radius is whatever cc can write to — keep cc's repo access scoped to bound it.
# `down` deletes the key. devpod's own host-credential forwarding is disabled on
# the ssh path (`--start-services=false`) so the operator's git/registry creds are
# never proxied into the session — the cc key is the only push path. Branch
# protection on creil (AGit refs/for/main, no direct protected-main merge) is the
# complementary server-side control; configure it once per repo in Forgejo. The
# SSH push path makes forgejo SSH (:22) a required allowance in the bt8gw VLAN-51
# policy.
#
# Auth: everything drives the cluster with the operator's Authelia OIDC identity
# via the standalone kubeconfig from kube.nix (KUBECONFIG exported below). Pushing
# images needs a one-time `skopeo login forgejo.internal` on the workstation.
{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.programs.dev-machine;
in {
  options.programs.dev-machine = {
    enable = lib.mkEnableOption "the locked-down KubeVirt LLM dev-machine wrappers";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "dev-machines";
      description = "k8s namespace the dev-machine VMs + secrets live in. VM data-plane egress is enforced by bt8gw on VLAN 51, not by Kubernetes NetworkPolicy.";
    };

    registry = lib.mkOption {
      type = lib.types.str;
      default = "forgejo.internal/mutantmell";
      description = "creil (Forgejo) registry path holding the base containerDisk and the dev image.";
    };

    flake = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/git/dotfiles";
      description = "Path to the dotfiles flake the images are built from.";
    };

    kubeconfig = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.kube/erebonia-oidc.yaml";
      description = "Standalone OIDC kubeconfig (kept out of ~/.kube/config on purpose; see kube.nix).";
    };

    sshPubKey = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.ssh/id_ed25519.pub";
      description = ''
        The operator's primary pubkey the guest agent injects into the VM's `dev`
        user (KubeVirt AccessCredentials). Kept for backward compatibility; it is
        the default sole entry of `sshPubKeys`. To inject more than one key
        (e.g. operator + mobile), set `sshPubKeys` instead.
      '';
    };

    sshPubKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [cfg.sshPubKey];
      defaultText = lib.literalExpression "[ config.programs.dev-machine.sshPubKey ]";
      description = ''
        Phase 6: ALL pubkey paths the guest agent injects into the VM's `dev`
        user (KubeVirt AccessCredentials), letting a mobile operator key attach
        ALONGSIDE the workstation key without an image rebuild. `create_vm`
        concatenates these into one authorized_keys blob the AccessCredentials
        secret carries; the guest agent appends every line. Defaults to just
        `[ sshPubKey ]`, so single-key setups need no change.
      '';
    };

    defaultMemory = lib.mkOption {
      type = lib.types.str;
      default = "8Gi";
      description = "Default VM memory request.";
    };

    defaultCpu = lib.mkOption {
      type = lib.types.str;
      default = "4";
      description = "Default VM vCPU cores.";
    };

    defaultDisk = lib.mkOption {
      type = lib.types.str;
      default = "60Gi";
      description = "Default capacity of the ephemeral scratch disk backing /nix store growth, Nix build directories, and Podman's rootful storage. Override per-session with `--disk`.";
    };

    forgejoApi = lib.mkOption {
      type = lib.types.str;
      default = "https://forgejo.internal/api/v1";
      description = "Forgejo (creil) API base URL used to mint/revoke the per-session deploy key.";
    };

    forgejoSshUser = lib.mkOption {
      type = lib.types.str;
      default = "forgejo";
      description = ''
        SSH login user for git-over-SSH to forgejo (the `<user>@forgejo.internal` in
        rewritten clone URLs). A Forgejo using the OS sshd + authorized-keys
        integration uses its RUN_USER here (default `forgejo`), NOT `git`. The key
        still identifies the actual account (forgejoUser); this is only the transport.
      '';
    };

    forgejoTokenFile = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Path to a file holding the bot user's (forgejoUser) Forgejo token
        (write:user scope). Used ONLY to add/remove that user's per-session SSH
        keys (POST/DELETE /user/keys); it never enters the VM/sandbox. The keys
        live on the bot account, so pushes authenticate as it — scope that user's
        repo access to bound the blast radius. Point this at a sops-decrypted tmpfs
        secret path, e.g. config.sops.secrets."dev-machine-forgejo-token".path.
      '';
    };

    forgejoUser = lib.mkOption {
      type = lib.types.str;
      default = "cc";
      description = ''
        The Forgejo bot user the dev machines push as — the owner of the token in
        forgejoTokenFile. Drives the default commit identity and user-facing
        messages; the per-session SSH key actually lands on whichever account owns
        that token (/user/keys), so keep this in sync with the token's owner.
      '';
    };

    commitName = lib.mkOption {
      type = lib.types.str;
      default = cfg.forgejoUser;
      defaultText = lib.literalExpression "config.programs.dev-machine.forgejoUser";
      description = "git user.name set inside the sandbox (commit author). Defaults to the bot user.";
    };

    commitEmail = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.forgejoUser}@forgejo.internal";
      defaultText = lib.literalExpression ''"''${config.programs.dev-machine.forgejoUser}@forgejo.internal"'';
      description = "git user.email set inside the sandbox. Set to one of the bot user's Forgejo emails so commits map to it.";
    };

    caCert = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Optional CA certificate path for TLS verification of the Forgejo API (internal step-ca root).";
    };

    agentsDotfiles = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether `dev-machine up` passes the reusable agents profile repository
          to DevPod as dotfiles. The profile installer reads repo-local
          `.net.mutantmell/agents.toml` manifests to activate per-repo plugins.
        '';
      };

      url = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Fallback DevPod dotfiles repository URL containing the reusable agents
          profile installer and plugin catalog. A target repo can override this in
          `.net.mutantmell/agents.toml` with `dotfiles.url`.
        '';
      };

      script = lib.mkOption {
        type = lib.types.str;
        default = "install.sh";
        description = ''
          Fallback script inside the selected agents dotfiles repository for
          DevPod to run after cloning it. A target repo can override this in
          `.net.mutantmell/agents.toml` with `dotfiles.script`.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [pkgs.mmell.dev-machine];
    xdg.configFile."dev-machine/config.json".text = builtins.toJSON {
      inherit
        (cfg)
        namespace
        registry
        flake
        kubeconfig
        sshPubKey
        sshPubKeys
        defaultMemory
        defaultCpu
        defaultDisk
        forgejoApi
        forgejoSshUser
        forgejoTokenFile
        forgejoUser
        commitName
        commitEmail
        caCert
        ;
      agentsDotfiles = {
        inherit (cfg.agentsDotfiles) enable url script;
      };
    };
  };
}
