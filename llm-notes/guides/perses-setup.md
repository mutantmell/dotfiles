# Perses Setup Guide

Step-by-step instructions for the Perses monitoring dashboard on tharbad.
Assumes Perses is deployed and reachable at `https://tharbad.internal/`.

Perses replaces the previous Grafana deployment. It is a lighter-weight
CNCF dashboarding tool with native Prometheus and VictoriaLogs support and a
dashboards-as-code model that fits our Nix-managed infrastructure.

---

## 1. Verify the Service

Open `https://tharbad.internal/` in a browser on the home network.

Perses is configured with Authelia OIDC, so it should redirect you to
Authelia automatically. Log in with your lldap-backed account.

If the page doesn't load, SSH into tharbad and check:

```bash
systemctl status perses
journalctl -u perses --no-pager -n 50
```

---

## 2. Verify Datasources

Two global datasources are provisioned automatically via Nix:

1. Navigate to the **gear icon** (Admin) in the left sidebar
2. Under **Global datasources** you should see:
   - **prometheus** (Prometheus, default)
   - **victorialogs** (VictoriaLogs)

If either is missing, check that the provisioning directory was loaded:

```bash
ls -la /nix/store/*perses-provisioning*/
journalctl -u perses --no-pager | grep -i provision
```

---

## 3. Verify the Monitoring Project

A `monitoring` project is provisioned automatically. It contains the
dashboards defined in `modules/dashboards/`. The project definition and
datasources are generated from Nix attrsets in `perses.nix`.

1. Click **Projects** in the left sidebar
2. You should see the **Monitoring** project
3. Click into it — you should see these dashboards:
   - **Node Overview** — CPU, memory, disk, network per host
   - **Prometheus Overview** — target health, scrape performance, resource usage
   - **Alertmanager Overview** — active alerts, notification success/failure rate, latency
   - **Log Viewer** — VictoriaLogs browser with host and text filter

---

## 4. Quick Sanity Check

### Check metrics are flowing

1. Open the **Node Overview** dashboard
2. Use the **Instance** dropdown at the top to select a host
   (instances appear as `<hostname>.internal:9100`)
3. You should see CPU, memory, disk I/O, and network panels populate

If panels show "No data", check Prometheus is scraping:

```bash
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health}'
```

### Check logs are flowing

1. Open the **Log Viewer** dashboard
2. Select a host from the **Host** dropdown
3. You should see log lines from that host in the LogsTable panel
4. Use the **Filter** text field for `|=` line matching (e.g. "error")

If no logs appear, verify VictoriaLogs is receiving data. The nginx push
endpoint keeps Loki-compatible API paths for Fluent Bit, while Perses queries
VictoriaLogs directly on its native port:

```bash
curl -s 'http://localhost:9428/select/logsql/query' -d 'query=* | limit 1' | jq .
```

---

## 5. Verify Alertmanager Integration

### Check alert rules in Prometheus

```bash
# From tharbad — list loaded alert rules
curl -s http://localhost:9090/api/v1/rules | jq '.data.groups[].rules[] | {name: .name, state: .state}'
```

You should see: HostDown, DiskSpaceLow, HighMemoryUsage, ZFSPoolDegraded,
SystemdUnitFailed.

### Check Alertmanager API directly

```bash
# Current alerts (should be empty if everything is healthy)
curl -s http://localhost:9093/api/v2/alerts | jq .

# Configured receivers
curl -s http://localhost:9093/api/v2/receivers | jq .
```

---

## 6. Test the Alert Pipeline

This verifies the full chain: Prometheus → Alertmanager → ntfy.

### Fire a test alert

```bash
curl -X POST http://localhost:9093/api/v2/alerts \
  -H 'Content-Type: application/json' \
  -d '[{
    "labels": {
      "alertname": "TestAlert",
      "severity": "critical",
      "instance": "test"
    },
    "annotations": {
      "summary": "This is a test alert"
    }
  }]'
```

This should route to `ntfy-critical` and send a webhook to
`http://localhost:2586/infra-critical`.

### Verify ntfy received it

```bash
curl -s 'http://localhost:2586/infra-critical/json?poll=1&since=1h' | jq .
```

### Subscribe on your phone

