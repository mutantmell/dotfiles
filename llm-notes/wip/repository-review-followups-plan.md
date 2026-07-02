# Repository Review Follow-ups Plan

Status: WIP. At least one finding has been fixed (`setup-guest.sh`
certificate/key convergence), while the OpenWrt readiness items and other
follow-ups remain active.

- **Fixed:** the `setup-guest.sh` certificate/key convergence issue is handled.
  Generated private keys are stored in passage before certificate signing, and
  existing SSH/X5C certificates are checked against the current public key before
  signing is skipped.
- **Still open:** the three OpenWrt live image-building findings are still
  present: cache keys do not include baked secret material, UCI export redaction
  only masks exact `.key='...'` values, and OpenWrt deploy still masks
  `sysupgrade` failure with `|| true`.
- **Still open:** router6 `hardwareName` rename semantics remain broken in the
  module; `thebeyond` still works around this by using kernel predictable names.
- **Partially addressed elsewhere:** erebonia k3s now has scheduled datastore
  snapshots and CA/token adoption, but fleet-activation health gates and
  pre-upgrade snapshot policy are still future work.

## Scope

This plan records follow-up work from a broad read-only repository review on
2026-06-13.
It intentionally separates OpenWrt readiness issues from the rest of the
findings because live OpenWrt image building has different operational
requirements than the NixOS host/router workflows.

Incus findings from the review are intentionally omitted. The current direction
is to replace Incus with k3s/KubeVirt, so those findings should not drive new
Incus hardening work unless the migration is reversed.

Validation run during review:

```bash
./scripts/agent-preflight.sh --quick
```

Result: passed.

## OpenWrt Live Image-Building Readiness

These should be fixed before treating live OpenWrt image building and deployment
from this flake as a reliable operator workflow.

### High: image cache ignores baked secret content

`apps/openwrt/default.nix` computes image cache directories from
`build.json` plus an optional `nosecrets` suffix. When secrets are enabled, the
decrypted sops YAML is piped to the builder after the cache key is computed.
That means rotating WiFi/mesh credentials can silently reuse a cached
sysupgrade image with old baked credentials.

Impact: an operator can believe new credentials were deployed while the device
continues running an image built with previous secrets.

Fix direction:

- Include a digest of the injected secret material in the cache key when secrets
  are used; or
- Include a digest/revision of the encrypted sops file and force `--rebuild`
  semantics when it changes; and
- Print whether a cached image was built with secrets and which cache key inputs
  were used.

Relevant code:

- `apps/openwrt/default.nix`: `compute_cache_dir`
- `apps/openwrt/default.nix`: `run_builder`
- `apps/openwrt/default.nix`: cached image reuse in `openwrt-build` and
  `openwrt-deploy`

### High: exported OpenWrt config redaction is incomplete

`openwrt-export-config` advertises `uci-show.txt` as key-redacted, but the
redaction only masks values named exactly `.key='...'`. Other sensitive UCI
fields can leak, including `password`, `secret`, `private_key`, PSK-like values
under different names, or values rendered with different quoting.

Impact: migration exports can accidentally write live credentials to disk in
plaintext.

Fix direction:

- Prefer writing raw exports only to an encrypted target; or
- Redact by a denylist of sensitive key-name patterns such as `key`, `password`,
  `passwd`, `secret`, `token`, `private`, `psk`; and
- Make the command output clearly distinguish "best-effort redacted" from
  "safe to commit".

Relevant code:

- `apps/openwrt/default.nix`: `openwrt-export-config`

### Medium: deploy treats all `sysupgrade` failures as success

`packages/openwrt-deployer/deploy.sh` runs remote `sysupgrade` with `|| true`.
That tolerates the expected SSH disconnect during reboot, but it also hides
ordinary failures such as a rejected image or missing command.

Impact: deploy output can say "Deployment complete" when no upgrade started.

Fix direction:

- Distinguish expected disconnect from an immediate nonzero command failure.
- Optionally poll for reboot and verify version/build metadata after the device
  returns.

Relevant code:

- `packages/openwrt-deployer/deploy.sh`

## Remaining Findings

### High: k3s upgrade automation needs explicit cluster health gates and datastore backup handling

