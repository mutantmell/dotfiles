# Perses Dashboard Overhaul

> **Status:** Planning (2026-05-12). Sub-plan of `metrics-alerting-plan.md`
> Phase 4 ("Review existing Perses dashboards, identify coverage gaps").

## Background

Dashboards in `hosts/calvard/microvm/guests/tharbad/modules/dashboards/` were
written against an assumed pull-based Prometheus scrape model, but the active
metrics path is push-based via fluent-bit:

```
each host: node_exporter (127.0.0.1:9100)
       → fluent-bit prometheus_scrape (local)
       → fluent-bit prometheus_remote_write (host label added on push)
       → vmsingle (localhost:8428 on tharbad)
       → Perses queries vmsingle (perses.nix:24, datasource url localhost:8428)
       → vmalert evaluates against vmsingle
```

Consequences:

- `instance` label is `127.0.0.1:<port>` for **every** host (each fluent-bit
  scrapes locally) — useless as a host differentiator.
- `host` label is populated by fluent-bit's `add_label` (`fluent-bit-agent/default.nix:181`).
- Alert rules already use `$labels.host` — they're aligned with the active
  scheme. Only dashboards are out of date.
- `job` label semantics are unclear in this push model — needs empirical
  verification (fluent-bit `prometheus_scrape` may not synthesize a `job` label
  the way Prometheus's scrape config does).

The scrape config in `tharbad/modules/prometheus.nix` is dead-code-ish for
fleet metrics: it scrapes `${name}.internal:9100`, but node-exporter binds
loopback only on remote hosts. Whether to keep, repurpose, or remove it is
a separate cleanup question (Phase 4).

## Phase 1 — Empirical label audit (DONE 2026-05-12)

Audit run on tharbad against `localhost:8428`. Findings:

**Active labels:**
- `host` — 13 values, the canonical host differentiator: basel, bose,
  calvard, creil, erebonia, langport, liberl, messeldam, oracion,
  ravennue, roer, tharbad, zeiss.
- `instance` — **zero values** (label exists in the index but no series
  populates it). Source: fluent-bit `prometheus_scrape` doesn't emit
  `instance` the way Prometheus does. This is the root cause of
  `node-overview`'s broken host dropdown.
- `job` — **zero values**. Same root cause. Means
  `prometheus-overview.yaml` (`job="prometheus"`), `loki-overview.yaml`
  (`job="loki"`), and `zfs-overview.yaml` (`job="$zfs_job"`) all return
  empty data — silently broken.
- `nodename` — populated (used by `log-viewer.yaml` for systemd-journal
  records via Loki — separate path, fine as-is).

**`up` metric doesn't exist.** fluent-bit `prometheus_scrape` doesn't
synthesize `up` like a Prometheus scraper does. Liveness checks must use
`time() - timestamp(node_uname_info) < 120` (the pattern already in
`MetricsStale` alert at `victoriametrics.nix:19-21`).

**Representative series confirmations:**
- `node_uname_info{host=...,nodename=...,release=...}` — one per host, all 13 hosts.
- `zfs_pool_health{host="liberl",pool="data"}` — `host` is the right label, not `job`.
- `loki_build_info{host="tharbad",version="3.7.1",...}` — Loki self-metrics carry `host=tharbad`.
- `vm_app_version{host="tharbad"}`, `vm_rows_inserted_total{type=...,host="tharbad"}` — vmsingle self-metrics carry `host=tharbad`, plus per-protocol `type` for inserts.

**Bonus bug (separate from dashboard work):** `probe_success` collapses to
a single `{host="tharbad"}` series — see
`llm-notes/wip/blackbox-target-label-bug.md`.

**Other useful labels surfaced** (potential for future enrichment):
`role`, `zone`, `tenant`. Out of scope for this overhaul.

**Conclusions for Phase 2:**
- ALL dashboard `{instance="..."}` / `{job="..."}` filters → `{host="..."}`.
- ALL `labelName: instance` / `labelName: job` template variables → `labelName: host`.
- `prometheus-overview.yaml` is obsolete (Prometheus removed in Phase 0).
  Delete it; if vmsingle-self visibility is desired later, write a fresh
  `vmsingle-overview.yaml`.
- `loki-overview.yaml` panels that use `job="loki"` → `host="tharbad"`
  (tharbad is the only Loki).
- Liveness panels: replace `up`-style queries with
  `time() - timestamp(node_uname_info) < 120`.

## Phase 2 — Fix existing dashboards (DONE 2026-05-12)

- [x] **2.1 `node-overview.yaml`** — rewritten
  - Variable: `name: host`, `labelName: host`, matcher `node_uname_info`,
    `allowMultiple: true`, `allowAllValue: true`.
  - All queries switched to `{host=~"$host"}`.
  - `seriesNameFormat: "{{host}}"` (or compound for disk/network).
  - Memory % converted from GaugeChart → TimeSeriesChart for fleet comparison.
- [x] **2.2 `zfs-overview.yaml`** — rewritten
  - Two variables (`zfs_job`, `smartctl_job`) collapsed into a single
    `host` variable, matcher `zfs_pool_health`, `allowMultiple: true`.
  - All queries switched from `{job="$..."}` to `{host=~"$host"}`.
  - All `seriesNameFormat` prefixed with `{{host}}` so multi-host views are
    legible (currently single-host since only liberl has ZFS, but ready).
- [x] **2.3 `prometheus-overview.yaml`** — DELETED (Prometheus removed in
      Phase 0; nothing to fix).
- [x] **2.4 `loki-overview.yaml`** — RSS panel removed
  - All `loki_*` metrics already carry `host=tharbad` and don't collide
    with anything; ingestion / latency / error panels work as-is.
  - `process_resident_memory_bytes{job="loki"}` was the only broken query;
    deleted the panel rather than refactor (no `service` label exists to
    disambiguate from vmsingle/alertmanager `process_*` series).
- [x] **2.5 `alertmanager-overview.yaml`** — left as-is; `alertmanager_*`
      metrics are unique to that binary and now flow via the new
      `host.metric.alertmanager` scrape added to `tharbad/modules/fluent-bit.nix`.
- [x] **2.6 `log-viewer.yaml`** — verified; `nodename` (from `node_uname_info`)
      and Loki's `host` label both populate per Phase 1 audit.

## Phase 3 — Fleet overview dashboard (DONE 2026-05-12)

- [x] **3.1** `fleet-overview.yaml` added with three rows:
  - **At a glance:** hosts up (count of `node_uname_info` series fresh within
    120s), hosts total, total firing alerts (`sum(ALERTS{alertstate="firing"})`),
    per-host liveness (`time() - timestamp(node_uname_info)`) with
    green/orange/red thresholds at 60s/120s.
  - **Resource Usage:** CPU%, Memory%, Max Filesystem%, Load Avg — all
    grouped `by (host)` with `{{host}}` series names so the legend gives a
    sortable per-host table.
  - **Alerts & Uptime:** `count by (host) (ALERTS{alertstate="firing"})` and
    `node_time_seconds - node_boot_time_seconds`.
- [x] **3.2** Lives in `./dashboards/`; auto-picked up by `perses.nix:99`.
- [ ] **3.3** Empirical check after deploy: confirm `ALERTS` series shape in
      vmsingle (vmalert is the producer — `victoriametrics.nix:134`). If
      `host` isn't a label vmalert preserves on `ALERTS`, the alerts-by-host
      panel will need an inner subquery or the alert rules will need a
      `host` label baked into their `expr`.

## Phase 0 — Remove dead `tharbad/modules/prometheus.nix` (DONE 2026-05-12)

Verified dead before removal:
- vmalert points at vmsingle (`victoriametrics.nix:134`), not Prometheus.
- Perses datasource points at vmsingle (`perses.nix:24`).
- No fleet host's egress rules permit scraping tharbad:9090.
- Tharbad's own fluent-bit (`fluent-bit.nix`) scrapes loki + vmsingle but
  does NOT scrape Prometheus on 9090.
- `services.prometheus.alertmanager` in `alertmanager.nix` is a separate
  binary that just shares the NixOS namespace — unaffected.

Changes made:
- Deleted `modules/prometheus.nix`.
- Removed import from `default.nix`.
- Moved `node-exporter-client.enable = true` into `modules/fluent-bit.nix`
  (preserves tharbad's own node_exporter, scraped locally by fluent-bit
  default `host.metric.node` input and pushed to vmsingle).
- `dashboards/prometheus-overview.yaml` now queries series that no longer
  exist (`prometheus_tsdb_*`, `process_resident_memory_bytes{job="prometheus"}`).
  Defer decision to Phase 2: delete or repurpose as `vmsingle-overview`.

**Operator follow-up after deploy:** orphaned state directory
`/var/lib/prometheus2` on tharbad — manual `rm -rf` after first successful
boot without the module.

## Out of scope

- Service-specific exporters (unbound/kea/nginx/nftables) — blocked on
  thebeyond hardware per parent plan.
- Firewall overview / DNS stats dashboards — depend on those exporters.
- Notification routing changes — separate concern.

## Open questions

- Should the variable be named `host` (matches the label) or `Host` (display)?
  Convention check across other dashboards.
- Should we standardize on a "host" template variable as a project-wide pattern
  (shared YAML fragment if Perses supports it)?
