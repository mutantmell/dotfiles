# Loki → VictoriaLogs Migration

> **Status:** Planning. Phase C fast-follow from
> `llm-notes/done/observability-stack-migration.md` — the deferred swap of the
> log store now that the VictoriaMetrics-on-receiver stack is in steady state
> and Perses 0.53.1 ships first-class VictoriaLogs plugins.
>
> **Supersedes:** the "Phase C — VictoriaLogs fast-follow (deferred)" section
> of `observability-stack-migration.md` (now scheduled, not deferred).

---

## Motivation

The deferred-decision rationale recorded in the parent plan has flipped:

- **Perses VictoriaLogs plugin is now upstream.** v0.53.0-beta.2 added a
  dedicated `VictoriaLogsDatasource`, a `VictoriaLogs Field Values Variable`,
  a `VictoriaLogs Log Query` panel type, and a `VictoriaLogs Time Series
Query` panel type for stats queries. We're on Perses 0.53.1 already. The
  one ecosystem gap that justified "wait" is closed.
- **VM-on-receiver stack has been stable.** vmsingle + vmauth + vmalert +
  fluent-bit fleet-wide is in steady operation; the ergonomics are good and
  the operator confidence the parent plan asked for has been built.
- **Loki cardinality is a known live risk.** The parent plan's risk table
  (line 918) flagged the `unit`/`comm`/`priority` label promotion as
  potentially exceeding Loki's comfort zone, mitigated by watching stream
  counts. VictoriaLogs has no stream/label dichotomy — all fields are
  queryable without becoming partition keys. The risk goes away rather than
  being monitored around.
- **Tharbad RAM headroom.** Tharbad is a 2 GB microVM running Perses,
  vmsingle, vmauth, vmalert, Alertmanager, ntfy, nginx, Loki, and
  fluent-bit. VictoriaLogs is materially smaller per ingest rate than Loki
  in published benchmarks (column-oriented + ZSTD vs. chunk store +
  boltdb-shipper index). Reclaiming the Loki footprint is worth it.

License is Apache 2.0 — matches stated preference, same as the VM stack.

---

## Stack delta

| Layer            | Before                             | After                                                                                                |
| ---------------- | ---------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Log store        | Loki (3101, behind nginx :3100)    | VictoriaLogs (9428, behind nginx :3100 — same external port, same mTLS gating)                       |
| Log ingest path  | nginx → `/loki/api/v1/push` → Loki | nginx → `/insert/loki/api/v1/push` → VictoriaLogs (Loki-protocol-compatible endpoint)                |
| Log ruler        | Loki ruler (built-in)              | Second vmalert instance with `-rule.defaultRuleType=vlogs`, pointed at VL stats API                  |
| Agent log output | fluent-bit `loki` output → :3100   | fluent-bit `loki` output → :3100, **unchanged** (URL path differs at the nginx vhost, not the agent) |
| Perses log panel | `LokiDatasource`                   | `VictoriaLogsDatasource` (new plugin in Perses 0.53.x)                                               |
| Notifications    | Alertmanager → ntfy (unchanged)    | Alertmanager → ntfy (unchanged)                                                                      |

### What this preserves

- **Fleet agent config is touched once, in the nginx vhost on tharbad — not
  on the 16 agents.** `fluent-bit-agent.lokiUrl` still points at
  `https://tharbad.internal:3100/loki/api/v1/push`. nginx on tharbad maps
  that path to VL's Loki-compat insert endpoint internally. No per-host
  redeploy needed for the storage swap itself.
- **mTLS posture.** Existing ingress.nix mTLS gating on :3100 stays as-is;
  client cert verification and the `$ssl_client_s_dn_cn` audit trail
  continue to work. The Loki-side "best-effort label binding" caveat
  (`hosts/calvard/microvm/guests/tharbad/modules/ingress.nix:46-57`) carries
  over verbatim — VL's Loki-compat endpoint inherits the same property,
  since the `host` label still sits inside the protobuf push body.
- **Alertmanager + ntfy + Perses + fluent-bit modules.** Unchanged.

### What changes

- One new tharbad module: `victorialogs.nix` (storage + ruler instance).
- `loki.nix` deleted at the end of Phase 4.
- `ingress.nix`'s `tharbad-loki-push` vhost: `proxy_pass` target swaps from
  Loki to VL during cutover. Single-line change.
