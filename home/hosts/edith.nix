# edith-specific home-manager config: sops + passage admin identity + the
# locked-down KubeVirt LLM dev machines (ai-dev-machine-kubevirt-plan.md).
{
  config,
  pkgs,
  lib,
  ...
}: {
  # Interactive `sops` (editing secrets) loads the admin identity from passage on
  # each invocation. sops-nix's home-manager activation, however, decrypts to a
  # tmpfs path at `home-manager switch` time and needs a key at rest — point it at
  # the user age key. (This one secret is cheap to rotate and tmpfs-backed.)
  home.sessionVariables.SOPS_AGE_KEY_CMD = "passage show sops/key";

  sops = {
    defaultSopsFile = ./edith/secrets/secrets.yaml;
    age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
    # The `cc` bot user's Forgejo token (write:user scope) the dev-machine wrapper
    # uses to add/remove cc's per-session SSH keys. Decrypts to a tmpfs path; never
    # enters the sandbox. Populate the value with:
    #   sops home/hosts/edith/secrets/secrets.yaml
    #   # add:  dev-machine-forgejo-token: <token>
    secrets."dev-machine-forgejo-token" = {};
  };

  programs.dev-machine = {
    enable = true;
    # creil's API + the internal step-ca root so curl trusts forgejo.internal.
    caCert = "${pkgs.mmell.lib.data.pki.root}";
    forgejoTokenFile = config.sops.secrets."dev-machine-forgejo-token".path;
  };

  # skopeo (dev-machine's image pushes) refuses to `copy` without a containers
  # trust policy, and a standalone home setup has none at /etc. Provide the
  # permissive default at ~/.config/containers/policy.json (skopeo's first search
  # path) — the de-facto default everywhere; "accept anything" is right here since
  # these internal images are unsigned (no signing infra to verify against).
  # Declared as a file (not the wrapper's --insecure-policy) so dev-machine honors
  # whatever trust policy the host defines, incl. any future signature enforcement.
  xdg.configFile."containers/policy.json".text = builtins.toJSON {
    default = [{type = "insecureAcceptAnything";}];
  };
}
