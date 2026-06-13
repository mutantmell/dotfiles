# Observability Stack Migration

**Status:** COMPLETE. Historical migration record for the Promtail/Prometheus
agent-side shift to Fluent Bit, VictoriaMetrics, and VictoriaLogs on tharbad.
Verify current service state in code before following plan-time architecture or
validation detail here.

**Supersedes:** parts of `metrics-alerting-plan.md` (specifically the agent
layer and metrics receiver). Alertmanager + ntfy sections now live in
`llm-notes/blocked/metrics-alerting-plan.md`.

---

## Motivation

`services.promtail` was removed from nixpkgs (Promtail reached EOL).
`modules/promtail-client/default.nix` is a no-op stub kept only so the 16
fleet-wide `promtail-client.enable = true` call sites continue to evaluate.
**No host is currently shipping logs.** Combined with the broader
"lighter-weight replacements" direction (kresd over BIND, Authelia replacing
Keycloak, Perses replacing Grafana), this is the moment to bundle four
otherwise-separate decisions into a single coordinated migration:

1. Promtail → Fluent Bit for log shipping.
2. Externally-listening node_exporter → loopback-only node_exporter scraped
   locally by Fluent Bit and forwarded via remote_write.
3. Pull → push for metrics ingestion (with full security mitigations).
4. Prometheus → VictoriaMetrics on the receiver side.

Doing all four together is justified by:

- **Pre-deployment window.** Liberl's media stack hasn't shipped yet; nobody
  outside the operator depends on observability uptime. Disruptive changes
  are cheapest right now.
- **Central-module pattern.** `flake.nix:211-217` wires shared modules into
  every host build. A single replacement module fans out to all 16 hosts via
  one config flip per host.
- **Liberl as a clean canary.** Liberl is being deployed fresh and can
  validate the new stack end-to-end without a migration step muddying the
  signal.
- **Coupled rewrites.** Push-mode security mitigations (freshness alerts,
  black-box probes, server-side label binding) require rewriting the same
  alert rules that a Prometheus → VictoriaMetrics swap would also touch.
  Bundling them is one rewrite, not two.
- **Auth bundled = no second redeploy.** Per-host bearer tokens require
  per-host config + sops changes. Doing them in v1 piggybacks on the
  redeploy we're already doing; deferring them to a v2 means redeploying
  the fleet again.

---

## Stack Selection