- `perses.nix`: `LokiDatasource` → `VictoriaLogsDatasource`; dashboards
  referencing Loki ported.
- 5 ruler queries rewritten from LogQL to LogsQL with `stats` pipe.

---

## Architecture (delta)

The architecture diagram in `observability-stack-migration.md` stays valid
everywhere except the "Loki (3101, local)" box. Replace it with:

```
┌────────────────────────────────────────────────────────────────────┐
│ tharbad (management zone)                                          │
│                                                                    │
│  nginx :3100 (mTLS)                                                │
│    │  proxy_pass to /insert/loki/api/v1/push                       │
│    ▼                                                               │
│  VictoriaLogs (9428, 127.0.0.1)                                    │
│    • column-oriented store                                         │
│    • LogsQL query API                                              │
│    • stats_query / stats_query_range API for vmalert               │
│    │                                                               │
│    ├──▶ vmalert-vlogs (local)                                      │
│    │     -datasource.url=http://127.0.0.1:9428                     │
│    │     -rule.defaultRuleType=vlogs                               │
│    │     -notifier.url=http://127.0.0.1:9093  (Alertmanager)       │
│    │                                                               │
│    └──▶ Perses VictoriaLogsDatasource (read-only query)            │
└────────────────────────────────────────────────────────────────────┘
```

Two vmalert instances run side by side: the existing one (Prometheus-type
rules against vmsingle) and a new one (`vlogs`-type rules against
VictoriaLogs). They share Alertmanager. Splitting them avoids any
per-group datasource ambiguity at the cost of ~30 MB RSS.

---

## Module: `hosts/calvard/microvm/guests/tharbad/modules/victorialogs.nix` (new)

Skeleton:

```nix
{config, pkgs, lib, ...}: let
  vlPort = 9428;
  vlAlertPort = 8881;  # distinct from existing vmalert (likely 8880)

  securityRules = pkgs.writeText "vlogs-security-alerts.yaml" (builtins.toJSON {
    groups = [
      {
        name = "security";
        type = "vlogs";
        interval = "1m";
        rules = [
          {
            alert = "SSHBruteForce";
            expr = ''unit:"sshd.service" AND (_msg:"Failed password" OR _msg:"authentication failure" OR _msg:"Invalid user" OR _msg:"Connection closed by authenticating user") | stats by (host) count() as failures | filter failures:>10'';
            "for" = "0m";
            labels = { severity = "warning"; category = "security"; };
            annotations.summary = "{{ $labels.host }}: more than 10 SSH auth failures in 5 minutes";
          }
          # ... other rewritten rules (see ruler table below)
        ];
      }
      {
        name = "log-health";
        type = "vlogs";
        interval = "1m";
        rules = [
          {
            alert = "FleetLogGap";
            expr = ''job:"systemd-journal" | stats by (host) count() as lines | stats count() as hosts | filter hosts:<16'';
            "for" = "15m";
            labels.severity = "warning";
            annotations.summary = "Fewer than 16 hosts shipping logs to VictoriaLogs";
          }
        ];
      }
    ];
  });
in {
  services.victorialogs = {
    enable = true;
    listenAddress = "127.0.0.1:${toString vlPort}";
    extraOptions = [
      "-retentionPeriod=30d"
      "-search.maxQueryDuration=30s"
    ];
  };

  systemd.services.vmalert-vlogs = {
    description = "vmalert (VictoriaLogs rules)";
    wantedBy = ["multi-user.target"];
    after = ["network.target" "victorialogs.service"];
    serviceConfig = {
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.victoriametrics}/bin/vmalert"
        "-datasource.url=http://127.0.0.1:${toString vlPort}"
        "-notifier.url=http://127.0.0.1:9093"
        "-rule.defaultRuleType=vlogs"
        "-rule=${securityRules}"
        "-httpListenAddr=127.0.0.1:${toString vlAlertPort}"
      ];
      DynamicUser = true;
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  environment.persistence."/persist".directories = [
    { directory = "/var/lib/victorialogs"; user = "victorialogs"; group = "victorialogs"; }
  ];
}
```

Notes:

- `services.victorialogs` uses `DynamicUser=true` (per the nixpkgs module —
  `nixos/modules/services/databases/victorialogs.nix`). Persist directory
  has to match `StateDirectory=victorialogs` ownership; verify ownership
  flags during Phase 0.
