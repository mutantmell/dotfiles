# Monitoring and dashboard operations

The current stack is declared under `hosts/calvard/microvm/guests/tharbad/modules/`: VictoriaMetrics for metrics, VictoriaLogs for logs, vmalert instances for their respective rule languages, Alertmanager, ntfy, and Perses. Old Prometheus/Grafana/Loki rollout instructions are retired.

Fleet Fluent Bit agents scrape local exporters and forward metrics/logs. nginx on tharbad terminates mTLS on 8427 for metrics and 3100 for Loki-compatible log push; the VictoriaLogs backend is loopback 9428. See `ingress.nix` for the exact paths and trust chain. Metrics ingestion derives the `host` label from certificate identity. Log labels remain client-supplied: mTLS admits a fleet member but does not prevent a compromised member claiming another host's name in the log body. nginx client identity remains useful audit evidence.

Perses uses Authelia OIDC. Dashboard YAML lives in `modules/dashboards/` beneath tharbad; changes belong in the repository, not only in the UI. Existing node, ZFS, fleet, log, VictoriaLogs, and Alertmanager views are a baseline. Use current datasource definitions and the `host` label when extending them.

For diagnosis, inspect the enabled systemd units and journal on tharbad, confirm an affected host's Fluent Bit journal, and check its latest metrics/log timestamps in the UI. Distinguish ingestion failure from a missing dashboard selector. Check metric rules against VictoriaMetrics and log rules against VictoriaLogs; old localhost:9090 commands are not the current metrics service contract.

Remaining exporters, firewall/certificate alerts, audit views, and live phone acceptance are separate [issues](work-tracking.md). The procedures below describe the configured notification path; they are not a record of successful live acceptance.

## Notification subscriptions and access

Use server URL **`https://ntfy.internal`** in the ntfy app or web client, from the home network or the intended `wg-vpn` path. The client must resolve that name and trust the internal CA. Do not bypass TLS verification to work around missing trust.

The current [ntfy module](../hosts/calvard/microvm/guests/tharbad/modules/ntfy.nix) defaults to deny-all, seeds an `admin` account, and grants anonymous **write-only** access to these four topics. Reading/subscribing requires an authenticated account with read access. Obtain credentials through the operator secret workflow, not from issue attachments or pasted shell commands. For a phone, prefer a dedicated subscriber account rather than sharing the admin account.

To provision that account, use an operator shell on tharbad. Locate the deployed `/nix/store/…/bin/ntfy` executable in `systemctl cat ntfy-sh.service` and set `ntfy_bin` to that exact path. Run the following against the deployed server configuration; `user add` prompts for a new password:

```bash
sudo "$ntfy_bin" user add phone
for topic in infra-critical security services cicd; do
  sudo "$ntfy_bin" access phone "$topic" read-only
done
sudo "$ntfy_bin" access phone
```

