# 2026-08-18 — Emerald spawns too: the Crystal spawn ADR extends to Emerald, and call-vs-imitate is answered

<!-- ADR 0034. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** The Pokémon Emerald adapter renders a peer by **spawning a real object event**, the
  way Crystal does, replacing today's `gui.drawPixel` overlay fed by a hand-rolled decode of the
  Brendan/May sprite out of ROM. This extends the 2026-08-17 Crystal spawn ADR above, whose scope
  line reads *"Scoped to vanilla Crystal V1.0 only"* — that scope is now vanilla Crystal V1.0 **and
  Emerald**, on the terms below. Everything that ADR holds absolute (never write a save, the core
  never touches the game, no gameplay authority) is unchanged and restated by reference, not
  relaxed.
- **Status:** Requested by the user 2026-08-18 — *"lets fix up emerald so spawns instead of draw"*.
  The read-only evidence step (`adapters/emulator/pokemon/emerald/probes/object_slot_probe.lua`) ran the same day.
  **Shipped the same day**: `meshghost_emerald.lua` spawns on a vanilla ROM and the user confirmed
  it piece by piece on screen — appears, follows, walks, runs, stays on-grid, leaks nothing. The
  end-to-end pass is still queued (`unverified.md`).
- **Why the mechanism transfers cleanly.** Emerald's structures are the same *shape* as Crystal's —
  two cross-linked arrays, one owning identity and one owning drawing — which is why the recipe
  carries over rather than needing rediscovery. Read from our own `make compare`-verified
  `pokeemerald` build, and confirmed live by the probe the same day:
  - `gObjectEvents` — 16 (`OBJECT_EVENTS_COUNT`) entries of `0x24` bytes at `0x02037350`.
  - `gSprites` — 64 (`MAX_SPRITES`) entries of `0x44` bytes at `0x02020630`.
  - **The cross-link is `objectEvent.spriteId` <-> `sprite.data[0]`** (`sObjEventId`), which the
    live dump shows holding exactly the owning object's index for every active slot.
  - **A live NPC and the player differ in their sprite callback** — `0x0808FD8D` for ordinary map
    NPCs, `0x0808A999` for the player — the same "the player's record is driven by the input
    system" distinction that made Crystal copy an NPC rather than the player.
  - **Budget is not the constraint Emerald's own Union Room investigation feared** (`ideas.md`,
    which noted 8 Union Room leaders would claim half the array): a real indoor map measured
    **4 of 16 object events and 8 of 64 sprites in use**. Outdoor figures still to be measured.
- **The call-vs-imitate question, which that ADR required be asked first and answered: BizHawk
  cannot call a GBA routine, so imitation is the path — and this now rests on a stated capability
  limit rather than on nobody having asked.** BizHawk 2.11's Lua API exposes `emu.getregister` /
  `emu.setregister` and execute *hooks* (`event.onmemoryexecute`), and **no primitive that invokes
  code in the emulated machine**. The only thing register writes would buy is hand-driving PC/LR
  mid-frame, which hijacks whatever the CPU was already doing — not a call mechanism, a stunt with
  a corrupted frame as its failure mode. So Emerald imitates `TrySetupObjectEventSprite`'s effects,
  as Crystal imitates `CopyMapObjectToObjectStruct`'s. This closes the open question the Crystal
  ADR left standing, for **both** BizHawk adapters.
- **The Archipelago condition is stronger here than for Crystal, and that is deliberate.** Crystal's
  patch rearranges WRAM non-uniformly; that adapter was originally to refuse on an unrecognised
  ROM, and since 2026-08-18 warns and attempts instead (see the amendment on the Crystal ADR).
  **Emerald's condition was not relaxed** — the spawn path still declines to write on a ROM whose
  layout is unmeasured and keeps the overlay there.
  Emerald's relocation is a **single verified constant shift** (`0x284` for
  `gObjectEvents`/`gPlayerAvatar`, established live 2026-08-14), and the shipped adapter already
  detects which of the two applies by finding the player's own object event rather than trusting
  either address. The same rule still governs: **positively identify the ROM before writing, and
  refuse to spawn otherwise.** Detection is retried every frame rather than latched once — the
  timing bug already found live on the read path (a script loaded during the intro latching onto
  the vanilla offset forever) would be far worse on a write path.
