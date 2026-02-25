# Metrics, Logging & Alerting Plan

Strategy for centralized monitoring, log aggregation, and alerting across the
homelab. Migrates the existing `ymir` monitoring VM from VLAN 20 (trusted) to
VLAN 11 (management) and expands it with log aggregation, alerting, and
notifications.

---

## Current State

**ymir** (on erebonia, VLAN 20 — trusted zone) currently runs:
- Prometheus (port 9001) — scrapes itself + remiferia exporters
- Grafana (via nginx) — visualization
- Loki/Promtail — **disabled** (configured but commented out)
- 2 vCPU, 1 GB RAM, 10 GB persist volume

**remiferia** exports:
- node_exporter (9001), zfs_exporter (9002), smartctl_exporter (9003)

**Problems with the current setup:**
1. ymir is on VLAN 20 (trusted/home) — infrastructure monitoring belongs on
   VLAN 11 (management)
2. Only scraping 2 hosts (ymir itself + remiferia)
3. No log aggregation (Loki disabled)
4. No alerting at all
5. No egress filtering

---

## Architecture Overview

Migrate ymir to **management zone** (VLAN 11) and expand its services. The
management zone already has `accessTo = [ "management" "trusted" "untrusted" ]`
in the router6 config, so ymir can reach exporters in those zones without extra
firewall rules. erebonia already has a VLAN 11 bridge (`br11`), so the parent
host needs no changes beyond the tap interface name.

### Stack Selection

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Metrics | **Prometheus** | Already running on ymir, NixOS module is mature, pull-based model works well for homelab |
| Visualization | **Grafana** | Already running on ymir, rich dashboard ecosystem |
| Log aggregation | **Loki** | Already configured (disabled) on ymir, designed for Prometheus+Grafana stack, low resource usage vs ELK |
| Log shipping | **Promtail** | Native Loki companion; can scrape systemd journal on each host |
| Alerting | **Alertmanager** | Native Prometheus integration, supports multiple notification channels |
| Notifications | **ntfy** (self-hosted) | See Notification System section below |

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
- Can also receive webhooks from CI/CD (Gitea/Forgejo), systemd failure units,
  and custom scripts

**Notification channels and routing:**

| Alert Category | ntfy Topic | Priority | Examples |
|----------------|-----------|----------|----------|
| Critical infra | `infra-critical` | urgent | Host down, disk >90%, ZFS degraded, OOM |
| Security | `security` | high | SSH brute force, firewall drops spike, failed sudo |
| Service health | `services` | default | Prometheus target down, cert expiring, DNS failure |
| CI/CD | `cicd` | default | Deploy success/failure, build status |
| Informational | `homelab-info` | low | Backup completed, package updates available |

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

## ymir Migration Spec

### What Changes

| Property | Before | After |
|----------|--------|-------|
| Zone | trusted (VLAN 20) | management (VLAN 11) |
| Network registry | `trusted.hosts.ymir = 41` | `management.hosts.ymir = 5` |
| IPv4 | `10.97.20.41` | `10.97.11.5` |
| IPv6 | `fdc6:55f2:0a5e:14::29` | `fdc6:55f2:0a5e:b::5` |
| Legacy IPv4 | `10.0.20.41` | `10.0.11.5` |
| Tap interface | `vm-20-ymir` | `vm-11-ymir` |
| MAC | `5E:A2:E4:CB:05:DA` | New MAC (VLAN 11 encoded) |
| RAM | 1024 MB | 2048 MB |
| Persist volume | 10 GB | 30 GB |
| Grafana domain | `ymir.internal` | `ymir.internal` (unchanged) |

### What Stays the Same

- Hostname: `ymir`
- Parent host: erebonia
- vCPU: 2
- Existing Prometheus config (scrape targets, port 9001)
- Existing Grafana config (nginx proxy, datasources)
- Hypervisor: microvm (QEMU), 9p for nix store
- All existing Grafana dashboards and Prometheus history (persist volume is
  recreated on the new VLAN — see migration note below)

### Resources

| Resource | Value | Rationale |
|----------|-------|-----------|
| vCPU | 2 | Prometheus compaction + Loki ingestion |
| RAM | 2048 MB | Prometheus TSDB in-memory chunks + Loki + Grafana |
| Persist volume | 30 GB | ~90 days retention at expected cardinality |

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
    # Grafana dashboards & datasources
    { directory = "/var/lib/grafana";
      user = "grafana"; group = "grafana"; }
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

Strict egress filter — ymir should only talk to known targets:

```nix
# Allowed egress:
# - Gateway: DNS (53), NTP (123)
# - All scrape targets (prometheus exporter ports)
# - legram: ACME cert issuance (443)
# No general internet access needed
```

### Secrets (sops-nix)

