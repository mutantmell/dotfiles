# Comprehensive migration review: resolution record

The full-source review compared all 72 original Markdown documents at `087f4f92dbe5b50479ff77065e7ecac33d7fa2a5` with migration commit `ed0a4ee`, all 89 then-existing draft bodies, and current implementation evidence. This follow-up addresses its eleven P2 omissions and one P3 documentation finding. At that review the migration had **96 individual issue drafts**; the [current issue index](../docs/work-tracking.md) records subsequent dispositions and counts. This record means requirements/procedures were restored, not that their proposed implementations or live acceptance tests have shipped.

| Finding | Resolution | Reviewable acceptance/procedure |
| --- | --- | --- |
| 1. Workstation root-identity trust boundary | Restore stopped-VM/offline disk seeding, exact guest age path, cleanup and explicit exclusions from cluster-held secret delivery. | [Ownership/bootstrap contract](../docs/design/workstation-lifecycle.md); [provisioning draft](https://forgejo.internal/mutantmell-net/dotfiles/issues/255) |
| 2. Guest updater ownership/enrollment | Separate Flux shell, one-shot provisioning and in-guest Comin; require signed release/closure enrollment, persisted state, cache-failure/recovery and exclusive old/new convergence. Both cutovers depend on this work. | [Guest updater draft](https://forgejo.internal/mutantmell-net/dotfiles/issues/261); [fleet contract](../docs/design/fleet-delivery.md); [edith](https://forgejo.internal/mutantmell-net/dotfiles/issues/258), [trista](https://forgejo.internal/mutantmell-net/dotfiles/issues/259) |
| 3. Backup mount failure | Require mount dependencies plus dataset/mount identity verification for namespace-backed writers, mirrors and dumps; add unmounted-parent negative acceptance. | [Namespace](https://forgejo.internal/mutantmell-net/dotfiles/issues/210), [mirrors](https://forgejo.internal/mutantmell-net/dotfiles/issues/211), [application dumps](https://forgejo.internal/mutantmell-net/dotfiles/issues/212) |
| 4. Cluster telemetry | Split selected Kubernetes metrics/object state and pod-log ingestion into bounded work units using current backends. Retain API-down/bootstrap diagnostic instructions. | [Metrics](https://forgejo.internal/mutantmell-net/dotfiles/issues/252), [pod logs](https://forgejo.internal/mutantmell-net/dotfiles/issues/253), [operator diagnosis](../docs/observability.md#kubernetes-coverage-and-bootstrap-diagnosis) |
| 5. CI resource containment | Add per-step/job and namespace/worker bounds plus safe negative admission, egress and resource-exhaustion acceptance for actual runner backends; link from the lane trust audit. | [Build containment](https://forgejo.internal/mutantmell-net/dotfiles/issues/203); [runner audit](https://forgejo.internal/mutantmell-net/dotfiles/issues/194) |
| 6. Independent friend router boundary | Require a Nix-owned default-drop host forwarding firewall, including same-zone targets, and negative tests under deliberately widened Headscale ACL/routes. | [Restricted routing](https://forgejo.internal/mutantmell-net/dotfiles/issues/263) |
| 7. Immutable inner image identity | Separate exact content/digest proof and verified preload/pull from upload deduplication, retention and deferred snapshotter work. Test stale tags and cold/refresh/recovery behavior. | [Image identity](https://forgejo.internal/mutantmell-net/dotfiles/issues/279); [publication optimization](https://forgejo.internal/mutantmell-net/dotfiles/issues/275) |
| 8. Curated TV | Preserve canonical Sonarr ownership, generated hardlink-view ownership and Jellyfin metadata/presentation contract; defer implementation until an operator-selected title/order mapping. HQ remains conditional. | [Media contract](../docs/media-library.md#curated-tv-selected-deferred-work); [curated-TV draft](https://forgejo.internal/mutantmell-net/dotfiles/issues/271) |
| 9. Angbar VPN | Correct completed-history language. Inventory existing manual profiles before verifying/configuring offsite client handshake, DNS/routing, reconnect and recovery. | [Client guide](../docs/client-workstations.md); [VPN acceptance](https://forgejo.internal/mutantmell-net/dotfiles/issues/237) |
| 10. Recurring WAN audit | Extract off-network TCP/UDP/echo/keyed-WireGuard checks, both-family scope, expected-surface review and private SHA-linked evidence; replace the obsolete three-tunnel assumption. | [WAN audit runbook](../docs/network/wan-audit.md); [OpenWrt lifecycle acceptance](https://forgejo.internal/mutantmell-net/dotfiles/issues/225) |
| 11. Jellyfin LDAP reconstruction | Preserve operator-managed plugin/config ownership, current IPv4 transport, secret authority, bind/base/membership settings, local-admin fallback and web/mobile negative authorization checks. Distinguish media membership from administrator assignment. | [LDAP reconstruction](../docs/jellyfin-ldap.md) |
| 12. Retained media facts | Remove the old oracion DMZ literal, describe both installed Lidarr tiers and their staging/library paths, and replace the curated-view dangling TBD with its explicit contract/draft. | [Media ingestion](../docs/media-ingestion.md); [media layout](../docs/media-library.md) |

The review's nonblocking dev-slot IPv6 follow-up is explicitly deferred to the stable-ingress rollout with a reachability/isolation decision; it is not silently treated as completed DHCPv6 work. Monitoring implementation preparation may start independently, while live rollout/phone acceptance remains operator-gated. Previously fixed Trista direct wg-ba/VLAN-100 and bounded notification procedures remain retained.

The original-source disposition table and issue index include the added destinations. The operator scratchpad remains unchanged. No live issues, production accounts, alerts, firewall rules or deployments were created by these documentation corrections.

## Second comprehensive review

The second pass reread every original source in full, all 96 draft bodies and
provenance, all changed documentation and entrypoint/comment changes. It compared
retired procedures and excluded ideas against current code and later decisions,
rather than sampling large files. The following findings were resolved:

- Friend enrollment now requires individual single-use scoped keys with an initial
  24-hour expiry and consumed/expired-key rejection tests in friends-01/03.
- [Dev-machine guidance](../docs/dev-machine.md) records current organization/fork
  ownership and restores mobile tssh, public-key injection and zellij attachment.
- OpenWrt drafts and [operations](../docs/openwrt-operations.md) retain non-DFS
  80 MHz qualification, disabled mesh forwarding beneath batman, role-specific
  DHCP/RA ownership, ULA-only default-route/RDNSS acceptance and separate cutovers.
- [Pod egress](https://forgejo.internal/mutantmell-net/dotfiles/issues/229) retains the independent
  host INPUT boundary, management/default-route and pod/Service exclusions,
  direct VLAN-51 neighbor negative tests and node/flannel restart acceptance.
- [Incus recovery](../docs/client-workstations.md#incus-guest-recovery-while-incus-remains-in-service)
  preserves backup/restore, external identities and recreation/update/reboot
  steps, including the current image-source marker guard after image removal.
- Arseille's deleted guide is correctly mapped to [network-06](https://forgejo.internal/mutantmell-net/dotfiles/issues/233),
  the NETGEAR GS108Tv3 management transition, rather than the separate GS1900
  PoE import. Coexistence routing and VLAN-10 L2 continuity remain explicit.
- [Media ingestion](../docs/media-ingestion.md) now reflects the full read-only
  export visible to oracion, preserves canonical Sonarr numbering, and replaces
  source-removing/flattening migration commands with verified copy-first batches,
  preserved relative paths and collision failure before separately approved cleanup.

Monitoring preparation remains independently actionable; production rollout and
phone acceptance remain operator-gated. No additional dependency on operator
availability is imposed on offline preparation. The 72-source inventory and
96-draft count are unchanged; no live issues or production actions were performed.

## Architecture and obsolescence review (2026-10-26)

The feature-tracking review reconciles the historical drafts with selected OpenWISP management and the Arteria gateway decision. The current index has **100 records: 96 import candidates (80 non-deferred and 16 Deferred), 0 Held and 4 Retired**. This changes proposed work, not live state. Import the 16 Deferred candidates as open issues with `status/deferred`; exclude Held and Retired records. Candidate drafts still require duplicate checks and their prerequisite/operator gates.

- Retain non-import tombstones for in-flake per-device OpenWrt rendering (`openwrt-04`), the replacement BT8 gateway (`openwrt-06`) and the dependent wg-ba relocation (`network-05`). No fresh tunnel relocation is justified by this review.
- Retire `dev-06`: the current managed runtime configuration has no Kata residue. The operator subsequently reproduced tunnel errors during successful setup/logout; `dev-03` is Ready with that concrete teardown scope. Historical authentication symptoms remain excluded.
- Rewrite wireless/switch/firmware work for Flint 2/BT8Bridge, independent recovery, shared model firmware and OpenWISP operational ownership. Defer the third BT8 until a useful role is selected; retain optional coverage-driven E8450 retirement without the old rotation dependency.
- Add trusted calvard controller/bootstrap, wired enrollment/ownership/offline acceptance, a single-device firmware upgrade/recovery pilot and independent NixOS/systemd Arteria microVM migration. OpenWISP is selected; deployment prerequisites remain gated.
- Correct gateway ownership in VIP, netmgmt and IPv6 drafts. Narrow DNS work around existing registry/kresd implementation and Arteria behavioral tests; reserve dns-04 for the demonstrably missing interception query/transport proof.

The earlier comprehensive-review records above remain historical provenance, not instructions to recreate superseded architecture. See the [current index](../docs/work-tracking.md) and [operator contract](../docs/openwrt-operations.md) for current scope.

The current-state reconciliation treats repository-managed configuration as the
current homelab baseline. Arteria implementation, Arcus enrollment, media directory
creation, Retrom roots, Samba symlink support and notification infrastructure are
complete. Drafts now cover only residual policy/behavior, data/application state,
phone subscription and the concrete missing Arcus APP destination routes. Angbar
still needs client configuration, Arseille remains on registry VLAN 10, and MFA
scope includes the existing one-factor k3s consumer. This documentation change
does not alter runtime configuration or import issues.

## Long-term task tracking posture (2026-10-26)

Forgejo issues will preserve retained tasks as source documentation is reduced.
Deferred work remains worth tracking: import all 16 deferred drafts with
`status/deferred`, their reason for deferral and concrete revisit trigger, without
an active milestone or assignee. Keep them outside the actionable backlog.
Retain `status/todo` for selected work awaiting implementation; use
`status/blocked` for selected work waiting on an identified dependency. Deferral
is an intentional postponement, not a claim that implementation is approved.

Before deleting source documents, copy essential design context and acceptance
criteria into the corresponding issues, replace draft dependency links with issue
URLs and record the mapping in the issue index. The four retired records remain
non-import tombstones. This posture changes import guidance only; no live issues
or labels were created by this documentation update.

## CA recovery import status (2026-10-26)

The operator selected `identity-07-ca-recovery` for import with `status/todo`.
Its initial expiry/restore inventory is actionable now; recurring review triggers
do not defer that work. The current inventory is 96 import candidates: 80
non-deferred and 16 Deferred, plus four retired non-import records.

## Imported draft retirement (2026-10-26)

After verified import of all 96 retained tasks, the operator authorized deleting
the local draft directory. [Work tracking](../docs/work-tracking.md) preserves
the complete import mapping, status conventions, four retirement dispositions
and an immutable link to the final source snapshot. References now point to live
issues or the preserved retirement record. Earlier sections describe review-time
state; they do not indicate that import remains pending.
