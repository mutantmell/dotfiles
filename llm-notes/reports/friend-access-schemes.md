# Friend Access to the Homelab — Survey & Recommendation

Date: 2026-04-06

## Purpose

Survey the design space for letting non-technical friends reach homelab
services (game servers, occasional desktop-hosted sessions, eventually web
services like a media library) without:

- Requiring them to learn networking, key management, or VPN configuration.
- Exposing self-hosted infrastructure (Keycloak, web admin UIs, SSH) to the
  general internet, where it would have to absorb scanning and brute-force.
- Granting wide access if a friend's account is compromised — the recent
  Discord+Steam thefts in your friend group are the live threat.
- Locking the project to a commercial SaaS that can't be substituted with
  an open-source equivalent.

This is a research report, not an implementation plan. It deliberately does
not anchor on existing infrastructure: microvm.nix makes it cheap enough to
spin up or tear down VMs that "we already have X" should not be a tiebreaker.

---

## Confirmed requirements (from Q&A)

| Question                       | Answer                                                                                                                                                                                                     |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Cloud VPS (~$5/mo) acceptable? | **Yes**, primary path may use one. **But** the report must include a clean no-VPS alternative for comparison.                                                                                              |
| Inbound on residential WAN?    | **No**, with a single exception: **WireGuard UDP** is acceptable. Nothing else (no HTTPS, no SSH, no game ports).                                                                                          |
| Retro / broadcast games?       | **Real but rare.** Came up once with AI War II when Steam networking broke. Acceptable if it can't work — don't build a parallel system, do note any easy escape hatches.                                  |
| Desktop-hosted sessions?       | **Occasional, ad-hoc.** A small ceremony at the start of a session is fine. Should not be a primary use case the architecture is built around.                                                             |
| Enrollment style?              | Initially "Discord bot or one-time link". **Resolved during the report to plain email + pre-authkeys** — no bot, blast radius is small enough that long-lived peer identities + key expiry are sufficient. |

These narrow the design space substantially. In particular: the WAN-only-WG
constraint forces _any_ no-VPS design into a shape where the WireGuard
listener itself is the only public-internet-reachable thing on the homelab,
and the control/auth plane has to be reachable through that tunnel rather
than directly. That's a real constraint and changes the option set.

---

## Threat model

Designed around the friend-account-compromise case, since it's already
happened in your friend group:

| Threat                                  | What "good" looks like                                                                                                               |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Friend's Steam/Discord stolen           | No direct path from those accounts to homelab access. Auth is decoupled from third-party gaming/chat identity.                       |
| Friend's homelab credential phished     | Per-friend credential, optional MFA, instant central revocation, no shared secrets between friends.                                  |
| Friend's machine compromised            | Attacker reaches **only** the IPs/ports you've explicitly opened, on the network position of game servers.                           |
| Internet scanner finds your edge        | Edge listens for one well-known protocol and silently drops everything else. No banner-grab reveals what the homelab is running.     |
| Auth service targeted from the internet | Auth service is not directly internet-reachable; reached only via a throwaway proxy or via the same WG tunnel friends already use.   |
| Compromise of the relay/proxy/edge      | Edge holds no plaintext, no long-lived secrets, routes only to a small allowlist of internal targets, and can be rebuilt in minutes. |

The most useful framing: **the friend access plane must not be the same
trust plane as the admin plane.** Friend credentials should be unable to
authenticate to anything that isn't a game.

---

## Solution categories

The design space falls into four shapes; serious answers are hybrids.

1. **Identity-aware L3 mesh overlay** — friends run a client that builds
   an authenticated WireGuard tunnel into the homelab. ACLs gate which
   IPs/ports are reachable. Examples: Tailscale (control plane is SaaS),
   Headscale, NetBird, Firezone, Defguard, innernet.
2. **L2 overlay** — emulates Ethernet, broadcast and LAN-discovery work.
   Examples: ZeroTier, n2n, tinc. Solves retro broadcast cases.
3. **Identity-aware reverse proxy at the edge** — only HTTP services. The
   proxy authenticates the user before forwarding. Examples: oauth2-proxy
   - nginx, Authelia, Pomerium, Pangolin. Useful for web services only.
4. **Out-of-band enrollment** — a side channel (Discord bot, one-time
   link) issues credentials that one of the above accepts. Not a
   transport, just changes how friends _get_ an account.

---

## Detailed options

Each option is evaluated against the same axes: friend onboarding UX,
support for game traffic, support for desktop hosting, broadcast/retro
games, blast radius on credential compromise, substitution risk
(can it be replaced if the project dies?), and how it interacts with
the WAN-only-WG constraint.

### A. Headscale + Tailscale clients

Self-hosted Tailscale control plane; friends use the upstream Tailscale
client; OIDC login via your own IdP; ACLs limit reachable destinations.

- **UX:** Best in class. Install one app, click one login button. STUN
  hole-punching means most data flows directly between peers.
- **Game traffic:** Excellent (WireGuard, direct after STUN, fall back to
  DERP relay).
- **Desktop hosting:** Workable: install Tailscale on the desktop with
  `--shields-up`, bring it up only during a session. ACLs restrict the
  `gamers` group to specific desktop ports.
- **Broadcast/retro:** L3 only. AI-War-II-style "Steam is broken, connect
  by IP" works fine. True LAN-discovery games don't work.
- **Blast radius:** Strong. OIDC group → tunnel allowed. ACL → reach only
  listed IP:port tuples. No SSH, no NAS, no admin paths.
- **Substitution risk:** Very low. Headscale is mature, BSD-3, multiple
  maintainers; the Tailscale client is open source under BSD-3 and would
  outlive the SaaS even in the worst case.