- Retention matches Loki's current 30 d.
- `vmalert-vlogs` is a separate systemd unit from the existing vmalert.
  Both point at the same Alertmanager. Keep their `httpListenAddr` ports
  distinct.

---

## Ingress change (`ingress.nix`)

Single line in the `tharbad-loki-push` vhost during cutover:

```nix
# Before (Loki):
locations."/loki/api/v1/push" = {
  proxyPass = "http://127.0.0.1:${toString lokiPort}";
};

# After (VictoriaLogs Loki-compat):
locations."/loki/api/v1/push" = {
  extraConfig = ''
    proxy_pass http://127.0.0.1:9428/insert/loki/api/v1/push;
  '';
};
```

The external listen address, mTLS verification, ACME cert, and the audit
property (`$ssl_client_s_dn_cn` in nginx access logs) stay identical.

**Optionally**, expose a second internal-only location for VL's native
query API (`/select/logsql/query`) for Perses to use. The Perses
datasource can run in "Direct access" mode if it shares the network
namespace (it does — both run on tharbad), so it can hit
`http://127.0.0.1:9428` without going through nginx.

---

## Perses datasource swap (`perses.nix`)

Replace the `LokiDatasource` block (currently at `perses.nix:30-39`):

```nix
vlDatasource = yaml "global-victorialogs.yaml" {
  kind = "GlobalDatasource";
  metadata.name = "victorialogs";
  spec = {
    plugin = {
      kind = "VictoriaLogsDatasource";
      spec = {
        directUrl = "http://localhost:9428";
      };
    };
  };
};
```

Drop `lokiDatasource` from the datasources file list once dashboards have
been ported.

### Dashboard port

Audit dashboards in `hosts/calvard/microvm/guests/tharbad/modules/dashboards/`
for any references to `datasource: loki`. Rewrite their queries:

- Loki `{unit="X"} |~ "pattern"` → VL `unit:"X" AND _msg:~"pattern"` (or
  the equivalent LogsQL phrase filter).
- Loki `rate({...}[5m])` for timeseries → VL `... | stats by (...)
count_over_time(5m)` panel via the `VictoriaLogs Time Series Query`
  type.
- Loki table → VL `VictoriaLogs Log Query` panel type.

---

## Ruler rewrite (LogQL → LogsQL)

| Alert (existing Loki rule)                                       | LogsQL rewrite (`type: vlogs`, paired with `stats`/`filter`)                                                                                                                                                                | Notes                                                                                                            |
| ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `SSHBruteForce` (>10 sshd failures/5m per host)                  | `unit:"sshd.service" AND (_msg:"Failed password" OR _msg:"authentication failure" OR _msg:"Invalid user" OR _msg:"Connection closed by authenticating user") \| stats by (host) count() as failures \| filter failures:>10` | Verify which side of LogsQL phrase grammar VL is on; use `_msg:~"..."` regex form if literal phrase match misses |
| `SSHBruteForceExtreme` (>50 sshd failures/5m per host, critical) | Same as above with `filter failures:>50`                                                                                                                                                                                    | Group `interval: 5m`                                                                                             |
| `SudoFailure` (any failed sudo in 10m per host)                  | `comm:"sudo" AND (_msg:"authentication failure" OR _msg:"incorrect password") \| stats by (host) count() as failures \| filter failures:>0`                                                                                 | Group `interval: 10m`                                                                                            |
| `HighPriorityLogs` (priority 0–2 in 5m per host)                 | `priority:in("0","1","2") \| stats by (host) count() as critical_logs \| filter critical_logs:>0`                                                                                                                           | Confirm field stays string in VL — if numeric, drop quotes                                                       |
| `FleetLogGap` (<16 hosts shipping in 15m)                        | `job:"systemd-journal" \| stats by (host) count() as lines \| stats count() as hosts \| filter hosts:<16`                                                                                                                   | Threshold matches the constant in `loki.nix:11`; keep in sync with `expectedHosts`                               |

Each rewritten rule needs an empirical spot-check against real ingested
data during Phase 2 before promoting. The LogsQL grammar around quoted
phrases vs. regex (`:` vs `:~`) is the most likely place to bite.

---

## Migration phases

The plan is one architecture change; the deploy stages to bound risk.

### Phase 0 — Module preparation (no deploy)