The CI/CD and fleet activation design is a good foundation for regular NixOS
host updates: it builds closures in CI, signs and caches them, pre-downloads
before activation, activates exact store paths, and rolls back to a known-good
GC-rooted system generation. That is the right shape for k3s hosts as long as
k3s-specific safety checks are added before the mechanism is trusted for routine
cluster upgrades.

Generic host connectivity is not enough for a k3s upgrade. A successful host
activation should also prove that the apiserver is reachable, the node returns
to `Ready`, core system pods are healthy, KubeVirt components are healthy when
enabled, and critical Multus/NAD objects still exist for VM networking.

The current Erebonia k3s configuration has persistent state and scheduled
snapshots, which is good, but the upgrade story should require a fresh
pre-upgrade k3s datastore snapshot, ideally with off-host availability, before
k3s version bumps or risky platform changes.

Impact: an automated activation can appear successful at the NixOS level while
leaving the single-node cluster, KubeVirt runtime, or dev-machine network path
degraded.

Fix direction:

- Extend the fleet coordinator's `connectivityCheck` contract with k3s-aware
  health checks.
- Require or trigger a fresh datastore snapshot before k3s version upgrades.
- Treat k3s minor-version bumps as deliberate channel/window changes rather
  than ordinary unattended drift.
- Keep a manual recovery path documented for cases where CI, Attic, NATS, or
  k3s itself is unavailable.

Relevant docs/code:

- `llm-notes/specs/cicd-fleet-management.md`
- `llm-notes/wip/cicd-fleet-activation-plan.md`
- `llm-notes/wip/k3s-cluster-workloads-plan.md`
- `hosts/erebonia/k3s/default.nix`

### Medium: CI/CD fleet activation plan is stale relative to the current k3s/KubeVirt direction

The fleet activation plan is explicitly marked stale. It still references old
host mappings and deployd-era container workflow assumptions that no longer
match the repository direction. The later k3s workload notes move dynamic
workloads into Kubernetes/Flux and retain Woodpecker server placement while
moving runners toward the Kubernetes backend.

The architectural intent remains sound: NATS carries facts, not authority; CI
and Attic signatures establish build trust; host-local policy decides
activation; and break-glass repair remains possible outside the pipeline. The
implementation plan should be re-grounded before work starts so the code does
not encode obsolete topology.

Impact: implementing the stale plan as written would rebuild parts of the
retired deployd model and could create circular recovery dependencies if the
only useful CI runners live inside the k3s cluster being repaired.

Fix direction:

- Update host mappings to the current `liberl`/`zeiss`, `erebonia`, `calvard`,
  and current service placement.
- Remove deployd/container API integration and replace it with Kubernetes/Flux
  workload eventing where needed.
- Explicitly separate NixOS/k3s-node upgrades from dynamic Kubernetes workload
  deployment.
- Preserve an out-of-cluster or operator-triggered build/repair path so a broken
  k3s cluster is not the only path to producing its own fix.

Relevant docs:

- `llm-notes/wip/cicd-fleet-activation-plan.md`
- `llm-notes/specs/cicd-fleet-management.md`
- `llm-notes/wip/k3s-cluster-workloads-plan.md`
- the historical k3s deployd decommission plan, now deleted from `done/`

### Medium: plain k3s pod networking still has broader host-zone access than the target security model

The KubeVirt dev-machine path has been moved to VLAN 51 with Multus/macvtap and
router-enforced isolation, which matches the current security intent for
untrusted AI-assisted development. However, the broader workload isolation plan
still documents that ordinary flannel pods egress as Erebonia's VLAN 11
management address until the deferred flannel-egress redirect, NetworkPolicy,
and service-IP work lands.

This is acceptable as a known transitional state if less-trusted workflows stay
on the VLAN 51 KubeVirt path, but it should remain visible as a security gap for
future plain container workloads.

Impact: a future pod-network workload can inherit more management-zone reach
than intended if it is treated as equivalently isolated to a multus-only
KubeVirt VM.

Fix direction:

- Keep untrusted workflows on multus-only VLAN 51 KubeVirt VMs until pod egress
  and NetworkPolicy hardening are complete.
- Add default-deny NetworkPolicy for pod-network workloads.
- Complete or explicitly defer the flannel-egress-to-VLAN-51 design before
  placing less-trusted plain pods on the cluster.