- **WAN-only-WG fit:** Bad without help. Headscale's control plane is
  HTTPS, the OIDC redirect flow is HTTPS, and the embedded DERP relay
  expects TCP/443 + UDP/3478 reachable from the internet. Without a cloud
  VPS, none of this is reachable. Workarounds (pre-auth keys instead of
  OIDC, friends bootstrap on a one-time hot-spot/visit) are awkward.

### B. NetBird

Open-source Tailscale-shaped product; WireGuard data plane; own clients;
own control plane; native OIDC; embedded relay/STUN.

- **UX:** Very good, slightly behind Tailscale's app polish — but still
  "install, click login, done". Mobile clients exist for iOS/Android.
- **Game traffic:** Excellent.
- **Desktop hosting:** Same shape as Headscale: install client, bring up
  on demand, restrict via policy.
- **Broadcast/retro:** L3 only.
- **Blast radius:** Strong (native group/policy model).
- **Substitution risk:** Low. AGPL, actively developed, designed for
  self-host as primary deployment (not as an afterthought).
- **WAN-only-WG fit:** Same problem as headscale — control plane and
  signal/relay are HTTP-shaped.

### C. innernet

Tonari's self-hosted WireGuard mesh. Distinguishing feature: **the entire
control plane is itself reached over WireGuard.** Bootstrap is a one-time
invite (a short-lived secret string); after that, all coordinator traffic
flows inside the mesh.

- **UX:** Good for technical users; for non-technical friends, it's a
  CLI tool with no GUI client. The bootstrap step is "paste this string
  into the app", not "click login".
- **Game traffic:** Pure WireGuard, fine.
- **Desktop hosting:** Pure WireGuard, fine.
- **Broadcast/retro:** L3 only.
- **Blast radius:** Strong (CIDR-based associations between groups). No
  OIDC layer, so revocation is "delete from coordinator, all peers
  refresh on next interval".
- **Substitution risk:** Low. Small, focused, MIT licensed; could be
  forked trivially if it stagnates.
- **WAN-only-WG fit:** **Excellent.** Innernet is the only mainstream L3
  option that natively requires nothing except a WireGuard listener.
  Coordinator HTTPS rides inside the WireGuard tunnel; the public-internet
  surface is one UDP port.

The catch is the UX: innernet doesn't have the polished mobile clients
that Headscale/NetBird inherit from Tailscale. For a non-technical
friend group, this is a significant downside. It's the natural fit for
the no-VPS path, where its WAN-fit advantage is decisive.

### D. Firezone (1.x)

Open-source WireGuard control plane with web UI and OIDC.

- **Substitution risk:** **High.** Firezone 1.x rewrote the architecture
  toward their hosted control plane. Self-hosted is now a secondary path
  and the project's commercial direction is the opposite of what you
  want. Not recommended on substitution-risk grounds alone.

### E. Defguard

Polish-developed open-source SDP; WireGuard; can be the IdP itself or
use external; MFA-at-the-gateway.

- **UX:** OK. Mobile client maturity behind Tailscale's. The
  MFA-on-reauth pattern is friction for casual gaming.
- **Otherwise:** Comparable to NetBird on most axes. Distinguishing
  feature is the periodic-reauth-on-the-tunnel itself, which is good for
  the compromise-blast-radius goal but bad for the friend-UX goal.
- **Verdict:** Better as the path for _your own_ devices than for friends.

### F. ZeroTier (with self-hosted controller)

L2 overlay. The unique capability: real broadcast/multicast.

- **UX:** Mature client on every platform, but the self-hosted control
  path is community-supported and the supported product is the SaaS
  controller. Friends would join a network ID; enrollment is by
  controller API call (no OIDC integration to speak of).
- **Game traffic:** Fine.
- **Broadcast/retro:** **Only option that natively carries it.**
- **Blast radius:** Weaker default (L2 means everyone in the network can
  ARP everyone else). Flow rules exist but aren't as ergonomic as
  Headscale ACLs.
- **Substitution risk:** Medium. The data-plane protocol is open and
  stable; the self-hosted controller is community code that has lived a
  long time but is not the company's focus.
- **WAN-only-WG fit:** Bad. ZeroTier uses its own UDP protocol (default
  port 9993) which is not WireGuard. By the rule "WireGuard UDP only",
  ZeroTier is excluded from the no-VPS path entirely.

### G. Manual WireGuard with a self-service portal (wg-portal, wg-easy)

A web UI generates per-friend WireGuard configs and QR codes.

- **UX:** "Import this file" is exactly what sank the previous attempt.
  QR helps on phones, fails on desktop. Not the friend solution.
- **Useful for:** maybe one or two more wg-ba-style technical friends.
  Not the primary answer.

### H. oauth2-proxy / Authelia / Pomerium (identity-aware reverse proxy)

Web-only. The proxy authenticates the user before forwarding to an
upstream service.

- **UX:** Lowest possible — browser, login, done. No install.
- **Game traffic:** **Cannot carry it.** Showstopper for the primary
  use case.
- **Verdict:** Necessary for _anything web-shaped_ friends might touch
  (server browser, mod download, eventual media library), insufficient
  on its own. This is a complement to a transport, not a substitute.

### I. Pangolin (self-hosted Cloudflare-Tunnel-equivalent)

A cloud relay holds the public IP; an outbound connection from the
homelab daemon multiplexes traffic back. Built-in OIDC and per-resource
policies. Supports TCP and UDP.

- **WAN fit:** Excellent (zero inbound, even WireGuard isn't needed
  inbound). However it requires the cloud VPS by definition.
- **Game traffic:** UDP through a single relay = friends' ping floor.
  Worse than the direct-WG-after-STUN model. Single-location latency.