| Secret | Used by |
|--------|---------|
| `grafana-admin-password` | Grafana initial admin |
| `ntfy-auth-token` | ntfy access control |
| `alertmanager-ntfy-url` | Alertmanager webhook config (includes topic auth) |
| `grafana-oidc-secret` | Grafana → Keycloak OIDC (if roer is deployed) |

---

## Services Configuration

### 1. Prometheus

```
Port: 9090 (migrate from 9001 to standard port)
Retention: 90d
Scrape interval: 15s (default), 60s (slow targets)
```

**Scrape targets — Phase 1 (management zone hosts):**

| Job | Target | Port | Exporter |
|-----|--------|------|----------|
| ymir_node | localhost | 9100 | node_exporter |
| remiferia_node | remiferia.internal | 9001 | node_exporter |
| remiferia_zfs | remiferia.internal | 9002 | zfs_exporter |
| remiferia_smartctl | remiferia.internal | 9003 | smartctl_exporter |
| thebeyond_node | thebeyond.internal | 9100 | node_exporter |
| erebonia_node | erebonia.internal | 9100 | node_exporter |
| calvard_node | calvard.internal | 9100 | node_exporter |

**Scrape targets — Phase 2 (cross-zone, microVM guests):**

| Job | Target | Port | Exporter |
|-----|--------|------|----------|
| phantasma_node | phantasma.internal | 9100 | node_exporter |
| ordis_node | ordis.internal | 9100 | node_exporter |
| heimdallr_node | heimdallr.internal | 9100 | node_exporter |
| roer_node | roer.internal | 9100 | node_exporter |
| legram_node | legram.internal | 9100 | node_exporter |
| ardent_node | ardent.internal | 9100 | node_exporter |

**Scrape targets — Phase 3 (service-specific exporters):**

| Job | Target | Exporter |
|-----|--------|----------|
| unbound | phantasma.internal:9167 | unbound_exporter |
| kea_dhcp | thebeyond.internal:9547 | kea_exporter |
| nginx | ordis.internal:9113 | nginx_exporter |
| nftables | thebeyond.internal:9630 | nftables_exporter |

### 2. Loki

```
Port: 3100
Retention: 30d
Storage: filesystem (boltdb-shipper + chunks on /var/lib/loki)
```

Receives logs from Promtail agents running on each host. Local Promtail on
ymir scrapes its own systemd journal.

### 3. Promtail (deployed to each host)

Promtail runs as a lightweight agent on every NixOS host and microVM, shipping
systemd journal logs to Loki on ymir.

**Deployment approach**: Add a shared NixOS module
(`modules/promtail-client/default.nix` or similar) that each host imports:

```nix
# Conceptual — actual module would be more complete
services.promtail = {
  enable = true;
  configuration = {
    server.http_listen_port = 3031;
    clients = [{ url = "http://ymir.internal:3100/loki/api/v1/push"; }];
    scrape_configs = [{
      job_name = "journal";
      journal = {
        max_age = "12h";
        labels.job = "systemd-journal";
        labels.host = config.networking.hostName;
      };
      relabel_configs = [{
        source_labels = [ "__journal__systemd_unit" ];
        target_label = "unit";
      }];
    }];
  };
};
```

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
- Write token for CI/CD webhooks (Gitea on ardent)
- Admin token for topic management

### 6. Grafana

```
Port: 3000 (proxied via nginx on 80/443)
Domain: ymir.internal
```

**Datasources (provisioned):**
- Prometheus → `http://localhost:9090`
- Loki → `http://localhost:3100`
- Alertmanager → `http://localhost:9093`

