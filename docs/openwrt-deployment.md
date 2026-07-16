# OpenWrt Image Deployment

`openwrt-deployer` is the low-level deployment tool for both operators and
eventual CI jobs. It deploys one already-built sysupgrade artifact. Human
approval, artifact publication, and multi-device rollout policy belong in the
calling workflow.

The normal operator command builds a fresh image, prompts, deploys it, waits for
the reboot, and verifies the evaluated hostname and build ID:

```bash
nix run .#openwrt-deploy -- bobcat 10.97.10.10
```

The low-level tool supports automation without depending on NATS or Attic:

```bash
nix run .#openwrt-deployer -- 10.97.10.10 ./sysupgrade.bin \
  --ci \
  --known-hosts ./openwrt-known-hosts \
  --ssh-key ./deploy-key \
  --expected-sha256 0123456789abcdef... \
  --expected-hostname bobcat \
  --expected-build-id 0123456789abcdef... \
  --verify-command 'fw4 check' \
  --json
```

`--ci` is deliberately separate from `--force`. It disables interactive SSH
authentication and requires a caller-provided `known_hosts` file with strict
checking plus an expected artifact SHA-256. The tool verifies that digest both
before and after upload, serializes deployments to a target on the local runner,
validates the image with `sysupgrade -T`, confirms that sysupgrade started,
observes the offline/online transition, and then runs identity and health checks.
Distinct exit codes identify digest (3), lock (4), upgrade (5), offline (6),
online (7), identity (8), and health-check (9) failures.

An eventual CI workflow should build an image once, boot-test that exact image,
publish the image plus digest and build ID, require environment approval, and
then invoke this tool with the published values. Roll out one device at a time
and stop on failure. CI credentials, approval, retention, and rollout order are
orchestration concerns and are intentionally not implemented here.
