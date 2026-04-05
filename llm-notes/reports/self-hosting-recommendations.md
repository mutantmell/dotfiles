# Self-Hosting Service Recommendations

Date: 2026-04-05 (revised)

## Current Infrastructure Summary

**Hosts:** thebeyond (router), remiferia/liberl (NAS), calvard (primary VM host), erebonia (build/CI host), angbar (laptop)

**Already deployed/planned:**

- Networking: zone-based nftables firewall, systemd-networkd, VLANs, WireGuard
- DNS: Unbound (split-horizon) + Adguard Home (filtering, not yet deployed — recommend Blocky instead)
- Identity: Keycloak OIDC, step-ca PKI, SSH certificates, oauth2-proxy
- Media: Jellyfin (oracion), arr stack planned (bose)
- Git/CI: Forgejo (creil), cgit (monrain), binary cache (ardent/zeiss), Woodpecker CI planned (saint-arkh)
- Monitoring: Prometheus, Loki, Perses (dashboards), Alertmanager, ntfy (tharbad)
- Storage: ZFS on NAS, NFS exports (RW/RO), Samba shares for Windows
- Containers: deployd + Kata on erebonia (roer API deployed, dynamic OCI workloads)
- Planned: Headscale VPN, Woodpecker CI, NATS fleet activation, media pipeline (arr stack on bose, Navidrome, Retrom), game servers, Raspberry Pi IoT hub (azoth, trusted VLAN)

---

## Recommended Services

### 1. File Sync & Personal Cloud — Seafile + Syncthing

**The problem:** You currently expose Samba shares (`drive`, `media`, `backup`) to Windows on the trusted VLAN. This works for LAN file access but provides no mobile access, no file versioning/history, no web UI, no file sharing links, and no sync to devices outside the home network.

**Recommendation:** **Seafile** for general file storage + **Syncthing** for media upload staging. Together they fully replace SMB.

**Important caveat:** Seafile stores files internally in a content-addressed chunked format, not as plain files on disk. You cannot point other services (e.g., the arr stack) at a Seafile library path and have them see normal files. This means Seafile is not suitable as the media upload path — files uploaded to Seafile would need an extraction step before the arr stack could process them.

**The split:**

| Current SMB share         | Replacement                                        | Why this tool                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| ------------------------- | -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `drive` (general storage) | **Seafile**                                        | Web UI, share links, versioning, mobile app, OIDC via Keycloak. Remote access without VPN. Replaces the "extra drive space" use case with a proper personal cloud.                                                                                                                                                                                                                                                                                                     |
| `media` (upload staging)  | **Syncthing**                                      | Direct-to-filesystem sync. Windows has a local `media-staging/` folder that syncs to liberl's `/data/media/manual/`. Files land directly on ZFS — no intermediary, no chunked storage, hardlink-safe for the arr stack. Works remotely (Syncthing handles NAT traversal natively). Uses "Send Only" / "Receive Only" folder types for one-way upload. Handles partial uploads gracefully (temp files + atomic renames, so the arr stack won't see half-written files). |
| `media` (library browse)  | **Seafile** (optional, read-only) or just Jellyfin | Expose `/data/media/library/` as a read-only Seafile library for browsing the organized collection from web/mobile. Cosmetic, not functional — Jellyfin already serves this role for playback.                                                                                                                                                                                                                                                                         |
| `backup`                  | **Seafile** or keep SMB                            | Depends on whether remote access to backups is wanted.                                                                                                                                                                                                                                                                                                                                                                                                                 |

**Deployment model:** Single microVM on liberl (vDMZ) running both Seafile and Syncthing. Both are user-facing services that accept inbound connections — vDMZ is the right zone for both. Co-locating avoids an extra VM while keeping inbound connections off the liberl host.

