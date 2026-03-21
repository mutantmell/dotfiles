# Metrics, Logging & Alerting Plan

Strategy for centralized monitoring, log aggregation, and alerting across the
homelab. The monitoring VM (now **tharbad** on calvard) needs to migrate from
VLAN 20 (trusted) to VLAN 11 (management) and have its disabled services
(Grafana, Alertmanager, ntfy) enabled.

---

## Current State

**tharbad** (on calvard, VLAN 11 — management zone) currently runs:

- Prometheus (port 9090) — scrapes parent hosts + remiferia exporters
- Loki (port 3100) — receiving logs from fleet-wide promtail-client
- Grafana (port 3000) — **deployed**, not fully configured (dashboards, OIDC)
- Alertmanager — **disabled** (module exists, pending sops secrets)
- ntfy — **disabled** (module exists, pending sops secrets)
- 2 vCPU, 2 GB RAM, 30 GB persist volume

> **History:** Originally `ymir` on erebonia. Renamed to `tharbad` and moved to
> calvard during the vm-guest-rebalance migration. Migrated from VLAN 20 to
> VLAN 11 (management zone) — completed 2026-03.

**remiferia** exports:

- node_exporter (9001), zfs_exporter (9002), smartctl_exporter (9003)

**promtail-client** module deployed fleet-wide, shipping to `tharbad.internal:3100`.

**Remaining work:**

1. Grafana dashboards and configuration not fully set up
2. Alertmanager, ntfy disabled pending sops secrets
3. Phase 4 service-specific exporters not yet deployed

---

## Architecture Overview

tharbad has been migrated to **management zone** (VLAN 11). Remaining work is
enabling Alertmanager/ntfy and completing Grafana configuration. The management
zone has `accessTo = [ "management" "trusted" "untrusted" ]` in the router6
config, so tharbad can reach exporters in those zones without extra firewall rules.

### Stack Selection

| Component       | Choice                 | Rationale                                                                                                  |
| --------------- | ---------------------- | ---------------------------------------------------------------------------------------------------------- |
| Metrics         | **Prometheus**         | Already running on tharbad, NixOS module is mature, pull-based model works well for homelab                |
| Visualization   | **Grafana**            | Already running on tharbad, rich dashboard ecosystem                                                       |
| Log aggregation | **Loki**               | Already configured (disabled) on tharbad, designed for Prometheus+Grafana stack, low resource usage vs ELK |
| Log shipping    | **Promtail**           | Native Loki companion; can scrape systemd journal on each host                                             |
| Alerting        | **Alertmanager**       | Native Prometheus integration, supports multiple notification channels                                     |
| Notifications   | **ntfy** (self-hosted) | See Notification System section below                                                                      |

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

Strict egress filter — tharbad should only talk to known targets:

```nix
# Allowed egress:
# - Gateway: DNS (53), NTP (123)
# - All scrape targets (prometheus exporter ports)
# - basel: ACME cert issuance (443)
# No general internet access needed
```

### Secrets (sops-nix)

| Secret                   | Used by                                           |
| ------------------------ | ------------------------------------------------- |
| `grafana-admin-password` | Grafana initial admin                             |
| `ntfy-auth-token`        | ntfy access control                               |
| `alertmanager-ntfy-url`  | Alertmanager webhook config (includes topic auth) |
| `grafana-oidc-secret`    | Grafana → Keycloak OIDC (future)                  |

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
| ymir_node          | localhost          | 9100 | node_exporter     |
| thebeyond_node     | thebeyond.internal | 9100 | node_exporter     |
| erebonia_node      | erebonia.internal  | 9100 | node_exporter     |
| calvard_node       | calvard.internal   | 9100 | node_exporter     |
| remiferia_node     | remiferia.internal | 9001 | node_exporter     |
| remiferia_zfs      | remiferia.internal | 9002 | zfs_exporter      |
| remiferia_smartctl | remiferia.internal | 9003 | smartctl_exporter |

**Guest scrape targets (configured, pending deploy):**

| Job             | Target              | Port | Exporter      |
| --------------- | ------------------- | ---- | ------------- |
| phantasma_node  | phantasma.internal  | 9100 | node_exporter |
| basel_node      | basel.internal      | 9100 | node_exporter |
| messeldam_node  | messeldam.internal  | 9100 | node_exporter |
| langport_node   | langport.internal   | 9100 | node_exporter |
| creil_node      | creil.internal      | 9100 | node_exporter |
| oracion_node    | oracion.internal    | 9100 | node_exporter |
| ardent_node     | ardent.internal     | 9100 | node_exporter |
| monrain_node    | monrain.internal    | 9100 | node_exporter |
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