Create the user only if it does not already exist; inspect existing access before changing it. These are operator-managed entries in the persisted ntfy auth database, not new declarative users. CLI permissions are described in the [upstream access-control documentation](https://docs.ntfy.sh/config/#access-control).

Add the account under the app's settings for `https://ntfy.internal`, then subscribe to the required topics:

| Topic            | Current Alertmanager selection                               |
| ---------------- | ------------------------------------------------------------ |
| `infra-critical` | `severity=critical`                                          |
| `security`       | `category=security`, unless the critical route matched first |
| `cicd`           | `category=cicd`, unless an earlier route matched             |
| `services`       | Default receiver for alerts not matched above                |

The [Alertmanager configuration](../hosts/calvard/microvm/guests/tharbad/modules/alertmanager.nix) defines this routing order. Internal webhook delivery uses localhost port 2586 with `template=alertmanager`; client subscriptions use HTTPS. Anonymous publishing does not imply anonymous reading. Verify an unauthenticated topic read is rejected and the subscriber can read its granted topics.

## Bounded notification test

Run the following in one operator shell **on tharbad**, with `curl`, `jq`, and GNU `date` available. No deployment, rule edits or public endpoint are needed. First inspect the current receivers and active alerts:

```bash
curl --fail --silent --show-error http://127.0.0.1:9093/api/v2/receivers | jq .
curl --fail --silent --show-error http://127.0.0.1:9093/api/v2/alerts | jq .
```

Announce the test to other subscribers as appropriate. Inject a uniquely labelled critical alert with an explicit ten-minute expiry:

```bash
test_instance="operator-notification-test-$(date -u +%Y%m%dT%H%M%SZ)-$$"
test_started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
test_expires=$(date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ)

post_test_alert() {
  jq -n --arg instance "$test_instance" --arg start "$test_started" --arg end "$1" \
    '[{labels: {alertname: "OperatorNotificationTest", severity: "critical", instance: $instance},
       annotations: {summary: "Operator notification test; no incident"},
       startsAt: $start, endsAt: $end}]' |
    curl --fail --silent --show-error -X POST \
      -H 'Content-Type: application/json' --data-binary @- \
      http://127.0.0.1:9093/api/v2/alerts
}
post_test_alert "$test_expires"
```

The [Alertmanager alerts API](https://prometheus.io/docs/alerting/latest/alerts_api/) accepts this labelled alert and explicit end time. Check the exact instance in `/api/v2/alerts`, confirm it is neither silenced nor inhibited, and allow the configured 30-second group wait before expecting `infra-critical` delivery. If delivery fails, inspect Alertmanager and ntfy service journals before retrying; do not inject an unbounded stream of test alerts.

Confirm receipt in the phone app and, if needed, inspect recent messages with authenticated HTTPS polling (`curl` prompts for the password; substitute your subscriber username):

```bash
curl --fail --silent --show-error --user phone \
  'https://ntfy.internal/infra-critical/json?poll=1&since=10m' | jq .
```

Resolve the **same label set** explicitly once firing delivery is observed. Keep the shell variables/function above until cleanup is complete:

```bash
post_test_alert "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
curl --fail --silent --show-error http://127.0.0.1:9093/api/v2/alerts |
  jq --arg instance "$test_instance" '[.[] | select(.labels.instance == $instance)]'
unset -f post_test_alert
unset test_instance test_started test_expires
```

Confirm the test is no longer active and observe the resolved notification; delivery can wait for the configured five-minute group interval. If it is absent, inspect the effective receiver's `send_resolved` setting and delivery logs rather than assuming resolution delivery works. If the shell is lost, the original ten-minute `endsAt` bounds firing; verify expiry before repeating the test. Leave real alerts, silences and routing unchanged. Historical test messages can remain in the normal ntfy cache; no persistent rule was added to remove.

Repeat the phone check away from the LAN over `wg-vpn`, including VPN disconnect/reconnect, and record actual delivery and resolution times. This tests **Alertmanager → ntfy → subscriber**, bypassing VictoriaMetrics/VictoriaLogs rule evaluation. Full pipeline acceptance additionally needs a controlled input that causes the relevant vmalert rule to fire and resolve; record that separately.

## Kubernetes coverage and bootstrap diagnosis

Current host journal/node-exporter collection does not establish pod stdout/stderr or Kubernetes object-state coverage. The selected follow-ups are [cluster metrics](https://forgejo.internal/mutantmell-net/dotfiles/issues/252) and [pod logs](https://forgejo.internal/mutantmell-net/dotfiles/issues/253), using the existing VictoriaMetrics/VictoriaLogs stores and scoped collector identities. Their deployment and failure/label acceptance remain outstanding.

Before centralized collectors are healthy, inspect `systemctl status k3s.service` and `journalctl -u k3s.service --since '-15 minutes'` on the affected cluster host. If its API is reachable, set `cluster_context` to the intended operator kubeconfig context and inspect readiness/events:

```bash
kubectl --context "$cluster_context" get nodes
kubectl --context "$cluster_context" get pods -A
kubectl --context "$cluster_context" get events -A --sort-by=.lastTimestamp
```

Use `kubectl describe` and scoped pod logs for the failing component after identifying it. Keep operator kubeconfig/cluster credentials outside agent containers. If the API is unavailable, use host journal/console and the documented datastore/identity recovery route; healthy Flux is not a prerequisite for that diagnosis. Store detailed logs privately and redact credential-bearing content from issue evidence.

The phone-notification issue covers device subscription and delivery acceptance
only: Alertmanager receivers, ntfy HTTPS, authentication persistence and topic
permissions already exist. Reuse this infrastructure; add a subscriber identity
with only the required read access rather than treating the existing admin
account as the desired phone identity. Phone app state is outside this flake.