- [ ] Write `hosts/calvard/microvm/guests/tharbad/modules/victorialogs.nix`
      (storage + vmalert-vlogs unit) per skeleton above.
- [ ] Stage the `ingress.nix` change as a commented-out alternative block
      so cutover is a single uncomment + Loki proxy_pass removal.
- [ ] Write the 5 rewritten LogsQL rules; keep them in a parallel rules
      file (not promoted yet).
- [ ] Add the `victorialogs.nix` import to tharbad's `default.nix` (module
      enabled, but not yet receiving traffic — bound to 127.0.0.1 only).
- [ ] Verify `./scripts/run-checks.sh` passes — VL module evaluates and
      tharbad builds.

### Phase 1 — Stand up VictoriaLogs alongside Loki

- [ ] Deploy tharbad. VL runs on 127.0.0.1:9428; Loki still authoritative
      on :3101; nginx :3100 still routes to Loki.
- [ ] Smoke test: `curl` push a synthetic JSON line to
      `http://127.0.0.1:9428/insert/jsonline` from tharbad, query back via
      `/select/logsql/query`. Verify storage roundtrip.
- [ ] Smoke test: `curl` push a Loki-protobuf payload to
      `http://127.0.0.1:9428/insert/loki/api/v1/push`, verify it lands.
      This is the Phase 2 gate — proves the Loki-compat endpoint works.
- [ ] vmalert-vlogs running, evaluating rules — they all fire trivially
      (no data yet); silence them for the duration of Phase 1.
- [ ] Tharbad RAM headroom check: VL footprint should be modest, but
      confirm before adding ingest traffic.

### Phase 2 — Cut nginx ingress to VL (dual-store window opens)

This is the operationally interesting step. Two options for the parallel
window:

**Option A: Hard cutover.** Flip the nginx `proxy_pass` from Loki to VL
in one redeploy. From that point forward, new logs land only in VL.
Loki still holds 30 d of history for grep-back. Cleanest, but no
ruler-parity verification window because Loki ruler stops getting fresh
data.

**Option B: Parallel ingest via nginx `mirror`.** Use nginx's `mirror`
directive on the `/loki/api/v1/push` location to fan a copy of the
incoming push to both Loki (existing proxy_pass) and VL's
`/insert/loki/api/v1/push`. Both stores receive the same data for the
parallel window. Loki ruler keeps firing on its data, vmalert-vlogs
fires on VL's data, alerts can be compared.

**Recommendation: Option B.** The cost is one nginx mirror directive and
double the write IO on tharbad for the parallel window. The benefit is
ruler parity validation against live traffic before deleting Loki —
which is the part most likely to surface a LogsQL semantic surprise.

- [ ] Add `mirror /vl-push; mirror_request_body on;` to the push location.
      Add an internal-only `location /vl-push` that proxies to
      `http://127.0.0.1:9428/insert/loki/api/v1/push`.
- [ ] Deploy. Verify both stores receive logs for a representative
      sample of hosts.
- [ ] Enable vmalert-vlogs un-silenced. Run for at least 24 h.
- [ ] **Ruler parity check.** Compare firing behavior: does
      vmalert-vlogs fire `SSHBruteForce` on the same events the Loki
      ruler does? Triage divergences as either (a) LogsQL semantic gaps
      to fix in the rewrite or (b) acceptable behavioral differences.
- [ ] Audit Perses dashboards rendering correctly off VL datasource —
      port any that break.

### Phase 3 — Decommission Loki ruler

Once vmalert-vlogs has run at parity for ~1 week:

- [ ] Delete the `ruler` block from `loki.nix` (rule files + tmpfiles).
- [ ] Redeploy tharbad. Loki keeps ingesting and serving queries; only
      the rule evaluation is removed.

This step is reversible — re-adding the ruler is a config rollback.

### Phase 4 — Make VL authoritative; drop Loki ingest

- [ ] Remove the nginx `mirror` directive; flip `proxy_pass` from Loki to
      VL. Loki stops receiving new data.
- [ ] Keep Loki running, read-only for historical queries, until
      retention expires (~30 d from last ingest).
- [ ] Update `perses.nix` to point dashboards at the VictoriaLogs
      datasource exclusively; remove the Loki datasource definition.

### Phase 5 — Delete Loki

After Loki's last ingested chunk has aged out (~30 d post-Phase 4):