- **Was open, DECIDED 2026-08-18:** whether the existing overlay renderer stays as a fallback
  (unrecognised ROM, no free slot) or is removed once spawning works. **Both paths stay for now** —
  the adapter spawns on a vanilla ROM and falls back to the overlay on an Archipelago-patched one
  (`avatarAddrOffset ~= 0`). Keeping both is exactly the shape of a compensation, so it went in
  where this bullet said it must: registered in
  `adapters/emulator/pokemon/emerald/BANDAGES.md` ("Two render paths at once"), with its own
  retirement condition — verifying `gSprites` for *writing* on a patched ROM — rather than left as
  a leftover.
- **Consequences, accepted going in:** the same three the Crystal ADR lists — per-map object state
  means re-spawning on every map load, a writer can race another tool's writes where two readers
  never could, and slot exhaustion needs a defined behaviour. Emerald adds one of its own:
  `RemoveObjectEventsOutsideView` culls any non-player object whose current *and* initial
  coordinates both leave a window around the player, so a ghost is culled by the engine when the
  peer walks off-screen and has to be re-spawned when they come back — which is closer to correct
  than it sounds, since an off-screen ghost has nothing to draw.

---

- **Date:** 2026-08-19
- **Decision:** TLS over the `tcp` transport, as a three-way `off` / `auto` / `required` switch
  on both the relay and the client, defaulting to `auto` in the flags and in a release's
  `config.json` alike (the `off` default was retired 2026-08-19 -- see below).
