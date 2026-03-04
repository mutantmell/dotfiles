## Quick-reference DNS naming cheat sheet

```
VM HOSTS (Countries)
├── erebonia          (GP host)
│   ├── heimdallr     (not allocated)
│   ├── ordis         (not allocated)
│   ├── roer          (not allocated)
│   ├── legram        (not allocated)
│   ├── ymir          (not allocated)
│   ├── trista        (Incus VM) — Dev environment / task runner (backup)
│   ├── saint-arkh    (not allocated)
│   └── leeves        (not allocated) — reserved for future backup dev env name
│
├── calvard           (GP host)
│   ├── edith         (microVM) — Keycloak OIDC identity provider
│   ├── basel         (microVM) — step-ca PKI / certificate authority
│   ├── langport      (microVM) — Reverse proxy, nginx, oauth2-proxy
│   ├── oracion       (microVM) — Jellyfin media server
│   ├── tharbad       (microVM) — Monitoring
│   ├── messeldam     (Incus container) — Dev environment / task runner (primary)
│   ├── (name TBD)    (microVM) — Headscale control plane
│   ├── (name TBD)    (microVM) — Tailscale subnet router
│   └── (name TBD)    (Incus VM) — SSH jump host
│
├── liberl            (GP host)
│   ├── grancel       (VM guest)
│   ├── bose          (VM guest)
│   ├── ruan          (VM guest)
│   ├── zeiss         (VM guest)
│   ├── rolent        (VM guest)
│   └── ravennue      (VM guest)
│
└── northambria       (GP host)
    ├── haliask       (VM guest)
    ├── difwa         (VM guest)
    ├── szaborja      (VM guest)
    ├── standza       (VM guest)
    ├── yabori        (VM guest)
    └── kilva         (VM guest)


NAS HOSTS (Countries)
└── remiferia         (NAS host)
    ├── ardent        (VM guest)
    ├── denai         (VM guest)
    ├── monrain       (VM guest)
    ├── lucent        (VM guest)
    └── eyja          (VM guest)

ROUTER (Extra-planar spaces)
└── thebeyond         (Router)
    └── phantasma     (Router VM guest)

SWITCHES (Named vehicles)
├── arseille          (Switch 1)
└── courageous        (Switch 2)

ACCESS POINTS (Named vehicles)
├── bobcat            (AP 1)
├── lusitania         (AP 2)
├── merkabah          (AP 3)
├── derfflinger       (AP 4)
├── pantagruel        (AP 5)
└── glorious          (AP 6)

DESKTOPS (Legendary weapons)
├── kernviter
├── blutgang
└── bolverk

UTILITY HOSTS (Artifacts)
├── azoth
├── gospel
└── gleipnir

OTHER HOSTS (Orbments)
├── arcus
├── enigma
└── xipha
```