- **Substitution risk:** Medium. Young project (2024-ish), promising,
  not yet "I'd bet the homelab on it."
- **Verdict:** Not where I'd start, worth tracking. Most useful as the
  _web_ path on a cloud VPS, where nginx + oauth2-proxy already does
  the same job with less novelty.

### J. Plain email enrollment with setup keys / one-time invites

You generate a credential (headscale pre-authkey, innernet invite, or
similar) via an admin command, and email it to the friend. The friend
pastes it into the client app once; from then on the client uses
peer keys that rotate naturally on expiry.

- **Strengths:** Zero infrastructure beyond what already exists.
  Email is universal. The "credential" is short-TTL (24h), single-use,
  group-bound. Allowlist enforcement is simply "who you decide to
  email". The transport layer (headscale, innernet, etc.) handles all
  subsequent re-auth via peer key expiry, so there's no ongoing
  password rotation to manage.
- **Compromise scenarios:** A stolen email at enrollment time only
  affects that single enrollment, not past or future ones. A stolen
  _peer identity_ later is bounded by the transport's ACLs (group →
  port). Long-lived friend identities are acceptable because:
  (a) blast radius is small (game ports only, no admin paths),
  (b) peer key expiry forces re-auth every 90 days,
  (c) inactive accounts can be auto-disabled after N days.
- **Substitution risk:** None (no SaaS).
- **Verdict:** **Recommended enrollment shape.** A bot was considered
  earlier in the report and rejected as overengineering for
  friend-group scale — the bot's only material advantage was
  self-service (`!enroll` instead of you sending an email), which is
  not worth the moving parts when enrollment happens five times in
  two years.

### J-alt. Discord bot for credential issuance (considered, not recommended)

A bot in a private guild, locked to allowlisted Discord user IDs,
provisions credentials on demand. Documented here for completeness;
worth revisiting only if friend-group scale grows past where manual
email becomes annoying (perhaps 30+ active friends).

- The bot's _advantages_ over plain email are self-service and
  turnaround speed.
- The bot's _costs_ are: a service to maintain, Discord SaaS
  dependency at the enrollment layer, an allowlist datastore to keep
  in sync, and a "stolen Discord account on the allowlist" attack
  vector that plain email doesn't have.
- For a friend group small enough that you remember everyone's name,
  the manual email path strictly dominates. Reconsider only if the
  scale changes.

### K. One-time enrollment links

You generate a single-use, short-lived URL by hand, deliver it any
channel, friend clicks it, gets an account. Dead after consumption.

- **Strengths:** No standing exposure. No SaaS dependency. Roughly
  equivalent to (J) on security; slightly worse on UX (you have to
  generate and deliver each link manually).
- **Verdict:** Reasonable fallback or alternative to (J). Trivially
  implementable as a small service inside the homelab.

---

## Comparison matrix

| Option                        | Friend UX | Game traffic  | Desktop host | Retro/broadcast | Blast radius | Substitution risk | WAN-only-WG fit |
| ----------------------------- | --------- | ------------- | ------------ | --------------- | ------------ | ----------------- | --------------- |
| A. Headscale                  | ★★★★★     | ★★★★★         | ★★★          | ✗               | ★★★★         | ★★★★★             | ★ (needs VPS)   |
| B. NetBird                    | ★★★★      | ★★★★★         | ★★★          | ✗               | ★★★★         | ★★★★              | ★ (needs VPS)   |
| C. innernet                   | ★★        | ★★★★          | ★★★          | ✗               | ★★★★         | ★★★★              | ★★★★★           |
| D. Firezone 1.x               | ★★★★      | ★★★★          | ★★★          | ✗               | ★★★★         | ★★ (declining)    | ★ (needs VPS)   |
| E. Defguard                   | ★★★       | ★★★★          | ★★★          | ✗               | ★★★★★        | ★★★★              | ★ (needs VPS)   |
| F. ZeroTier (self-host)       | ★★★       | ★★★★          | ★★★          | ★★★★★           | ★★★          | ★★★               | ✗ (non-WG UDP)  |
| G. Manual WG + portal         | ★★        | ★★★           | ★★           | ✗               | ★★★          | ★★★★★             | ★★★★            |
| H. oauth2-proxy / IAP         | ★★★★★     | ✗             | ✗            | ✗               | ★★★★★        | ★★★★★             | ★ (needs VPS)   |
| I. Pangolin                   | ★★★★      | ★★ (UDP iffy) | ★★           | ✗               | ★★★★         | ★★★               | n/a (needs VPS) |
| J. Email setup keys / invites | layer     | layer         | layer        | layer           | layer        | ★★★★★             | layer           |
| J-alt. Discord bot enrollment | layer     | layer         | layer        | layer           | layer        | ★★★ (Discord)     | layer           |

"Layer" entries are enrollment overlays on top of A–F.

---

## Recommendation

I'm going to give you **two complete designs**: a primary recommendation
that uses a small cloud VPS, and an alternative that does not. The
primary is meaningfully better on friend UX; the alternative is
meaningfully better on independence.

### Primary recommendation (with cloud VPS): Headscale with zero-inbound rendezvous + email pre-authkey enrollment + on-demand desktop client

**Why Headscale over NetBird:** They're very close, and either is a
defensible choice. Headscale wins on three things, two of which only
became apparent during this report:

1. **The Tailscale client app is the most polished mobile/desktop
   experience in the space.** For non-technical friends installing
   client software they didn't ask for, that polish matters more than
   any other factor — it's the difference between "friends actually
   use it" and "friends quietly drop it after a frustrating
   onboarding". With no SaaS bootstrap option to fall back on (the
   user counts on Tailscale free and NetBird Cloud free are both too
   small for the friend group), the client UX is the friction point
   that determines whether this works at all.