- Make health checks distinguish cluster-internal pod health from VLAN 51
  workload reachability, since NetworkPolicy does not govern multus-only VM data
  plane traffic.

Relevant docs/code:

- `llm-notes/wip/workload-network-isolation-plan.md`
- `llm-notes/done/ai-dev-machine-kubevirt-plan.md`
- `hosts/erebonia/k3s/default.nix`
- `hosts/erebonia/k3s/multus.nix`

### Low: break-glass WAN access should be documented as an explicit temporary firewall mode

The intended emergency recovery path is to temporarily add a host-specific VLAN
11 firewall exception that allows WAN access so the affected host can repair or
update itself without the normal CI/CD path. That is a reasonable homelab
tradeoff, but it should be documented as a bounded emergency mode rather than
an implicit operational habit.

Impact: the main risk is not the temporary exception itself, but leaving it in
place or making it broader than necessary.

Fix direction:

- Document the break-glass runbook alongside the fleet activation plan.
- Scope the exception to one host and only the required duration.
- Prefer a visible declarative toggle if this ever enters repo-managed router
  config.
- Include a final verification step that the live firewall exception has been
  removed.

Relevant docs:

- `llm-notes/wip/cicd-fleet-activation-plan.md`
- `llm-notes/specs/cicd-fleet-management.md`

### High: guest setup is not convergent when cert signing succeeds before key persistence — DONE

**Resolved in `scripts/setup-guest.sh` by 2026-07-02.** The script now persists
new SSH host keys, PQC age identities, and fleet enrollment keys to passage
before certificate signing. It also verifies that existing SSH host certificates
and fleet X5C certificates match the current public key before skipping signing,
and re-signs when they do not.

Original finding retained for context:

The original review described key setup as "not transactional." A more precise
classification is: most public metadata updates are convergent on rerun, but
`setup-guest.sh` has a genuine non-convergence bug around certificates.

`setup-guest.sh` signs SSH host certificates and fleet enrollment certificates
before newly generated private keys are inserted into `passage`. If the script
is interrupted after certificate creation but before private-key persistence, a
rerun generates a new private key, updates `keys.json`, and then skips signing
because the old certificate file already exists.

Impact: the repo can preserve a certificate for a lost/private key while the
current private key and `keys.json` point elsewhere.

Fix direction:

- Store generated private keys in `passage` before signing certificates; or
- When a cert already exists, verify that it matches the current public key and
  re-sign when it does not.

Relevant code:

- `scripts/setup-guest.sh`: guest SSH key generation/reuse
- `scripts/setup-guest.sh`: SSH host certificate skip/sign logic
- `scripts/setup-guest.sh`: fleet enrollment cert skip/sign logic
- `scripts/setup-guest.sh`: late `passage insert` calls

### High: router6 exposes `type = "pppoe"` without implementing PPPoE

The router6 network type enum advertises `pppoe`, but the systemd-networkd
renderer only handles `dhcp`, `static`, and `disabled`. A `pppoe` network
therefore renders as no DHCP and no PPP session.

Impact: a user can configure a documented network type and receive a build that
evaluates but cannot establish PPPoE connectivity.

Fix direction:

- Implement PPPoE end to end; or
- Remove `pppoe` from the public enum until support exists.

Relevant code:

- `modules/router6/default.nix`: network type option
- `modules/router6/networking.nix`: network renderer

### Medium: router6 address parsing is narrower than its option surface

Router6 address helpers assume more than the option types state. IPv4 subnet
and DHCP pool derivation assume `/24`-shaped addresses. IPv6 prefix extraction
assumes compressed addresses containing `::`.

Impact: valid-looking CIDRs outside the supported shape can render incorrect
DHCP, RA, or Kea config.

Fix direction:

- Use real CIDR math for IPv4 and IPv6; or
- Explicitly validate the currently supported subset and fail evaluation for
  unsupported forms.

Relevant code:

- `modules/router6/lib.nix`: `parseIPAddress`
- `modules/router6/lib.nix`: `parseCIDR`
- `modules/router6/lib.nix`: `mkKeaSubnet6`

### Medium: DHCPv6 DNS option can diverge from RA DNS

`dhcp6.dnsAddress` is required and used for Router Advertisement DNS, but
Kea DHCPv6 option-data currently advertises the parsed first IPv6 interface
address instead.

