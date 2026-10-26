# Work tracking and notes migration

Work belongs in [Forgejo issues](https://forgejo.internal/mutantmell-net/dotfiles/issues).
Forgejo also holds future designs, execution plans and the current focus.
[Repository docs](README.md) describe implemented state, operating procedures and
workflow rules. Update them when work ships; retain obsolete guidance in Git
history rather than presenting it as current. Existing target-design documents
are context, not evidence of deployment or an independently maintained backlog.
Keep issues bounded and self-contained, link prerequisites, and split
implementation PRs further when necessary.

Repository-managed configuration is the current-state baseline. Hardware behavior,
application databases, private data and manually managed devices require separate
evidence. Do not recreate completed implementation because an old note lacks an
acceptance record. Importing a task does not authorize deployment or a production
cutover; prerequisite and operator gates still apply.

## Issue status

- `status/todo`: accepted backlog awaiting execution, not a readiness or priority
  signal. Check prerequisites before starting.
- `status/in-progress`: an owner is actively taking a concrete next step.
- `status/in-review`: a linked result or PR awaits review.
- `status/blocked`: progress requires a named dependency, decision or external
  condition. Record the gate and what evidence unblocks it.
- `status/deferred`: intentionally postponed until a concrete revisit trigger.
  Preserve its reason, design context, acceptance criteria and dependencies;
  keep it outside the actionable backlog without an active milestone or assignee.
  Reassess status when its trigger occurs. Dependencies alone do not activate it.

Keep exactly one status label on each open issue. Closed is an issue state, not an
additional status label. Close completed work with acceptance evidence; close
cancelled, duplicate or superseded work with an explanation and replacement link
where applicable. Do not close issues automatically because they are old.

## Milestones and current focus

Use [native Forgejo milestones](https://forgejo.internal/mutantmell-net/dotfiles/milestones)
for bounded outcomes, not permanent subsystem categories. The operator selects
priorities and identifies one open milestone with the title prefix `Current:`.
Keep the live focus and queued outcomes in Forgejo, not a parallel roadmap in
repository docs. Queued milestone membership does not activate deferred work,
satisfy prerequisites or authorize deployment. Deferred issues have no active
milestone or assignee.

A milestone description records its outcome, why it matters, scope and exclusions,
completion criteria, coordinator, next actionable issue or execution order, and
review point. Use dates for real deadlines rather than invented delivery promises.
The coordinator is named in the description because milestones have no assignee.

Create a tracking issue only when an outcome needs substantial sequencing, design
decisions or acceptance across tasks. Assign it to the coordinator and link it from
the milestone. Keep the detailed plan there and the milestone description brief;
use milestone membership for the task list instead of duplicating checklists.
Implementation issues retain their own scope and acceptance criteria.

Before milestone closure, the agent prepares an acceptance summary, reconciles
remaining or removed scope, and updates current-state docs. The operator confirms
completion and promotion of the next focus. Closed child issues alone do not prove
operational acceptance.

The project board is intentionally unused until its public API is stable enough
to rely on or a standard CLI provides supported board operations. Do not populate
it or maintain a second status record there; an empty board is expected.

## Ownership, execution and handoff

Assign an accountable owner when work starts. Assignment alone does not mean work
is active; default to at most two in-progress issues per person. The shared `cc`
account identifies agent activity, not an exclusive claim. Check existing owners,
active PRs and recent handoffs before starting to avoid duplicate work.

At start and each handoff, update the issue's status, owner, branch/PR links, next
action, blockers and acceptance evidence. Include enough context to resume in a
new session. The coordinator reviews the current focus manually each week and when
its outcome changes; issue owners review blocked and deferred issues when their
gates or triggers change. Record tested commits, relevant check results and any
remaining limits on behavioral or deployment evidence.
This convention does not create scheduled automation.

Use native issue dependencies for genuine prerequisites and retain prose explaining
the acceptance gate. Related or advisory links do not block closure. When a
prerequisite completes, reassess readiness rather than automatically activating
every dependent issue.

A merge completes an issue only if it satisfies all acceptance criteria. Otherwise
link the merged PR, record completed criteria and state the remaining validation or
deployment step. Leave operator-dependent acceptance open, using `status/blocked`
when operator action is required. Split remaining work into a linked follow-up only
when that creates a clear scope boundary and preserves all requirements. Use
automatic closing references only when merge completes the entire issue.

## Agent authority

Agents may create bounded implementation issues and maintain status, ownership,
dependencies, links and acceptance records for work they perform. Choose ready
tasks within the current focus unless the operator explicitly directs otherwise.
Agents may split tasks while preserving requirements and links. Dropping
requirements, changing architecture or moving work between focus milestones needs
an operator decision unless already authorized in the session.

Agents may file findings outside the current focus, leaving them outside the active
milestone. Report urgent blockers rather than silently changing priorities. Close
issues only when all criteria can be verified, or when cancellation, duplication
or supersession is explicitly established; do not claim operator acceptance.
Routine tracking maintenance is authorized, but it does not authorize production
execution, cutovers or other separately gated actions.

## Migration record

On 2026-10-26, 96 eligible drafts were imported as open issues: 27
`status/todo`, 53 `status/blocked`, and 16 `status/deferred`. No assignees or
milestones were set. Four retired records were excluded. These are import-time
statuses; Forgejo holds current status. The duplicate check found no existing
matching issues. CA recovery was explicitly selected for `status/todo`.
The operator confirmed legacy media work remains; inventory and consumer checks
define its remaining scope rather than holding it out of tracking.

All 96 issue bodies were verified to preserve task context and draft keys.
Dependencies point to issue URLs; documentation links use published source commit
`40a96e7e8aaf799182229aa07cd908f89950a0b0`, preserving anchors. Historical
provenance uses its original immutable commits. Links supplement essential context
in the issue body rather than replacing it.

The operator authorized removal of the imported draft directory. Its full contents
and original README/mapping remain recoverable at
[the final draft snapshot](https://forgejo.internal/mutantmell-net/dotfiles/src/commit/f8b86c4b85ed58c27e298005ecd792ad52cab773/issue-drafts).
This Git snapshot preserves the imported source; it does not establish Forgejo
application backup or recovery. That remaining work is tracked in
[issue #212](https://forgejo.internal/mutantmell-net/dotfiles/issues/212).
[Source disposition](../llm-notes/README.md) accounts for the original notes.

## Imported issue mapping

Historical draft keys are retained for provenance and lookup, not as a second backlog.

| Former draft key                  | Forgejo issue                                                       | Imported status   |
| --------------------------------- | ------------------------------------------------------------------- | ----------------- |
| `fleet-01-runner-trust`           | [#194](https://forgejo.internal/mutantmell-net/dotfiles/issues/194) | `status/todo`     |
| `fleet-02-cache-closures`         | [#195](https://forgejo.internal/mutantmell-net/dotfiles/issues/195) | `status/blocked`  |
| `fleet-03-release-signatures`     | [#196](https://forgejo.internal/mutantmell-net/dotfiles/issues/196) | `status/blocked`  |
| `fleet-04-release-promotion`      | [#197](https://forgejo.internal/mutantmell-net/dotfiles/issues/197) | `status/blocked`  |
| `fleet-05-comin-vm`               | [#198](https://forgejo.internal/mutantmell-net/dotfiles/issues/198) | `status/blocked`  |
| `fleet-06-recovery`               | [#199](https://forgejo.internal/mutantmell-net/dotfiles/issues/199) | `status/blocked`  |
| `fleet-07-canary`                 | [#200](https://forgejo.internal/mutantmell-net/dotfiles/issues/200) | `status/blocked`  |
| `fleet-08-k3s-upgrade`            | [#201](https://forgejo.internal/mutantmell-net/dotfiles/issues/201) | `status/blocked`  |
| `fleet-09-update-observability`   | [#202](https://forgejo.internal/mutantmell-net/dotfiles/issues/202) | `status/blocked`  |
| `ci-01-build-containment`         | [#203](https://forgejo.internal/mutantmell-net/dotfiles/issues/203) | `status/todo`     |
| `flux-01-dependency-registry`     | [#204](https://forgejo.internal/mutantmell-net/dotfiles/issues/204) | `status/todo`     |
| `flux-02-bootstrap`               | [#205](https://forgejo.internal/mutantmell-net/dotfiles/issues/205) | `status/blocked`  |
| `flux-03-release-source`          | [#206](https://forgejo.internal/mutantmell-net/dotfiles/issues/206) | `status/blocked`  |
| `flux-04-addon-ownership`         | [#207](https://forgejo.internal/mutantmell-net/dotfiles/issues/207) | `status/blocked`  |
| `dependencies-01-update-prs`      | [#208](https://forgejo.internal/mutantmell-net/dotfiles/issues/208) | `status/blocked`  |
| `scripts-01-deno-pilot`           | [#209](https://forgejo.internal/mutantmell-net/dotfiles/issues/209) | `status/deferred` |
| `backup-01-namespace`             | [#210](https://forgejo.internal/mutantmell-net/dotfiles/issues/210) | `status/todo`     |
| `backup-02-forgejo-mirrors`       | [#211](https://forgejo.internal/mutantmell-net/dotfiles/issues/211) | `status/blocked`  |
| `backup-03-forgejo-state`         | [#212](https://forgejo.internal/mutantmell-net/dotfiles/issues/212) | `status/blocked`  |
| `backup-04-offsite`               | [#213](https://forgejo.internal/mutantmell-net/dotfiles/issues/213) | `status/blocked`  |
| `storage-01-blob-evaluation`      | [#214](https://forgejo.internal/mutantmell-net/dotfiles/issues/214) | `status/deferred` |
| `dns-01-split-horizon`            | [#215](https://forgejo.internal/mutantmell-net/dotfiles/issues/215) | `status/todo`     |
| `dns-02-recursion-fallback`       | [#216](https://forgejo.internal/mutantmell-net/dotfiles/issues/216) | `status/blocked`  |
| `dns-03-retire-phantasma`         | [#217](https://forgejo.internal/mutantmell-net/dotfiles/issues/217) | `status/blocked`  |
| `dns-04-real-query-tests`         | [#218](https://forgejo.internal/mutantmell-net/dotfiles/issues/218) | `status/todo`     |
| `openwrt-01-capture`              | [#219](https://forgejo.internal/mutantmell-net/dotfiles/issues/219) | `status/blocked`  |
| `openwrt-02-policy`               | [#220](https://forgejo.internal/mutantmell-net/dotfiles/issues/220) | `status/blocked`  |
| `openwrt-03-hardware`             | [#221](https://forgejo.internal/mutantmell-net/dotfiles/issues/221) | `status/blocked`  |
| `openwrt-05-bridge`               | [#222](https://forgejo.internal/mutantmell-net/dotfiles/issues/222) | `status/blocked`  |
| `openwrt-07-third-bt8`            | [#223](https://forgejo.internal/mutantmell-net/dotfiles/issues/223) | `status/deferred` |
| `openwrt-08-switch`               | [#224](https://forgejo.internal/mutantmell-net/dotfiles/issues/224) | `status/blocked`  |
| `openwrt-09-ci-lifecycle`         | [#225](https://forgejo.internal/mutantmell-net/dotfiles/issues/225) | `status/blocked`  |
| `openwrt-10-controller`           | [#226](https://forgejo.internal/mutantmell-net/dotfiles/issues/226) | `status/blocked`  |
| `openwrt-11-enrollment`           | [#227](https://forgejo.internal/mutantmell-net/dotfiles/issues/227) | `status/blocked`  |
| `openwrt-12-upgrade-pilot`        | [#228](https://forgejo.internal/mutantmell-net/dotfiles/issues/228) | `status/blocked`  |
| `network-01-pod-egress`           | [#229](https://forgejo.internal/mutantmell-net/dotfiles/issues/229) | `status/todo`     |
| `network-02-service-vips`         | [#230](https://forgejo.internal/mutantmell-net/dotfiles/issues/230) | `status/blocked`  |
| `network-03-macvtap`              | [#231](https://forgejo.internal/mutantmell-net/dotfiles/issues/231) | `status/todo`     |
| `network-04-liberl-firewall`      | [#232](https://forgejo.internal/mutantmell-net/dotfiles/issues/232) | `status/blocked`  |
| `network-06-netmgmt`              | [#233](https://forgejo.internal/mutantmell-net/dotfiles/issues/233) | `status/blocked`  |
| `network-07-homeassistant`        | [#234](https://forgejo.internal/mutantmell-net/dotfiles/issues/234) | `status/deferred` |
| `network-08-media-vpn`            | [#235](https://forgejo.internal/mutantmell-net/dotfiles/issues/235) | `status/blocked`  |
| `network-09-e8450`                | [#236](https://forgejo.internal/mutantmell-net/dotfiles/issues/236) | `status/deferred` |
| `network-10-angbar-vpn`           | [#237](https://forgejo.internal/mutantmell-net/dotfiles/issues/237) | `status/blocked`  |
| `network-11-arteria-microvm`      | [#238](https://forgejo.internal/mutantmell-net/dotfiles/issues/238) | `status/blocked`  |
| `ipv6-01-token-test`              | [#239](https://forgejo.internal/mutantmell-net/dotfiles/issues/239) | `status/todo`     |
| `ipv6-02-rollout`                 | [#240](https://forgejo.internal/mutantmell-net/dotfiles/issues/240) | `status/blocked`  |
| `identity-01-mfa`                 | [#241](https://forgejo.internal/mutantmell-net/dotfiles/issues/241) | `status/blocked`  |
| `identity-02-audit-view`          | [#242](https://forgejo.internal/mutantmell-net/dotfiles/issues/242) | `status/todo`     |
| `identity-03-revocation-proof`    | [#243](https://forgejo.internal/mutantmell-net/dotfiles/issues/243) | `status/todo`     |
| `identity-04-jwk-outage`          | [#244](https://forgejo.internal/mutantmell-net/dotfiles/issues/244) | `status/blocked`  |
| `identity-05-login-floor`         | [#245](https://forgejo.internal/mutantmell-net/dotfiles/issues/245) | `status/deferred` |
| `identity-06-certificate-policy`  | [#246](https://forgejo.internal/mutantmell-net/dotfiles/issues/246) | `status/deferred` |
| `identity-07-ca-recovery`         | [#247](https://forgejo.internal/mutantmell-net/dotfiles/issues/247) | `status/todo`     |
| `monitoring-01-phone`             | [#248](https://forgejo.internal/mutantmell-net/dotfiles/issues/248) | `status/blocked`  |
| `monitoring-02-exporters`         | [#249](https://forgejo.internal/mutantmell-net/dotfiles/issues/249) | `status/todo`     |
| `monitoring-03-security-alerts`   | [#250](https://forgejo.internal/mutantmell-net/dotfiles/issues/250) | `status/blocked`  |
| `monitoring-04-dashboards`        | [#251](https://forgejo.internal/mutantmell-net/dotfiles/issues/251) | `status/todo`     |
| `monitoring-05-cluster-metrics`   | [#252](https://forgejo.internal/mutantmell-net/dotfiles/issues/252) | `status/blocked`  |
| `monitoring-06-pod-logs`          | [#253](https://forgejo.internal/mutantmell-net/dotfiles/issues/253) | `status/blocked`  |
| `workstation-01-neutral-config`   | [#254](https://forgejo.internal/mutantmell-net/dotfiles/issues/254) | `status/todo`     |
| `workstation-02-provisioning`     | [#255](https://forgejo.internal/mutantmell-net/dotfiles/issues/255) | `status/blocked`  |
| `workstation-03-calvard-platform` | [#256](https://forgejo.internal/mutantmell-net/dotfiles/issues/256) | `status/blocked`  |
| `workstation-04-csi`              | [#257](https://forgejo.internal/mutantmell-net/dotfiles/issues/257) | `status/blocked`  |
| `workstation-05-edith`            | [#258](https://forgejo.internal/mutantmell-net/dotfiles/issues/258) | `status/blocked`  |
| `workstation-06-trista`           | [#259](https://forgejo.internal/mutantmell-net/dotfiles/issues/259) | `status/blocked`  |
| `workstation-07-retire-incus`     | [#260](https://forgejo.internal/mutantmell-net/dotfiles/issues/260) | `status/blocked`  |
| `workstation-08-guest-updates`    | [#261](https://forgejo.internal/mutantmell-net/dotfiles/issues/261) | `status/blocked`  |
| `friends-01-headscale`            | [#262](https://forgejo.internal/mutantmell-net/dotfiles/issues/262) | `status/todo`     |
| `friends-02-restricted-routing`   | [#263](https://forgejo.internal/mutantmell-net/dotfiles/issues/263) | `status/blocked`  |
| `friends-03-enrollment`           | [#264](https://forgejo.internal/mutantmell-net/dotfiles/issues/264) | `status/blocked`  |
| `friends-04-public-ingress`       | [#265](https://forgejo.internal/mutantmell-net/dotfiles/issues/265) | `status/deferred` |
| `games-01-storage-migration`      | [#266](https://forgejo.internal/mutantmell-net/dotfiles/issues/266) | `status/blocked`  |
| `games-02-consumer-acceptance`    | [#267](https://forgejo.internal/mutantmell-net/dotfiles/issues/267) | `status/blocked`  |
| `media-01-smb-policy`             | [#268](https://forgejo.internal/mutantmell-net/dotfiles/issues/268) | `status/todo`     |
| `media-02-bulk-ingest`            | [#269](https://forgejo.internal/mutantmell-net/dotfiles/issues/269) | `status/deferred` |
| `media-03-transcode`              | [#270](https://forgejo.internal/mutantmell-net/dotfiles/issues/270) | `status/deferred` |
| `media-05-curated-tv`             | [#271](https://forgejo.internal/mutantmell-net/dotfiles/issues/271) | `status/deferred` |
| `cluster-01-identity-rotation`    | [#272](https://forgejo.internal/mutantmell-net/dotfiles/issues/272) | `status/todo`     |
| `cluster-02-game-snapshots`       | [#273](https://forgejo.internal/mutantmell-net/dotfiles/issues/273) | `status/blocked`  |
| `dev-01-inventory`                | [#274](https://forgejo.internal/mutantmell-net/dotfiles/issues/274) | `status/todo`     |
| `dev-02-image-publication`        | [#275](https://forgejo.internal/mutantmell-net/dotfiles/issues/275) | `status/todo`     |
| `dev-03-auth-and-startup`         | [#276](https://forgejo.internal/mutantmell-net/dotfiles/issues/276) | `status/todo`     |
| `dev-04-package-policy`           | [#277](https://forgejo.internal/mutantmell-net/dotfiles/issues/277) | `status/deferred` |
| `dev-05-sizing`                   | [#278](https://forgejo.internal/mutantmell-net/dotfiles/issues/278) | `status/deferred` |
| `dev-07-image-identity`           | [#279](https://forgejo.internal/mutantmell-net/dotfiles/issues/279) | `status/todo`     |
| `runtime-01-nix-snapshotter`      | [#280](https://forgejo.internal/mutantmell-net/dotfiles/issues/280) | `status/deferred` |
| `router-01-address-contract`      | [#281](https://forgejo.internal/mutantmell-net/dotfiles/issues/281) | `status/todo`     |
| `router-02-rename-acceptance`     | [#282](https://forgejo.internal/mutantmell-net/dotfiles/issues/282) | `status/todo`     |
| `tests-01-platform-outputs`       | [#283](https://forgejo.internal/mutantmell-net/dotfiles/issues/283) | `status/todo`     |
| `tests-02-pure-invocations`       | [#284](https://forgejo.internal/mutantmell-net/dotfiles/issues/284) | `status/todo`     |
| `tests-03-disko-behavior`         | [#285](https://forgejo.internal/mutantmell-net/dotfiles/issues/285) | `status/todo`     |
| `recovery-01-console`             | [#286](https://forgejo.internal/mutantmell-net/dotfiles/issues/286) | `status/blocked`  |
| `iot-01-pi-baseline`              | [#287](https://forgejo.internal/mutantmell-net/dotfiles/issues/287) | `status/deferred` |
| `iot-02-ble-scanner`              | [#288](https://forgejo.internal/mutantmell-net/dotfiles/issues/288) | `status/blocked`  |
| `iot-03-netboot`                  | [#289](https://forgejo.internal/mutantmell-net/dotfiles/issues/289) | `status/deferred` |

## Retired records

These records were deliberately excluded from import; they are not pending tasks.

### openwrt-04-render

OpenWISP is selected for OpenWrt configuration and image management. Implementing parallel Nix-generated per-device UCI would create competing owners. Arteria/thebeyond own routing in NixOS.

Preserved requirements move to [ownership/enrollment](https://forgejo.internal/mutantmell-net/dotfiles/issues/227), [wireless qualification](https://forgejo.internal/mutantmell-net/dotfiles/issues/222), [hardware artifacts](https://forgejo.internal/mutantmell-net/dotfiles/issues/221), and [switch acceptance](https://forgejo.internal/mutantmell-net/dotfiles/issues/224).

This tombstone preserves the original draft key. Historical scope is available in Git; it is not an additional acceptance requirement.

### openwrt-06-gateway

The [Arteria decision](arteria-gateway.md) supersedes the proposed BT8 gateway rotation. OpenWrt provides wireless bridging; no new BT8 routing implementation should be created.

Use the Arteria cutover/recovery runbook for remaining physical acceptance. Track the selected future [gateway microVM migration](https://forgejo.internal/mutantmell-net/dotfiles/issues/238) separately. The physical Arteria configuration represents current managed state; do not propose another initial gateway deployment issue.

This tombstone preserves the original draft key. Historical scope is available in Git; it is not an additional acceptance requirement.

### network-05-backup-tunnel

This relocation depends on a BT8 gateway architecture that Arteria supersedes. The working liberl tunnel is not a reason to recreate that gateway.

Retain [liberl firewall work](https://forgejo.internal/mutantmell-net/dotfiles/issues/232). A future tunnel move requires a new destination decision, operational justification and remote-peer coordination; no replacement relocation issue is proposed.

This tombstone preserves the original draft key. Historical scope is available in Git; it is not an additional acceptance requirement.

### dev-06-runtime-inventory

The current repository-managed runtime configuration has no Kata runtime or workloads to remove. `hosts/erebonia/k3s/runtimes.nix` declares runsc and runc-kvm; KubeVirt owns dev-machine VMs. Retain these supported paths. Historical Kata experiments do not justify a new cleanup issue.

This tombstone preserves the original draft key. Any future unmanaged residue should be reported as a specific new finding, rather than importing speculative cleanup.