2. **License: BSD-3 vs AGPL.** Headscale and the Tailscale client are
   both BSD-3-licensed. NetBird is AGPL. Both are open source, both
   are self-hostable, but BSD-3 is preferred for this project.
3. **A working starting point already exists in `wip/`.** The 1071-
   line `headscale-integration-plan.md` is ~80% applicable to the
   design this report calls for, modulo specific changes (zero-inbound
   architecture, pre-authkeys instead of OIDC for friends, on-demand
   desktop client, host firewall on the homelab peer as load-bearing).
   That existing work shouldn't be thrown away to re-derive a NetBird
   equivalent.

The arguments that earlier drafts of this report used to favor NetBird
(self-host as the primary deployment story, cleaner signal/relay
separation) are real but smaller. They were worth a tiebreaker; they
weren't worth giving up the Tailscale client polish or the existing
plan work. **Build this as Headscale; treat NetBird as the known-good
fallback** if Headscale ever pivots away from self-host (which it
shows no sign of doing).

**Note on the headscale STUN/DERP awkwardness:** earlier drafts of
this report flagged the embedded-DERP-needs-correct-STUN issue as a
mark against Headscale. That concern was specific to the _previous_
architecture, where DERP/STUN had to traverse a wg-tunnel from the
cloud VPS into the homelab and STUN's reflected addresses would be
wrong. In the **zero-inbound design** below, DERP and STUN run
directly on the cloud VPS — they see friends' real public IPs
correctly, no tunnel in the way. The original awkwardness disappears.

#### Architecture (zero-inbound from cloud)

The defining property of this design is that **no traffic ever flows
from the cloud VPS into the homelab.** The cloud VPS is a control-plane
rendezvous server only; the friend↔homelab data plane runs over a
direct WireGuard tunnel that terminates on the homelab's residential
WAN.

```
Friends (Tailscale client)                     Cloud VPS (~$5/mo)
   │                                           ┌────────────────────────┐
   │  outbound HTTPS ─────────────────────────▶│ headscale (control)    │
   │  (control plane: register, ACL push,      │ • Node registry        │
   │  peer info, key refresh)                  │ • Policy push          │
   │                                           │ • Embedded DERP relay  │
   │                              ┌───────────▶│   (TCP/443 fallback,   │
   │                              │ outbound   │    sees encrypted WG)  │
   │                              │ HTTPS      │ • STUN (UDP 3478)      │
   │                              │            │   sees real public IPs │
   │                              │            └────────────────────────┘
   │                              │
   │  direct WireGuard UDP        │
   │  to home.wan.ip:41641        │
   ▼                              │
┌───────────────────────────────────────────┐
│  Homelab subnet router (vDMZ microVM)     │
│  • tailscaled, dials VPS outbound for     │
│    control plane                          │
│  • Listens on WG UDP for friend traffic   │
│  • Enforces ACL + host firewall (load-    │
│    bearing — see WG key handling section) │
│  • Advertises vDMZ routes into the        │
│    tailnet                                │
└──────────┬────────────────────────────────┘
           │
           ▼
   Game server VMs (vDMZ),
   on-demand desktop, etc.
```

**Important: the open WG port on the residential WAN does _not_ mean
friends configure WireGuard.** That port is purely a server-side
listener. Friends install the Tailscale app, run one login command (or
tap a button on mobile), and the app handles keypair generation, peer
info exchange, and tunnel setup automatically. From a friend's
perspective the experience is identical to using hosted Tailscale —
install one app, log in, done. They never see a `.conf` file, never
type a key, never know what port number they're connecting to. The
only thing that's different from the hosted Tailscale UX is the
one-time login command pointing at your headscale URL instead of
Tailscale's.

Important properties of this shape:

- **Zero inbound traffic from the cloud VPS into the homelab.** The
  homelab dials _outbound_ HTTPS to the VPS for control plane. Friend
  traffic terminates directly on the homelab's residential WAN over
  WireGuard. The cloud VPS is in neither direction of the data path.
- **One WireGuard UDP port is the entire residential WAN attack
  surface.** WireGuard's listener silently drops anything that doesn't
  authenticate against a known peer key — to a port scanner it looks
  like a closed port, no banner, no responses. There is no HTTPS
  service, no SSH service, no game-server port forwarded.
- **The cloud VPS holds nothing valuable.** It runs headscale (node
  registry + ACL policy + embedded DERP relay + STUN). No plaintext
  friend traffic, no Keycloak database, no SSH keys, no homelab
  credentials. If it gets owned, you delete the VM, `nix run
.#deploy-cloud-host`, and the homelab subnet router reconnects to
  the new instance on its next dial-in cycle.
- **The cloud VPS is necessary but not sufficient for any attack on
  the homelab.** A hostile control server could push an ACL that
  _says_ "let attacker reach 10.97.x.y:22", but the homelab's own
  subnet-router host firewall and the router's nftables rules enforce
  the actual permitted IPs and ports. Defense in depth: control-plane-
  pushed ACL is one layer of three.
- **Friend data flows direct WG whenever possible**, with headscale's
  embedded DERP on the VPS as fallback for friends behind aggressive
  symmetric NATs. DERP relays _encrypted_ WireGuard packets that it
  cannot decrypt — being in the data path doesn't compromise zero-
  inbound, since "inbound" means inbound _to the homelab_, and
  DERP-relayed packets still arrive at the homelab over the same WG
  UDP port as direct ones.
- **STUN sees real public IPs.** Because DERP and STUN run directly
  on the cloud VPS (not tunneled through anything), the STUN server
  sees friends' actual public IPs and can give correct NAT-traversal
  hints. This was the awkwardness called out in earlier drafts of
  this report; the zero-inbound design happens to resolve it.
