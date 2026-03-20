# Grafana Setup Guide

Step-by-step instructions for configuring Grafana on tharbad. Assumes
Grafana is already deployed and reachable at `https://tharbad.internal/`.

---

## 1. First Login

Open `https://tharbad.internal/` in a browser on the home network.

Grafana is configured with Keycloak OIDC (`auto_login = true`), so it
should redirect you to Keycloak automatically. Log in with your Keycloak
`homelab` realm credentials. If your Keycloak user is in the `admin`
group, you'll get the Grafana Admin role.

**If Keycloak is down or OIDC isn't working**, you can bypass it by
navigating to `https://tharbad.internal/login?disableAutoLogin` and
using the local admin account (username: `admin`, password: from
sops secret `grafana-admin-password`).

---

## 2. Verify Datasources

Three datasources are provisioned automatically via Nix. Verify they're
connected:

1. Go to **Connections > Data sources** (left sidebar, gear icon)
2. You should see: **Prometheus**, **Loki**, **Alertmanager**
3. Click each one and hit **Test** at the bottom
   - Prometheus → "Successfully queried the Prometheus API"
   - Loki → "Data source successfully connected"
   - Alertmanager → "OK"

If any fail, check that the corresponding service is running on tharbad
(`systemctl status prometheus`, `systemctl status loki`, `systemctl
status alertmanager`).

---

## 3. Quick Sanity Check with Explore

Before importing dashboards, verify data is actually flowing.

### Prometheus metrics

1. Go to **Explore** (compass icon in the left sidebar)
2. Make sure **Prometheus** is selected as the datasource (top dropdown)
3. Switch to **Code** mode (toggle at top-right of the query editor)
4. Type `up` and click **Run query**
5. You should see one row per scrape target, with value `1` (up) or `0` (down)

If you see results, Prometheus is scraping successfully.

### Loki logs

1. Still in **Explore**, switch the datasource dropdown to **Loki**
2. Switch to **Builder** mode
3. Under **Label filters**, select `host` and pick any host name
4. Click **Run query**
5. You should see journal log lines from that host

If you see logs, Promtail → Loki is working.

---

## 4. Import Community Dashboards

Grafana has a large library of pre-built dashboards. You import them by
their numeric ID from grafana.com.

### Node Exporter Full (Dashboard #1860)

This is the standard dashboard for `node_exporter` metrics — CPU, memory,
disk, network, etc. It's the single most useful dashboard for infrastructure
monitoring.

1. Go to **Dashboards** (left sidebar) → **New** → **Import**
2. In the **"Import via grafana.com"** field, enter: `1860`
3. Click **Load**
4. On the next screen:
   - **Name**: leave as "Node Exporter Full" (or customize)
   - **Folder**: "General" is fine, or create a folder like "Infrastructure"
   - **Prometheus**: select your **Prometheus** datasource from the dropdown
5. Click **Import**

You should immediately see panels populating with CPU, memory, disk I/O,
network traffic, etc. Use the **Host** dropdown at the top to switch between
scraped targets.

**Note:** The `instance` labels in Prometheus will look like
`thebeyond.internal:9100` or `remiferia.internal:9001`. The dashboard's
host filter uses these labels.

### Other useful community dashboards

| Dashboard          | ID    | What it shows                                               | Requires                          |
| ------------------ | ----- | ----------------------------------------------------------- | --------------------------------- |
| Node Exporter Full | 1860  | CPU, memory, disk, network per host                         | node_exporter (already deployed)  |
| Prometheus Stats   | 2     | Prometheus self-monitoring (ingestion rate, memory, chunks) | Prometheus (already running)      |
| Loki & Promtail    | 10880 | Log volume, Promtail throughput                             | Loki + Promtail (already running) |
| Alertmanager       | 9578  | Alert state, notification history                           | Alertmanager (already running)    |

Import process is the same for all — enter the ID, load, select the
matching datasource, import.

**To import any dashboard:** Go to
`https://grafana.com/grafana/dashboards/` and browse. Each dashboard page
shows the ID number and which datasource/exporter it expects.

---

## 5. Explore Logs in Loki

Loki is Grafana's log backend. It works differently from Prometheus —
instead of metrics, you query log lines using **LogQL**.

### Using the visual builder

1. Go to **Explore**, select **Loki** datasource
2. Use **Builder** mode (easier to start with)
3. Pick labels to filter:
   - `host` — which machine the logs came from
   - `unit` — which systemd unit (e.g., `sshd.service`, `nginx.service`)