### 2. Loki

```
Port: 3100
Retention: 30d
Storage: filesystem (boltdb-shipper + chunks on /var/lib/loki)
```

Receives logs from Promtail agents running on each host (via `promtail-client`
module). Local Promtail on tharbad scrapes its own systemd journal.

### 3. Promtail (deployed to each host)

Promtail runs as a lightweight agent on every NixOS host and microVM, shipping
systemd journal logs to Loki on tharbad.

**Deployment approach**: Add a shared NixOS module
(`modules/promtail-client/default.nix` or similar) that each host imports:

```nix
# Conceptual — actual module would be more complete
services.promtail = {
  enable = true;
  configuration = {
    server.http_listen_port = 3031;
    clients = [{ url = "http://tharbad.internal:3100/loki/api/v1/push"; }];
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
- Write token for CI/CD webhooks (Forgejo on ardent)
- Admin token for topic management

### 6. Grafana

```
Port: 3000 (proxied via nginx on 80/443)
Domain: tharbad.internal
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

Loki-based alerts are evaluated by Loki's built-in ruler (not Grafana — we
migrated dashboards to Perses). The ruler sends firing alerts to Alertmanager.

```yaml
# SSH authentication failures (from Loki ruler — LogQL queries)
# Implemented in loki.nix securityRules:
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

For hosts in the management zone, tharbad can already reach them (management zone
has `accessTo = [ "management" ... ]`). For DMZ hosts (langport, ardent, etc.),
the management zone already has `accessTo` that covers `trusted` and
`untrusted` but **not** DMZ, so cross-zone forward rules are needed:

```nix
# In thebeyond extraForwardRules:
# tharbad (management) → DMZ exporter ports
{ iifname = "vINFRA.br0"; oifname = "vDMZ.br0";
  ip.saddr = tharbad.ipv4; tcp.dport = 9100;
  verdict = "accept"; comment = "tharbad -> DMZ (node_exporter)"; }
```

### Promtail → Loki Connectivity

Hosts in all zones need to reach tharbad:3100 (Loki push endpoint). Management
zone hosts can already reach tharbad (intra-zone). For other zones:

- **trusted zone** → management: already allowed (`accessTo` includes
  `management`)
- **DMZ zone** → management: needs cross-zone forward rule for Loki port
  (**already implemented** — forward rules + per-host egress rules in place)

```nix
# DMZ hosts → tharbad for log shipping (ALREADY IN PLACE)
{ iifname = "vDMZ.br0"; oifname = "vINFRA.br0";
  ip.daddr = tharbad.ipv4; tcp.dport = 3100;
  verdict = "accept"; comment = "DMZ -> tharbad (Loki)"; }
```

---

## File Structure

Current file structure at `hosts/calvard/microvm/guests/tharbad/`:

```
hosts/calvard/microvm/guests/tharbad/
├── default.nix          # Networking, imports, persistence
├── microvm.nix          # Tap interface, MAC, resources
├── sops.nix             # TODO — secrets for grafana, ntfy, alertmanager
├── secrets/
│   └── secrets.yaml     # TODO — encrypted secrets
└── modules/
    ├── prometheus.nix   # Prometheus + scrape configs + alert rules ✓
    ├── grafana.nix      # Grafana + nginx reverse proxy + datasources (DISABLED)
    ├── loki.nix         # Loki + local promtail ✓
    ├── alertmanager.nix # Alertmanager + routing config (DISABLED)
    └── ntfy.nix         # ntfy notification server (DISABLED)