1. Install the **ntfy** app
   ([Android](https://play.google.com/store/apps/details?id=io.heckel.ntfy) /
   [iOS](https://apps.apple.com/app/ntfy/id1625396347))
2. Add a subscription:
   - **Server URL**: `http://tharbad.internal:2586` (home network or VPN only)
   - **Topic**: `infra-critical`
3. Fire the test alert above — you should get a push notification

**Topics to subscribe to:**

| Topic            | What you'll get                             |
| ---------------- | ------------------------------------------- |
| `infra-critical` | Host down, disk full, ZFS degraded (urgent) |
| `services`       | Default catch-all for service health        |
| `security`       | SSH brute force, firewall anomalies         |

---

## 7. Adding Custom Dashboards

Perses dashboards are YAML files following a validated schema. They can
be created in two ways:

### Option A: Via the UI

1. Open the **Monitoring** project
2. Click **+ Create** → **Dashboard**
3. Use the visual editor to add panels, queries, and variables
4. Changes are saved to `/var/lib/perses/data/` (persisted on tharbad)

### Option B: Provisioned via Nix (recommended)

For dashboards you want to survive VM rebuilds and be version-controlled,
add a YAML file to `modules/dashboards/`. The provisioning directory is
assembled from these dashboard files plus Nix-generated datasource and
project definitions.

**Example: a VictoriaLogs log volume dashboard**

Create a YAML file in `modules/dashboards/`:

```yaml
kind: Dashboard
metadata:
  name: victorialogs-log-volume
  project: monitoring
spec:
  display:
    name: VictoriaLogs / Log Volume
  variables:
    - kind: ListVariable
      spec:
        display:
          name: host
          hidden: false
        allowAllValue: true
        allowMultiple: false
        plugin:
          kind: PrometheusLabelValuesVariable
          spec:
            datasource:
              kind: PrometheusDatasource
              name: prometheus
            labelName: host
            matchers:
              - promtail_build_info
        name: host
  panels:
    "0_0":
      kind: Panel
      spec:
        display:
          name: Log Lines per Host (rate)
        plugin:
          kind: TimeSeriesChart
          spec:
            legend:
              position: bottom
              mode: table
              values: [last]
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  datasource:
                    kind: PrometheusDatasource
                    name: prometheus
                  query: sum by (host) (rate(promtail_custom_entries_total{host=~"$host"}[5m]))
                  seriesNameFormat: "{{host}}"
  layouts:
    - kind: Grid
      spec:
        display:
          title: Log Volume
        items:
          - x: 0
            "y": 0
            width: 24
            height: 10
            content:
              $ref: "#/spec/panels/0_0"
  duration: 1h
```

### Community dashboards

The [perses/community-dashboards](https://github.com/perses/community-dashboards)
repo has reference dashboards for node-exporter, Prometheus, Alertmanager,
etcd, Thanos, Kubernetes, Istio, OpenTelemetry Collector, and Tempo.
These are written in Go using the Perses SDK and compiled to YAML —
useful as a reference for query patterns and panel layout, but our
dashboards are written directly as YAML tailored to our setup.

---

## 8. Architecture Notes

### How it differs from Grafana

- **No plugin ecosystem** — Perses ships with built-in panel types
  (TimeSeriesChart, GaugeChart, StatChart, LogsTable, BarChart) and
  datasource types (Prometheus, VictoriaLogs, Tempo). No marketplace needed.
- **No `${DS_PROMETHEUS}` indirection** — datasources are referenced
  directly by name in dashboard YAML. No import-time variable mapping.
- **Dashboards-as-code first** — YAML with a validated schema, designed
  for version control and provisioning. The UI is an editor, not the
  source of truth.
- **Authelia OIDC authentication** — same identity provider as other homelab
  services. Client secret managed via sops-nix.

### Resource footprint

Perses is a single Go binary. Expect ~50-100 MB RSS vs Grafana's
~300-500 MB. The file-based database (YAML files in `/var/lib/perses/data/`)
eliminates the need for SQLite/Postgres.

### Persistence

Dashboard state lives in two places:

1. **Provisioned dashboards** — in the Nix store, rebuilt on deploy.
   These are the source of truth for community and custom dashboards
   managed as code.
2. **UI-created dashboards** — in `/var/lib/perses/data/` (persisted
   via impermanence). These survive reboots but not VM rebuilds unless
   the persist volume is preserved.

For dashboards you invest time into via the UI, export them as YAML
and add them to the provisioning derivation to make them permanent.
