# Homelab documentation

Code and the network registry represent current homelab state for devices managed
by this repository. Separate implemented configuration from future design and from
behavioral checks, application/data state or manually managed hardware that code
does not establish. Work tracking belongs in Forgejo; [status conventions and the migration mapping](work-tracking.md)
record the completed issue import. [Migration disposition](../llm-notes/README.md) accounts for every old note.

## Operator guides

- [Deployment and installation](deployment.md), [router deployment](router-deployment.md), [OpenWrt deployment](openwrt-deployment.md)
- [OpenWrt fleet capture and staged management](openwrt-operations.md)
- [Monitoring and dashboards](observability.md)
- [Recurring external WAN audit](network/wan-audit.md)
- [Jellyfin LDAP reconstruction](jellyfin-ldap.md)
- [Media layout](media-library.md) and [detailed ingestion](media-ingestion.md)
- [Identity resilience](identity-resilience.md), [JWK break-glass SSH](step-ca-jwk-break-glass.md), [identity incident response](authelia-incident-response.md)
- [Dev machines](dev-machine.md), [managed clients/workstations](client-workstations.md), [hostnames](hostnames.md)
- [Host identity](host-identity.md), [secrets](secrets.md), [security model](security-model.md)
- [Arteria gateway](arteria-gateway.md), [Git Pages](git-pages.md)

## Architecture and explicit proposals

- [Workload trust/network boundaries](network/workload-isolation.md)
- [DNS](network/dns.md) and [IPv6](network/ipv6.md)
- [Dated BT8 observed-state evidence](network/bt8-observed-state.md) — fresh capture required before deployment
- [Planned host pull updates](host-pull-updates.md) and [full fleet-delivery contract](design/fleet-delivery.md)
- [Current and target cluster ownership](design/cluster-ownership.md)
- [Selected persistent workstation ownership/bootstrap contract](design/workstation-lifecycle.md)
- [Deferred decisions and revisit conditions](design/deferred-decisions.md)
- [Proposed Pi sensor gateway](design/iot-device.md)

## Existing documents with identified follow-ups

The [organization transfer record](forgejo-org-transfer.md) records
pre-transfer observations and remaining verification, not current ownership.
The [deployment alternatives](deployment-options-comparison.md) and
[security audit report](security-audit-report.md) are dated analysis, not proofs
that every suggested control has been deployed.
