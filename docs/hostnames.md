## Quick-reference DNS naming cheat sheet

Naming + purpose overview only. Authoritative addresses, zones, and VLANs
are derived from the network registry (`lib/common/data/network.nix`); do
not duplicate IPs here. Names marked "(reserved)" are part of a host's
Trails-themed name pool but not yet provisioned.

In-flight k3s migration (see `llm-notes/plans/k3s-*-plan.md`) is noted
inline with "→".

```
VM HOSTS (Countries)
├── erebonia          (GP / dynamic-compute host)
│   ├── roer          (microVM) — deployd-api  → decommissioned with deployd
│   ├── saint-arkh    (microVM) — CI runner (Forgejo Actions)  → Woodpecker CI server; build runners move into k3s
│   ├── trista        (Incus VM) — NixOS dev workstation; SSH over wg-ba in DMZ  → KubeVirt VM
│   ├── k3s-server    (microVM, planned) — k3s control plane (apiserver/kine); name TBD
│   ├── heimdallr     (reserved)
│   ├── ordis         (reserved)
│   ├── legram        (reserved)
│   ├── ymir          (reserved)
│   └── leeves        (reserved)
│
├── calvard           (GP / static-fleet host)
│   ├── messeldam     (microVM) — Keycloak OIDC identity provider (→ Authelia)
│   ├── basel         (microVM) — step-ca PKI / SSH certificate authority
│   ├── langport      (microVM) — reverse proxy / web gateway (nginx)
│   ├── oracion       (microVM) — Jellyfin / Navidrome / Retrom media
│   ├── tharbad       (microVM) — VictoriaMetrics, VictoriaLogs, Alertmanager, ntfy, Perses
│   ├── creil         (microVM) — Forgejo git hosting + container registry
│   ├── edith         (Incus VM) — NixOS dev workstation (primary)  → KubeVirt VM
│   ├── altair        (microVM, planned) — Headscale control plane
│   ├── longlai       (microVM, planned) — Tailscale subnet router
│   └── nemeth        (reserved)
│
├── liberl            (NAS + VM host)
│   ├── zeiss         (microVM) — Attic Nix binary cache
│   ├── bose          (microVM) — Arr stack — UHD/4K (Sonarr, Radarr, Bazarr, Lidarr)
│   ├── ravennue      (microVM) — Arr stack — SD/1080p (Sonarr, Radarr, Bazarr)
│   ├── ruan          (reserved)
│   ├── grancel       (reserved)
│   └── rolent        (reserved)
│
└── (northambria)     (reserved GP-host name — not provisioned)

ROUTER (Extra-planar spaces)
└── thebeyond         (Router)
    └── phantasma     (microVM) — DNS (Blocky + Unbound), ad-blocking, internal proxy

SWITCHES (Named vehicles)
├── arseille          (L2 switch)
└── courageous        (Switch, reserved)

ACCESS POINTS (Named vehicles)
├── bobcat            (AP)
├── lusitania         (AP)
├── merkabah          (AP)
├── derfflinger       (AP)
├── pantagruel        (AP)
└── glorious          (AP)

PERSONAL COMPUTERS (Legendary weapons)
├── kernviter         (NixOS-WSL desktop)
└── angbar            (NixOS laptop — ThinkPad X1 Carbon 7th Gen)

UTILITY HOSTS (Artifacts)
├── azoth             — Raspberry Pi (Home Assistant, MQTT)
├── gospel            (reserved)
└── gleipnir          (reserved)

OTHER HOSTS (Orbments)
├── arcus             — Steam Deck
├── enigma            (reserved)
└── xipha             (reserved)
```

Notes:

- The static service fleet lives on **calvard**; **erebonia** is the
  dynamic-compute host (deployd today, k3s cluster planned). **liberl** is
  the NAS and also hosts the media/cache microVMs.
- Several old erebonia guest names (heimdallr, ordis, legram, ymir, and
  formerly roer) were the pre-migration names of guests now on calvard
  (oracion, langport, basel, tharbad, messeldam respectively). They are
  free again on erebonia except **roer**, reused for deployd-api.
- The removed **remiferia** NAS host (former home of ardent/monrain/denai)
  is gone; its Attic cache moved to **zeiss** on liberl.