- **virtiofs shares:** Seafile's chunked data directory (on `/persist/guests/<name>/`) + Syncthing's receive folder passthrough to `/data/media/manual/` (direct ZFS access, hardlink-safe for the arr pipeline).
- **Resources:** 512MB-1GB RAM, 1-2 vCPU. Combined footprint is still small.
- **Seafile** served via local nginx on the same VM (TLS from step-ca), with langport forwarding external requests to it — same pattern as other proxied services. Keycloak OIDC for auth. Note: external access depends on langport's external proxy being unblocked (currently waiting on cloud host) or Headscale. Internal access works immediately. Dramatically lighter than Nextcloud — focused file sync engine in C/Python, clean upgrade path, no PHP/kitchen-sink overhead. (Nextcloud was previously run and retired due to upgrade pain and RAM consumption — Seafile avoids both issues.)
- **Syncthing** handles its own NAT traversal and discovery — no reverse proxy needed. Point the receive folder at the virtiofs mount of `/data/media/manual/`, accept the Windows device. Also useful for angbar↔NAS sync if needed.

**SMB retirement:** Once Seafile + Syncthing are operational, all three SMB shares can be removed. WSDD (Windows network discovery) can also be disabled. This simplifies the NAS firewall rules (remove ports 139, 445, 3702, 5357).

**Alternatives considered:**

- **Nextcloud** — Previously used, retired due to upgrade difficulty and high RAM usage. Not recommended.
- **FileBrowser** — Extremely lightweight web file manager. Viable if Seafile feels too heavy, but no sync client, no versioning, no mobile app.
- **SMB + Seafile without Syncthing** — Would require a webhook/script to extract files from Seafile's chunked storage to `/data/media/manual/`. Adds complexity; Syncthing is simpler for the direct-to-filesystem delivery.

---

### 2. Backups — Borg (existing, needs completion)

**Current state:** Borg backup is partially configured but not fully set up. The media pipeline plan also notes that the backup workflow needs its own plan — the liberl reformat is the forcing function since the current root SSH key used for manual off-site backups will be removed.

**Recommendation:** Complete the existing Borg setup rather than switching tools.

- Finalize Borg configuration with a scheduled NixOS systemd timer (`services.borgbackup.jobs`).
- Back up: ZFS datasets (via `zfs send` snapshots or direct Borg), sops secrets, guest persistent volumes (`/persist/guests/`), Keycloak/PostgreSQL database dumps (messeldam), Forgejo data (creil).
- Remote target: Backblaze B2 (via `rclone` bridge), BorgBase, rsync.net, or a USB drive for cold backup.
- **ZFS snapshots** for local point-in-time recovery — `services.sanoid` is the standard NixOS option for automated ZFS snapshot management if not already in use.
- The media pipeline plan mentions creating a dedicated `backup` system user with sops-managed SSH key, scoped to the backup provider. This should be part of the completion work.

**Deployment model:** Borg agent on remiferia/liberl (NAS) with systemd timers. For guests, back up their persistent storage from the host level. Prioritize completing this before the liberl reformat.

---

### 3. Blog / Personal Site — Static Site Generator via CI/CD

**The problem:** Blog/homepage containers were previously on ardent and retired. The roadmap notes "provision a dedicated microVM" when ready to host again. But a static site doesn't need a VM.

**Recommendation:** **Hugo or Zola** built via Woodpecker CI, deployed as static files

- Write content in a git repo on creil (Forgejo).
- Woodpecker CI on saint-arkh builds the static site on push.

**Option A — Self-hosted via deployd:** Woodpecker builds the static site into an OCI image containing nginx + the built files, pushes it to creil's container registry, and deploys it via deployd on erebonia. No dedicated microVM needed — this is exactly the kind of lightweight, CI-driven workload deployd is designed for. Proxied through langport for `mutantmell.net` or a subdomain.

**Option B — GitHub Pages:** Woodpecker pushes the built site to a GitHub Pages repo. Zero infrastructure to maintain. Use this if you don't want to depend on deployd being operational, or if external access (without Headscale/cloud host) is a priority.

**Recommendation for engine:**

- **Zola** — single binary (Rust), fast, good Nix support, no npm/node dependency chain.
- **Hugo** — most popular, largest theme ecosystem, also a single Go binary.

---

### Secrets Management Architecture (cross-cutting concern)

**Current state:** Three layers cover distinct trust domains:

| Layer               | Tool            | Access model                                     | Scope                                                              |
| ------------------- | --------------- | ------------------------------------------------ | ------------------------------------------------------------------ |
| Service secrets     | sops-nix        | Decrypted at NixOS activation, per-host age keys | Static NixOS services                                              |
| Operational secrets | passage         | CLI, encrypted in git, human-triggered           | Operator tasks (manual deploys, API keys, break-glass credentials) |
| Personal passwords  | Cloud Bitwarden | Browser/mobile apps, cloud-hosted                | Personal accounts, logins                                          |

