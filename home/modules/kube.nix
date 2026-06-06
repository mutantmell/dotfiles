# kubectl + OIDC login for the erebonia k3s cluster.
#
# Auth is the operator's Authelia identity via `kubectl oidc-login` (int128
# kubelogin, packaged as kubelogin-oidc → the kubectl-oidc_login plugin). The
# apiserver-side wiring lives in hosts/erebonia/k3s/default.nix; this is just the
# client half. A member of the lldap `k8s-admins` group lands as the kube
# `oidc:k8s-admins` group and is bound to cluster-admin there.
{
  config,
  pkgs,
  lib,
  ...
}: let
  oidcIssuer = "https://authelia.internal.mutantmell.net";
  oidcClientId = "kubernetes";

  # step-ca root (public PKI cert in this repo). kubelogin needs to trust
  # Authelia's step-ca-issued TLS during the browser/token exchange; pointing at
  # the store-copied root is self-contained (Authelia's nginx serves the
  # intermediate in its chain, so the root alone completes verification).
  stepCaRoot = ../../lib/common/data/pki/root_ca.crt;

  kubeDir = "${config.home.homeDirectory}/.kube";

  kubeconfig = {
    apiVersion = "v1";
    kind = "Config";
    clusters = [
      {
        name = "erebonia";
        cluster = {
          server = "https://erebonia.internal:6443";
          # The apiserver presents a k3s-CA-signed serving cert (k3s keeps its
          # own control-plane CA — bootstrap decision #3). That CA is generated
          # at first boot and isn't in this flake, so copy it once out of
          # erebonia:/etc/rancher/k3s/k3s.yaml (certificate-authority-data,
          # base64-decoded) into the path below. It is not secret.
          certificate-authority = "${kubeDir}/erebonia-ca.crt";
        };
      }
    ];
    users = [
      {
        name = "authelia-oidc";
        user.exec = {
          apiVersion = "client.authentication.k8s.io/v1beta1";
          command = "kubectl";
          args = [
            "oidc-login"
            "get-token"
            "--oidc-issuer-url=${oidcIssuer}"
            "--oidc-client-id=${oidcClientId}"
            "--oidc-extra-scope=profile"
            "--oidc-extra-scope=email"
            "--oidc-extra-scope=groups"
            "--certificate-authority=${kubeDir}/step-ca-root.crt"
          ];
          # Only pop a browser for commands run interactively; scripted calls
          # reuse the cached token rather than hanging on a login prompt.
          interactiveMode = "IfAvailable";
        };
      }
    ];
    contexts = [
      {
        name = "erebonia";
        context = {
          cluster = "erebonia";
          user = "authelia-oidc";
        };
      }
    ];
    current-context = "erebonia";
  };
in {
  home.packages = [pkgs.kubectl pkgs.kubelogin-oidc];

  # step-ca root for kubelogin to trust Authelia's TLS during the OIDC flow.
  home.file.".kube/step-ca-root.crt".source = stepCaRoot;

  # Standalone kubeconfig — kept out of ~/.kube/config so it never clobbers a
  # config managed elsewhere. Select it with `export KUBECONFIG=~/.kube/
  # erebonia-oidc.yaml` (or list it in a KUBECONFIG colon-path to merge).
  home.file.".kube/erebonia-oidc.yaml".text = builtins.toJSON kubeconfig;
}
