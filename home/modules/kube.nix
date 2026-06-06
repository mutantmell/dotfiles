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

  # k3s apiserver serving-cert CA — the cluster's own control-plane root (kept
  # separate from step-ca; bootstrap decision #3). Flake-owned and committed
  # (lib/common/data/k3s/erebonia, adopted from erebonia's initialized cluster),
  # so this is distributed declaratively like stepCaRoot — no post-boot copy.
  k3sServerCa = ../../lib/common/data/k3s/erebonia/server-ca.crt;

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
          # own control-plane CA — bootstrap decision #3). The public server CA
          # is now flake-owned (k3sServerCa) and written to ~/.kube below, so no
          # manual copy out of erebonia is needed.
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
            # Headless/SSH-friendly login: print the auth URL and read the code
            # back from the keyboard instead of spawning a browser + a localhost
            # callback server (unreachable when SSH'd into a remote host with no
            # local browser). Open the URL on any machine that can reach Authelia,
            # authenticate, then copy the `code` from the redirect URL's address
            # bar (the localhost page itself won't load) and paste it back.
            "--grant-type=authcode-keyboard"
            # authcode-keyboard does NOT derive a redirect_uri from
            # --listen-address (that is authcode-only), so it must be set
            # explicitly — otherwise the auth request omits redirect_uri and
            # Authelia rejects it ("redirect_uri is required"). http://localhost:8000
            # is a registered redirect on the `kubernetes` client, so it validates
            # with no Authelia change; nothing actually listens there — the code is
            # copied by hand from the address bar.
            "--oidc-redirect-url=http://localhost:8000"
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
  # devpod drives on-demand dev-container workspaces against the cluster's
  # Kubernetes provider (workloads plan Phase A). It's a client CLI that talks
  # straight to the apiserver using the kubeconfig below — no in-cluster server.
  home.packages = [pkgs.kubectl pkgs.kubelogin-oidc pkgs.devpod];

  # step-ca root for kubelogin to trust Authelia's TLS during the OIDC flow.
  home.file.".kube/step-ca-root.crt".source = stepCaRoot;

  # k3s apiserver CA — distributed from the flake (was a one-time manual copy).
  home.file.".kube/erebonia-ca.crt".source = k3sServerCa;

  # DevPod pod-manifest template — merged onto the generated workspace pod by the
  # kubernetes provider (POD_MANIFEST_TEMPLATE option). Sole purpose: run the
  # workspace inside a Cloud Hypervisor microVM via the kata-clh RuntimeClass
  # instead of a plain container. The provider itself is added imperatively
  # (`devpod provider add kubernetes --option POD_MANIFEST_TEMPLATE=...`) and
  # points at this stable path.
  home.file.".kube/devpod-kata-clh.yaml".text = ''
    apiVersion: v1
    kind: Pod
    spec:
      runtimeClassName: kata-clh
  '';

  # Standalone kubeconfig — kept out of ~/.kube/config so it never clobbers a
  # config managed elsewhere. Select it with `export KUBECONFIG=~/.kube/
  # erebonia-oidc.yaml` (or list it in a KUBECONFIG colon-path to merge).
  home.file.".kube/erebonia-oidc.yaml".text = builtins.toJSON kubeconfig;
}
