# Metrics, Logging & Alerting Plan

Strategy for centralized monitoring, log aggregation, and alerting across the
homelab.

---

## Blocked on

[`cicd-fleet-activation-plan.md`](../plans/cicd-fleet-activation-plan.md).

The original block on this plan was thebeyond hardware (for wg-vpn reachability
and for the Phase 4 service-specific exporters running on the router). thebeyond
is now deployed (dual-gateway work shipped 2026-05), so the hardware gate is
lifted — but the remaining Phase 4 items are deferred behind CI/CD for the same
reason as dual-gateway Phase 4/4.5 (see
[[project_phase_4_deferred_to_cicd]]): rolling new exporters and dashboard
changes out to every host by hand is exactly the churn the CI/CD pipeline is
designed to absorb, and doing it pre-CI/CD just creates throwaway operator work.

**Unblock condition:** CI/CD fleet activation reaches the point where
`nixos-rebuild` is driven by the pusher host on merge — at which point the
Phase 4 exporter rollout, dashboard refresh, and Forgejo → ntfy webhook all
ride the new pipeline.

---

## Current State

**tharbad** (on calvard, VLAN 11 — management zone) currently runs:

- Prometheus (port 9090) — scrapes parent hosts + all guest node_exporters
- VictoriaLogs (port 9428, behind nginx :3100) — receiving logs from fleet-wide fluent-bit-agent
- Perses — dashboard visualization (replacing Grafana)
- Alertmanager — **enabled**, routing alerts to ntfy
- ntfy — **enabled**, self-hosted notification server
- 2 vCPU, 2 GB RAM, 30 GB persist volume

> **History:** Originally `ymir` on erebonia. Renamed to `tharbad` and moved to
> calvard during the vm-guest-rebalance migration. Migrated from VLAN 20 to
> VLAN 11 (management zone) — completed 2026-03.

**liberl** exports:

- node_exporter (9001), zfs_exporter (9002), smartctl_exporter (9003)

**fluent-bit-agent** module deployed fleet-wide, shipping to `tharbad.internal:3100` (nginx → VictoriaLogs).

**Remaining work** (all deferred behind CI/CD — see `## Blocked on` above):

1. Review Perses dashboards, identify gaps
2. ntfy phone integration — needs wg-vpn (thebeyond hardware now in place; wg-vpn is its own track)
3. Phase 4 service-specific exporters (unbound, kea, nginx, nftables) — fleet rollout deferred to CI/CD
4. CI/CD webhook integration (Forgejo → ntfy)

---

## Architecture Overview

tharbad has been migrated to **management zone** (VLAN 11). Alertmanager and
ntfy are now enabled and running. Remaining work is Perses dashboard review
and ntfy phone integration (blocked on thebeyond/wg-vpn). The management
zone has `accessTo = [ "management" "trusted" "untrusted" ]` in the router6
config, so tharbad can reach exporters in those zones without extra firewall rules.

### Stack Selection

| Component       | Choice                 | Rationale                                                                                                             |
| --------------- | ---------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Metrics         | **Prometheus**         | Already running on tharbad, NixOS module is mature, pull-based model works well for homelab                           |
| Visualization   | **Perses**             | Prometheus-native; dashboards-as-code (declarative/GitOps-first), replaces Grafana                                    |
| Log aggregation | **VictoriaLogs**       | Column-oriented log store; no label/stream cardinality limits; Apache 2.0; smaller RSS than Loki at equivalent ingest |
| Log shipping    | **fluent-bit**         | Fleet-wide agent shipping via Loki-compat push protocol to VictoriaLogs through nginx mTLS                            |
| Alerting        | **Alertmanager**       | Native Prometheus integration, supports multiple notification channels                                                |
| Notifications   | **ntfy** (self-hosted) | See Notification System section below                                                                                 |

### Why not VictoriaMetrics / Mimir / Thanos?

Single-site homelab with <20 hosts. Prometheus's local TSDB is sufficient.
No need for distributed storage, multi-tenancy, or long-term retention beyond
what Prometheus compaction provides. Keep it simple.

---

## Notification System