- **Auth is fully internal.** Keycloak runs on vINFRA and is _not_
  internet-reachable at all in this design. Headscale's OIDC flow
  _would_ require Keycloak to be reachable to friends' browsers,
  which would re-introduce inbound traffic. **The zero-inbound design
  uses headscale pre-authkeys for friends instead of OIDC** — see
  "Authentication path" below.

#### Authentication path (no inbound to Keycloak from internet)

This is the trickiest sub-problem of the zero-inbound design.
Headscale's OIDC flow requires that the friend's _browser_ can reach
the configured IdP for the login redirect. If Keycloak lives in the
homelab, that means either:

1. **Keycloak is published through a VPS reverse proxy** — re-introduces
   inbound to the homelab for HTTPS. Defeats the goal.
2. **Keycloak is migrated to the cloud VPS** — auth state on the VPS,
   higher-value compromise target, harder to back up.
3. **Headscale uses pre-authkeys instead of OIDC** — friends never do
   an interactive OIDC login at all; you generate a per-friend
   pre-authkey via the headscale CLI (or a small admin tool), email
   it to them, they pass it to their Tailscale client during initial
   `tailscale up`. After that, the node registers persistently and
   re-auth happens via key expiry, not OIDC.

**Recommendation: option 3 (pre-authkeys).** It's the cleanest fit
with the zero-inbound goal. Headscale supports pre-authkeys natively
with the properties you want: single-use, time-limited, tagged (so
friends register pre-assigned to `tag:friend`, which the ACL uses
for group membership).

From the friend's POV the flow becomes:

1. You run an admin command that mints a single-use pre-authkey
   tagged `tag:friend`, with a 24-hour TTL.
2. They receive an email containing: the Tailscale app download link,
   the headscale login URL (`https://vpn.<your-domain>`), and the
   pre-authkey string.
3. They install the Tailscale app and run (or paste into the GUI):
   ```
   tailscale up --login-server=https://vpn.<your-domain> --authkey=<key>
   ```
   On mobile, the equivalent is "Use a custom server" in app
   settings, then paste the auth key when prompted.
4. They're connected. The node persists in headscale; subsequent
   reconnects don't need a new key.

The pre-authkey is single-use (consumed by the friend's first
registration; the resulting node identity is what subsequent
connections use). Headscale's per-node key expiration handles natural
rotation: set node expiry to 90 days, and friends re-auth quarterly
by reopening the app. No new pre-authkey needed unless you want to
rotate the underlying identity.

**Keycloak is still useful**, just not for friend WG access. Keep
Keycloak in the homelab for:

- Admin SSO for _your_ devices and the homelab admin UIs.
- The web-services-for-friends path (see "Future: web services" below).
- SSH certificates (via the existing SSH cert plan).

Friends end up with one credential (the headscale pre-authkey,
consumed at enrollment) for game access, and _no_ Keycloak account
at all unless and until you decide to offer them web services.

#### Friend onboarding UX

1. You run an admin command (~50-line wrapper around `headscale
preauthkeys create`) that mints a tagged, single-use, 24h-TTL
   pre-authkey and emails it to the friend.
2. They get an email containing the Tailscale app link, the headscale
   login URL, and the pre-authkey string.
3. They install the Tailscale app, paste in the URL and key (or run
   one `tailscale up` command on desktop).
4. They're connected. They see entries in the Tailscale client
   labeled by friendly hostname (MagicDNS handles this — they see
   `minecraft.tail.internal` not `10.0.100.70`).

No config files. No keys (the pre-authkey is one paste, then
forgotten). No port numbers. No terminals beyond a single one-line
`tailscale up` command on Linux desktops, which mobile and Windows
friends never need to touch.

If you want, the email can come from a tiny script (~50 lines of Nix
or Python) that shells out to `headscale preauthkeys create` (or hits
the headscale gRPC API directly) to mint the pre-authkey and uses your
SMTP relay (or even just `mailutils` over a local SMTP-to-self) to
send the message. There is no bot, no Discord dependency, no enrollment
service — just an admin command that produces an email.

#### Compromise blast radius

- **Friend's pre-authkey intercepted (single-use).** The first person
  to use it becomes the legitimate peer; if an attacker beats the
  friend to it, the friend's client errors when they try to enroll,
  and you immediately know to revoke and reissue. Pre-authkeys should
  be short-TTL (24 hours).
- **Friend's tailnet node identity (peer key) stolen.** Attacker
  reaches `tag:friend`-tagged resources only — specific game server
  IP:port tuples. Cannot reach SSH, NAS, admin UIs, vINFRA, vHOME,
  other friends, or the desktop unless an active session has it up.
  Per-node key expiry (90 days) limits how long a stolen key remains
  valid without re-auth.
- **Friend's email account stolen (the channel that delivered the
  pre-authkey).** Only impacts _future_ enrollments. Past enrollments
  rely on the persisted node identity, not the pre-authkey. Mitigation:
  short TTL on pre-authkeys (24h) means a stale email inbox doesn't
  contain a usable key.
- **Cloud VPS owned.** Attacker holds the management server. Cannot
  decrypt friend traffic and cannot impersonate any existing peer (see
  "WireGuard key handling under control-plane compromise" below). Can
  push policy that adds a new attacker-controlled peer to the `gamers`
  group. The homelab's host firewall + router rules enforce the actual
  permitted destinations, so policy push is necessary but not
  sufficient — the attacker reaches at most what `gamers` can already
  reach (game server IP:port tuples). Recovery: rebuild the VPS from
  `nix run .#deploy-cloud-host`, rotate the headscale signing keys,
  homelab reconnects on next dial-in.