| Layer                                    | Choice                                                    | Replaces                                          | Rationale                                                                                                                                                                                                                                                                                                                                                                     |
| ---------------------------------------- | --------------------------------------------------------- | ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Per-host agent (logs + metrics shipping) | **Fluent Bit**                                            | promtail (and node_exporter as a public listener) | Apache 2.0, ~5–10 MB RSS, native systemd input, native `prometheus_scrape` and `loki` and `prometheus_remote_write` outputs. Replaces Promtail's role and node_exporter's external-facing role.                                                                                                                                                                               |
| Local metric source on each host         | **node_exporter (loopback only, port 9100 on 127.0.0.1)** | externally-listening node_exporter                | Fluent Bit's `node_exporter_metrics` input is a partial reimplementation — it lacks the `systemd` collector that the existing `SystemdUnitFailed` alert depends on. Keeping real node_exporter as a loopback-only source preserves the full collector set; Fluent Bit scrapes it locally and forwards. Net: zero externally-listening metrics ports, full collector coverage. |
| Metrics store                            | **VictoriaMetrics (vmsingle)**                            | Prometheus                                        | Apache 2.0, 3-5× smaller RSS, 2-7× less disk, native `remote_write` receiver, PromQL-superset query language.                                                                                                                                                                                                                                                                 |
| Metrics auth proxy                       | **vmauth**                                                | (new)                                             | Per-host bearer-token authentication for `remote_write` ingestion. Maps tokens to identities via per-user `url_prefix`.                                                                                                                                                                                                                                                       |
| Metrics relabel proxy                    | **vmagent** (conditional)                                 | (new)                                             | Only included if Phase 0 selects Option B/C — sits between vmauth and vmsingle and applies `-remoteWrite.relabelConfig` to **pin the `host` label** per identity. If Phase 0 confirms Option A (vmsingle's `extra_label` URL query overrides incoming labels), vmagent is **not** deployed. See "Receiver chain" below.                                                       |
| Metrics rule eval                        | **vmalert**                                               | Prometheus rule evaluator                         | Drop-in for VM; sends to existing Alertmanager.                                                                                                                                                                                                                                                                                                                               |
| Black-box probes                         | **blackbox_exporter**                                     | (new)                                             | Restores agent-independent liveness signal lost when going push-mode.                                                                                                                                                                                                                                                                                                         |
| Log store                                | **Loki** (unchanged)                                      | —                                                 | Working; ruler in active use. VictoriaLogs is a Phase C fast-follow once VM-on-receiver is stable.                                                                                                                                                                                                                                                                            |
| Log ingest auth                          | **nginx HTTP basic auth + sops-generated htpasswd**       | (new)                                             | Simpler than `auth_request`; same security guarantee at our scale. Per-host username = hostname, password = bearer token.                                                                                                                                                                                                                                                     |
| Log rule eval                            | Loki ruler (unchanged)                                    | —                                                 | Working.                                                                                                                                                                                                                                                                                                                                                                      |
| Alerting                                 | Alertmanager (unchanged)                                  | —                                                 | Working.                                                                                                                                                                                                                                                                                                                                                                      |
| Notifications                            | ntfy (unchanged)                                          | —                                                 | Working.                                                                                                                                                                                                                                                                                                                                                                      |
| Dashboards                               | Perses (unchanged)                                        | —                                                 | Working. PromQL queries should port to MetricsQL with no edge cases at current dashboard complexity, but each dashboard gets a smoke test during cutover.                                                                                                                                                                                                                     |

### What this gives up

- The `up == 0` semantic (intrinsic to pull). Replaced with black-box
  probes + freshness alerts.
- The `scrape_duration_seconds` metric and `SlowScrape` alert. Not
  meaningful in push mode; alert is dropped.
- 1-5% chance of a PromQL→MetricsQL semantic edge case in an existing
  rule or dashboard. Mitigated by running the new VM stack alongside
  retained-historical Prometheus data during Phase 1–4.

### What gets added

- Three new receiver-side services on tharbad: vmauth, vmagent,
  blackbox_exporter. Each <50 MB RSS, configured once, then operationally
  invisible. (vmsingle + vmalert replace Prometheus + its rule evaluator
  1-for-1, so they're not "new" in net-component-count terms.)
- A 16-entry per-host bearer-token table in tharbad's sops file, plus one
  token entry per host's own sops file.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Each host (16×)                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ node_exporter (127.0.0.1:9100, all collectors enabled)   │   │
│  └──────────────────────┬───────────────────────────────────┘   │
│                         │ scrape (loopback)                     │
│  ┌──────────────────────▼───────────────────────────────────┐   │
│  │ fluent-bit                                               │   │
│  │  inputs:                                                 │   │
│  │   • systemd                  → tag=host.log.*            │   │
│  │   • prometheus_scrape (127.0.0.1:9100)                   │   │
│  │                              → tag=host.metric.node      │   │
│  │   • prometheus_scrape (per-host extras: zfs, smartctl,   │   │
│  │     unbound, kea, nginx, nftables — all loopback)        │   │
│  │                              → tag=host.metric.*         │   │
│  │   • fluentbit_metrics        → tag=host.metric.agent     │   │
│  │  filters:                                                │   │
│  │   • modify (rename _SYSTEMD_UNIT→unit, _COMM→comm, etc.) │   │
│  │   • modify (add job, host static labels)                 │   │
│  │  outputs:                                                │   │
│  │   • loki                  match=host.log.*    [basic auth│───┼──┐
│  │   • prometheus_remote_write match=host.metric.* [bearer] │───┼──┐
│  └──────────────────────────────────────────────────────────┘   │  │
└─────────────────────────────────────────────────────────────────┘  │  │
                                                                     │  │
┌─────────────────────────────────────────────────────────────────┐  │  │
│ tharbad (management zone)                                       │  │  │
│  ┌─────────────────────────┐   ┌──────────────────────────────┐ │  │  │
│  │ vmauth (8427)           │   │ Loki nginx vhost (3100)      │◀┼──┘  │
│  │  • bearer-token auth    │   │  • HTTP basic auth (htpasswd)│ │     │
│  │  • map token → identity │   │  • forwards to Loki :3101    │ │     │
│  │  • forward to vmagent   │   └──────────────────────────────┘ │     │
│  └─────────┬───────────────┘                                    │     │
│            │ X-Identity header (or url-prefix per token)        │     │
│  ┌─────────▼───────────────┐                                    │     │
│  │ vmagent (8429, local)   │                                    │     │
│  │  • write_relabel_configs│                                    │     │
│  │    pin host label       │                                    │     │
│  │    from auth identity   │                                    │     │
│  │  • forward to vmsingle  │                                    │     │
│  └─────────┬───────────────┘                                    │     │
│            ▼                                                    │     │
│  ┌─────────────────────────┐  ┌───────────────────────────────┐ │     │
│  │ vmsingle (8428, local)  │  │ Loki (3101, local)            │ │     │
│  │  • TSDB                 │  │  • log store                  │ │     │
│  │  • PromQL/MetricsQL API │  │  • ruler (existing)           │ │     │
│  └─────────┬───────────────┘  └───────────┬───────────────────┘ │     │
│            │                              │                     │     │
│  ┌─────────▼─────────┐         ┌──────────▼─────────┐           │     │
│  │ vmalert (local)   │         │ Alertmanager (9093)│◀──────────┼─────┘
│  │  • rule eval      │────────▶│  • routes → ntfy   │           │ remote_write
│  │  • → AM           │         └────────────────────┘           │ (vmalert metrics)
│  └───────────────────┘                                          │
│                                                                 │
│  ┌─────────────────────────────┐                                │
│  │ blackbox_exporter (9115,    │                                │
│  │ 127.0.0.1)                  │                                │
│  │  • TCP probe :22 per host   │◀── scraped by tharbad's        │
│  │                             │    own fluent-bit              │
│  └─────────────────────────────┘                                │
│                                                                 │
│  ┌──────────┐                                                   │
│  │ ntfy     │                                                   │
│  │ (2586)   │                                                   │
│  └──────────┘                                                   │
└─────────────────────────────────────────────────────────────────┘
```

Key flow points:

- **One fluent-bit per host**, with a single config that splits logs and
  metrics by tag prefix. Routing to two outputs in parallel.
- **`node_exporter` runs on each host bound to `127.0.0.1:9100`** — no
  firewall opening, no external listener. Fluent-bit scrapes it locally
  and forwards via remote_write. Same for any other per-host exporters
  (zfs, smartctl, future service-specific exporters).
- **vmauth** is the only externally-listening metrics endpoint on tharbad.
  It validates per-host bearer tokens, maps tokens to identities, and
  forwards to vmagent. It does **not** relabel — that's vmagent's job.
- **vmagent** sits between vmauth and vmsingle, applies
  `write_relabel_configs` per identity to **pin the `host` label** to the
  authenticated identity. Producer can't claim to be a different host.
- **Loki ingest** goes through the existing nginx vhost, gated by HTTP
  basic auth. Username = hostname, password = bearer token. **Label
  binding for logs is best-effort** — nginx can't rewrite Loki's protobuf
  push payload.
- **vmsingle, vmagent, Loki, blackbox** all listen on 127.0.0.1 — no
  direct fleet ingress.
- **blackbox_exporter** runs on tharbad and gives an agent-independent
  liveness signal. Its metrics are scraped locally by tharbad's own
  fluent-bit and forwarded through the same vmauth → vmagent → vmsingle
  chain as everything else.

---

## Module: `modules/fluent-bit-agent/`

Replaces `modules/promtail-client/`. Coexists with (and depends on)
`modules/node-exporter-client/`, which is modified to be loopback-only.

### Public interface

```nix
options.fluent-bit-agent = {
  enable = lib.mkEnableOption "Fluent-bit agent (logs + metrics)";

  lokiUrl = lib.mkOption {
    type = lib.types.str;
    default = "http://tharbad.internal:3100/loki/api/v1/push";
  };

  metricsUrl = lib.mkOption {
    type = lib.types.str;
    default = "http://tharbad.internal:8427/api/v1/write";
  };

  authTokenFile = lib.mkOption {
    type = lib.types.path;
    description = ''
      Path to a file containing the per-host bearer token. Used as the
      `Authorization: Bearer …` header on the VictoriaMetrics push output
      and as the basic-auth password (with the hostname as username) on
      the Loki push output.

      Typically a sops-nix secret resolving to /run/secrets/observability-token.
    '';
  };

  extraInputs = lib.mkOption {
    type = lib.types.listOf lib.types.attrs;
    default = [];
    description = ''
      Additional Fluent Bit inputs. Used for hosts with extra local
      exporters (e.g. liberl scrapes its own zfs/smartctl exporters
      bound to 127.0.0.1). Tags should start with "host.metric." to
      route to vmsingle.
    '';
  };
};
```

### Implementation outline

```nix
config = lib.mkIf cfg.enable {
  # Ensure node_exporter is running locally for the metrics scrape.
  assertions = [{
    assertion = config.node-exporter-client.enable;
    message = "fluent-bit-agent depends on node-exporter-client.enable being true";
  }];

  services.fluent-bit = {
    enable = true;
    settings = {
      service = {
        flush = 5;
        log_level = "info";
        storage.path = "/var/lib/fluent-bit/storage/";
        storage.sync = "normal";
        storage.backlog.mem_limit = "16M";
      };
      pipeline = {
        inputs = [
          {
            name = "systemd";
            tag = "host.log.*";
            db = "/var/lib/fluent-bit/systemd.db";
            db.sync = "normal";
            read_from_tail = "off";
            strip_underscores = "on";
          }
          # Local node_exporter scrape — replaces the public :9100 listener
          # with a loopback scrape. All standard collectors plus systemd.
          {
            name = "prometheus_scrape";
            tag = "host.metric.node";
            host = "127.0.0.1";
            port = config.node-exporter-client.port;  # 9100
            scrape_interval = 15;
          }
          # Fluent-bit's own metrics, for self-observability.
          {
            name = "fluentbit_metrics";
            tag = "host.metric.agent";
            scrape_interval = 30;
          }
        ] ++ cfg.extraInputs;

        filters = [
          # Logs: rename journald fields → Loki labels expected by ruler
          {
            name = "modify";
            match = "host.log.*";
            rename = [
              "SYSTEMD_UNIT unit"
              "COMM comm"
              "PRIORITY priority"
            ];
          }
          {
            name = "modify";
            match = "host.log.*";
            add = [
              "job systemd-journal"
              "host ${config.networking.hostName}"
            ];
          }
          # Metrics: ensure host label is on every series (vmagent will
          # also enforce this server-side; this is the producer-side copy).
          {
            name = "modify";
            match = "host.metric.*";
            add = [ "host ${config.networking.hostName}" ];
          }
        ];

        outputs = [
          {
            name = "loki";
            match = "host.log.*";
            host = "<parsed from cfg.lokiUrl>";
            port = "<parsed>";
            uri  = "<parsed, default /loki/api/v1/push>";
            label_keys = "$unit,$comm,$priority,$job,$host";
            line_format = "json";
            # Basic auth — username is the hostname, password is the
            # bearer token from the secret file.
            http_user = config.networking.hostName;
            http_passwd_file = cfg.authTokenFile;
          }
          {
            name = "prometheus_remote_write";
            match = "host.metric.*";
            host = "<parsed from cfg.metricsUrl>";
            port = "<parsed>";
            uri  = "<parsed, default /api/v1/write>";
            bearer_token_file = cfg.authTokenFile;
            add_label = [
              "host ${config.networking.hostName}"
            ];
          }
        ];
      };
    };
  };

  systemd.services.fluent-bit = {
    # Wait for sops-nix to decrypt the token before starting.
    after = [ "sops-nix.service" ];
    wants = [ "sops-nix.service" ];
  };

  environment.persistence."/persist".directories = [
    { directory = "/var/lib/fluent-bit"; user = "fluent-bit"; group = "fluent-bit"; }
  ];
};
```

### Notes on the auth-credential mechanic

Fluent Bit's outputs accept dedicated auth fields:

- `loki` output: `http_user` (string) + `http_passwd_file` (path to file).
  The file is read at startup; the password (= bearer token) never appears
  in the Nix store. Username is set to the hostname so nginx can map
  basic-auth credentials to identity in the htpasswd file.
- `prometheus_remote_write` output: `bearer_token_file` (path to file).
  Sent as `Authorization: Bearer <token>` on every push. vmauth validates
  and maps to identity.

Both outputs read the **same** token file. One sops secret per host
(`/run/secrets/observability-token`), used by both auth paths.

The systemd unit waits on `sops-nix.service` so the file is guaranteed to
exist before fluent-bit starts. If the secret is rotated, sops-nix
re-decrypts and a `systemctl restart fluent-bit` picks up the new value.

### Liberl extraInputs example

```nix
fluent-bit-agent = {
  enable = true;
  authTokenFile = config.sops.secrets.observability-token.path;
  extraInputs = [
    {
      name = "prometheus_scrape";
      tag = "host.metric.zfs";
      host = "127.0.0.1";
      port = 9134;
      scrape_interval = 30;
    }
    {
      name = "prometheus_scrape";
      tag = "host.metric.smartctl";
      host = "127.0.0.1";
      port = 9633;
      scrape_interval = 60;
    }
  ];
};
```

The existing zfs_exporter / smartctl_exporter listen on localhost only.
fluent-bit on liberl scrapes them locally and forwards via remote_write to
tharbad. No external listening ports for these exporters anymore.

---

## Module: `modules/node-exporter-client/` (modified)

Currently exposes node_exporter on `:9100` and opens the firewall port.
Modified to bind to `127.0.0.1` only and drop the firewall opening:

```nix
config = lib.mkIf cfg.enable {
  services.prometheus.exporters.node = {
    enable = true;
    inherit (cfg) port;
    listenAddress = "127.0.0.1";   # was: not set, defaulted to all interfaces
    enabledCollectors = ["systemd"];
  };
  # No firewall opening — this is a loopback-only source for fluent-bit.
};
```

The module name stays `node-exporter-client` (call sites unchanged) and the
module remains in `flake.nix` `commonModules`. Every host that had
`node-exporter-client.enable = true` keeps that line.

---

## Tharbad receiver redesign

### New service layout

```
hosts/calvard/microvm/guests/tharbad/modules/
├── victoriametrics.nix    [NEW]  vmsingle, vmagent, vmauth, vmalert
├── loki.nix               [MOD]  unchanged storage; nginx ingest + basic auth
├── alertmanager.nix       [MOD]  rule list rewritten for push semantics
├── blackbox.nix           [NEW]  blackbox_exporter (loopback)
├── fluent-bit.nix         [NEW]  tharbad's own agent (also scrapes blackbox)
├── ntfy.nix               []     unchanged
├── prometheus.nix         [DEL]  removed in Phase 5
└── perses.nix             [MOD]  datasource URL → vmsingle
```

### Receiver chain: vmauth → (vmagent?) → vmsingle

The receiver-side label-binding mechanism has three candidate forms,
listed in the order Phase 0 should evaluate them. The first that works
wins; later forms are fallbacks.

**Option A (preferred): vmauth → vmsingle direct, label pinned via
`extra_label` URL query.** vmsingle's write API supports
`?extra_label=host=<name>` to add a label to every sample in the
request. If — and this is the Phase 0 verification — the URL-supplied
value **overrides** an incoming label on conflict, vmauth alone
suffices and **vmagent drops out of the architecture entirely**. One
fewer service, one fewer config file, simpler rotation surface. This
is the form to test first because it collapses the most complexity.

**Option B (fallback): vmauth → vmagent → vmsingle, vmagent applies
`-remoteWrite.relabelConfig`.** Used if Option A only adds-when-missing
(producer can win the conflict). vmauth's per-user `url_prefix`
differentiates ingest paths (one path per identity); vmagent's
relabel config maps each path to a forced `host` label. The label
binding is enforced by relabel rules that match on the **ingest
path**, not on URL query parameters or headers — this is the form
actually documented for vmagent.

**Option C (last resort): vmauth + per-identity vmagent instances or
hand-tagged ingest paths.** Used only if Options A and B both fail
validation. Significantly more config; avoid unless forced.

### vmauth config (Option A sketch)

```yaml
# /etc/vmauth/auth.yml — generated from sops-decrypted per-host tokens
users:
  - bearer_token: "<thebeyond-token>"
    url_prefix: "http://127.0.0.1:8428/api/v1/write?extra_label=host=thebeyond"
  - bearer_token: "<liberl-token>"
    url_prefix: "http://127.0.0.1:8428/api/v1/write?extra_label=host=liberl"
  # ... 14 more entries, one per host
```

### vmauth + vmagent config (Option B sketch)

```yaml
# /etc/vmauth/auth.yml
users:
  - bearer_token: "<thebeyond-token>"
    url_prefix: "http://127.0.0.1:8429/api/v1/write/thebeyond"
  - bearer_token: "<liberl-token>"
    url_prefix: "http://127.0.0.1:8429/api/v1/write/liberl"
  # ...
```

```yaml
# vmagent -remoteWrite.relabelConfig (per-path host pinning)
- source_labels: [__path__]
  regex: "/api/v1/write/(.+)"
  target_label: host
  replacement: "$1"
  action: replace
```

The vmauth (and vmagent, if used) configs are **generated from Nix**
during the build, pulling tokens from sops-nix at deploy time. Each
host's token is a 32-byte random string, generated once and stored
encrypted per-host in
`hosts/calvard/microvm/guests/tharbad/secrets/host-tokens.yaml`.

### Loki ingest auth (HTTP basic auth)

Loki's existing nginx vhost (`hosts/calvard/microvm/guests/tharbad/modules/loki.nix:154`)
gains a per-host htpasswd file and `auth_basic` directive on the
`/loki/api/v1/push` location:

```nix
services.nginx.virtualHosts."loki" = {
  # ... existing config ...
  locations."/loki/api/v1/push" = {
    extraConfig = ''
      auth_basic "loki-push";
      auth_basic_user_file /run/secrets/loki-htpasswd;
    '';
    proxyPass = "http://127.0.0.1:3101";
  };
};
```

The htpasswd file is **pre-hashed at token-generation time** and stored
directly in tharbad's sops file as `<hostname>:<bcrypt-hash>` lines.
Sops decrypt produces the htpasswd file as a verbatim paste-out — no
build-time bcrypt invocation, no decrypted-token-in-build-tree window.
Plaintext tokens never live on tharbad; only the hashes do. (Each host
still gets the plaintext token in its own sops file for the agent's
auth credential — server side stores hashes only.)

**Label binding for logs is best-effort** — if a host's basic-auth
credentials are valid, the request is forwarded as-is to Loki. Rationale:

- Loki ingest is write-only; a compromised host can pollute logs but can't
  read peers' logs.
- Implementing label rewriting for Loki requires parsing its protobuf
  push payload, which is more complexity than the threat warrants.
- A compromised host could inject log lines labeled `host=B`, poisoning
  B's security alerts, but the same host's metrics path is identity-bound
  and would show the discrepancy.

This is a documented, accepted tradeoff. Revisit if log-side spoofing
becomes a real threat.

### vmalert + Alertmanager wiring

vmalert reads the rewritten rule files (with PromQL→MetricsQL spot-checks),
evaluates them against vmsingle, and forwards firing alerts to the existing
Alertmanager on `127.0.0.1:9093`. Alertmanager itself is unchanged.

### Persistence

```nix
environment.persistence."/persist".directories = [
  { directory = "/var/lib/victoriametrics"; user = "victoriametrics"; group = "victoriametrics"; }
  { directory = "/var/lib/vmagent"; user = "vmagent"; group = "vmagent"; }
  { directory = "/var/lib/vmalert"; user = "vmalert"; group = "vmalert"; }
  # vmauth is stateless — no persistence pin needed.
  # blackbox_exporter is stateless — no persistence pin needed.
  # Loki, alertmanager, ntfy already pinned in their existing modules.
];
```

---

## Security model

### Per-host bearer tokens

- Generated once per host, 32 bytes from `openssl rand -hex 32`.
- **Server side**: full token table stored encrypted in
  `hosts/calvard/microvm/guests/tharbad/secrets/host-tokens.yaml`. Sops
  decrypts at deploy time; vmauth config and Loki htpasswd are generated
  from this single source.
- **Client side**: each host's own token stored encrypted in the host's
  existing sops file as `observability-token`. Decrypts to
  `/run/secrets/observability-token` at deploy time.
- Used for both metrics (Bearer header to vmauth) and logs (basic-auth
  password to nginx) — single token per host serves both auth paths.

### Token rotation runbook

Order matters: server must accept old + new during the window, or the
host's pushes fail mid-rotation. Procedure:

1. Generate new token for host X. Bcrypt-hash it locally.
2. **Add** new token to tharbad's `host-tokens.yaml` as a second entry
   for X (vmauth gets two valid bearer tokens for X; htpasswd gets
   two entries for X). Old entry stays.
3. Redeploy tharbad. vmauth + nginx now accept both.
4. Update host X's `observability-token` secret to the new value.
5. Redeploy host X. fluent-bit picks up the new token on restart.
6. Verify host X's metrics + logs still arriving on tharbad.
7. **Remove** the old entry from tharbad's `host-tokens.yaml`.
8. Redeploy tharbad. Old token no longer valid.

Skipping step 2 (going straight from old → new on tharbad) creates a
window where the host pushes with the old token but vmauth has only the
new one; pushes drop until step 5 completes.

### Server-side label binding (metrics)

vmagent enforces `host` label per identity. A leaked token can only push
as the host it was issued for. vmauth maps token → identity; vmagent maps
identity → forced `host` label. Producer cannot lie about which host it
is, even with a tampered config.

### Black-box availability probes

`blackbox_exporter` on tharbad TCP-probes port 22 (SSH) on every fleet
host every 30 s. SSH is universally present and its presence is a
stronger liveness signal than node_exporter's response.

**Scrape topology**: tharbad's fluent-bit uses blackbox's
**multi-target** pattern — one logical job, one URL per fleet host with
the host as `?target=` query parameter, all hitting the same
`blackbox_exporter:9115/probe` endpoint. The fleet target list is
generated from the network registry into a single fluent-bit
`prometheus_scrape` block that fans out to N targets, not N separate
input blocks. This keeps the receiver-side fluent-bit config compact
and matches the canonical blackbox pattern.

Probe target list lives in `blackbox.nix` and is derived from the network
registry (same source-of-truth as Prometheus's old scrape config).

### Freshness alerts

Replace every `up == 0` style rule with two complementary alerts:

1. **HostUnreachable** — `probe_success{job="blackbox-ssh"} == 0` (the
   probe failed; agent-independent).
2. **MetricsStale** — `time() - timestamp(node_uname_info{host="X"}) > 120`
   (no fresh sample arrived from X for 2 min; the agent stopped
   emitting). Uses `node_uname_info` because it's a constant series per
   host; any other always-present series would work equally well.

Two signals because they fail differently:

- Network partition: both fire (host genuinely unreachable).
- Compromised agent that goes silent: only `MetricsStale` fires;
  `HostUnreachable` stays green (host is up, agent isn't reporting).
  This divergence is itself a signal.
- Successful push of a stale-but-plausible value: `MetricsStale` still
  fires because the _timestamp_ of the stored sample is still old —
  vmsingle's out-of-order rejection prevents the producer from
  back-dating.

### Out-of-order rejection

vmsingle is configured with `-search.maxStalenessInterval=5m` and a
write deadline rejecting samples older than 5 minutes or newer than
1 minute. Defeats replay-of-old-data attacks.

---

## Alert rule rewrite

| Existing alert              | Source              | Action      | New form / notes                                                                                                                                                              |
| --------------------------- | ------------------- | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `HostDown` (`up == 0`)      | prometheus.nix      | **Replace** | Split into `HostUnreachable` (blackbox) + `MetricsStale` (freshness)                                                                                                          |
| `DiskSpaceLow`              | prometheus.nix      | Keep        | `node_filesystem_*` series come from loopback node_exporter via fluent-bit's prometheus_scrape input                                                                          |
| `HighMemoryUsage`           | prometheus.nix      | Keep        | Same                                                                                                                                                                          |
| `ZFSPoolDegraded`           | prometheus.nix      | Keep        | Liberl scrapes zfs_exporter via fluent-bit's `prometheus_scrape` (extraInputs); metric names unchanged                                                                        |
| `SystemdUnitFailed`         | prometheus.nix      | Keep        | `node_systemd_unit_state` comes from real node_exporter (with `enabledCollectors=["systemd"]`) on loopback. This was the rule that drove the loopback-node_exporter decision. |
| `HighCPUUsage`              | prometheus.nix      | Keep        | Verify MetricsQL handles `rate(node_cpu_seconds_total{mode="idle"}[5m])` identically (high confidence; trivial PromQL)                                                        |
| `HostRebooted`              | prometheus.nix      | Keep        | `node_boot_time_seconds` comes from loopback node_exporter                                                                                                                    |
| `SlowScrape`                | prometheus.nix      | **Drop**    | Not meaningful in push mode                                                                                                                                                   |
| `PrometheusRuleEvalFailure` | prometheus.nix      | **Replace** | `rate(vmalert_iteration_errors_total[5m]) > 0`                                                                                                                                |
| `LokiRequestErrors`         | prometheus.nix      | Keep        | Loki self-metrics scraped by tharbad's own fluent-bit                                                                                                                         |
| `LokiIngestionLag`          | prometheus.nix      | Keep        | Same                                                                                                                                                                          |
| `SSHBruteForce`             | loki.nix ruler      | Keep        | Depends on `unit` label being mapped correctly                                                                                                                                |
| `SSHBruteForceExtreme`      | loki.nix ruler      | Keep        | Same                                                                                                                                                                          |
| `SudoFailure`               | loki.nix ruler      | Keep        | Depends on `comm` label                                                                                                                                                       |
| `HighPriorityLogs`          | loki.nix ruler      | Keep        | Depends on `priority` label                                                                                                                                                   |
| `FleetLogGap`               | loki.nix ruler      | Keep        | Threshold stays at 16 hosts                                                                                                                                                   |
| (new) `HostUnreachable`     | victoriametrics.nix | Add         | `probe_success{job="blackbox-ssh"} == 0`, severity critical, for 2m                                                                                                           |
| (new) `MetricsStale`        | victoriametrics.nix | Add         | `time() - timestamp(node_uname_info) > 120`, severity warning                                                                                                                 |
| (new) `IngestAuthFailures`  | victoriametrics.nix | Add         | `rate(vmauth_user_request_errors_total{reason="bad_auth"}[5m]) > 0`, severity warning                                                                                         |
| (new) `LokiAuthFailures`    | victoriametrics.nix | Add         | `rate(nginx_http_requests_total{server="loki",status="401"}[5m]) > 0`, severity warning                                                                                       |

---

## Cross-zone firewall changes

### What's removed

- **management → DMZ:9100**. No longer needed; DMZ hosts don't expose
  node_exporter externally.
- **management → trusted:9100**. Same.
- **management → liberl:9001/9002/9003**. liberl no longer exposes its
  exporters externally; fluent-bit scrapes them locally.
- Per-host `networking.firewall.allowedTCPPorts = [9100]` lines (handled
  by removing the firewall rule from the modified `node-exporter-client`
  module).

### What's added

- **All zones → management:8427** (vmauth metrics ingest). Add an analog
  of the existing `tharbad TCP 3100` egress rule for `tharbad TCP 8427`
  on every host with the new agent.
- Tharbad-only loopback: ports 8428 (vmsingle), 8429 (vmagent),
  9115 (blackbox) — bound to 127.0.0.1, no firewall rules needed.
- Tharbad outbound: blackbox probes to all hosts on port 22. SSH is
  already universally reachable from management for operator access;
  verify during Phase 0 that no host firewall blocks tharbad → :22.

### Net change

The number of cross-zone forward rules **decreases** (one inbound port
per host removed; one outbound port per host added, but outbound goes
through the existing Loki egress rule pattern, so much of it
consolidates).

The "wrong-direction" rule (management → DMZ for scraping) goes away
entirely. All metrics flow now matches the conventional less-trusted →
more-trusted pattern.

---

## Migration phases

The plan is one architecture decision; the deploy is staged.

### Phase 0 — Module preparation (no deploy)

- [ ] **Resolve label-binding option (A/B/C).** Stand up a throwaway
      vmsingle locally; test whether `?extra_label=host=foo` on the
      write URL **overrides** an incoming `host=bar` label. If yes,
      Option A — drop vmagent from the architecture and use vmauth →
      vmsingle direct. If only adds-when-missing, fall back to
      Option B (vmagent + path-based relabel). Option C only if both
      fail. This decision unblocks the rest of Phase 0.
- [ ] Verify tharbad → :22 reachability for every fleet host (blackbox
      probe prerequisite). Should be already in place from operator SSH;
      flagged here to catch zone gaps before Phase 4.
- [ ] Generate per-host bearer tokens (16 hosts) and encrypt into both
      tharbad's secrets (full table) and each host's secrets
      (single-token entry) via sops-nix.
- [ ] Modify `modules/node-exporter-client/default.nix`: bind to
      `127.0.0.1`, drop `allowedTCPPorts`. (No call-site changes.)
- [ ] Write `modules/fluent-bit-agent/default.nix` (logs + metrics).
- [ ] Write `hosts/calvard/microvm/guests/tharbad/modules/victoriametrics.nix`
      (vmsingle + vmagent + vmauth + vmalert).
- [ ] Write `hosts/calvard/microvm/guests/tharbad/modules/blackbox.nix`.
- [ ] Write `hosts/calvard/microvm/guests/tharbad/modules/fluent-bit.nix`
      (tharbad's own agent: scrapes Loki + blackbox + vmsingle locally,
      forwards via remote_write to local vmauth).
- [ ] Update `loki.nix`: nginx basic-auth on the push location, htpasswd
      generated from sops at deploy.
- [ ] Add `fluent-bit-agent` module to flake.nix `commonModules`. Keep
      old `promtail-client` registered (still no-op stub) until Phase 5.
- [ ] Verify everything builds: `./scripts/run-checks.sh`.

### Phase 1 — Stand up new tharbad stack alongside Prometheus

- [ ] Deploy tharbad. New services (vmsingle, vmauth, vmalert,
      blackbox, and vmagent if Option B was selected) start running on
      their own ports alongside existing Prometheus on 9090. **Hosts
      still push nowhere** — no agent has been deployed yet.
- [ ] Verify vmsingle accepts a manual `curl` push from tharbad
      (loopback test).
- [ ] Verify vmauth correctly maps a known test token to its identity
      and rejects unknown tokens.
- [ ] **Spoof test (label-binding enforcement).** From tharbad,
      `curl` push a sample with `host="erebonia"` in the payload using
      **liberl's** bearer token. Confirm vmsingle stores the sample
      with `host="liberl"` (the authenticated identity), not
      `host="erebonia"` (the producer's claim). This validates the
      receiver chain works regardless of which option (A/B/C) was
      selected during Phase 0.
- [ ] Verify vmalert evaluates the migrated alert rules without error
      (they'll fire `MetricsStale` on every host, since nobody's
      pushing yet — silenced for the duration of Phase 1).
- [ ] Verify Perses queries against the vmsingle datasource return
      expected results for the basic dashboards.
- [ ] **Prometheus retains its existing TSDB** but stops being the
      authoritative store. No further sample comparison happens — the
      Prometheus history exists as reference until Phase 5.
- [ ] **Tharbad headroom check.** New stack adds ~225 MB RSS above the
      retained Prometheus + Loki + nginx + Alertmanager + ntfy
      footprint (vmsingle ~80, vmagent ~50 if used, vmauth ~30, vmalert
      ~30, blackbox ~20, fluent-bit ~15). Confirm tharbad's microvm has
      headroom; bump memory if needed before Phase 2.

### Phase 2 — Liberl as canary (clean deploy)

- [ ] Deploy liberl fresh with `fluent-bit-agent.enable = true` and
      `node-exporter-client.enable = true` (loopback).
- [ ] Verify metrics arrive at vmsingle with `host="liberl"` label
      (label-binding test — vmagent forces the label even if the
      producer claims something else; explicit test by spoofing
      add_label).
- [ ] Verify zfs/smartctl exporters scraped locally and forwarded.
- [ ] Verify logs arrive at Loki with the expected label set
      (`unit`, `comm`, `priority`, `job`, `host`).
- [ ] Verify Loki ruler queries return liberl-scoped results.
- [ ] Verify blackbox probe of liberl returns `probe_success=1`.
- [ ] Run for 24-48 h, watch Loki stream count and vmsingle ingestion
      rate, confirm no surprises.

### Phase 3 — Migrate tharbad itself

- [ ] On tharbad, switch `promtail-client.enable = true` →
      `fluent-bit-agent.enable = true`. (`node-exporter-client.enable`
      already true; stays.)
- [ ] Tharbad's fluent-bit scrapes blackbox + Loki self-metrics +
      local node_exporter, forwards to local vmauth (loopback).
- [ ] Verify tharbad's own metrics + logs flowing through new pipeline.
- [ ] Decommission tharbad's local Promtail block in `loki.nix`.

### Phase 4 — Migrate the rest of the fleet, by zone

One zone per session, deploying all hosts in that zone together.
Recommended order:

1. **Management zone first** (intra-zone, lowest forward-rule risk):
   thebeyond, phantasma, basel, messeldam.
2. **Trusted zone**: calvard, erebonia (parent hosts).
3. **DMZ**: langport, creil, oracion, saint-arkh, roer (validates the
   new push-direction cross-zone rule).
4. **Lab**: bose, zeiss.

For each host:

- Flip `promtail-client.enable` → `fluent-bit-agent.enable` and set
  `authTokenFile = config.sops.secrets.observability-token.path`.
- For liberl, add `extraInputs` for zfs/smartctl.
- `node-exporter-client.enable` stays as-is (it's already true; the
  module is now loopback-only internally).
- Deploy.
- Verify within 5 minutes: host's metrics in vmsingle (with correctly
  pinned `host` label), logs in Loki, blackbox probe green.

### Phase 5 — Decommission old stack

After Phase 4 has been stable for one Loki retention window (~30 days):

- [ ] Remove `services.prometheus` from tharbad
      (`hosts/calvard/microvm/guests/tharbad/modules/prometheus.nix` deleted).
- [ ] Remove `modules/promtail-client/`.
- [ ] Remove its entry from flake.nix `commonModules`.
- [ ] Keep `modules/node-exporter-client/` — it's now a permanent part
      of the new architecture as the loopback-only metric source.
- [ ] Remove cross-zone forward rules for `:9100` (management→DMZ et al.).
- [ ] Update `metrics-alerting-plan.md` to reference this plan; mark its
      Phase 1-4 sections superseded.

### Rollback

The plan is recoverable at every phase, but the rollback target degrades
as phases progress:

- **Phase 1 fails** (new tharbad stack misbehaves before any host is
  cut over): revert tharbad's deploy. Prometheus on 9090 is still
  authoritative; nothing else has changed. Zero-cost unwind.
- **Phase 2 fails** (liberl deploys but pipeline breaks): liberl flips
  `fluent-bit-agent.enable = false` and the host stops pushing. Loki
  has no liberl logs (no regression — promtail-client was a no-op),
  Prometheus still scrapes nothing for liberl (it never had a config
  entry for liberl, since liberl is being deployed fresh). Investigate
  on tharbad without fleet pressure.
- **Phase 3 fails** (tharbad's own agent breaks): tharbad's logs stop
  arriving via fluent-bit. Revert just tharbad's agent flip; the
  receiver stack (vmsingle/vmauth/etc.) keeps running. Other hosts
  unaffected.
- **Phase 4 fails mid-zone** (some hosts pushing, some not): the
  half-migrated state is fine — pushed hosts land in vmsingle, scraped
  hosts (none, since Prometheus has no remaining scrape targets after
  Phase 0 firewall changes) land nowhere. To unwind a specific host,
  flip `fluent-bit-agent.enable = false` and accept it has no logs
  until the issue is resolved (matches today's broken-promtail state).
- **Phase 5 fails** (Prometheus removal triggers an issue): Phase 5 is
  pure deletion; the only failure mode is "we deleted Prometheus and
  needed historical data." Mitigation: snapshot
  `/var/lib/prometheus2` to long-term storage before the Phase 5
  deploy, retain for the post-Phase-5 cooldown window.

The single fundamental-failure scenario the plan can't cleanly unwind
is "vmauth/vmagent label-binding turns out to be wrong after Phase 4"
— but Phase 1's spoof test plus Phase 2's canary specifically gate
that risk before the fleet is touched.

### Phase C — VictoriaLogs fast-follow (deferred)

After Phase 5 dust settles (~2 weeks of stable VM-receiver operation),
re-evaluate swapping Loki → VictoriaLogs:

- Single query language family (LogsQL is closer to MetricsQL than LogQL is).
- One operational model for all observability storage.
- VictoriaLogs is younger; wait until Phase 5 has demonstrated the
  VM-side ergonomics are good before extending to logs.
- Migration is mostly the receiver: rewrite the ruler queries
  (LogQL → LogsQL), point fluent-bit's output at VL instead of Loki,
  run both in parallel during migration window.

Not in this plan's scope. Captured here so it's not forgotten.

---

## Risks & mitigations

| Risk                                                                                                                                                            | Mitigation                                                                                                                                                                                                                                                     |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| PromQL→MetricsQL semantic drift breaks an alert silently.                                                                                                       | Phase 1 explicitly validates every rewritten rule on vmalert before Phase 2. Spot-check `rate()`, `last_over_time()`, and `absent_over_time()` semantics specifically.                                                                                         |
| fluent-bit's `prometheus_scrape` against loopback node_exporter has higher latency than direct collector input would.                                           | Acceptable. 15s scrape interval on loopback is fast and reliable; latency budget is dominated by network push to tharbad, not local scrape.                                                                                                                    |
| Bearer token leaked from one host → attacker can push as any host?                                                                                              | No — vmagent pins the `host` label per token-derived identity. A leaked liberl token can only push as liberl. Other hosts are unaffected. Rotation is one-host scope.                                                                                          |
| vmauth or vmagent misconfigured → all pushes rejected → fleet-wide observability outage.                                                                        | Phase 1 validates each component against manual test pushes before any host depends on them. Phase 2 (liberl) is the second gate.                                                                                                                              |
| `auto_kubernetes_labels` or other fluent-bit defaults add unintended labels that break query selectors.                                                         | Explicit allow-list of labels via `label_keys`. Verify the label set in Loki/vmsingle directly during Phase 2.                                                                                                                                                 |
| Per-host token sops files balloon the secrets layout.                                                                                                           | Each host's secrets file gets one new entry (`observability-token`). Tharbad's secrets file gets a 16-entry token map. Manageable.                                                                                                                             |
| Black-box probes don't provide useful "why" detail when they fail.                                                                                              | Acceptable — black-box is the up/down signal. The "why" comes from logs (the host's logs were arriving up to T-now and stopped) and from the `MetricsStale` divergence.                                                                                        |
| Fluent-bit DynamicUser breaks `/var/lib/fluent-bit` persistence path.                                                                                           | Verify state path on running unit during Phase 0. Module should explicitly set `User=fluent-bit` + `StateDirectory=fluent-bit` if DynamicUser interacts badly with the persistence layout.                                                                     |
| htpasswd generation from sops requires bcrypt — extra build-time tooling.                                                                                       | `pkgs.apacheHttpd` provides `htpasswd`. Alternative: pre-hash tokens at token-generation time and store the hash directly in tharbad's sops file (avoids build-time hashing).                                                                                  |
| Receiver-side label-binding mechanism turns out to be subtler than expected (Option A doesn't override, Option B's path-based relabel doesn't apply at ingest). | Phase 0 explicitly tests A then B then C; first one that works is selected before any other Phase 0 work proceeds. Worst case adds vmagent or per-tenant config but doesn't block the migration.                                                               |
| Loki label cardinality from promoting `unit`/`comm`/`priority` exceeds Loki's comfort zone.                                                                     | Add `loki_ingester_streams` and `loki_ingester_chunks_stored_total` to the Phase 2 monitoring checklist. If problematic, narrow to `unit` only and rewrite `SudoFailure` / `HighPriorityLogs` ruler queries to use content filters instead of label selectors. |

---

## Open questions

1. **Receiver-side label binding: which option (A/B/C)?** Resolved
   during Phase 0 by testing in order — A (vmsingle `extra_label` URL
   query overrides incoming label), B (vmauth → vmagent with
   path-based relabel), C (per-identity vmagent). The architecture
   diagram and config sketches assume A succeeds; if B or C is
   selected, vmagent re-enters the receiver chain and Phase 1 services
   list expands.

2. **`fluent-bit_metrics` self-monitoring scope.** Worth scraping at
   30s for fleet visibility into agent health, or overkill? Lean
   **keep** — small overhead, useful when debugging push pipeline issues.

3. **Loki label cardinality with all three of `unit`/`comm`/`priority`
   promoted to labels.** May be fine at our scale; may not. Resolved
   empirically during Phase 2 by watching Loki stream count.

---

## Out of scope (deliberately)

- Replacing Loki with VictoriaLogs — captured as Phase C fast-follow.
- Replacing Alertmanager — works, no benefit to swapping.
- Replacing ntfy — works.
- Adding traces (OTLP). Fluent-bit and VM both support it; we have no
  use case yet. Add when there's something to trace.
- Service-specific exporters listed in `metrics-alerting-plan.md` Phase 4
  (unbound, kea, nginx, nftables) — those add as `extraInputs` post-migration
  using the same `prometheus_scrape` pattern liberl uses. All bound to
  loopback per the new convention.
- mTLS on push endpoints — bearer tokens cover the threat model at lower
  cost; same calculus as the rejected-mTLS-on-Loki decision in the
  existing metrics-alerting-plan.

---

## File touchpoints

```
flake.nix                                              [MOD]   commonModules: add fluent-bit-agent, keep node-exporter-client
modules/fluent-bit-agent/default.nix                   [NEW]   logs + metrics shipper
modules/node-exporter-client/default.nix               [MOD]   bind 127.0.0.1, drop firewall opening
modules/promtail-client/default.nix                    [DEL]   in Phase 5

hosts/calvard/microvm/guests/tharbad/modules/
  victoriametrics.nix                                  [NEW]   vmsingle + vmagent + vmauth + vmalert
  blackbox.nix                                         [NEW]   blackbox_exporter (loopback)
  fluent-bit.nix                                       [NEW]   tharbad's own agent
  loki.nix                                             [MOD]   nginx basic-auth on push location
  alertmanager.nix                                     [MOD]   rule list rewrite (push semantics)
  perses.nix                                           [MOD]   datasource → vmsingle
  prometheus.nix                                       [DEL]   in Phase 5

hosts/calvard/microvm/guests/tharbad/secrets/
  host-tokens.yaml                                     [NEW]   16-entry token map (server side)
  secrets.yaml                                         [MOD]   add observability-token

# Each of the 16 hosts:
hosts/<host>/.../default.nix                           [MOD]   promtail-client.enable → fluent-bit-agent.enable + authTokenFile
hosts/<host>/.../sops.nix or secrets.yaml              [MOD]   add observability-token (host's own copy)

llm-notes/blocked/metrics-alerting-plan.md                 [MOD]   mark Phase 1-4 superseded; point to this plan
docs/security-audit-report.md                          [MOD]   update promtail/node_exporter references
```