Impact: stateless/stateful DHCPv6 clients can receive a different DNS server
than SLAAC/RA clients.

Fix direction:

- Use `network.dhcp6.dnsAddress` consistently in Kea DHCPv6 `dns-servers`
  option-data.

Relevant code:

- `modules/router6/default.nix`: `dhcp6.dnsAddress`
- `modules/router6/networking.nix`: RA DNS rendering
- `modules/router6/lib.nix`: Kea DHCPv6 subnet rendering

### Medium: some DNS integration checks cannot fail

Several tests wrap `dig` commands in `|| true`, so `router.succeed` or
`client.succeed` succeeds even if DNS resolution fails.

Impact: integration tests can report success while skipping the behavior they
claim to verify.

Fix direction:

- Replace with `wait_until_succeeds` or assert `dig` output/status directly.

Relevant tests:

- `tests/modules/router6-listening-sockets.nix`
- `tests/modules/router6-ipv6.nix`

### Medium: Linux-only checks are exposed for Darwin systems

The flake generates `checks` for all systems, including Darwin, while importing
the Linux/NixOS/container test suite unconditionally. The repository runner
hardcodes `x86_64-linux`, so the normal agent/operator path masks the issue.

Impact: Darwin check attrs exist but are not valid, which makes flake outputs
less coherent for multi-system consumers.

Fix direction:

- Gate NixOS/container/VM checks to Linux systems.
- Optionally expose only formatting or pure Darwin-safe checks on Darwin.

Relevant code:

- `flake.nix`: `allSystems`
- `flake.nix`: `checks`
- `scripts/run-checks.sh`: hardcoded Linux system

### Medium: documented pure-test command is a no-op for function-valued tests

The test docs mention direct `nix-instantiate --eval --strict
tests/lib/<file>.nix`, but many files are functions. Evaluating the file alone
returns a lambda rather than running assertions.

Impact: operators can run a documented command and get false confidence that a
test passed.

Fix direction:

- Remove the direct command from headers; or
- Document a complete invocation that supplies `pkgs`/`lib`; or
- Prefer `nix build .#checks.x86_64-linux.<name>` everywhere.

Relevant docs:

- `tests/default.nix`
- individual `tests/lib/*.nix` headers

### Low: certificate expiry check is runner-only

`scripts/run-checks.sh` always runs `check-cert-expiry.sh`, including for
explicit check selections, but there is no corresponding flake check.

Impact: `./scripts/run-checks.sh foo` and
`nix build .#checks.x86_64-linux.foo` do not mean the same thing.

Fix direction:

- Decide whether cert expiry is canonical validation.
- If yes, expose it as a flake check.
- If no, keep it out of explicit targeted `run-checks.sh` calls.

Relevant code:

- `scripts/run-checks.sh`
- `scripts/check-cert-expiry.sh`
- `flake.nix`: `checks`

### Low: disko tests mostly prove import/serialization

The current disko checks import profiles and serialize them to JSON, but they
do not strongly validate schema behavior or representative NixOS integration.

Impact: these checks provide weaker assurance than their names imply.

Fix direction:

- Evaluate representative NixOS configs using the profiles; or
- Assert important generated layout fields directly.

Relevant code:

- `tests/default.nix`: `disko-*` checks

### Low: dev-machine image keeps root serial autologin

The dev-machine base image enables root autologin on the serial console. The
comment documents the tradeoff, but it remains a privilege-boundary caveat for
anyone with console access.

Impact: acceptable if console access is inside the intended KubeVirt/cluster
boundary, but worth keeping explicit in the threat model.

Fix direction:

- Keep documented if intentional.
- Revisit if console access is ever exposed beyond the trusted operator path.

Relevant code:

- `packages/dev-machine-image/configuration.nix`

### Medium: deployment documentation is stale for current secret handling

`docs/deployment.md` still describes older `.keys/` and manual `/boot/secrets`
handling, while the current deployment script uses `passage` and `--extra-files`.

Impact: operators following the docs can use obsolete or less safe recovery and
deployment steps.

Fix direction:

- Update the deployment guide to match `scripts/deploy-nixos-anywhere.sh`.
- Prefer `passage` as the authoritative private-key/keyfile store in docs.

Relevant docs/code:

- `docs/deployment.md`
- `scripts/deploy-nixos-anywhere.sh`