modules/promtail-client/default.nix  # Shared module, deployed fleet-wide ✓
```

---

## Implementation Phases

### Phase 1 — Core Metrics (COMPLETE)

- [x] Split monit.nix into `modules/prometheus.nix` + `modules/grafana.nix`
- [x] Expand Prometheus scrape targets to cover parent hosts
- [x] Bump RAM to 2048 MB, persist volume to 30 GB
- [x] Move `tharbad` from `trusted` to `management` in network registry (host ID 5)
- [x] Update `microvm.nix`: tap `vm-11-tharbad`
- [x] Add sops.nix + secrets for Grafana admin password + secret key
- [x] Write + enable `modules/grafana.nix` (nginx TLS via basel ACME, provisioned datasources)
- [x] Add egress filtering (default-drop, scrape targets + DNS/NTP + ACME)
- [x] Deploy and verify tharbad on VLAN 11 (management zone)
- [ ] Finish Grafana configuration (dashboards, full datasource verification)

### Phase 2 — Log Aggregation (COMPLETE)

- [x] Enable Loki on tharbad — `modules/loki.nix`: TSDB + v13 schema, port 3100
- [x] Enable local Promtail on tharbad via loki.nix
- [x] Create `modules/promtail-client/default.nix` shared module — fleet-wide
- [x] Deploy Promtail to all parent hosts + microVMs
- [x] Add cross-zone firewall rules for DMZ → tharbad Loki port (IPv4 + IPv6)
- [x] Add per-host egress rules for Loki push
- [ ] Verify logs flowing from all hosts after deployment

### Phase 3 — Alerting & Notifications (COMPLETE, pending deploy + verify)

- [x] Write + enable `modules/ntfy.nix` — ntfy on tharbad, port 2586
- [x] Write + enable `modules/alertmanager.nix` — Alertmanager with ntfy webhook receivers
- [x] Write Phase 1 alert rules — HostDown, DiskSpaceLow, HighMemoryUsage,
      ZFSPoolDegraded, SystemdUnitFailed
- [x] Provision Alertmanager + Loki datasources in Grafana
- [ ] Install ntfy app on phone, subscribe to topics
- [ ] Test alert pipeline: trigger test alert → Alertmanager → ntfy → phone

### Phase 4 — Expanded Monitoring

- [x] Create `modules/node-exporter-client/default.nix` shared module
- [x] Wire `node-exporter-client` into all flake builder functions
- [x] Enable node_exporter on all microVM + Incus guests (11 hosts)
- [x] Add scrape targets to prometheus.nix for all guests
- [x] Add egress rules on tharbad for all new scrape targets
- [x] Add management → DMZ/lab forward rules on router for Prometheus scraping
- [x] Rename stale `ymir_node` scrape job to `tharbad_node`
- [ ] Deploy service-specific exporters (unbound, kea, nginx, nftables) — blocked on thebeyond hardware
- [x] Add Phase 2 alert rules (Loki ruler: SSHBruteForce, SSHBruteForceExtreme, SudoFailure)
- [ ] Add remaining Phase 2 alerts (FirewallDropsSpike, CertExpiringSoon) — blocked on exporters
- [x] Add Phase 3 alert rules (Prometheus: SlowScrape, PrometheusRuleEvalFailure, LokiRequestErrors, LokiIngestionLag; also HighCPUUsage, HostRebooted in infrastructure group; Loki ruler: FleetLogGap)
- [ ] Build Perses dashboards (firewall overview, DNS stats) — replaced Grafana dashboards
- [ ] Configure CI/CD webhook integration (Forgejo → ntfy)
- [ ] Configure Perses OIDC auth via Keycloak (messeldam) — replaced Grafana OIDC

---

## Rejected Alternatives

### mTLS on Loki push endpoint

We considered adding mutual TLS to the Promtail→Loki connection so that only
hosts presenting a valid client certificate can push logs. The infrastructure
exists (basel runs step-ca, several hosts already use ACME), but the
operational cost outweighs the benefit for this deployment:

- **Every host running Promtail would need an ACME-issued client cert.**
  Management-zone hosts can already reach basel (intra-zone), but the cert
  renewal lifecycle adds a hard dependency: if basel is down, certs expire and
  log shipping stops across the fleet.
- **Certificate renewal plumbing** — Promtail and Loki need systemd restart
  triggers after ACME renewal. NixOS's `security.acme` handles renewal but
  wiring the restart dependencies for every host is boilerplate.
- **Loki needs a serving cert too** (for `https://`), plus its own ACME setup.
  Local Promtail on tharbad would need special handling (loopback TLS or a second
  plaintext listener).
- **The threat model doesn't justify it.** The DMZ→tharbad:3100 forward rules are
  narrow (specific destination + port), and the 5 DMZ hosts with egress filters
  are the only ones that can even attempt the connection. A compromised DMZ host
  can write garbage logs but can't read other hosts' logs or pivot further
  through Loki's append-only push API.

Revisit if Loki is ever exposed beyond the LAN or multi-tenant log separation
is needed.

---

## Resolved Questions

1. **ntfy external access**: VPN only (via `wg-vpn`). No DMZ exposure. Phone
   notifications require VPN connection when away from home.

2. **Retention**: 90 days for Prometheus metrics, 30 days for Loki logs.
   ~15-20 GB estimated disk usage. Tune down if needed.

3. **Grafana auth**: Local admin only (sops-managed password). Add Keycloak
   OIDC later via Keycloak (messeldam).

4. **Data migration**: Start fresh on VLAN migration. Prometheus history on the
   current VLAN 20 persist volume can be copied or discarded.