- **Homelab subnet router microVM owned.** Attacker holds one vDMZ
  microVM with egress filtered to the cloud VPS (HTTPS) and DNS only.
  Same blast radius as compromising any vDMZ service.

#### WireGuard key handling under control-plane compromise

This is the property that makes the "cloud VPS owned" row above
acceptable, and it's worth being explicit about because it constrains
what the implementation must do.

**WireGuard private keys never leave the peer that generates them.**
Each tailnet peer (the homelab subnet router microVM, each friend's
device) generates its own keypair locally on first run. Only the
public key is uploaded to headscale. Headscale's database contains:

- Public keys for every peer
- Last-known endpoint info (public IP and port) per peer
- Group memberships, policies, user identities

Headscale does **not** contain any WireGuard private key, ever. A
compromise of the cloud VPS therefore cannot:

- Decrypt past friend↔homelab traffic. WireGuard's handshake uses
  ephemeral Curve25519 keys per session and provides forward secrecy;
  even retroactively obtaining the long-term private keys would not
  decrypt prior sessions.
- Decrypt future traffic between legitimate peers.
- Impersonate the homelab to a friend's client (would need the
  homelab's WG private key, which lives on the subnet router microVM).
- Impersonate a friend to the homelab (would need that friend's WG
  private key, which lives on the friend's device).

What it **can** do — and this is the residual risk — is **add a new
peer with an attacker-controlled keypair**:

1. Attacker generates a fresh WG keypair on their own machine.
2. Attacker inserts a row into headscale's database: "node 'rogue',
   public key X, tagged `tag:friend`, allowed to reach <whatever the
   friend ACL permits>".
3. Attacker pulls the homelab subnet router's public key and endpoint
   info from headscale (they control it now).
4. Attacker establishes a direct WireGuard handshake from their
   machine to the homelab's residential WAN port, using their own
   private key against the homelab's known public key.
5. The homelab tailscaled trusts headscale's claim that this new
   public key is tagged `tag:friend`, so the handshake succeeds.

The defense is **not** "trust headscale"; it's **two independent
enforcement layers** at the homelab side that headscale cannot
override:

1. **Host firewall on the homelab subnet router microVM** — an
   nftables ruleset that only permits _forwarded_ traffic to specific
   destination IPs on specific ports, deployed via Nix and not
   configurable from headscale. The headscale ACL says "reach
   10.97.x.y:25565"; the host firewall says "I will only forward to
   the explicit list of game-server-IP:game-server-port tuples
   regardless of what headscale thinks". Both must permit a packet.
2. **Router nftables rules** — thebeyond enforces zone boundaries.
   Even if the subnet router microVM tries to forward traffic to
   vINFRA or vHOME, the router drops it at the zone boundary.

With both layers in place, the worst a fully-compromised cloud VPS
can achieve is to inject a peer that can reach exactly the same set
of IPs and ports the legitimate `tag:friend` nodes can already reach.
**Functionally, a pwned cloud VPS has the same blast radius as a
stolen friend credential.** That's the property worth checking
against during implementation.

**This is not a headscale-specific weakness.** Tailscale, NetBird,
Defguard, and every other control-plane-based mesh share the same
property: control-server compromise enables peer injection but not
key theft. The mitigation (independent enforcement at the data-plane
endpoints) is also the same for all of them.

**Implementation consequence:** the homelab subnet router microVM's
host firewall is **load-bearing**, not advisory. It is the second of
two independent enforcement layers and skipping it would make the
cloud VPS the sole authority for what friends can reach. The
implementation plan must treat it as a non-negotiable component, not
"defense in depth we'll add later".

#### Desktop hosting

When you want to host from the workstation:

1. Run `sudo tailscale up --login-server=https://vpn.<your-domain>
--shields-up` (or a hotkey/script). The client comes up with
   shields-up hardening so only ACL-permitted ports are reachable.
2. Start the game.
3. Tell friends the desktop's MagicDNS name (or it's already in their
   Tailscale client labeled "<your handle>-desktop").
4. After the session, `sudo tailscale down`.

The desktop is _not_ on the friend trust plane outside of those active
windows. The headscale ACL limits `tag:friend` to a small list of
ports on the desktop (e.g., the common game-hosting port ranges) so
even _during_ a session a misbehaving friend client cannot poke
arbitrary services.

If you'd rather avoid client-on-desktop entirely, the relay-VM
alternative (a small vDMZ microVM that DNATs one port to the desktop
when armed) is also available. For _occasional, ad-hoc_ sessions the
on-demand client approach has less standing infra and seems like the
right tradeoff.

#### Future: web services for friends

The zero-inbound design intentionally does **not** offer browser-based
services (Jellyfin, future media library, server status pages, mod
downloads) to friends from outside the homelab — there is no public
HTTPS endpoint. This is an explicit tradeoff. When and if you decide
you want to offer such services, three options exist, in order of how
much they erode the zero-inbound property:

1. **Friends use the tailnet for web too.** Bind Jellyfin (and
   anything similar) to the homelab subnet router's advertised
   tailnet route, expose it via the headscale ACL, and friends reach
   it at its MagicDNS name (`jellyfin.tail.internal` or similar)
   once their Tailscale client is up. Pros: zero-inbound preserved;
   the same auth path protects everything. Cons: friends have to
   start the Tailscale client to watch a movie.
