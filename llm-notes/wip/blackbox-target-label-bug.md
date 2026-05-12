# Blackbox Probe Target Label Bug

> **Status:** Discovered 2026-05-12 during Perses dashboard label audit
> (`perses-dashboard-overhaul.md` Phase 1).

## Summary

`probe_success` returns ONE series — `{host="tharbad"}` — instead of 13 (one
per probed target). All 13 blackbox SSH probes clobber the same series, so
`HostUnreachable` (`expr = probe_success == 0`) fires for "any host down"
with no way to identify which host is unreachable.

## Root cause

`hosts/calvard/microvm/guests/tharbad/modules/fluent-bit.nix:22-28` defines a
`modify` filter that should add a `target` label per host:

```nix
blackboxFilters = map (host: {
  name = "modify";
  match = "host.metric.blackbox.${host}";
  add = ["target ${host}.internal:22"];
}) fleetHosts;
```

The intent: each `prometheus_scrape` input is tagged
`host.metric.blackbox.<hostname>`, and the matching `modify` filter adds a
`target` label that disambiguates the series. In practice the label is not
applied — the series collapses onto the single `host=tharbad` label that
fluent-bit's outer `add_label` adds to everything.

## Hypotheses to investigate

1. **`add` syntax mismatch** — the fluent-bit `modify` filter `Add` operation
   takes `KEY VALUE` as a single string. The Nix attribute `add = ["target
   ${host}.internal:22"]` may not render the way fluent-bit expects (e.g.,
   needs `Add` not `add`, or needs a different list shape).
2. **Order-of-operations** — `prometheus_remote_write` may serialize labels
   before the `modify` filter sees the record (fluent-bit metric pipelines
   are stricter than log pipelines about filter applicability).
3. **`prometheus_scrape` label semantics** — scraped Prometheus metrics may
   ignore record-level labels added by `modify` and only honor labels added
   via `add_label` on the output.

## Investigation steps

- [ ] Inspect rendered fluent-bit config on tharbad (`/etc/fluent-bit/...` or
      the systemd unit's ExecStart) and check the `[FILTER]` block for the
      blackbox modify entries.
- [ ] Confirm which key fluent-bit's `modify` filter expects (`Add` vs `add`,
      space- vs comma-separated).
- [ ] Try reproducing locally with a minimal fluent-bit config to determine
      whether `prometheus_scrape` → `modify` → `prometheus_remote_write`
      preserves filter-added labels.
- [ ] If `modify` fundamentally cannot add labels to scraped metric series,
      pivot to per-input `add_label` (output side) or run blackbox via a
      proper Prometheus `scrape_configs` that supports `__param_target`
      relabeling.

## Fix sketch (pending investigation)

The cleanest answer is probably to swap fluent-bit's `prometheus_scrape` for a
real Prometheus-style scrape config — vmsingle's `vmagent` (or
prometheus_remote_write with proper relabeling) handles the
`__param_target → target` relabel pattern natively. Worth weighing against
keeping fluent-bit as the only metrics shipper.

Alternative: drop blackbox entirely and rely on `node_uname_info` freshness
checks (already used by `MetricsStale` alert) — `node_exporter` itself is the
liveness signal we care about, and an SSH-port probe is mostly redundant.

## Impact

- `HostUnreachable` alert is currently low-signal (fires on any single host
  down without naming the host).
- No dashboard panel surfaces blackbox data today, so the visual impact is
  zero — this is purely an alerting fidelity issue.
- Not blocking dashboard overhaul; tracked separately.

## Out of scope

- Other blackbox modules (HTTP probes, etc.) — only TCP/SSH is wired today.
- Probe target list overhaul — the per-host fan-out is fine; fix the label
  plumbing first.
