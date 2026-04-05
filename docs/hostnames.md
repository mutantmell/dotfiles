## Quick-reference DNS naming cheat sheet

```
VM HOSTS (Countries)
├── erebonia          (GP host)
│   ├── trista        (Incus VM) — Dev environment / task runner (backup)
│   ├── saint-arkh    (microVM, planned) — Forgejo Actions CI/CD runners
│   ├── heimdallr     (not allocated)
│   ├── ordis         (not allocated)
│   ├── roer          (not allocated)
│   ├── legram        (not allocated)
│   ├── ymir          (not allocated)
│   └── leeves        (not allocated)
│
├── calvard           (GP host)
│   ├── messeldam     (microVM) — Keycloak OIDC identity provider
│   ├── basel         (microVM) — step-ca PKI / certificate authority
│   ├── langport      (microVM) — Reverse proxy, nginx, oauth2-proxy
│   ├── oracion       (microVM) — Jellyfin media server
│   ├── tharbad       (microVM) — Prometheus, Loki, Alertmanager, ntfy
│   ├── edith         (Incus container) — Dev environment / task runner (primary)
│   ├── creil         (microVM) — Forgejo git hosting
│   ├── altair        (microVM, planned) — Headscale control plane
│   ├── longlai       (microVM, planned) — Tailscale subnet router
│   └── nemeth        (not allocated)
│
├── liberl            (NAS host)
│   ├── zeiss         (microVM) — Attic binary cache
│   ├── ruan          (microVM) — cgit bare repository hosting
│   ├── bose          (microVM) — Arr stack (Sonarr, Radarr, Bazarr)
│   ├── grancel       (not allocated)
│   ├── rolent        (not allocated)
│   └── ravennue      (not allocated)
│
├── northambria       (GP host)
│   ├── haliask       (not allocated)
│   ├── difwa         (not allocated)
│   ├── szaborja      (not allocated)
│   ├── standza       (not allocated)
│   ├── yabori        (not allocated)
│   └── kilva         (not allocated)
│
└── remiferia         (GP host)
    ├── ardent        (not allocated)
    ├── monrain       (not allocated)
    ├── denai         (not allocated)
    ├── lucent        (not allocated)
    └── eyja          (not allocated)

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

PERSONAL COMPUTERS (Legendary weapons)
├── kernviter         (NixOS-WSL Desktop)
└── angbar            (NixOS Laptop — ThinkPad X1 Carbon 7th Gen)

UTILITY HOSTS (Artifacts)
├── azoth             (not allocated)
├── gospel
└── gleipnir

OTHER HOSTS (Orbments)
├── arcus             (not allocated)
├── enigma
└── xipha
```