This covers the current infrastructure well. The gaps emerge with the planned CI/CD and deployd layers:

**Gap 1 — CI/CD pipeline secrets:** Woodpecker needs registry credentials, signing keys, and deploy tokens at build time. Woodpecker has its own encrypted secrets store, but it's an opaque blob in its database — not auditable, not rotatable from outside, and duplicates values that already exist in sops.

**Gap 2 — deployd container secrets:** Dynamic containers aren't NixOS services, so sops-nix doesn't apply directly. The deployd spec passes env vars in the JSON definition, but the secret values need to come from somewhere.

**Gap 3 — Application-to-application credentials:** When a deployd container needs a database password or a CI job needs an Attic push token, each system currently maintains its own secret store with no central source of truth.

**Recommendation:** Extend sops to cover CI and deployd rather than adding new infrastructure.

- **Woodpecker secrets from sops:** Write a Woodpecker plugin or pre-step that decrypts sops secrets at build time. Secrets stay in git (auditable, version-controlled), Woodpecker doesn't need its own store. The CI runner host (erebonia/saint-arkh) already has an age key for sops decryption.
- **deployd reads host-level sops:** The deployd-helper runs on erebonia where sops secrets are already decrypted to `/run/secrets/`. The helper can inject host-side secrets into container env vars, using the host's age key as the trust anchor. No new infrastructure — just a deployment convention where deployd container definitions reference secret names rather than literal values.
- **passage stays for human operations:** Operator credentials, break-glass keys, and anything that requires human judgment to use. This is the right tool for the job and doesn't need to change.
- **Cloud Bitwarden stays for personal passwords:** The self-hosting overhead of Vaultwarden isn't worth the marginal savings for a single-user password manager. Keep cloud Bitwarden.

**Passage + Yubikey Bio — hardening options:**

The natural next step for passage is tying decryption to a Yubikey Bio via `age-plugin-yubikey`. However, this has a known limitation: age plugin decryption talks to the Yubikey via PCSC (local hardware interface), which **cannot be forwarded over SSH**. If the passage store is accessed from a remote host (e.g., edith), but the Yubikey is plugged into the local machine (angbar), decryption won't work remotely.