2. **A separate VPS reverse-proxy path, only for web.** A second
   nginx vhost on the cloud VPS proxies HTTPS to the homelab via a
   small outbound-initiated tunnel (like the original design in this
   report's earlier drafts). The friend WG path stays zero-inbound;
   only the web path gets the inbound exposure. Friends authenticate
   via Keycloak through oauth2-proxy. This is the right shape if web
   services become a regular thing and the "start the Tailscale
   client first" friction is too high.
3. **Don't offer web services to friends at all.** They can use them
   when they're on the LAN, and not otherwise. Strictest answer.

Default: option 1, with option 2 as a "if it becomes annoying" upgrade
path. There is no need to decide now — the friend WG plane and the
web-services plane are independent designs and can be built (or not)
in either order.

For the AI-War-II / direct-IP precedent: that's a _game_ connection,
not a web one, and works fine over the friend WG plane without any
web-services path.

#### Retro / broadcast games

Skipped as a primary capability. If a future session genuinely needs
broadcast (real LAN-discovery game, not "Steam P2P is broken so connect
by IP" — that case works fine over the tailnet), the lightest fallback is:

1. Spin up an ad-hoc ZeroTier microVM with `ztncui` for that one
   evening.
2. Send friends the network ID. They install the ZeroTier client once
   and join.
3. Tear it down after.

This is hours of work to set up the first time and minutes thereafter.
The cost of _not_ having it standing is that the broadcast capability
isn't immediately available — but you confirmed that's acceptable for
how rare the case is.

For the AI War II precedent specifically: the failure mode there was
Steam networking, not LAN broadcast. AI War II supports direct-IP
connection, which works fine over any L3 overlay. The tailnet handles
that case without any L2 layer.

---

### Alternative recommendation (no cloud VPS): innernet + email invites + same web/desktop story

**Why innernet over Headscale here:** Headscale (like NetBird and any
Tailscale-shaped product) wants an HTTPS-reachable control plane.
Under the WAN-only-WG constraint with no cloud VPS, that path doesn't
exist anywhere reachable to friends. Pre-authkeys remove the OIDC
dependency but still need the headscale gRPC/HTTPS endpoint to be
reachable for the initial registration handshake; without a VPS to
host that endpoint, the only options become awkward (require friends
to be on a specific network for first bootstrap, or stand up an
HTTPS endpoint on the residential WAN, both of which violate the
spirit of the no-VPS path).

innernet is designed differently: **its coordinator is reached over
WireGuard, not in addition to it.** Bootstrap is a one-time invite
string (a few-line text snippet); after that, all coordinator API
traffic flows inside the mesh. The only public-internet listener on
the homelab is one WireGuard UDP port — exactly what you said is
acceptable.

#### Architecture

```
Internet
   │
   │ WireGuard UDP (one port, residential WAN)
   ▼
┌────────────────────────────────────────┐
│  innernet WireGuard listener (vDMZ)    │
│  • innernet-server (coordinator)       │
│  • Reachable only over WG once in      │
└──────────┬─────────────────────────────┘
           │
           ▼
   Game server VMs, desktop relay, etc.
```

#### Friend onboarding UX

This is where the alternative pays its costs.

1. You generate an innernet invite from an admin command.
2. You email the friend the invite string and a link to download the
   innernet client (no app store presence — direct download / package
   manager).
3. They paste the invite into the client (CLI or, on platforms where
   it exists, a small GUI wrapper).
4. They're connected.

Steps 3–4 are noticeably more friction than the Tailscale app's
"install app, paste pre-authkey". For a non-technical friend group
this is a real downgrade. It's the honest tradeoff for not running a
cloud VPS.

#### What's the same

- Compromise blast radius is comparable (innernet has CIDR-based group
  associations; you create a `gamers` CIDR with no route to admin
  resources).
- Email enrollment shape is identical, just minting innernet invites
  instead of headscale pre-authkeys.
- Desktop hosting is the same on-demand-client pattern.
- Retro broadcast handling is the same (spin up ad-hoc ZeroTier when
  needed).

#### What's worse

- Mobile clients are essentially absent. Friends on phones are
  effectively excluded. This may be a dealbreaker depending on what
  fraction of your friends play from PC vs. phone.
- No native OIDC. You don't get "log in with the same account that
  reaches the web services". Friends end up with two pieces of state:
  a Keycloak account for web (oauth2-proxy still gates browser
  services), and an innernet membership for game traffic.
- Web services _can't be reached the same way_. Without the cloud VPS,
  there is no public HTTPS path. Friends would have to be on the
  innernet mesh to reach Jellyfin, etc. — which means starting the
  innernet client even just to browse, which defeats one of the things
  the proxy approach was good for.

#### What's better

- **Zero cloud dependency.** Nothing outside your house has to keep
  running for friends to connect. No bills, no third party that can
  rate-limit you, no VPS provider account to maintain, no DNS setup
  outside your existing zone.
- **One UDP port is the entire externally reachable surface.** Easiest
  possible thing to monitor and harden.
- **Smallest substitution risk in the report.** innernet is small,
  focused, MIT-licensed, and would survive being forked by one person
  in a weekend if it ever needed to be.

---

### Side-by-side summary

|                             | Primary (Headscale + cloud VPS)                   | Alternative (innernet, no VPS)                        |
| --------------------------- | ------------------------------------------------- | ----------------------------------------------------- |
| Friend UX                   | ★★★★★ (install Tailscale, paste pre-authkey once) | ★★★ (paste invite into CLI/GUI; no real mobile story) |
| Cloud dependency            | ~$5/mo VPS, control plane only                    | None                                                  |
| Inbound on WAN              | One WireGuard UDP port                            | One WireGuard UDP port                                |
| Inbound from VPS to homelab | **Zero**                                          | n/a (no VPS)                                          |
| Web services for friends    | Deferred decision (3 options, all viable)         | Either nothing, or "start the mesh client first"      |
| Mobile (iOS/Android)        | Full support (upstream Tailscale apps)            | Practically none                                      |
| Auth model                  | headscale pre-authkeys + node key expiry          | innernet invite + peer key expiry                     |
| Substitution risk           | Very low (headscale BSD-3, Tailscale BSD-3)       | Very low (innernet MIT, tiny)                         |
| Operational complexity      | Two services to maintain (VPS + subnet router)    | One service to maintain                               |
| Compromise blast radius     | Strong (tag → ACL → port-level)                   | Strong (group → CIDR association)                     |
| Retro broadcast             | Ad-hoc ZeroTier when needed                       | Ad-hoc ZeroTier when needed (same)                    |
| Desktop hosting             | On-demand client                                  | On-demand client                                      |
| Enrollment                  | Email pre-authkey (no bot, no Keycloak needed)    | Email innernet invite                                 |

**My pick: the primary path** (Headscale + cloud VPS), because the
friend UX gap is large enough to be the difference between "friends
actually use it" and "friends don't bother", and you've already said
you're willing to commit to the VPS. The alternative is not worse on
security or independence — in fact it's slightly better on both — but
the UX hit is significant and the loss of mobile support would exclude
a real fraction of friends.

If the substitution-risk axis ever rises (the project's value
proposition shifts, or headscale does a Firezone-style pivot), the
alternative path is a few days of work to switch to.

---

### Bootstrap option (considered and rejected): SaaS free tiers

Earlier drafts of this report proposed using either Tailscale's or
NetBird Cloud's hosted free tier as a stepping-stone — get friends
playing within a week, migrate to self-hosted later. **Both are ruled
out by user-count limits**:

- **Tailscale free** caps at **3 users**. The friend group is larger.
- **NetBird Cloud free** caps at **5 users**. The friend group is
  larger than that too.

Either could be unlocked by paying ($6/user/month for Tailscale's
Personal Pro / Starter tiers; $5/user/month for NetBird Team), but
paying for SaaS for what is otherwise a self-hostable service
contradicts the project's substitution-risk goal — and at that point
you're paying every month for something the self-hosted plan does
once for $5/mo of VPS.

There is no SaaS bootstrap path that fits the friend group size _and_
preserves the no-lock-in goal. Skip directly to the self-hosted
primary plan.

#### Migration path summary

```
Day 1:  Self-hosted Headscale on cloud VPS (primary plan)
                              │
                              │ if cloud VPS becomes unwanted
                              ▼
Day N:  innernet (alternative plan), no VPS
```

The two paths share the friend-side enrollment shape (email + paste),
the host firewall layer, and the router zone rules. Switching between
them is "swap the transport" not "redesign the friend trust model".

---

## Things explicitly NOT recommended

- **Putting the desktop on the friend mesh permanently.** On-demand
  client only.
- **Cloudflare Tunnel or any similar SaaS-bound tunnel.** Worst
  substitution story in the space.
- **Self-service web signup for Keycloak accounts.** Allowlisted
  enrollment only.
- **A standing enrollment bot of any kind.** Email + pre-authkeys
  (headscale) or email + invites (innernet) is sufficient at
  friend-group scale. Reconsider only if scale grows past where manual
  email becomes annoying.
- **Letting Discord be the credential** (or part of one). If Discord
  is in the picture at all, it is for _out-of-band conversation_, not
  for delivering or holding credentials.
- **A second WireGuard mesh in the wg-ba style for non-technical
  friends.** It didn't scale to one technical friend cleanly. wg-ba can
  stay as-is for that one friend; it should not be the answer for
  anyone else.
- **Standing ZeroTier deployment.** Spin it up ad-hoc when a real
  broadcast game session is planned, tear it down after.

---

## Resolved decisions and remaining context

Resolved during the report:

- **MFA on friend accounts:** Friends authenticate via headscale
  pre-authkeys (not OIDC), so MFA-at-auth doesn't apply. Long-lived
  node identities are acceptable because the `tag:friend` ACL
  containment is the primary defense for that population. Admins
  remain on Keycloak with MFA required.
- **Geographic distribution:** NA, coast to coast. East coast (you),
  west coast, central. A single self-hosted DERP relay anywhere in NA
  will be ~70ms+ for the far end on a fallback path; most friend
  traffic should still flow direct after STUN-assisted NAT traversal,
  with DERP only as a fallback. The cloud VPS should be in a central
  region (somewhere like us-central1 / Dallas / Chicago) rather than
  co-located with any one friend.
- **`wg-ba` retention:** Stays as-is for the one technical friend.
  Don't fold it into the friend-access design; the trust models and
  user populations don't overlap.

Items deferred to a future implementation plan:

- **Cloud VPS shape (if self-hosting):** Its own `nixosConfiguration`
  deployable via `nixos-anywhere`, hardened sshd (or no public sshd at
  all — SSH only over an admin WG tunnel from the homelab), running
  headscale + embedded DERP + STUN. The VPS holds no homelab
  credentials and has no inbound path to the homelab. Worth its own
  short plan; the existing `wip/headscale-integration-plan.md` is
  ~80% applicable as the starting point.
- **Homelab subnet router microVM:** vDMZ placement, runs tailscaled
  pointed at the headscale URL on the cloud VPS, listens on the
  residential WAN port for friend WG traffic (forwarded by the router
  via a single port-forward rule), dials VPS outbound for control
  plane, enforces per-resource host firewall in addition to
  headscale's ACL.
- **Email enrollment tool:** A small admin command (or systemd
  service) that shells out to `headscale preauthkeys create` (or hits
  the gRPC API), formats an enrollment email (Tailscale download link
  - headscale login URL + pre-authkey), and sends it via your
    existing SMTP path. ~50 lines of code total.
- **Web services for friends:** Deferred entirely. Pick from the three
  options listed in the primary recommendation when (and if) you
  decide to offer them.