- **Status:** accepted
- **Context:** `quic` has been encrypted since it existed and is the shipped default session
  transport, but **every client handshakes over `tcp` first and that handshake carries the room
  code** (`core.queryTransports`, and `docs/security.md`'s "How a client actually connects"). So
  a session that ends up on quic still handed its room code to anyone watching the network, on
  the discovery leg, before quic was ever reached. Naming `tcp` explicitly was worse again — the
  whole session was plaintext NDJSON. The room code is the thing worth protecting: it is the
  only secret in the protocol, and `relay.Server` enforces it entirely on its own side, so
  reading it off the wire is enough to join any room on that relay.
  Scoped in `agent_docs/ideas.md`'s transport-security entry, which reached a full design on
  2026-08-16 and deliberately left it unscheduled.
- **Options considered:**
  - **Nothing; rely on quic.** Rejected by the discovery leg above — it is not optional and it
    is not quic.
  - **A separate TLS port**, the way quic has its own. Rejected: hosting is where people give
    up, and this project already spent a decision (`quicSharesAddrPort`) on keeping port
    forwarding to one number. A second tcp port would undo that for a security feature nobody
    would then enable.
  - **TLS channel binding (`tls-exporter`, RFC 9266) replacing the room code on the wire**, the
    shape `ideas.md` designed. Still the right eventual answer for *authentication*, and
    deliberately not built here: it is a protocol change (two new optional `protocol` fields and
    a second room-code comparison path), and that plan's own risk note says getting the split
    wrong creates a downgrade hole where none exists today. This ADR is confidentiality only,
    with no protocol change at all — `protocol.Version` stays at 1 and no message gained a
    field.
  - **On by default.** Rejected, and this is the one worth stating: plaintext is how a session
    gets debugged here — netcat against the relay, a packet capture between two binaries,
    `cmd/meshghost-netsim`. Encrypting by default would take the project's cheapest diagnostic
    away from every developer in order to protect a dev-loopback room code that is not secret.
    The built-in default is `off`; a release turns it on in `config.json`, which is the same
    lever `transport` already uses.
  - **`required` as the release default**, which is what `ideas.md`'s plan proposed. Rejected in
    favour of `auto` on both sides, for a reason specific to how this project is distributed: a
    release is a zip a host and their friends copy around at different times, so `required` on
    either side hard-fails against anyone still on an older copy. `auto` on both sides gives a
    matched pair of current releases an encrypted session **always** — the relay serves TLS, the
    client uses it, and the no-downgrade rule below then forbids falling back — while a mismatched
    pair still connects. `required` is documented in `packaging/release/README.txt` as the
    stricter setting for someone who wants the guarantee over the compatibility.
- **Resolution:**
  - A new leaf package `netx/tlsx` holds the mode, the self-signed certificate, the sniffing
    listener and the client wrap. `netx` gains `ListenWithTLS`/`DialWithTLS` beside
    `Listen`/`Dial`. Nothing in `relay`, `transport`, `protocol` or `core`'s message handling
    changed: `relay.Serve` takes any `net.Listener` and `handleConn` any `net.Conn`, which is
    exactly the property that made this a seam-level change rather than a rewrite.
  - **One port serves both, and this is the compatibility story.** A TLS ClientHello starts with
    the byte `0x16`; an NDJSON line starts with `{`. The listener reads exactly one byte and
    decides, so a relay in `auto` serves encrypted clients and plaintext ones — including netcat
    and every client built before this existed — on the same port, with no new configuration and
    no second port to forward. That sniff happens on the connection's own goroutine, never
    inside `Accept`: done in `Accept`, one client that connects and then says nothing would
    stall every other client for the whole handshake timeout.
  - **Certificates: self-signed, generated in memory, never written to disk.** The same choice
    `netx/quicconn` already made, for the same reason — nothing verifies it by default, so a key
    file next to the exe would buy zero security while putting a private key inside a zip people
    re-share. **This is encryption without authentication**: it stops passive capture, and it
    does not stop an active man-in-the-middle, who presents their own self-signed certificate
    and is accepted. Exactly what `quic` has offered since 2026-08-16 — no more is claimed for
    tcp than quic already gets. There is no CA story and none is planned.
  - **Authentication is opt-in, via a fingerprint a human compares.** The relay prints its
    certificate's SHA-256 at startup; a player who was given it out of band puts it in
    `"tls_fingerprint"`, and a relay presenting anything else is refused instead of trusted.
    This is the only thing in the design that authenticates a relay, it works only if someone
    actually compares the string, and the certificate is regenerated on every relay restart so
    the pin has to be re-copied then. All three of those are stated in the relay's own startup
    log, not only here.
  - **No silent downgrade, by three separate mechanisms.** (1) `required` never sends a byte of
    application data to a relay it could not handshake with — the first MeshGhost security
    setting a stale peer cannot disable from the other end, which room-code auth explicitly
    cannot claim (`docs/security.md`, "A new risk this creates"). (2) `auto`'s fallback to
    plaintext exists only for relays that predate this feature, and it logs a warning naming the
    downgrade in those words. (3) Once the *discovery* leg to a relay has completed over TLS,
    `auto` is raised to `required` for that connection attempt's session leg — the relay has
    just proven it speaks TLS, so a plaintext session to the same relay could only be
    interference.
  - `udp` is untouched and untouchable (Go's standard library has no DTLS). `udp` plus
    `required` is a refusal rather than a silently plaintext session. `quic` satisfies
    `required` by construction and is not double-wrapped.
- **Consequences:**
  - **A packet capture between two real binaries goes opaque once it is on.** That is the point,
    and it is also a real loss; `tls: off` is the way back, and `auto` keeps netcat working
    against the relay regardless.
  - **Roughly 25 bytes of TLS record overhead per message** — about 10-15% on 150-250 byte
    packets, ~1.8 MB/hour per direction at 20Hz. Post-handshake CPU is immeasurable at this
    traffic volume.
  - **A new way for a version mismatch to break a session.** A `required` client hard-fails
    against an old relay instead of limping along. Intended, and still a new support case.
  - **Handshake CPU is now something an unauthenticated stranger can ask for.** Bounded by a
    per-connection handshake timeout. A real per-IP cap remains unbuilt and needs its own
    decision, since it would need `conn.RemoteAddr()`, which `docs/security.md` currently
    asserts is never called anywhere as a privacy property (`ideas.md` records this).
  - **The antivirus risk `ideas.md` flagged is now real rather than hypothetical**: certificate
    generation plus encrypted outbound traffic are two classic heuristic triggers, on binaries
    that already draw false positives. Mitigated by the default being `off` — nothing generates
    a certificate unless someone turns it on — and by the SignPath code-signing work that entry
    sequences ahead of it, still unstarted.