This is a [known gap in the age ecosystem](https://github.com/FiloSottile/age/discussions/244). Filippo (author of age, passage, and yubikey-agent) has a clear design direction — a separate `age-plugin-yubikey-agent` that uses an SSH agent protocol extension with explicit opt-in for forwarding — but there is no implementation or timeline. The deliberate blocker is that `ssh -A` forwarding age decryption by default would be a security surprise. OpenSSH has added some support for detecting forwarded requests, which could eventually enable denying forwarded age requests while permitting local ones, but this hasn't been implemented in the age tooling yet.

Two practical options:

1. **Local passage clone (intended model):** Clone the passage git repo on angbar/kernviter where the Yubikey is physically present. All decryption happens locally. When you need a secret while SSH'd into a remote host, `passage show` locally and paste, or pipe over SSH. This is how Filippo uses passage himself.

2. **Yubikey for disk encryption, not per-decryption:** Keep passage secured by the age key on disk. Protect disk access with the Yubikey Bio via `systemd-cryptenroll --fido2-device=auto` on angbar's LUKS volume. This gives "Yubikey required to boot/unlock" without needing it for every `passage show`. The threat this skips (someone with your unlocked session reading passage) is narrower than the threat it covers (cold-disk extraction).

Option 1 is stronger if you want per-operation hardware attestation. Option 2 is more ergonomic and still meaningfully raises the bar. Both are compatible with a future `age-plugin-yubikey-agent` if/when it ships.

**Future direction — OpenBao:** If the homelab grows to the point where dynamic credential rotation matters (short-lived database credentials, automatic API token rotation, multiple operators with different access levels), **OpenBao** (open-source Vault fork) is the natural next step. It supports Keycloak OIDC auth, dynamic secrets engines, and audit logging. But it's a significant operational commitment (unsealing, HA, backup) and overkill for the current scale. Note it as a future option, not a current need. The sops-based approach above doesn't preclude migrating to OpenBao later — it's a stepping stone, not a dead end.

---

### 4. Bookmarks & Read-Later — Linkding or Wallabag

**The problem:** Browser bookmarks don't sync well across devices, aren't searchable, and don't archive content.

**Recommendation:** **Linkding** (lightweight) or **Wallabag** (full read-later)

- **Linkding** — minimal bookmark manager with tags, search, browser extension, and API. ~50MB RAM. Python/Django. Simple and focused.
- **Wallabag** — full read-later service (like Pocket). Archives articles, strips formatting, provides a reading view. Heavier (~256MB RAM), PHP-based, but much more capable.

**Deployment model:** Either runs as a container via deployd (ideal lightweight workload for the dynamic container layer) or a small microVM. Proxy through langport with Keycloak auth.

---

### 5. Dashboard — Homepage or Homarr

**The problem:** With 15+ services across multiple VMs, there's no single pane of glass to see what's running or navigate to services.

**Recommendation:** **Homepage** (by gethomepage)

- Lightweight dashboard that shows service status, links, and widget data (Prometheus metrics, Jellyfin now-playing, etc.).
- YAML-configured, easy to declare in NixOS.
- Has integrations for most services you run (Jellyfin, Prometheus, Forgejo, etc.).

**Deployment model:** Static config, runs on langport itself or a tiny container via deployd. Serves as the landing page for `home.mutantmell.net` or similar.

**Alternatives:**

- **Homarr** — more polished UI, heavier, more opinionated.
- **Dashy** — extremely configurable, Vue-based, slightly heavier.

---

### 6. Recipes — Tandoor or Mealie

**The problem:** Recipe management is a surprisingly good fit for self-hosting — you likely have recipes scattered across bookmarks, screenshots, and browser tabs.

**Recommendation:** **Mealie** (simpler) or **Tandoor** (more powerful)

- **Mealie** — clean UI, URL scraping (paste a recipe URL, it extracts ingredients/steps), meal planning, shopping lists, API. ~200MB RAM, Python. Has OIDC support.
- **Tandoor** — more feature-rich (nutritional info, multi-user, import/export), Django-based, slightly heavier.

**Deployment model:** Container via deployd or small microVM. Ideal deployd workload — it's exactly the kind of application that doesn't warrant a NixOS rebuild when you want to try it.

---

### 7. Media Companions — Navidrome, Retrom, and others

**The problem:** The media spec (`jellyfin-media-organization.md`) already defines a full serving-node architecture on calvard alongside Jellyfin. These are natural next steps once the arr stack (bose) and Jellyfin (oracion) are fully operational.

**Already decided in the media spec/plan:**

- **Navidrome** — Dedicated music streaming server (Subsonic API). ~50-100MB idle, ~200-300MB active. Works with Subsonic-compatible mobile apps (DSub, play:Sub, Symfonium). Reads `/media/library/music` via RO NFS.
- **Retrom** — ROM library manager (replaces RomM per the media pipeline plan — publishes a Nix flake, better NixOS fit). Use **Igir** for ROM ingestion/DAT verification. Reads `/media/library/roms` via RO NFS.
- **Unmanic** — SVT-AV1 background re-encoding on erebonia. Reads/writes via RW NFS mount (already prepared in the media plan). Future work, out of scope for the media pipeline's initial delivery.

**Optional services from the spec (not yet decided):**

- **Audiobookshelf** — Audiobook and podcast server. ~100-200MB idle. Reads `/media/library/audiobooks`.
- **Kavita** — Ebook, comic, and manga library. ~100-200MB idle. Reads `/media/library/books`.
- **Immich** — Photo and video backup/gallery. Heavier (~300MB-2GB), manages its own storage independently. The most complex addition — only pursue if you want a Google Photos replacement.
- **Calibre-Web** — Lighter alternative to Kavita for ebook-only use. OIDC-capable via oauth2-proxy.

**Deployment model:** All read-only consumers share the same security model as Jellyfin (RO NFS mount from liberl). The media spec allocates them to calvard (serving node). Deploy as additional microVMs or co-locate lightweight ones (Navidrome) with oracion if resource constraints allow. **Lidarr** (music organization, analogous to Sonarr/Radarr) would go on bose alongside the arr stack if music management is wanted.

---

### 8. DNS Ad Blocking — Blocky (replaces Adguard Home)

**The problem:** Adguard Home is not yet actively deployed on phantasma. Before deploying it, the choice of DNS filtering tool should be reconsidered.

**Recommendation:** Deploy **Blocky** instead of Adguard Home.

Blocky is a better architectural fit for this homelab:

- **YAML-configured, no web UI** — fully declarative, lives in NixOS config, tracked in git. Adguard Home stores config and query logs in a mutable database outside NixOS declarations.
- **Native Prometheus metrics** — `/metrics` endpoint out of the box, plugs directly into tharbad's Prometheus scraping. Adguard Home has no native Prometheus exporter (requires a third-party shim).
- **Smaller footprint** — single Go binary, roughly half the memory of Adguard Home. Matters on phantasma (512MB, shared with Unbound).
- **NixOS module** — `services.blocky` in nixpkgs, [well-documented on the NixOS wiki](https://wiki.nixos.org/wiki/Blocky).
- **Per-client groups** — define device groups (e.g., by IP/MAC) with independent blocklist policies. Useful for household members with different filtering needs.

**What Blocky does NOT have:**

- No web UI — manage via config. Use Perses/Prometheus for DNS metrics, which is where your monitoring already lives.
- No DHCP server — irrelevant, Kea on thebeyond handles this.
- No built-in DoH/DoT _server_ — can query upstream via DoH/DoT, but doesn't serve encrypted DNS to LAN clients. Irrelevant since DNS interception on the router handles client queries.

**Kill switch for non-technical users:** Blocky exposes a [REST API](https://0xerr0r.github.io/blocky/latest/interfaces/) for toggling blocking at runtime:

- `PUT /api/blocking/disable` — disable blocking (optional `duration` and `groups` parameters)
- `PUT /api/blocking/enable` — re-enable blocking
- `GET /api/blocking/status` — check current state

This enables several wife-friendly toggle approaches:

- **Phone shortcut (simplest):** iOS/Android Shortcuts can make HTTP requests. A home screen shortcut that calls `PUT /api/blocking/disable?duration=2h&groups=household` — one tap, blocking disabled for 2 hours on her devices, re-enables automatically.
- **Simple web page behind oauth2-proxy:** A single HTML file with on/off buttons served from phantasma's nginx, protected by Keycloak auth. No NixOS rebuild, no YAML editing, no SSH.
- **Per-client group scoping:** Define her devices as a client group in Blocky's config. The API toggle is scoped to just her group — the rest of the network stays filtered. This avoids the "someone disabled ad blocking for everyone" problem that Adguard Home's global toggle has.

**Deployment model:** Replace Adguard Home on phantasma. Blocky handles the filtering/blocking layer and forwards non-blocked queries to Unbound (recursive resolver). Since Adguard Home isn't actively deployed yet, there's no migration cost — configure Blocky from the start.

---

### 9. Home Automation — Home Assistant (or Mosquitto + lightweight stack)

**The problem:** The Raspberry Pi MQTT spec already plans for SwitchBot BLE + Zigbee sensors. But sensors without a controller just produce data — you need something to act on it.

**Recommendation:** **Home Assistant** (when you're ready for the IoT layer)

- Home Assistant is the de facto standard. It has excellent Zigbee/BLE/MQTT integration.
- Runs well in a dedicated microVM or Incus container (~1GB RAM).
- Can integrate with your Keycloak identity layer.
- The Raspberry Pi pushes sensor data to MQTT; Home Assistant subscribes and provides automation rules, dashboards, and mobile app access.

**Deployment model:** Microvm on calvard or an Incus container. The network registry already has `azoth` (Raspberry Pi) on the trusted VLAN — Home Assistant would need a cross-zone firewall rule to reach the MQTT broker there. This is a future consideration — only deploy when the Pi/IoT layer is ready.

**Alternatives:**

- **Node-RED** — flow-based automation, lighter, but less polished for home automation specifically.
- **Pure MQTT + Prometheus** — if you only want observability (temperature graphs) without automation, the Pi's Prometheus exporter + tharbad is already sufficient.

---

### 10. Wiki / Knowledge Base — Outline or Wiki.js

**The problem:** Documentation about the homelab itself (runbooks, decisions, procedures) currently lives in `llm-notes/`. That works well for implementation plans, but operational knowledge (how to recover from X, where Y is stored, network diagrams) benefits from a searchable, linkable wiki.

**Recommendation:** **Outline** (if you want OIDC integration and a polished UI) or **BookStack** (if you want a simpler, documentation-focused tool)

- **Outline** — Notion-like wiki with native OIDC/Keycloak support, real-time collaboration, API, Markdown. Needs PostgreSQL + Redis (~512MB RAM total). Fits naturally into your Keycloak auth flow.
- **BookStack** — simpler, PHP/Laravel, book/chapter/page hierarchy. Less resource-hungry. Good if you want straightforward documentation rather than a collaboration tool.

**Deployment model:** Microvm on calvard or deployd container. Outline can share PostgreSQL with Keycloak (messeldam) if you want to consolidate, or run its own instance.

**Alternatives:**

- **Wiki.js** — Node.js, good git-backed storage option, OIDC support. Mid-weight.
- **Keep using git** — if `llm-notes/` is working, no need to add infrastructure for documentation's sake.

---

## Priority Ranking

| Priority | Section | Service                              | Effort | Value    | Why this priority                                                                                        |
| -------- | ------- | ------------------------------------ | ------ | -------- | -------------------------------------------------------------------------------------------------------- |
| **1**    | §2      | Backups (Borg, complete existing)    | Low    | Critical | Partially configured, needs completion before liberl reformat.                                           |
| **2**    | §1      | File sync (Seafile + Syncthing)      | Medium | High     | Replaces SMB entirely. Seafile for general storage, Syncthing for media upload.                          |
| **3**    | §3      | Blog (Zola/Hugo + Woodpecker CI)     | Low    | Medium   | Low-effort with planned CI/CD pipeline. Content is the hard part.                                        |
| **4**    | §5      | Dashboard (Homepage)                 | Low    | Medium   | Quality of life — single pane of glass for all services.                                                 |
| **5**    | §7      | Media companions (Navidrome, Retrom) | Low    | Medium   | Already decided in media spec. Deploy after arr stack is running.                                        |
| **6**    | §8      | DNS filtering (Blocky)               | Low    | Medium   | Better fit than Adguard Home — declarative, Prometheus-native, per-client groups. Deploy from the start. |
| **7**    | §4      | Bookmarks (Linkding)                 | Low    | Medium   | Good deployd candidate, lightweight, immediately useful.                                                 |
| **8**    | §6      | Recipes (Mealie)                     | Low    | Low-Med  | Fun, practical, good deployd test workload.                                                              |
| **9**    | §10     | Wiki (Outline)                       | Medium | Medium   | Depends on whether git-based docs feel insufficient.                                                     |
| **10**   | §9      | Home Assistant                       | High   | Medium   | Blocked on Pi/IoT hardware deployment (azoth).                                                           |

**Not ranked separately:** Secrets management (cross-cutting section between §3 and §4) is an architectural concern, not a standalone service. The sops bridging work for Woodpecker and deployd should be done as part of those systems' implementation, not as an independent project.

---

## Notes on Deployment Strategy

**Static NixOS services** (priorities 1-2): Borg backup completion, Seafile, and Syncthing are stable, long-lived services that benefit from declarative NixOS configuration. Seafile + Syncthing share a single microVM on liberl (vDMZ).

**SMB retirement:** Once Seafile + Syncthing are operational, all three SMB shares (`drive`, `media`, `backup`) can be removed along with WSDD. This also resolves the media pipeline plan's concern about SMB's full RW access to `/data/media` contradicting the least-privilege model — Syncthing delivers files to `/data/media/manual/` (the staging inbox) rather than exposing the entire media tree.

**Media companions** (priority 5): Navidrome and Retrom are already specified in the media pipeline plan. They follow the same deployment pattern as Jellyfin (RO NFS mount, microVM on calvard). Deploy after the arr stack (bose) is operational.

**deployd candidates** (priorities 4, 7-8): Homepage, Linkding, and Mealie are ideal early workloads for the deployd dynamic container layer — they're stateless or near-stateless, don't need tight NixOS integration, and are easy to replace or remove. Good for validating deployd before using it for CI/CD-deployed services.

**Blog** (priority 3): Doesn't need a running service at all if built statically via Woodpecker CI. The "service" is just nginx serving files — this could share langport's nginx or be a trivial dedicated microVM.
