{
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (pkgs.mmell.lib.data) pki;

  # ── Chunk 2a — cert-manager + a step-ca ClusterIssuer ───────────────────────
  # cert-manager is the in-cluster issuer for *workload* TLS. Per open decision
  # #3 (PKI overlap) we do NOT make k3s' control-plane CA a step-ca intermediate;
  # k3s keeps its own CA for the apiserver/kubelet, and step-ca is bridged in
  # ONLY for workload certs via this ClusterIssuer. Two trust roots, documented.
  #
  # We talk to step-ca's *existing* `acme` provisioner (basel,
  # hosts/calvard/.../basel/modules/step-ca.nix) over ACME. That keeps Chunk 2
  # strictly erebonia-local — no basel change. (A step-issuer / JWK path would
  # need a new dedicated provisioner on basel, which we deliberately avoid here.)
  #
  # step-ca serves ACME directly on :443 with a cert signed by its own
  # root+intermediate. cert-manager (in a pod) does not get the host's system
  # trust store (common.internal-pki only seeds the *host*), so the ClusterIssuer
  # carries the step-ca trust chain inline via `caBundle`.
  acmeDirectory = "https://basel.internal.mutantmell.net/acme/acme/directory";

  # base64(root || intermediate) PEM bundle for the ACME server's TLS chain.
  stepCaBundle = builtins.readFile (pkgs.runCommand "stepca-cabundle-b64" {} ''
    ${pkgs.coreutils}/bin/cat ${pki.root} ${pki.intermediate} \
      | ${pkgs.coreutils}/bin/base64 -w0 > $out
  '');
in {
  # cert-manager Helm chart, pinned. autoDeployCharts fetches the chart tgz at
  # build time (FOD, hash-pinned) and hands it to k3s' helm-controller as a
  # HelmChart CR — no in-cluster network fetch, no imperative `helm install`.
  services.k3s.autoDeployCharts.cert-manager = {
    repo = "https://charts.jetstack.io";
    name = "cert-manager";
    version = "v1.20.2";
    hash = "sha256-0qUL1EoJ2DjCV2qPPfyhUkWXxzk8+Ngqs+yKRlue63k=";
    targetNamespace = "cert-manager";
    createNamespace = true;
    values = {
      # Let the chart manage the CRDs (the ClusterIssuer below needs them).
      crds.enabled = true;
      # Single-node homelab: one replica of each component is plenty.
      replicaCount = 1;
      webhook.replicaCount = 1;
      cainjector.replicaCount = 1;
    };
  };

  # The step-ca ClusterIssuer. Lands as a *separate* auto-deploy manifest (not
  # the chart's extraDeploy) so its admission isn't attempted inside the same
  # helm release before cert-manager's webhook is serving — k3s' deploy
  # controller re-applies it until the webhook + CRDs are ready, then it sticks.
  #
  # The issuer becomes Ready once cert-manager registers an ACME account against
  # basel (needs only erebonia→basel:443 egress — no ingress/solver). Issuing an
  # actual Certificate additionally needs the HTTP-01 solver to be reachable,
  # which depends on cluster ingress + the router6 `cluster` zone (Chunk 3); the
  # solver is declared here so the issuer is usable the moment that lands.
  services.k3s.manifests.stepca-clusterissuer.content = [
    {
      apiVersion = "cert-manager.io/v1";
      kind = "ClusterIssuer";
      metadata.name = "step-ca";
      spec.acme = {
        server = acmeDirectory;
        # Trust step-ca's self-issued web TLS chain (no skipTLSVerify).
        caBundle = stepCaBundle;
        # step-ca's ACME provisioner does not require account contact info.
        privateKeySecretRef.name = "step-ca-acme-account-key";
        solvers = [
          {
            http01.ingress.ingressClassName = "traefik";
          }
        ];
      };
    }
  ];
}