- [ ] Snapshot `/var/lib/loki` to long-term storage if any historical
      log access might still matter post-deletion.
- [ ] Delete `hosts/calvard/microvm/guests/tharbad/modules/loki.nix`.
- [ ] Remove `loki` import + persistence entry from `default.nix`.
- [ ] Remove `/var/lib/loki` from impermanence directories.
- [ ] Deploy. Reclaim the persist volume space.
- [ ] Update `llm-notes/wip/metrics-alerting-plan.md` to point at VL.
- [ ] Move this plan from `wip/` to `done/`.

### Rollback

- **Phase 1 fails** (VL won't start, breaks tharbad): revert the
  `victorialogs.nix` import. Nothing else has changed.
- **Phase 2 fails** (Loki-compat endpoint behaves oddly, mirror corrupts
  payloads, ingest rate kills VL): remove the mirror directive. Loki
  is still authoritative; vmalert-vlogs goes back to no-op.
- **Phase 3 fails** (vmalert-vlogs alerts are wrong): re-enable the Loki
  ruler. Both ruler systems fire concurrently until the LogsQL queries
  are fixed.
- **Phase 4 fails** (Perses can't query VL well enough for the
  dashboards we care about): keep the mirror in place; flip dashboards
  back to the Loki datasource; investigate.
- **Phase 5 is irreversible** — only run it after the post-Phase-4
  cooldown.

The single unrecoverable failure mode is "VL turns out to be a bad fit
for our log shape after the Loki retention has expired in Phase 5." The
parallel window in Phase 2 + ~30 d of dual-store coexistence in Phase 4
is the gate against that.

---

## Risks & mitigations

| Risk                                                                                                                                               | Mitigation                                                                                                                                                                                                                                       |
| -------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| LogsQL semantic surprise — a rewritten rule doesn't fire on the same events the LogQL rule does.                                                   | Phase 2 ruler parity window catches this against live data. Five rules total; each gets a manual spot-check.                                                                                                                                     |
| VictoriaLogs Loki-compat endpoint diverges from real Loki in some payload detail.                                                                  | Phase 1 smoke test pushes a synthetic Loki-protobuf payload and verifies it stores correctly. Phase 2 mirror catches any real-traffic divergence before Loki is decommissioned.                                                                  |
| Perses VictoriaLogs plugin (new in 0.53.0-beta.2) has rough edges that don't surface until specific dashboards exercise it.                        | Phase 2 dashboard audit before flipping the datasource. Keep the Loki datasource defined alongside until Phase 4.                                                                                                                                |
| Tharbad runs out of RAM during the dual-store mirror window.                                                                                       | VL is expected to be smaller than Loki, not larger. But monitor `node_memory_*` on tharbad through Phase 2; abort early if pressure shows.                                                                                                       |
| `priority` field type drift (was string under Loki labels; LogsQL may treat it as int).                                                            | Spot-check `HighPriorityLogs` against synthetic data with various priority values during Phase 2; adjust quoting.                                                                                                                                |
| Existing fluent-bit `label_keys = "$unit,$comm,$priority,$job,$host"` directive (per `modules/fluent-bit-agent/default.nix:177`) is Loki-specific. | The `loki` output plugin in fluent-bit produces Loki-protocol payloads regardless of receiver. The `label_keys` directive shapes the labels in the protobuf body; VL's Loki-compat endpoint reads those same labels as fields. No change needed. |
| Two vmalert instances confuse the Alertmanager grouping (alerts from different sources get re-grouped unexpectedly).                               | Both instances send to the same Alertmanager; Alertmanager's `group_by: [alertname, instance]` is unaffected by which vmalert emitted the alert. Verify in Phase 2.                                                                              |
| Loki-compat endpoint loses some field information (e.g., LogQL `                                                                                   | json` parse semantics differ from VL).                                                                                                                                                                                                           | Out of scope — we don't use parsed JSON pipelines today. Logs are systemd-journal lines; the labels we care about (`unit`, `comm`, `priority`, `job`, `host`) are set on the producer side by fluent-bit's `modify` filter. |
| Token/auth model differences (VL has its own `-httpAuth.username` flag; we use nginx mTLS instead).                                                | We bypass VL's built-in auth entirely — nginx terminates and verifies; VL listens on 127.0.0.1. The nixpkgs VL module's `basicAuth*` options stay unset. Same posture as the current Loki setup.                                                 |

---

## Rejected alternatives

### Switch fluent-bit's `loki` output to VL's native JSON insert

Could change every host's `fluent-bit-agent.lokiUrl` to point at VL's
`/insert/jsonline` endpoint with a custom JSON line_format. Avoids the
Loki-compat shim in nginx.

Rejected because:

- 16 agent redeploys for a storage swap that can be a 1-line nginx change.
- The Loki-compat endpoint is a documented, supported VL feature; not a
  hack. Using it preserves the agent's `loki` output, which is
  battle-tested, instead of switching to fluent-bit's `http` output with
  hand-rolled formatting.
- mTLS plumbing in `fluent-bit-agent` already targets the `loki` output's
  TLS fields; redoing it for `http` output is incidental work.

Revisit if VL's Loki-compat endpoint ever lags behind native ingest in a
way that matters.

### Use VL's built-in basic auth instead of keeping nginx mTLS

VL's nixpkgs module supports `basicAuthUsername` + `basicAuthPasswordFile`.
We could drop the nginx mTLS layer and have agents authenticate to VL
directly with bearer tokens.

Rejected because:

- The mTLS-on-nginx pattern is already established for `tharbad-loki-push`
  and `tharbad-metrics-push`. Consistency matters more than per-store auth
  options.
- mTLS gives audit identity via `$ssl_client_s_dn_cn` in nginx access
  logs; basic auth doesn't, unless we add custom logging.
- The fleet already has client certs issued; no new cred infrastructure.

### Cluster VL (`vlinsert`/`vlselect`/`vlstorage`)

VL supports a sharded cluster mode for scale-out. We don't need it at
fleet=16; the single-binary deployment matches our scale and matches
how the parent plan sized vmsingle. Cluster mode is a future
consideration only if we cross into multi-node observability infra
(which would presumably also push vmsingle to vmcluster).

---

## Open questions

1. **LogsQL phrase grammar.** Does `_msg:"Failed password"` do exact-substring
   match, token match, or something else? The rewrites assume substring
   semantics analogous to LogQL's `|~ "..."`. Resolved by Phase 2 spot-check;
   the alternative is `_msg:~"Failed password"` regex form, easy to flip.

2. **vmalert single-binary vs. two-instance.** Could we run one vmalert with
   per-group `type: prometheus` and `type: vlogs`, sharing one
   `-datasource.url`? Docs are ambiguous on URL routing in the mixed-type
   case. The plan errs toward two instances for clarity; revisit once one
   has been running and the routing semantics are understood, possibly
   consolidating in a follow-up.

3. **VL retention vs. archival.** Loki's plan referenced a possible future
   S3-via-Garage backend for long retention. VL's storage layer doesn't have
   an analogous S3 backend in the same form (its retention is local, with
   downsampling/compaction handled internally). If long-term log retention
   ever becomes a goal, this is a re-evaluation point.

---

## Out of scope (deliberately)

- Replacing Alertmanager — works, no benefit.
- Replacing ntfy — works.
- Adding OTLP traces — captured in parent plan's out-of-scope.
- Adding service-specific log parsers (e.g., audit log enrichment).
  Today's logs are systemd-journal lines; add structured parsers when
  there's a specific use case.
- mTLS-direct on VL (skipping nginx) — see rejected alternatives.

---

## File touchpoints

```
hosts/calvard/microvm/guests/tharbad/modules/
  victorialogs.nix                              [NEW]   VL + vmalert-vlogs
  ingress.nix                                   [MOD]   proxy_pass swap (Phase 2/4)
  perses.nix                                    [MOD]   LokiDatasource → VictoriaLogsDatasource
  loki.nix                                      [MOD]   drop ruler block (Phase 3)
  loki.nix                                      [DEL]   in Phase 5
  default.nix                                   [MOD]   import victorialogs.nix; drop loki.nix in Phase 5
  dashboards/                                   [MOD]   port any LokiDatasource references

llm-notes/wip/metrics-alerting-plan.md          [MOD]   final reference swap in Phase 5
llm-notes/wip/loki-to-victorialogs.md           [MOV]   → done/ at end of Phase 5
```

No fleet-wide changes. All 16 agents stay on
`fluent-bit-agent.lokiUrl = "https://tharbad.internal:3100/loki/api/v1/push"`
through the entire migration.