4. Click **Run query**

### Common LogQL queries (Code mode)

```logql
# All logs from a specific host
{host="langport"}

# All logs from a specific systemd unit across all hosts
{unit="sshd.service"}

# Filter log lines containing a string
{host="langport"} |= "error"

# Case-insensitive search
{host="langport"} |~ "(?i)error"

# Exclude noise
{host="thebeyond"} != "CRON"

# Combine filters
{host="remiferia", unit="zfs-zed.service"} |= "scrub"

# Count log lines per host over time (for graphing)
sum by (host) (rate({unit="sshd.service"}[5m]))
```

### Tips

- Loki queries **must** start with a label selector in `{}` — you can't
  just search all logs with a text filter.
- The **Live tail** button (top right in Explore) streams logs in real time.
- Log volume is shown as a histogram above the log lines — useful for
  spotting spikes.

---

## 6. Verify Alertmanager Integration

### Check alert rules are loaded

1. Go to **Alerting** (bell icon in left sidebar) → **Alert rules**
2. You should see the rules defined in `prometheus.nix`:
   - HostDown, DiskSpaceLow, HighMemoryUsage, ZFSPoolDegraded, SystemdUnitFailed
3. Each rule shows its current state: **Normal** (green), **Pending**
   (yellow), or **Firing** (red)

If you don't see any rules here, check **Alerting > Contact points** and
confirm the Alertmanager datasource is listed.

**Note:** These are Prometheus-evaluated alert rules (defined in
`services.prometheus.rules`), not Grafana-managed alert rules. Grafana
reads them from Alertmanager's API. You may need to look under the
Alertmanager-sourced rules rather than Grafana-managed rules.

### Check Alertmanager status directly

SSH into tharbad and run:

```bash
# See current alerts (should be empty if everything is healthy)
curl -s http://localhost:9093/api/v2/alerts | jq .

# See configured receivers
curl -s http://localhost:9093/api/v2/receivers | jq .
```

---

## 7. Test the Alert Pipeline

This verifies the full chain: Prometheus → Alertmanager → ntfy.

### Option A: Fire a test alert via Alertmanager API

SSH into tharbad and run:

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

This injects a test alert directly into Alertmanager. It should:

1. Route to `ntfy-critical` (because `severity: critical`)
2. Send a webhook to `http://localhost:2586/infra-critical`
3. Show up in the ntfy topic

### Option B: Check ntfy received it

```bash
# Check ntfy received the alert (last 10 messages on the topic)
curl -s 'http://localhost:2586/infra-critical/json?poll=1&since=1h' | jq .
```

If you've installed the ntfy app on your phone and subscribed to the
topic `infra-critical` at `http://tharbad.internal:2586`, you should
get a push notification.

### Subscribe on your phone

1. Install the **ntfy** app ([Android](https://play.google.com/store/apps/details?id=io.heckel.ntfy) / [iOS](https://apps.apple.com/app/ntfy/id1625396347))
2. Add a subscription:
   - **Server URL**: `http://tharbad.internal:2586` (only works on home network or VPN)
   - **Topic**: `infra-critical` (or `services`, `security`, etc.)
3. Fire the test alert above — you should get a notification

**Suggested topics to subscribe to:**

| Topic            | What you'll get                             |
| ---------------- | ------------------------------------------- |
| `infra-critical` | Host down, disk full, ZFS degraded (urgent) |
| `services`       | Default catch-all for service health        |
| `security`       | SSH brute force, firewall anomalies         |

---

## 8. Housekeeping

### Folder organization

As you add dashboards, consider organizing them into folders:

- **Infrastructure** — Node Exporter Full, Prometheus Stats
- **Logs** — Loki/Promtail dashboards
- **Alerts** — Alertmanager overview

Create folders via **Dashboards** → **New** → **New folder**.

### Saving dashboard changes

Community dashboards are imported into Grafana's database (persisted at
`/var/lib/grafana` on tharbad). If you customize a dashboard, those
changes persist across restarts but **not** across VM rebuilds unless
the persist volume is preserved.

For dashboards you customize heavily, you can export them as JSON
(**Dashboard settings** → **JSON Model** → copy) and provision them
via Nix in `grafana.nix` using `provision.dashboards`. This is optional —
only worth doing once you have dashboards you've invested time into.
