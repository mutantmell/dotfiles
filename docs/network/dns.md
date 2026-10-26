# DNS architecture and migration boundaries

The router6 DNS module separates filtering, resolver caching, and fallback. `router6.dns.blocking` supports Blocky in front of kresd; the feature is implemented and tested in `tests/modules/router6-dns-blocking.nix`. Inspect the host's enable setting before assuming it is active on a live router.

Blocky sees client source addresses and applies per-request policy before the shared clean-answer cache. Do not restore source-dependent upstream routing behind a shared kresd cache: blocked answers can otherwise leak to exempt clients. Per-interface bypass is `network.dnsBlock = false`. Bypass clients map to the named empty-denylist `noblock` group; an empty group list falls back to the default group and does not disable blocking.

The client-facing port stays 53. With blocking enabled, kresd retreats to loopback port 5335, an internal constant. Denylists are pinned store inputs, not downloaded mutable lists. Special-use internal names require explicit conditional handling.

The current thebeyond configuration still depends on phantasma. The agreed target is native kresd recursion plus registry-generated local answers, then removal of phantasma and Unbound. That migration has not landed. Preserve static NXDOMAIN behavior for unknown internal names, transparent public-domain overrides, and native recursion elsewhere. Prove those semantics in a running resolver before switching production.

The pinned read-only root trust anchor and the existing ISP-lease fallback address earlier DNSSEC and reboot failure modes. A recursive replacement needs its own tested stall/fallback policy; do not copy the old remote-primary breaker unchanged. DNS and firewall tests must assert returned answers, not merely listening sockets or Lua strings.
