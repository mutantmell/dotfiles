{
  config,
  lib,
  pkgs,
  modulesPath,
  claude-code,
  codex,
  ...
}: let
  devMachineTools = import ../dev-machine-tools.nix {
    inherit pkgs claude-code codex;
  };

  # ── Phase 6 — attach helper for a mobile/remote operator (attach-only) ───────
  # A mobile tssh session runs this as its remote command to land DIRECTLY in the
  # agent's persistent in-container zellij, skipping the operator wrapper (which
  # lives only on the workstation, off this VM by design). It finds the running
  # devcontainer through the rootful Podman API — the one container with a
  # /workspaces/*/.git — then attaches to a zellij session named
  # `main` (create-or-attach, so the first attach starts it and later ones rejoin
  # the agent's live session). Read-only/attach-only: it never creates VMs or
  # touches the cluster.
  dev-attach = pkgs.writeShellScriptBin "dev-attach" ''
    set -euo pipefail
    cid=""
    for c in $(podman-rootful ps -q); do
      if podman-rootful exec "$c" sh -c 'ls -d /workspaces/*/.git' >/dev/null 2>&1; then
        cid=$c
        break
      fi
    done
    if [ -z "$cid" ]; then
      echo "dev-attach: no running devcontainer with a /workspaces git repo found" >&2
      echo "            (bring one up from the operator workstation: dev-machine up)" >&2
      exit 1
    fi
    exec podman-rootful exec -it "$cid" zellij attach -c main
  '';

  # ── Phase 6 — file transfer in/out of the inner devcontainer ─────────────────
  # `dev-attach`'s sibling for moving files between this VM (or a remote laptop,
  # over `ssh … dev-cp …`) and the agent's workspace INSIDE the devcontainer.
  # Plain scp can't reach the container — the workspace lives on the container
  # filesystem (reached via `podman-rootful exec`, exactly how dev-attach finds it),
  # not on the VM host — so this wraps `podman-rootful cp` with the same container probe and
  # makes a `container:` path mean "inside the devcontainer", resolved against the
  # workspace root (the dir holding .git) unless it is absolute. `-` is a tar
  # stream on stdin/stdout (the runtime cp convention), which gives a remote
  # operator a one-hop transfer with no scratch file on the VM:
  #   pull:  ssh dev@<host> dev-cp container:build/out.log - > out.log
  #   push:  tar c file | ssh dev@<host> dev-cp - container:incoming
  # Both run as a remote COMMAND (`bash -c …`), so they never trip the interactive
  # auto-attach below. PATH is pinned because a bare `ssh host dev-cp …` does not
  # source a login shell, so the rootful Podman wrapper would otherwise be off PATH.
  dev-cp = pkgs.writeShellScriptBin "dev-cp" ''
    set -euo pipefail
    export PATH="/run/current-system/sw/bin:''${PATH:-}"

    usage() {
      cat >&2 <<'EOF'
    usage: dev-cp <src> <dst>
      Copy files between this VM and the inner devcontainer's workspace.
      Prefix exactly ONE endpoint with `container:` to mean "inside the
      devcontainer"; a `container:` path is relative to the workspace root unless
      it starts with `/`. Use `-` for a tar stream on stdin/stdout, e.g.:
        pull:  ssh dev@<host> dev-cp container:build/out.log - > out.log
        push:  tar c file | ssh dev@<host> dev-cp - container:incoming
    EOF
      exit 2
    }
    [ $# -eq 2 ] || usage
    case "$1$2" in
      *container:*) : ;;
      *) echo "dev-cp: exactly one path must be prefixed with container:" >&2; usage ;;
    esac

    cid=""
    for c in $(podman-rootful ps -q); do
      if podman-rootful exec "$c" sh -c 'ls -d /workspaces/*/.git' >/dev/null 2>&1; then
        cid=$c
        break
      fi
    done
    if [ -z "$cid" ]; then
      echo "dev-cp: no running devcontainer with a /workspaces git repo found" >&2
      exit 1
    fi
    ws=$(podman-rootful exec "$cid" sh -c 'for d in /workspaces/*/.git; do dirname "$d"; exit; done')

    # Translate a `container:PATH` endpoint into the runtime cp `<cid>:<abs>` form;
    # leave local paths and `-` untouched.
    resolve() {
      case "$1" in
        container:/*) printf '%s:%s' "$cid" "''${1#container:}" ;;
        container:*)  printf '%s:%s/%s' "$cid" "$ws" "''${1#container:}" ;;
        *)            printf '%s' "$1" ;;
      esac
    }

    exec podman-rootful cp "$(resolve "$1")" "$(resolve "$2")"
  '';

  podman-rootful = pkgs.writeShellScriptBin "podman-rootful" ''
    exec ${pkgs.podman}/bin/podman --remote --url unix:///run/podman/podman.sock "$@"
  '';
in {
  # ── Phase 1.3 — base VM image for the locked-down LLM dev machines ───────────
  # (ai-dev-machine-kubevirt-plan.md). This is the KubeVirt VM that is the
  # security boundary: a NixOS VM carrying sshd, rootful Podman, the host
  # nix-daemon, and the same dev-tool closure the devcontainer references. The
  # agent still runs in the DevPod-managed OCI container, but Nix builds execute
  # through the VM host daemon so uid-range/container tests get real host
  # namespace and cgroup behavior.
  #
  # Standalone NixOS (NOT mk-nixos): no impermanence, no sops, no host registry —
  # the plan requires this image be thin and host-agnostic.
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    (modulesPath + "/profiles/headless.nix")
    (modulesPath + "/profiles/minimal.nix")
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  # MBR/BIOS grub on the disk make-disk-image hands us at /dev/vda — KubeVirt's
  # default q35 + SeaBIOS boots this with no firmware config on the VMI. The root
  # partition is labeled `nixos` and auto-grows into whatever the containerDisk
  # overlay provides.
  boot.loader.grub = {
    enable = true;
    device = "/dev/vda";
  };
  boot.loader.timeout = lib.mkForce 1;
  boot.growPartition = true;
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };

  # Runtime scratch — a KubeVirt emptyDisk (ephemeral, sized at the VMI). Podman's
  # rootful storage and Nix build directories live here, so container layers and
  # large build work dirs get scratch capacity while the boot store remains on the
  # root disk. Formatted on first boot; the VMI sets the disk serial "scratch"
  # for a stable by-id name. systemd-makefs (autoFormat) + the mount are ordered
  # before podman via local-fs.
  fileSystems."/var/lib/containers" = {
    device = "/dev/disk/by-id/virtio-scratch";
    fsType = "ext4";
    autoFormat = true;
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/containers/nix-builds 1777 root root -"
  ];

  # Serial console — `virtctl console` attaches to ttyS0.
  boot.kernelParams = ["console=ttyS0"];

  # Debug affordance: root autologin on the (serial) console. The VM is reachable
  # ONLY via `virtctl console` (cluster/operator access) and is a disposable
  # sandbox, so an unauthenticated serial shell is acceptable — and necessary to
  # diagnose boot/sshd/network issues, since root has no password and `dev` is
  # key-only. Revisit once the path is solid.
  services.getty.autologinUser = lib.mkDefault "root";

  # KubeVirt macvtap binding (multus-only, VLAN 51) gives the VM one routable
  # virtio NIC on the low-trust cluster VLAN. The guest DHCPs its slot address
  # from bt8gw via the launcher-pinned MAC; bt8gw fw4 governs egress. The VM has
  # no flannel NIC, so Kubernetes NetworkPolicy does not apply to its data plane.
  networking.useDHCP = lib.mkForce true;
  networking.firewall.allowedTCPPorts = [22];
  # tssh/tsshd (Phase 6 mobile access) carries its session over UDP: after the
  # initial SSH login, tssh starts a per-session tsshd that picks a UDP port in
  # this range and the session roams over it. 61001-61999 is tsshd's default
  # range (TsshdPort) and matches the wg-vpn->cluster bt8gw rule the isolation
  # plan opens, so the guest firewall never drops a session the router allowed (a
  # narrower guest range would). A client that pins a narrower TsshdPort can ride
  # a correspondingly narrower hole, but the default keeps zero-config working.
  networking.firewall.allowedUDPPortRanges = [
    {
      from = 61001;
      to = 61999;
    }
  ];

  # ── What devpod's SSH provider needs, and nothing else ──────────────────────
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  # SSH-key injection: KubeVirt AccessCredentials with the `qemuGuestAgent`
  # propagation method drops the operator's pubkey into `dev`'s authorized_keys
  # at VM-create time (and can rotate it live). The guest agent is wanted anyway
  # — KubeVirt uses it for VMI status (IP/OS reporting), graceful shutdown, and
  # `virtctl` console/fs ops. cloud-init is deliberately NOT used: on a
  # declarative NixOS boundary VM its only non-redundant job is key injection
  # (which this covers), and it would add Python + a multi-stage boot to an image
  # we want thin and fast to cold-start. Any real VM-level first-boot need later
  # is a small, local re-add of a cloudInitNoCloud path.
  services.qemuGuest.enable = true;

  # Compressed in-RAM swap, so a memory spike degrades instead of tripping the
  # guest OOM killer — which would reap sshd / the devpod agent and leave the VM
  # up-but-unreachable (the failure mode `dev-machine ssh --recover` / `down
  # --no-agent` exist to clean up after). This VM runs memory-spiky workloads:
  # the flake's nixosTest suite boots nested QEMU VMs inside the 8Gi guest. zram
  # is RAM-backed, so it only buys headroom on compressible pages (build output,
  # page cache, anon memory) — it keeps sshd/the agent alive through a spike
  # rather than raising the real ceiling. It stays within the guest's allocation,
  # so it adds no pressure on the (full, swap-0) erebonia node. For real capacity,
  # reclaim node RAM and/or run the tests at low concurrency.
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  # OOM containment. The flake's nixosTest suite boots nested QEMU VMs inside
  # this 8Gi guest; an overrun used to trip the guest kernel OOM killer, which
  # reaped session-critical processes (sshd, the devpod agent) at random and
  # left the VM up-but-unreachable — the failure mode `dev-machine ssh --recover`
  # / `down --no-agent` exist to clean up after. Two layers:
  #
  #   1. systemd-oomd kills under MEMORY PRESSURE inside user.slice only. The
  #      dev user's shell + workload (run-checks.sh, the nixosTest's nested
  #      QEMUs) all live there; sshd, podman, and qemu-guest-agent live in
  #      system.slice and are excluded (enableRootSlice / enableSystemSlice
  #      stay off). So a runaway test is killed EARLY (PSI-driven, not at hard
  #      exhaustion) and the session-critical services keep running — the VM
  #      stays reachable for `dev-machine ssh`.
  #   2. Low OOMScoreAdjust on sshd / qemu-guest-agent / podman as a backstop
  #      for the kernel OOM killer (in case PSI never spikes hard enough for
  #      oomd to act first): kernel-level reaping skips them and targets the
  #      workload instead.
  #
  # Pairs with zramSwap above: compressed swap absorbs a spike, which raises
  # memory pressure and gives oomd time to act before hard exhaustion. The real
  # capacity ceiling (~8Gi guest on a full node) is unchanged — these just turn
  # the failure mode from "session is gone" into "the test got killed".
  systemd.oomd = {
    enable = true;
    enableUserSlices = true;
  };
  systemd.services.sshd.serviceConfig.OOMScoreAdjust = -900;
  systemd.services.qemu-guest-agent.serviceConfig.OOMScoreAdjust = -900;
  systemd.services.podman.serviceConfig.OOMScoreAdjust = -500;

  # The VM host owns Nix builds. Agents run Nix clients inside the devcontainer,
  # but /nix is bind-mounted from this host and NIX_REMOTE talks to this daemon.
  # That keeps uid-range/container-test sandbox setup on a real NixOS VM instead
  # of inside a constrained OCI container.
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
      "auto-allocate-uids"
      "cgroups"
    ];
    sandbox = true;
    sandbox-fallback = false;
    auto-allocate-uids = true;
    use-cgroups = true;
    allowed-users = [
      "root"
      "dev"
    ];
    trusted-users = ["root"];
    system-features = [
      "nixos-test"
      "kvm"
      "uid-range"
    ];
    extra-sandbox-paths = ["/dev/kvm"];
    build-dir = "/var/lib/containers/nix-builds";
  };

  # The container runtime devpod's SSH provider targets through its Docker driver,
  # but the driver can use a replacement CLI. Use rootful Podman as the VM-local
  # OCI runtime: it has first-class cgroup-v2/systemd integration and keeps the
  # runtime rootful without granting the `dev` user sudo. Rootless Podman is not
  # the first target here because the workload needs direct VM resources and
  # stable host-daemon integration; the KubeVirt VM remains the primary security
  # boundary.
  virtualisation.containers.enable = true;
  virtualisation.podman = {
    enable = true;
  };

  # The service user devpod targets: passwordless SSH (key injected at runtime)
  # and the `podman` group so the provider can build/run the devcontainer. That
  # is the whole job — devpod injects its agent over SSH into the user's own
  # home/tmp and drives the inner container through Podman's Docker-compatible
  # interface, so NO sudo is
  # needed. Deliberately no `wheel`: the VM is the security boundary, and giving
  # `dev` passwordless root would hand it to anything that escaped the inner
  # runc container to this user — the opposite of the lockdown intent.
  users.users.dev = {
    isNormalUser = true;
    extraGroups = ["podman"];
  };

  # A UTF-8 locale for the VM session (Phase 6 mobile access). Unlike mosh-server,
  # tsshd has no hard locale requirement (it's a Go binary, no glibc locale
  # check), but the fallback `dev` VM shell and zellij still render correctly only
  # under a UTF-8 locale. This image rides profiles/minimal.nix, which narrows
  # i18n.supportedLocales (via mkDefault) to ONLY the default locale's charset
  # line — so the glibc locale archive would otherwise carry just that one entry.
  # Pin the default to en_US.UTF-8 AND list it explicitly in supportedLocales so
  # the archive actually contains it for the shell to select.
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.supportedLocales = ["en_US.UTF-8/UTF-8"];

  # devpod's SSH provider clones the workspace repo on the agent HOST (this VM)
  # before handing off to the devcontainer, so it needs `git` here — without it
  # devpod tries (and fails) to apt/apk-install it. `git` is the one dev tool the
  # base carries; the actual toolchain lives in the devcontainer image.
  #
  # tsshd + dev-attach are Phase 6 (remote/mobile operator access, attach-only): a
  # mobile operator `tssh --udp`'s into this VM (roaming/low-latency over flaky
  # links — Rootshell bundles the tssh client) and runs `dev-attach` to drop
  # straight into the agent's persistent in-container zellij. tsshd belongs on the
  # BASE image because tssh launches it over the SSH login (the mosh-server
  # analog), found on PATH here — no per-VM `--install-tsshd` into a writable home
  # needed; like the Podman socket, it lives on the VM, not inside the
  # devcontainer. dev-cp is the file-transfer sibling (rootful Podman cp wrapper) for
  # moving files into/out of the inner workspace.
  environment.systemPackages =
    [
      pkgs.git
      pkgs.tsshd
      podman-rootful
      dev-attach
      dev-cp
    ]
    ++ devMachineTools.devTools;

  # ── Phase 6 — auto-attach an interactive login straight into the devcontainer ─
  # So a mobile operator only needs a saved ssh/tssh profile (no remembered
  # command): a bare interactive login lands DIRECTLY in the agent's persistent
  # in-container zellij via dev-attach. The two guards keep every NON-interactive
  # path pristine, so nothing the control plane relies on changes:
  #   * `[ -t 0 ]`  — only a real TTY login attaches. Remote commands
  #                   (`ssh host cmd` / scp's legacy -O mode / git-over-ssh /
  #                   devpod's agent / the operator `dev-machine` ssh probes) run
  #                   as a non-interactive `bash -c` and skip this; modern scp and
  #                   sftp ride the sftp subsystem, which starts no login shell at
  #                   all. So file transfer and the orchestration plane are
  #                   untouched.
  #   * id = dev    — leaves root's serial-console autologin (the VM debug
  #                   affordance above) a plain shell.
  # dev-attach exits non-zero when no devcontainer is up; `|| true` then lets the
  # login fall through to a normal VM shell, so detaching zellij — or logging into
  # a machine whose container isn't up yet — drops you at a `dev` shell on the
  # boundary VM rather than logging you out. Need a plain VM shell deliberately?
  # `ssh -t dev@<host> bash --noprofile -i`.
  programs.bash.loginShellInit = ''
    if [ -t 0 ] && [ "$(id -un)" = dev ]; then
      ${dev-attach}/bin/dev-attach || true
    fi
  '';

  # Keep the closure lean — this is a disposable sandbox base, not a workstation.
  documentation.enable = lib.mkForce false;

  system.stateVersion = "25.11";
}