**Dashboards (provisioned as JSON):**
- Node Exporter Full (community dashboard #1860)
- ZFS overview (custom or community)
- Loki log explorer
- Alertmanager overview
- Network/firewall overview (custom)

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

# ZFS pool health (remiferia)
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

```yaml
# SSH authentication failures (from Loki log queries)
# Implemented as Grafana alerting rules against Loki datasource:
# - SSH brute force: >10 failed auth attempts in 5 min from same source
# - Successful SSH from unexpected IP range

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

Move `ymir` from `trusted` to `management` in `lib/common/data/network.nix`:

```nix
# Remove from trusted:
trusted = {
  vlanId = 20;
  hosts = {
    denai = 40;
    # ymir removed
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
    ymir       = 5;    # Metrics/monitoring (migrated from trusted)
    remiferia  = 20;
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

For hosts in the management zone, ymir can already reach them (management zone
has `accessTo = [ "management" ... ]`). For DMZ hosts (ordis, heimdallr,
ardent), the management zone already has `accessTo` that covers `trusted` and
`untrusted` but **not** DMZ, so cross-zone forward rules are needed:

```nix
# In thebeyond extraForwardRules:
# ymir (management) → DMZ exporter ports
{ iifname = "vINFRA.br0"; oifname = "vDMZ.br0";
  ip.saddr = ymir.ipv4; tcp.dport = 9100;
  verdict = "accept"; comment = "ymir -> DMZ (node_exporter)"; }
```

### Promtail → Loki Connectivity

Hosts in all zones need to reach ymir:3100 (Loki push endpoint). Management
zone hosts can already reach ymir (intra-zone). For other zones:

- **trusted zone** → management: already allowed (`accessTo` includes
  `management`)
- **DMZ zone** → management: needs cross-zone forward rule for Loki port

```nix
# DMZ hosts → ymir for log shipping
{ iifname = "vDMZ.br0"; oifname = "vINFRA.br0";
  ip.daddr = ymir.ipv4; tcp.dport = 3100;
  verdict = "accept"; comment = "DMZ -> ymir (Loki)"; }
```

---

## File Structure

Evolves the existing `hosts/erebonia/guests/ymir/` directory:

```
hosts/erebonia/guests/ymir/
├── default.nix          # Updated networking (VLAN 11), expanded persistence
├── microvm.nix          # Updated tap interface, MAC, resources
├── monit.nix            # Refactored → split into modules/ (or kept and expanded)
├── sops.nix             # NEW — secrets for grafana, ntfy, alertmanager
├── secrets/
│   └── secrets.yaml     # NEW — encrypted secrets
└── modules/
    ├── prometheus.nix   # Prometheus + scrape configs + alert rules (from monit.nix)
    ├── grafana.nix      # Grafana + nginx reverse proxy + datasources (from monit.nix)
    ├── loki.nix         # Loki + local promtail (enable existing disabled config)
    ├── alertmanager.nix # NEW — Alertmanager + routing config
    └── ntfy.nix         # NEW — ntfy notification server

modules/promtail-client/default.nix  # NEW — shared module for all hosts
```

---

## Implementation Phases

### Phase 1 — VLAN Migration + Core Metrics

1. Move `ymir` from `trusted` to `management` in network registry (host ID 5)
2. Update `microvm.nix`: tap `vm-11-ymir`, new MAC, bump RAM to 2048 MB,
   persist volume to 30 GB
3. Update `default.nix`: new IP/CIDR from `net.forHost "ymir"`, gateway from
   management zone
4. Split `monit.nix` into `modules/prometheus.nix` + `modules/grafana.nix`
5. Deploy node_exporter on all parent hosts (thebeyond, erebonia, calvard)
6. Expand Prometheus scrape targets to cover all parent hosts
7. Add firewall rules for exporter scraping (cross-zone for DMZ targets)
8. Add sops.nix + secrets for Grafana admin password
9. Verify: all targets up, Grafana accessible at ymir.internal

**Migration note:** The persist volume path changes from
`/persist/guests/ymir/images/persist.img` on the old VLAN 20 tap to the same
path but with a fresh image (new IP, new volume size). Prometheus history and
Grafana dashboards from the old volume can be migrated by copying the persist
image before reprovisioning, or started fresh.

### Phase 2 — Log Aggregation

1. Enable Loki on ymir (update existing disabled config)
2. Enable local Promtail on ymir (update existing disabled config)
3. Create `modules/promtail-client/default.nix` shared module
4. Deploy Promtail to all parent hosts + microVMs
5. Add cross-zone firewall rules for DMZ → ymir Loki port
6. Add Loki persistence directory
7. Configure Grafana Loki datasource
8. Verify: logs flowing from all hosts, searchable in Grafana

### Phase 3 — Alerting & Notifications

1. Add `modules/ntfy.nix` — deploy ntfy on ymir
2. Add `modules/alertmanager.nix` — configure with ntfy webhook receivers
3. Add Phase 1 alert rules (host down, disk space, ZFS, systemd)
4. Install ntfy app on phone, subscribe to topics
5. Test alert pipeline: trigger test alert → Alertmanager → ntfy → phone
6. Verify: alerts fire and deliver within expected timeframes

### Phase 4 — Expanded Monitoring

1. Deploy service-specific exporters (unbound, kea, nginx, nftables)
2. Add Phase 2 alert rules (security alerts from Loki queries)
3. Add Phase 3 alert rules (service health)
4. Build custom Grafana dashboards (firewall overview, DNS stats)
5. Configure CI/CD webhook integration (Gitea → ntfy)
6. Configure Grafana OIDC auth via roer/Keycloak (if available)

---

## Resolved Questions

1. **ntfy external access**: VPN only (via `wg-vpn`). No DMZ exposure. Phone
   notifications require VPN connection when away from home.

2. **Retention**: 90 days for Prometheus metrics, 30 days for Loki logs.
   ~15-20 GB estimated disk usage. Tune down if needed.

3. **Grafana auth**: Local admin only (sops-managed password). Add Keycloak
   OIDC later when roer is stable.

4. **Data migration**: Start fresh. Current ymir has minimal history (only 2
   scrape targets). Clean persist volume on the new VLAN.