### Recommendation: **ntfy** (self-hosted)

[ntfy](https://ntfy.sh) is a simple HTTP-based pub/sub notification service.

**Why ntfy:**

- Self-hosted (runs as a single binary, NixOS module available)
- Push notifications to phone via ntfy Android/iOS app — no email server needed
- Dead simple API: `curl -d "disk full" ntfy.example.com/alerts`
- Alertmanager webhook integration (first-class)
- Supports access control (token-based auth)
- Extremely lightweight (~20 MB RAM)
- Can also receive webhooks from CI/CD (Forgejo), systemd failure units,
  and custom scripts

**Notification channels and routing:**

| Alert Category | ntfy Topic       | Priority | Examples                                           |
| -------------- | ---------------- | -------- | -------------------------------------------------- |
| Critical infra | `infra-critical` | urgent   | Host down, disk >90%, ZFS degraded, OOM            |
| Security       | `security`       | high     | SSH brute force, firewall drops spike, failed sudo |
| Service health | `services`       | default  | Prometheus target down, cert expiring, DNS failure |
| CI/CD          | `cicd`           | default  | Deploy success/failure, build status               |
| Informational  | `homelab-info`   | low      | Backup completed, package updates available        |

**Alternatives considered:**

- **Gotify**: Similar to ntfy but less actively maintained, no iOS app
- **Email (SMTP)**: Requires mail server or relay, spam filtering hassle, slower
  delivery for urgent alerts
- **Pushover**: Commercial SaaS, one-time $5 fee per platform — viable fallback
  if self-hosting notification delivery proves unreliable
- **Slack/Discord webhooks**: Depends on external service availability — defeats
  the purpose of self-hosted monitoring
- **Apprise**: Meta-notifier that wraps many services — adds complexity, better
  as a future addition if multi-channel is needed

---

## tharbad VLAN Migration Spec

### What Changes

| Property         | Before (current)             | After                          |
| ---------------- | ---------------------------- | ------------------------------ |
| Zone             | trusted (VLAN 20)            | management (VLAN 11)           |
| Network registry | `trusted.hosts.tharbad = 41` | `management.hosts.tharbad = 5` |
| IPv4             | `10.97.20.41`                | `10.97.11.5`                   |
| IPv6             | `fdc6:55f2:0a5e:14::29`      | `fdc6:55f2:0a5e:b::5`          |
| Tap interface    | `vm-20-tharbad`              | `vm-11-tharbad`                |
| MAC              | `5E:A2:E4:CB:05:DA`          | New MAC (VLAN 11 encoded)      |

### What Stays the Same

- Hostname: `tharbad`
- Parent host: calvard
- vCPU: 2, RAM: 2048 MB, persist volume: 30 GB (already upgraded)
- Existing Prometheus config (scrape targets, port 9090)
- Hypervisor: cloud-hypervisor microvm
- Loki + promtail-client fleet deployment

### Resources

| Resource       | Value   | Rationale                                         |
| -------------- | ------- | ------------------------------------------------- |
| vCPU           | 2       | Prometheus compaction + Loki ingestion            |
| RAM            | 2048 MB | Prometheus TSDB in-memory chunks + Loki + Grafana |
| Persist volume | 30 GB   | ~90 days retention at expected cardinality        |

### Persistence

```nix
environment.persistence."/persist" = {
  hideMounts = true;
  directories = [
    "/var/log"
    "/var/lib/nixos"
    "/var/lib/systemd/coredump"
    # Prometheus TSDB
    { directory = "/var/lib/prometheus2";
      user = "prometheus"; group = "prometheus"; }
    # Perses dashboards & config
    { directory = "/var/lib/perses";
      user = "perses"; group = "perses"; }
    # Loki chunks & index
    { directory = "/var/lib/loki";
      user = "loki"; group = "loki"; }
    # Alertmanager silences & notification log
    { directory = "/var/lib/alertmanager";
      user = "alertmanager"; group = "alertmanager"; }
    # ntfy message cache & auth DB
    { directory = "/var/lib/ntfy-sh";
      user = "ntfy-sh"; group = "ntfy-sh"; }
  ];
  files = [ "/etc/machine-id" ];
};
```

### Egress Filtering

Strict egress filter — tharbad should only talk to known targets:

```nix
# Allowed egress:
# - Gateway: DNS (53), NTP (123)
# - All scrape targets (prometheus exporter ports)
# - basel: ACME cert issuance (443)
# No general internet access needed
```

### Secrets (sops-nix)

| Secret                  | Used by                                           |
| ----------------------- | ------------------------------------------------- |
| `ntfy-auth-token`       | ntfy access control                               |
| `alertmanager-ntfy-url` | Alertmanager webhook config (includes topic auth) |
| `perses-oidc-secret`    | Perses → Authelia OIDC (was Keycloak)             |

---

## Services Configuration

### 1. Prometheus

```
Port: 9090 (migrate from 9001 to standard port)
Retention: 90d
Scrape interval: 15s (default), 60s (slow targets)
```

**Currently scraping (deployed in prometheus.nix):**

| Job                | Target             | Port | Exporter          |
| ------------------ | ------------------ | ---- | ----------------- |
| tharbad_node       | localhost          | 9100 | node_exporter     |
| thebeyond_node     | thebeyond.internal | 9100 | node_exporter     |
| erebonia_node      | erebonia.internal  | 9100 | node_exporter     |
| calvard_node       | calvard.internal   | 9100 | node_exporter     |
| liberl_node        | liberl.internal    | 9001 | node_exporter     |
| liberl_zfs         | liberl.internal    | 9002 | zfs_exporter      |
| liberl_smartctl    | liberl.internal    | 9003 | smartctl_exporter |

**Guest scrape targets (configured, pending deploy):**

| Job             | Target              | Port | Exporter      |
| --------------- | ------------------- | ---- | ------------- |
| phantasma_node  | phantasma.internal  | 9100 | node_exporter |
| basel_node      | basel.internal      | 9100 | node_exporter |
| messeldam_node  | messeldam.internal  | 9100 | node_exporter |
| langport_node   | langport.internal   | 9100 | node_exporter |
| creil_node      | creil.internal      | 9100 | node_exporter |
| oracion_node    | oracion.internal    | 9100 | node_exporter |
| zeiss_node      | zeiss.internal      | 9100 | node_exporter |
| bose_node       | bose.internal       | 9100 | node_exporter |
| ravennue_node   | ravennue.internal   | 9100 | node_exporter |
| saint-arkh_node | saint-arkh.internal | 9100 | node_exporter |
| trista_node     | trista.internal     | 9100 | node_exporter |
| edith_node      | edith.internal      | 9100 | node_exporter |

**Future scrape targets (service-specific exporters):**

| Job      | Target                  | Exporter          |
| -------- | ----------------------- | ----------------- |
| unbound  | phantasma.internal:9167 | unbound_exporter  |
| kea_dhcp | thebeyond.internal:9547 | kea_exporter      |
| nginx    | langport.internal:9113  | nginx_exporter    |
| nftables | thebeyond.internal:9630 | nftables_exporter |

### 2. VictoriaLogs

```
External port: 3100 (nginx mTLS)
Internal port: 9428 (127.0.0.1)
Retention: 30d
Storage: column-oriented on /var/lib/victorialogs
```

Receives logs from fluent-bit agents running on each host (via
`fluent-bit-agent` module). Agents push to `https://tharbad.internal:3100/loki/api/v1/push`;
nginx verifies mTLS and proxies to VictoriaLogs' Loki-compat insert endpoint.
Log alerting is handled by a dedicated vmalert-vlogs instance (see
`modules/victorialogs.nix`) using LogsQL rules evaluated against VL's stats API.

> **Log Aggregation superseded:** This section originally described Loki +
> Promtail. The full migration to VictoriaLogs is documented in
> `llm-notes/done/loki-to-victorialogs.md`.

### 3. fluent-bit (deployed to each host)

fluent-bit runs as a lightweight agent on every NixOS host and microVM (via
`modules/fluent-bit-agent/default.nix`), shipping systemd journal logs to
VictoriaLogs on tharbad via the Loki-compat push protocol over mTLS.

### 4. Alertmanager

```
Port: 9093
```

**Notification routing:**

```yaml
route:
  receiver: ntfy-default
  group_by: [alertname, instance]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - match:
        severity: critical
      receiver: ntfy-critical
      repeat_interval: 1h
    - match:
        category: security
      receiver: ntfy-security
      repeat_interval: 2h
    - match:
        category: cicd
      receiver: ntfy-cicd

receivers:
  - name: ntfy-critical
    webhook_configs:
      - url: http://localhost:2586/infra-critical
        # ntfy accepts alertmanager webhook format natively
  - name: ntfy-security
    webhook_configs:
      - url: http://localhost:2586/security
  - name: ntfy-cicd
    webhook_configs:
      - url: http://localhost:2586/cicd
  - name: ntfy-default
    webhook_configs:
      - url: http://localhost:2586/services
```

### 5. ntfy

```
Port: 2586 (internal, localhost only for alertmanager)
       80/443 (via nginx, for phone app + external webhook access)
```

**Access control:**

- Read-only token for phone app subscriptions
- Write token for Alertmanager (localhost, can be unrestricted)
- Write token for CI/CD webhooks (Forgejo on creil)
- Admin token for topic management

### 6. Perses

```
Domain: perses.internal (tharbad)
```

**Datasources:**

- Prometheus → `http://localhost:9090`

**Dashboards (to review/build):**

- Node overview
- ZFS overview
- Firewall/network overview
- DNS stats
- Alertmanager overview

---

## Alert Rules

### Phase 1 — Infrastructure Health

```yaml
# Host availability
- alert: HostDown
  expr: up == 0
  for: 2m
  labels: { severity: critical }
  annotations: { summary: "{{ $labels.instance }} is unreachable" }

# Disk space
- alert: DiskSpaceLow
  expr: (node_filesystem_avail_bytes / node_filesystem_size_bytes) < 0.10
  for: 5m
  labels: { severity: critical }

# Memory pressure
- alert: HighMemoryUsage
  expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.90
  for: 5m
  labels: { severity: warning }

# ZFS pool health (liberl)
- alert: ZFSPoolDegraded
  expr: node_zfs_zpool_state{state!="online"} > 0
  for: 1m
  labels: { severity: critical }

# Systemd unit failures
- alert: SystemdUnitFailed
  expr: node_systemd_unit_state{state="failed"} == 1
  for: 5m
  labels: { severity: warning }
```

### Phase 2 — Security Alerts

VictoriaLogs-based alerts are evaluated by vmalert-vlogs using LogsQL rules.
The ruler sends firing alerts to Alertmanager.

```yaml
# SSH authentication failures (from vmalert-vlogs — LogsQL queries)
# Implemented in victorialogs.nix securityRules:
# - SSHBruteForce: >10 failed auth in 5min (warning)
# - SSHBruteForceExtreme: >50 failed auth in 5min (critical)
# - SudoFailure: any failed sudo auth in 10min (warning)

# Firewall drops spike
- alert: FirewallDropsSpike
  expr: rate(nftables_chain_packets_total{chain="drop"}[5m]) > 100
  for: 5m
  labels: { severity: warning, category: security }

# Certificate expiry
- alert: CertExpiringSoon
  expr: (probe_ssl_earliest_cert_expiry - time()) / 86400 < 14
  for: 1h
  labels: { severity: warning }
```

### Phase 3 — Service Health

```yaml
# DNS resolution failure
- alert: DNSResolutionFailure
  expr: probe_dns_lookup_time_seconds == 0
  for: 2m
  labels: { severity: critical }

# Prometheus target down
- alert: PrometheusTargetDown
  expr: up == 0
  for: 5m
  labels: { severity: warning }

# High scrape duration
- alert: SlowScrape
  expr: scrape_duration_seconds > 10
  for: 5m
  labels: { severity: warning }
```

---

## Network & Firewall Changes

### Network Registry Migration

Move `tharbad` from `trusted` to `management` in `lib/common/data/network.nix`:

```nix
# Remove from trusted:
trusted = {
  vlanId = 20;
  hosts = {
    denai = 40;
    # tharbad removed
  };
};

# Add to management:
management = {
  vlanId = 11;
  hosts = {
    thebeyond  = 1;
    phantasma  = 2;
    roer       = 3;
    legram     = 4;
    tharbad    = 5;    # Metrics/monitoring (migrated from trusted)
    liberl     = 20;
    calvard    = 30;
    erebonia   = 31;
  };
};
```

### Exporter Firewall Rules

Each host being scraped needs to allow Prometheus connections on exporter ports.
For hosts with input firewalls (most microVMs and hardened hosts), add:

```nix
networking.firewall.allowedTCPPorts = [
  9100  # node_exporter
  # ... service-specific exporter ports
];
```

For hosts in the management zone, tharbad can already reach them (management zone
has `accessTo = [ "management" ... ]`). For DMZ/APP hosts (langport, zeiss, etc.),
the management zone already has `accessTo` that covers `trusted` and
`untrusted` but **not** DMZ, so cross-zone forward rules are needed:

```nix
# In thebeyond extraForwardRules:
# tharbad (management) → DMZ exporter ports
{ iifname = "vINFRA.br0"; oifname = "vDMZ.br0";
  ip.saddr = tharbad.ipv4; tcp.dport = 9100;
  verdict = "accept"; comment = "tharbad -> DMZ (node_exporter)"; }
```

### fluent-bit → VictoriaLogs Connectivity

Hosts in all zones need to reach tharbad:3100 (nginx mTLS log push endpoint,
proxies to VictoriaLogs). Management zone hosts can already reach tharbad
(intra-zone). For other zones:

- **trusted zone** → management: already allowed (`accessTo` includes
  `management`)
- **DMZ zone** → management: needs cross-zone forward rule for port 3100
  (**already implemented** — forward rules + per-host egress rules in place)

```nix
# DMZ hosts → tharbad for log shipping (ALREADY IN PLACE)
{ iifname = "vDMZ.br0"; oifname = "vINFRA.br0";
  ip.daddr = tharbad.ipv4; tcp.dport = 3100;
  verdict = "accept"; comment = "DMZ -> tharbad (log push)"; }
```

---

## File Structure

Current file structure at `hosts/calvard/microvm/guests/tharbad/`:

```
hosts/calvard/microvm/guests/tharbad/
├── default.nix          # Networking, imports, persistence
├── microvm.nix          # Tap interface, MAC, resources
├── sops.nix             # Secrets for ntfy, alertmanager
├── secrets/
│   └── secrets.yaml     # Encrypted secrets
└── modules/
    ├── victoriametrics.nix  # vmsingle + vmalert (Prometheus rules) ✓
    ├── victorialogs.nix    # VictoriaLogs + vmalert-vlogs (LogsQL rules) ✓
    ├── alertmanager.nix    # Alertmanager + routing config ✓
    └── ntfy.nix            # ntfy notification server ✓

modules/fluent-bit-agent/default.nix     # Shared module, deployed fleet-wide ✓
modules/node-exporter-client/default.nix # Shared module, deployed fleet-wide ✓
```

---

## Implementation Phases

### Phase 1 — Core Metrics (COMPLETE)

- [x] Split monit.nix into `modules/prometheus.nix` + `modules/grafana.nix`
- [x] Expand Prometheus scrape targets to cover parent hosts
- [x] Bump RAM to 2048 MB, persist volume to 30 GB
- [x] Move `tharbad` from `trusted` to `management` in network registry (host ID 5)
- [x] Update `microvm.nix`: tap `vm-11-tharbad`
- [x] Add sops.nix + secrets
- [x] Add egress filtering (default-drop, scrape targets + DNS/NTP + ACME)
- [x] Deploy and verify tharbad on VLAN 11 (management zone)
- [x] Migrated from Grafana to Perses for dashboard visualization

### Phase 2 — Log Aggregation (COMPLETE — migrated to VictoriaLogs)

> Loki + Promtail have been replaced by VictoriaLogs + fluent-bit-agent.
> See `llm-notes/done/loki-to-victorialogs.md` for the full migration record.

- [x] VictoriaLogs running on tharbad, port 9428 (127.0.0.1)
- [x] vmalert-vlogs evaluating LogsQL security alert rules
- [x] nginx mTLS on :3100 proxies to VL Loki-compat insert endpoint
- [x] `modules/fluent-bit-agent/default.nix` deployed fleet-wide
- [x] Cross-zone firewall rules for DMZ → tharbad :3100 (IPv4 + IPv6)
- [x] Per-host egress rules for log push

### Phase 3 — Alerting & Notifications (DEPLOYED)

- [x] Write + enable `modules/ntfy.nix` — ntfy on tharbad, port 2586
- [x] Write + enable `modules/alertmanager.nix` — Alertmanager with ntfy webhook receivers
- [x] Write Phase 1 alert rules — HostDown, DiskSpaceLow, HighMemoryUsage,
      ZFSPoolDegraded, SystemdUnitFailed
- [x] Alertmanager + ntfy deployed and running
- [ ] Install ntfy app on phone, subscribe to topics — needs wg-vpn (thebeyond hardware now in place; wg-vpn is its own track)
- [ ] Test end-to-end alert pipeline once phone integration is possible

### Phase 4 — Expanded Monitoring

- [x] Create `modules/node-exporter-client/default.nix` shared module
- [x] Wire `node-exporter-client` into all flake builder functions
- [x] Enable node_exporter on all microVM + Incus guests (11 hosts)
- [x] Add scrape targets to prometheus.nix for all guests
- [x] Add egress rules on tharbad for all new scrape targets
- [x] Add management → DMZ/APP/lab forward rules on router for Prometheus scraping
- [x] Rename stale `ymir_node` scrape job to `tharbad_node`
- [ ] Deploy service-specific exporters (unbound, kea, nginx, nftables) — fleet rollout deferred to CI/CD (see `## Blocked on`)
- [x] Add Phase 2 alert rules (vmalert-vlogs: SSHBruteForce, SSHBruteForceExtreme, SudoFailure)
- [ ] Add remaining Phase 2 alerts (FirewallDropsSpike, CertExpiringSoon) — needs the exporters above
- [x] Add Phase 3 alert rules (Prometheus: SlowScrape, PrometheusRuleEvalFailure; also HighCPUUsage, HostRebooted in infrastructure group; vmalert-vlogs: FleetLogGap)
- [ ] Review existing Perses dashboards, identify coverage gaps (dashboards are declarative/code-managed — changes go through the repo and CI)
- [ ] Build additional Perses dashboards (firewall overview, DNS stats)
- [ ] Configure CI/CD webhook integration (Forgejo → ntfy)
- [x] Configure Perses OIDC auth via Authelia (messeldam) — migrated from
      Keycloak; see authelia-migration-plan.md

---

## Rejected Alternatives

### mTLS-direct on VictoriaLogs push endpoint

mTLS is terminated at nginx (:3100); VictoriaLogs listens on 127.0.0.1:9428
with no auth. We considered having agents authenticate directly to VL, but:

- **nginx mTLS is already the established pattern** for both the metrics push
  (:8427) and log push (:3100) endpoints. Consistency matters.
- **Audit identity** — `$ssl_client_s_dn_cn` in nginx access logs gives per-host
  attribution. VL's built-in basicAuth doesn't provide this without custom logging.
- **The fleet already has client certs issued** — no new credential infrastructure.

Revisit if VictoriaLogs is ever exposed beyond the LAN or multi-tenant log
separation is needed.

---

## Resolved Questions

1. **ntfy external access**: VPN only (via `wg-vpn`). No DMZ exposure. Phone
   notifications require VPN connection when away from home.

2. **Retention**: 90 days for Prometheus metrics, 30 days for Loki logs.
   ~15-20 GB estimated disk usage. Tune down if needed.

3. **Perses auth**: OIDC via Authelia (messeldam, replacing Keycloak) — configured and working.

4. **Data migration**: Start fresh on VLAN migration. Prometheus history on the
   current VLAN 20 persist volume can be copied or discarded.
