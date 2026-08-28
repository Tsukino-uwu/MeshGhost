# Risks and assumptions

<!-- line-cap: none -- risk register; entries close in place rather than being deleted. Why: agent_docs/claude-md-cap.md. -->

## Current assumptions

- The core/adapter/relay split, with an out-of-process Go core, is the right long-term
  architecture (see `agent_docs/architecture.md` ADR on the Go decision).
- A replayable JSON snapshot schema is sufficient for the first two target games.
- **Closed 2026-08-11 (Phase 1):** Pokémon Emerald can expose local player position, area, and
  basic animation state from BizHawk — confirmed via dozens of live-tested entries in
  `agent_docs/verified.md` (position, map bank/number, facing, running/dash state, and more).
- **Closed 2026-08-11 (Phase 2), but corrected, not simply confirmed:** Lua overlay rendering
  (`gui.drawImage`) is the fastest practical approach for Emerald ghost drawing. The
  no-flicker half of this assumption was **wrong as originally stated** — BizHawk's `gui.*`
  overlay does NOT auto-clear between frames (found live; see `agent_docs/plans.md`'s Phase 2
  entry and
  `agent_docs/pitfalls.md`'s overlay-rendering entry), contradicting `contract.md`'s original
  tick-model assumption. The actual fix (unconditionally clear the overlay at the top of every
  frame) is what's now implemented and confirmed live, not the original assumption itself.
- **Closed 2026-08-12 (Phase 6 start):** TEVI's engine tooling assumption is confirmed, not
  analogized. TEVI is Mono, not IL2CPP — `TEVI_Data\Managed\Assembly-CSharp.dll` present, no
  `GameAssembly.dll` anywhere in the install, `doorstop_config.ini` has a `[UnityMono]` section.
  Re-confirmed against the current on-disk build (`TEVI.exe` 2026-07-16) after updating, not just
  the original April-2025 check. BepInEx/Harmony tooling applies directly; see
  `agent_docs/environment.md`'s Unity/TEVI section and `agent_docs/licensing.md`.
- **Closed 2026-08-11 (Phase 5.5):** every Emerald finding through Phase 2 had only been tested
  on a male save. Re-verified live on a real female-character save (`gSaveBlock1Ptr`,
  `gPlayerAvatar`, `gObjectEvents`, `gSprites`, `gSpriteCoordOffsetX/Y` all confirmed correct —
  see `agent_docs/verified.md`'s Phase 5.5 Step 4 entry) — no longer an open risk. Running
  specifically wasn't exercised on that save (no Running Shoes yet, a save-progression limit,
  not an address concern).
- **Closed 2026-08-11 (Phase 5.5):** player appearance (gender) is now in the schema, as
  `extras.gender`, read from `gSaveBlock2Ptr->playerGender` and confirmed live rendering the
  correct Brendan/May sprite for a remote on both a male-save and a female-save client. See
  `agent_docs/phases/phase5_5.md` and `agent_docs/verified.md`.

- **Emerald's ferry is built and has never been watched; rails are not built at all** (moved here
  from `status.md` 2026-08-25; restated 2026-08-27). The user dropped them from the open list on
  purpose — they are not work anybody is scheduled to do — but an untested assumption that lives
  nowhere decays into a fact, which is what this register exists to prevent. What watching it would
  settle: `adapters/emulator/pokemon/emerald/UNVERIFIED.md`. **This entry said "assumed to work" and
  "Emerald is parked (2026-08-21)" until 2026-08-27** — both were overtaken by the 2026-08-26 Emerald
  session, which is precisely how an entry in a risk register decays: nothing re-reads it.
- **A loopback rig's ghost offset can place a peer inside or above geometry the game would never
  put a player in** (moved here from `status.md` 2026-08-25). Not a defect: the rig offsets a
  ghost a couple of tiles sideways from the local player, and a real peer's position is always
  somewhere that peer could legitimately stand. It is recorded because it changes how evidence is
  read — an artefact seen ONLY under loopback offset is the rig's, and `adapters/CLAUDE.md` says
  to say so plainly rather than build a rule around it. Pseudoregalia's sloped geometry is where
  it showed up; `verified.md` has the sighting.

## Known risks

- **A maximal `event`, and a committed `escrow_state`, are silently undeliverable to any udp peer
  — pre-existing, found 2026-08-17 while sizing the world plane, and NOT fixed.** Measured:
  a maximal `Event` (payload 1024 + `to` 128 + `corr_id` 64 + scaffolding) renders to **1441
  bytes**, and a committed `EscrowState` carrying two 1024-byte blobs to **3302**, against
  `udpconn.MaxDatagramBytes` (1200) minus 18 bytes of framing = **1182 usable**. Both fail
  `udpconn.checkWritable` — *including on the reliable plane* — and the refusal surfaces only as a
  `relay: send to pX failed:` line, so the message is lost for that recipient and never superseded.
  `MaxEventBytes`' own doc comment used to claim it was sized to keep an event "comfortably under"
  the datagram limit; it was sized against the payload alone, not the envelope. **That comment was
  corrected 2026-08-18** and now states the real relationship, with
  `netx/udpconn/world_bounds_test.go`'s `TestMaximalEventDoesNotFitAUDPDatagram` and
  `TestMaximalCommittedEscrowDoesNotFitAUDPDatagram` pinning it in both directions — so the
  documentation half of this risk is closed; the constants themselves are unchanged and the risk
  below still stands. Reachable only by a
  client that actually uses the full ceiling, which nothing does yet — no adapter uses these planes
  at all — which is why this is recorded rather than hot-fixed: **shrinking those constants is a
  contract change with its own trade-offs and should be its own decision**, weighed against the
  alternative of making the bound transport-dependent (`beyond-cosmetic.md` §9 lays out that
  choice). The assertion tests were retrofitted onto events and escrow on 2026-08-18
  (`netx/udpconn/world_bounds_test.go`), so the gap can no longer widen unnoticed;
  `MaxWorldBlobBytes` was derived this way from the start and does fit.
- **A lossy world write over quic is bounded by the path MTU, not by our own constants.** quic's
  `SendUnreliable` is a real datagram path (RFC 9221) and quic-go refuses a datagram larger than the
  connection's *current* path MTU rather than fragmenting it — a dynamic value that can sit below
  `udpconn.MaxDatagramBytes` (1200), which is what `MaxWorldBlobBytes` was derived against. **quic is
  the default transport**, and the refusal reaches the adapter only as a logged error, so an
  undersized path would make lossy world writes quietly stop working while reliable ones (which ride
  the stream and have no such limit) kept going. A maximal world message round-trips as a quic
  datagram today (`netx/quicconn`'s `TestMaximalWorldStateFitsAQuicDatagram`, 2026-08-17) —
  on loopback, which is the generous case. Not closed: an undersized real-world path has never been
  tested, and per CLAUDE.md a clean light test does not close a risk that depends on the real
  environment.
- Changing the adapter contract after Phase 5 may create compatibility issues across
  already-built adapters.
- The TEVI and Pseudoregalia targets may require substantially different adapter behavior
  than Emerald — the brief's own estimate is 60–70% new work for the second game, ~50% for
  the third.
- BizHawk Lua's socket support may be slower or more limited than expected for real-time
  ghost rendering once the adapter is calling out to an out-of-process Go core every frame
  (see the tick model in `contract.md` — chatty by design, cost unverified at 60fps).
- Relying on a single emulator version or toolchain may create setup drift between sessions.
- Undocumented game state or menu/camera edge cases can break ghost placement or crash the
  adapter's assumptions about `get_local_state()`'s return shape.
- **Gender read may resolve before a real save is loaded — raised by the user 2026-08-14,
  fix applied and confirmed live the same day.** `readLocalGender()` only ever runs once per
  session, the first time `getLocalState()` succeeds; that only checked `gSaveBlock1Ptr` being
  non-null, not that the player has actually finished the intro/title screen/character select.
  Every previous gender test (see the two "Closed 2026-08-11" entries above) was run with a
  save already present, so this path had never actually been exercised. If a bad read had
  occurred during the intro, it would have silently locked in the wrong gender for the rest of
  the session (no crash, no error — exactly the "plausible number instead of crashing" case
  CLAUDE.md warns about). **Fix**: the gender read is now additionally gated on `inOverworld()`
  (`adapters/emulator/pokemon/emerald/meshghost_emerald.lua`), the same gate already used before drawing
  remotes. **Confirmed live 2026-08-14**: user started BizHawk fresh with an existing female
  save, deleted it, created a new male-gender save, and watched the Lua Console directly — the
  `MeshGhost: local gender = ...` line did not print at all during the title screen/intro/
  character-creation sequence, and printed exactly once, correctly as `male`, only once actual
  gameplay began in the overworld. See `agent_docs/verified.md`.
  - **Confirms the most likely real trigger, per the user: booting BizHawk with no save,
    deleting/skipping to a fresh save, and picking a gender during character creation** — not
    the rarer "already playing, return to menu, delete and remake a save mid-session" case,
    which the user judged unlikely enough not to design around.
  - **Known, accepted limitation, not fixed**: `localGender` is cached for the rest of a Lua
    script session once resolved and never re-checked. If a player deletes and remakes a save
    as the other gender *mid-session* without reloading the script, their ghost keeps showing
    the stale gender to peers until they reload `meshghost_emerald.lua` — cosmetic only, no
    crash. Deliberately not fixed: the user judged this specific sequence (already playing →
    back to menu → delete → remake save, same session) rare enough not to be worth the
    complexity of re-checking gender on every `inOverworld()` false→true transition.
- **Licensing exposure**: `pokeemerald` carries no LICENSE file (see `agent_docs/licensing.md`)
  and SilklessCoop is restrictively licensed. Both are permitted as read-only fact sources,
  never as copied code — the risk is a future session forgetting that distinction under time
  pressure.
- **macOS distribution friction**: an unsigned Go binary will trip Gatekeeper on first run.
  Not a blocker for early phases, but worth planning for before a public release. Autostart
  (below) would make this worse there in the same way it does on Windows, whenever Mac builds land.
- **The shipped exes draw antivirus false positives, from two separate causes.** Recorded as its
  own entry 2026-08-16 — until then this was asserted as a premise inside four other entries
  (autostart, TLS, quic-go, macOS) with nowhere stating it. **(1)** Scanners that do not recognise
  Go binary structure; not ours and not specific to this project, and Go's own FAQ documents it
  (`go.dev/doc/faq`), which is why the public README cites upstream rather than reassuring in our
  own voice. **(2)** A Defender detection ending in `!ml`, meaning a machine-learning verdict
  rather than a signature match. The profile it fires on is accurate about us: unsigned, almost no
  download reputation, opens network connections, and now started by a game mod rather than a
  person. **Signing is expected to reduce this, not end it** — an ML verdict weighs reputation too,
  and a new certificate has none. Explained to users in `docs/antivirus.md` and
  `packaging/release/README.txt`; the intended fix has its own entry in `ideas.md`.
- **Autostart makes the antivirus false positives more likely, not less** (added 2026-08-16 with
  the autostart ADR). The shipped exes already draw false-positive trojan flags, and a game mod
  silently starting a hidden, unsigned executable is the literal shape of a dropper — a materially
  stronger heuristic trigger than a user double-clicking the same file. **This raises the priority
  of the SignPath OSS code-signing work**, which is mentioned once in `ideas.md` and has never been
  scheduled; it is now the mitigation for two separate things rather than a nice-to-have.
  Available today instead: `MESHGHOST_NO_AUTOSTART` skips the spawn entirely, and the manual
  "run meshghost.exe yourself" path is unchanged and still supported. Unmeasured — no antivirus
  has actually been observed reacting to the spawn yet, on this machine or a tester's.
- **No-auth relay window — closed 2026-08-14, with two real limits.** Room-code auth shipped
  (`protocol.Hello.RoomCode`, constant-time-checked against `Server.RoomCode`; empty/unset
  means auth stays off, unchanged default). See the ADR in `agent_docs/architecture.md` and
  `docs/security.md`'s "What changed" section for the full record, including the design
  options considered (a plain shared secret was chosen over an HMAC challenge-response or a
  per-room lobby code). Two things this does **not** close: (1) **no TLS** — the code crosses
  the wire in plaintext, so this raises the bar from "anyone with the address" to "anyone with
  the address and the code," not to "safe against a network-level attacker"; tracked as its own
  entry below. (2) **the new "stale relay" risk**, also below — auth is enforced entirely by
  the relay, so it only works if the relay binary is current.
- **No TLS on the relay/bridge connection — since closed for `quic` (2026-08-16) and `tcp`
  (2026-08-19); `udp` and the loopback bridge stay plaintext.** As originally written:
  `transport` is plaintext NDJSON over TCP,
  deliberately, for the "greppable with netcat" debuggability property (see
  `docs/security.md`'s "Why TCP, not UDP" section). This means room-code auth (above) doesn't
  defend against a network-level attacker who can observe the connection — they can read the
  code in transit. Not attempted as part of the 2026-08-14 hardening pass (see that ADR's
  "Options considered (auth)" for why); a real, separately-scoped piece of future work if the
  threat model ever requires it. **Scoped 2026-08-16 to a full design** — three-way
  `off`/`auto`/`required` mode, an in-memory self-signed cert with no files anywhere, and
  identity via TLS channel binding so the room code proves the relay automatically rather than
  the user copying a fingerprint. Written up with its costs in `agent_docs/ideas.md`'s
  "Relay/client — transport security (TLS)" section; **still unscheduled, and deliberately
  sequenced after the code-signing work** — cert generation plus encrypted traffic would likely
  worsen the existing antivirus false positives on the shipped exes. **Largely overtaken
  2026-08-16 by selectable transports, then by the default change the same day**: `quic` is
  encrypted (its handshake is TLS 1.3), and since the client ships `auto` and the relay
  `tcp,quic`, a default session is encrypted without anyone configuring anything — so a room
  code no longer crosses the wire in the clear by default. **The open residue is authentication,
  not confidentiality**: the certificate is unverified, so quic stops a passive eavesdropper and
  not an active man-in-the-middle. Its `tls.ConnectionState` exposes a working
  `ExportKeyingMaterial`, so the channel-binding design that would close this drops straight in.
  **TLS-over-`tcp` was built 2026-08-19** (`netx/tlsx`; `tls: off`/`auto`/`required` on both ends,
  the binaries defaulting to `off` and `packaging/release/config.json` to `auto`), so both default
  transports now encrypt and `netx/tls_test.go` asserts the room code is absent from the bytes on
  the wire. Unchanged: the certificate is still unverified (encrypted, not authenticated), and
  `udp` remains plaintext with no fix available.
- **`udp` cannot be encrypted, ever, and this is not fixable** (added 2026-08-16 with selectable
  transports). Go's standard library has no DTLS, so a client choosing `transport: "udp"` sends
  its `room_code` in the clear with no option available to change that. **The real mitigation
  since 2026-08-16 is structural, not documentary**: the client defaults to `auto` and the relay
  to `tcp,quic`, so a default pair never touches udp at all — `netx.AutoPreference` is
  QUIC/TCP/UDP and deliberately never picks udp on a user's behalf, because choosing an
  unencryptable transport for someone is not a decision a default should make. udp is reachable
  only by naming it explicitly on both ends. Anyone who needs confidentiality must not choose it.
- **`udp` adds pre-auth attack surface that `tcp` did not have** (added 2026-08-16). The
  demultiplexer in `netx/udpconn` parses bytes from any stranger who knows the address,
  *before* address validation, room code, or protocol version. Mitigations built in: a derived
  (not stored) address-validation cookie, so a flood of forged hellos costs one HMAC and zero
  memory; a hard datagram size cap; and a bounded per-connection receive queue that drops rather
  than blocking the shared read loop. Covered by `FuzzListenerSurvivesArbitraryDatagrams`, whose
  liveness check exists because a wedged listener looks exactly like "nobody is joining." **A
  per-connection token was added the same day, after the user asked whether the CelesteNet UDP
  measures were needed here**: address validation gates *admission* only, so without a token a
  connection is identified by source address alone and anyone able to spoof a live client's
  ip:port could inject state into its session. 64 unpredictable bits on every datagram clears the
  same bar TCP's 32-bit sequence number does. Practical risk before the fix was narrow (it needs
  the victim's IP from outside MeshGhost — the relay never calls `RemoteAddr` — plus source-IP
  spoofing, which most ISPs filter, and pays out in cosmetic griefing), but `docs/security.md`
  cited CelesteNet's token as the reason TCP is safer by construction, so shipping without it was
  a claim the code did not honour. **Neither defence helps against an on-path attacker**, who can
  read cookie and token straight off the wire — the same limit TCP sequence numbers have, and
  the reason `quic` exists. **Still
  open, and unchanged by any of this: there is no per-IP connection cap** — `MaxClients` (8,
  global) is only reserved after a successful hello. A real cap would need `conn.RemoteAddr()`,
  which `docs/security.md` currently asserts is never called anywhere as a privacy property, so
  it needs its own decision rather than being folded into transport work.
- **First third-party dependency, with two knock-on risks** (added 2026-08-16). `quic-go` (MIT)
  plus three `golang.org/x/*` modules (BSD-3-Clause) are now compiled into the shipped binaries.
  (1) Both licences require their notice to travel with a binary, so `THIRD-PARTY-NOTICES.txt`
  for the Go executables must be re-checked whenever the pin moves — audit it against
  `go version -m meshghost.exe`, which reports what actually linked, not against `go.mod`.
  (2) A larger binary with a real dependency may shift the antivirus false-positive baseline
  recorded above; unmeasured as of this entry. Also note `go get` raised the module's Go
  directive from 1.22 to **1.25.0**, which raises the minimum toolchain for anyone building this.
- **Stale relay silently disables room-code auth — found while scoping the 2026-08-14 pass,
  from the user asking what happens with an old client/server against new ones.** Room-code
  auth is enforced entirely by the relay (the host controls admission, not each joiner — the
  correct architecture), which means it only exists if the *relay* binary is current. A
  `room_code` in an old relay's `config.json` is an unrecognized JSON field to that binary and
  is silently ignored — no error, no warning, the relay just starts up open. A host could set a
  room code, believe their session is protected, and be completely wrong, with nothing telling
  them so. Not a client-side problem and can't be fixed client-side. See the ADR in
  `agent_docs/architecture.md`'s "Consequences" for the full reasoning. Follow-up done:
  `docs/security.md`/`packaging/README.md` both say plainly that room-code auth requires an
  updated *relay*, not just an updated client.
- **Archipelago coexistence, confirmed with a real gap**: tested 2026-08-11 with the real
  `connector_bizhawk_generic.lua` against a real `.apemerald`-patched ROM (see
  `agent_docs/verified.md`). Two scripts coexist fine, no performance difference, and
  position/map (`gSaveBlock1Ptr`-relative) reads are unaffected. But `gPlayerAvatar`/
  `gObjectEvents` (fixed EWRAM addresses) read as invalidated garbage under the patch — the
  patch's own code/data insertion shifts what's at those addresses, unlike the pointer-based
  SaveBlock1 fields. Concretely: `flags`, `runningState`, and `facingDirection` cannot be
  trusted when Archipelago is present. Planned mitigation (not yet built, deferred until after
  Phases 2–4 prove the vanilla path, since position/map already syncs correctly regardless of
  the patch and the ghost isn't blocked by this):
  - **Facing**: derive it from the delta between consecutive position reads (`dx`/`dy`,
    tile-grid, no diagonals) instead of reading `facingDirection`. Hold the last known facing
    while stationary. Make this the *only* code path (not a conditional fallback triggered by
    detecting "weird" values) — garbage-detection is itself fragile against a different patch
    returning plausible-but-wrong data, and there's no accuracy lost by not reading the raw
    field even when it would be valid.
  - **Walk/run/idle**: no good proxy identified yet. Candidate: infer from tiles-per-second
    (frames between position changes), since Emerald's walk and run speeds are different fixed
    frame-counts-per-tile — but this is an unverified hypothesis, not a known fact, and needs
    its own on-screen verification pass (vanilla first, then patched) before it can be trusted
    or written into `verified.md`, per the same "no addresses/facts from memory" standard as
    everything else in this project.
  This is also the concrete argument for keeping the read-only default (see the depth ladder
  in `plans.md`): two readers never race, but a future memory-*writing* feature could race
  Archipelago's own writes.
  - **Source-level explanation found 2026-08-14, from reading Archipelago's own
    `worlds/pokemon_emerald/` (MIT, own per-directory LICENSE, added to `licensing.md`).**
    Upgrades this from "observed symptom, cause unconfirmed" to a real mechanism, and adds
    concrete evidence for anything that might someday try writing memory instead of just
    reading it. The ROM side is genuinely heavy: a static `base_patch.bsdiff4`
    (`rom.py:98-105`) compiled from Archipelago's own decomp fork, rewriting real game logic
    (`docs/rom_changes_en.md` — dozens of changes, including **a changed save-data format**:
    "Bag space was greatly expanded... Save data format was changed as a result... Shrank some
    unused space and removed some multiplayer phrases"), plus hundreds of small per-seed
    `write_token` calls on top for randomized content. The RAM side is much lighter and more
    disciplined: the live BizHawk client (`client.py`) polls every ~0.75s, reads flags via
    `gSaveBlock1Ptr`/`gSaveBlock2Ptr`-relative offsets, and gives items by writing exactly 6
    bytes into a small dedicated mailbox struct, `gArchipelagoReceivedItem` — a *new* symbol the
    base patch injects, never touching bag/party memory directly; the patch's own injected code
    does the actual insertion. Every read/write is "guarded" against preconditions (still in
    overworld, save block pointer unchanged) — the same defensive shape Emerald's own
    `inOverworld()` gate and map-transition debounce already use independently.
    **Directly corroborates the pointer-based fields surviving**: Archipelago's own client reads
    `gMain`/`CB2_Overworld` and `gSaveBlock1Ptr`/`gSaveBlock2Ptr` every poll cycle — the exact
    same anchors this adapter already uses — so if those broke under the patch, Archipelago's
    own randomizer would break too. `gPlayerAvatar`/`gObjectEvents` are absent from Archipelago's
    own dependency set entirely, consistent with (not just similar to) the already-observed
    break.
    **New, relevant data point for the Union Room/NPC-hijack idea in `ideas.md`**: Archipelago's
    generated symbol table (`data/extracted_data.json`, `misc_rom_addresses`) includes real,
    cited addresses for `gObjectEventGraphicsInfoPointers`, `PatchObjectPalette`,
    `LoadObjectEventPalette`, and the OAM tables (`gObjectEventBaseOam_*`, `sOamTables_*`) —
    exactly the graphics/palette machinery a live NPC-reskin would depend on — so that specific
    machinery is confirmed still present, at known addresses, in at least this checked-out
    Archipelago build. **What this does *not* cover**: `rom_changes_en.md` also states "The
    union room receptionist... was reworked for wonder trading" and "Some NPCs or tiles are
    removed on the creation of a new save file based on player options" — real, cited evidence
    that Archipelago *does* rearrange which object events exist and where, which is a concrete
    risk for any design that assumes a specific map's NPC layout (a hijack target, or a
    spawn-template local id) is the same as vanilla. And Archipelago's own symbol table has
    nothing for `gObjectEventPic_BrendanNormal`/`MayNormal`/`*Running` — the fixed ROM addresses
    MeshGhost's **current, already-shipping** overlay-drawing adapter reads to decode the
    gender-correct player sprite. Their absence here doesn't prove they're broken under the
    patch, only that this hasn't been checked — a real, previously-undocumented open question
    about the *existing* shipped renderer, not just a hypothetical future one.
    **Confirmed broken, live, 2026-08-14** — no longer just an open question, and no longer just
    inferred from the rendered result. A real loopback session showed the rendered ghost as a
    solid, structured (not random-noise) purple/brown-striped block instead of a Brendan/May
    sprite; then `sprite_probe.lua` run directly against the same ROM/seed confirmed it at the
    decode level — the printed palette has 10 of its 16 entries collapsed into just two exact
    duplicate colors (a real hand-authored sprite palette wouldn't do that), matching the
    rendered pink/brown block exactly. Same mechanism already confirmed for `CB2_Overworld`
    (a fixed vanilla ROM address landing on different real bytes after the recompile, which
    moved that address by ~2.4KB, `0x995`). See `verified.md`
    for the full palette/bitmap dump. **Since closed**: the adapter's `detectSpriteAddrOffset()`
    finds the relocated sprite/palette block at runtime, and 2026-08-19 found that
    `gObjectEventGraphicsInfoPointers` moves by that same shift — after which a spawned ghost
    appeared on a patched seed (`verified.md`, 2026-08-19).
    **Concrete next step, if this is ever pursued for real**: `extracted_data.json` is a small,
    curated set (7 RAM symbols, 48 ROM symbols) — not a full symbol table — so it can't be
    diffed wholesale against `pokeemerald.sym` the way this project's own address-verification
    standard would want. Getting a real answer for any *other* specific address (like the
    Brendan/May sprite pics above) means building against Archipelago's own decomp fork to
    generate a real map/symbol file for it, the same rigor already applied to vanilla addresses
    — not assumed from this partial table.
  - **Third consequence — found, fixed, and confirmed on screen, 2026-08-14 (closed).**
    `playerScreenPos()` (`meshghost_emerald.lua`) reads a sprite index from
    `GPLAYERAVATAR_ADDR + 0x04` (the same struct confirmed garbage above) to find `gSprites[]`'s
    local-player entry, which every remote ghost's drawn position is anchored relative to. A
    loopback ghost was observed spawning at a different fixed screen location each script
    restart, jittering slightly when the local player moved but never actually following —
    confirmed to be exactly the garbage-`gPlayerAvatar` mechanism, not a network/relay/core bug
    (loopback is shared, game-agnostic code already confirmed working for the other two games,
    which ruled out that layer). The camera-scroll-instead-of-sprite-move idea in an earlier
    version of this note turned out not to apply — checked `field_camera.c`/
    `field_player_avatar.c` directly and the player's sprite goes through the same generic
    object-event placement as any NPC, no shortcut available. Found the real relocated
    addresses instead, via a four-stage live investigation (scripted snapshot-diff probe → hex
    dump matched against pokeemerald's real `struct ObjectEvent` layout → array-boundary scan →
    final live verification watching real, responsive dash/movement/facing data instead of
    frozen garbage) — full trail in `verified.md`'s "Archipelago-relocated gObjectEvents/
    gPlayerAvatar found and fixed" entry. `gObjectEvents` and `gPlayerAvatar` both shift by the
    same `0x284` delta, detected once at startup (`detectAvatarAddrOffset()`) by scanning up to
    16 entries for the player's own `isPlayer`+`LOCALID_PLAYER` signature.
    **First fix attempt failed its own live re-test**, a real, worth-remembering lesson: loading
    the fixed `meshghost_emerald.lua` and watching the ghost showed the exact same stuck-position
    symptom. Cause: `playerObjEventExistsAt()`'s `isPlayer`+`LOCALID_PLAYER` check alone had a
    false positive against the *abandoned* vanilla address's frozen `FF 03 FF 03...` garbage —
    `OBJECTEVENT_SIZE` (`0x24`) is even, so every entry lands on the same phase of that 2-byte
    repeat, and offset `+0x02`/`+0x08` both read `0xFF`, coincidentally satisfying both checks at
    once — `detectAvatarAddrOffset()` picked vanilla on a ROM already confirmed relocated. A
    narrow, single-bit-level check against a uniform repeating byte pattern is exactly the kind
    of coincidental match this project's own "no addresses from memory, verify live" discipline
    exists to catch; it took a real on-screen re-test to surface it, not code review alone.
    Fixed by also requiring `mapGroup` to be a plausible real value, bounded by `MAP_GROUPS_COUNT`
    (34, `pret/pokeemerald`'s `include/constants/map_groups.h:598` — cited, not a guessed round
    number) rather than the garbage pattern's `255`.
    **Confirmed on screen after the second fix, then re-confirmed across all three ROMs**: user
    reloaded `meshghost_emerald.lua` and watched a loopback ghost spawn and follow correctly on
    each of the two independent Archipelago-patched seeds AND the vanilla ROM — the auto-detect
    logic added for this fix doesn't regress vanilla (important, since the detector now runs
    there too and needs to correctly resolve offset 0).
    **Fourth issue found, fixed, and confirmed on screen the same day, in this same fix**:
    loading the script WHILE still in the
    intro cutscene (before the game's own object-event system has spawned the player's entry at
    all) reproduced the identical stuck-ghost symptom — confirmed live, and confirmed to be a
    timing bug specifically: reloading the script after actually reaching real gameplay fixed it
    every time. Root cause: the detector ran exactly once at script startup and, if it found
    nothing at either candidate address (nothing to find yet, this early), permanently latched
    the vanilla fallback for the rest of the session — never retrying once the player's entry
    later appeared. Same class of problem `readLocalGender()`'s own header comment already
    documents for `gSaveBlock1Ptr`/`gSaveBlock2Ptr` needing an `inOverworld()` gate. Fixed by
    making detection retry every frame (`tryDetectAvatarAddrOffset()`, called from the main
    loop) until it actually finds the player's entry, then stopping.
    **Confirmed on screen**: user reloaded the script during the intro cutscene itself (the
    exact failing case) and watched the ghost correctly follow once real gameplay started, with
    no stuck/anchored symptom — then also re-confirmed the ordinary mid-game reload case still
    works with no regression. This closes the fourth and final Archipelago rendering bug found
    via this investigation.
  - **Correction, found live 2026-08-14 (Stage 1/2 of the VRAM investigation,
    `adapters/emulator/pokemon/emerald/probes/vram_probe.lua`), to the "directly corroborates the pointer-based
    fields surviving" claim two paragraphs up: that reasoning conflated "Archipelago's own
    client also reads a `gMain.callback2`-shaped anchor" with "Archipelago's own client uses the
    *same numeric* `CB2_Overworld` value this project's vanilla-derived address (0x08085e5c)
    does." Those are different claims, and a full recompile (already established, `base_patch`
    above) makes the second one unlikely on its face — Archipelago's client almost certainly
    reads its own recompiled `CB2_Overworld` value out of *its own* generated symbol data, not
    vanilla's. Real evidence: a ~29-minute session (102,600 frames) on a real
    `.apemerald`-patched ROM, covering real varied play (44 distinct `callback2` values
    observed, so the read itself is live and changing, not stuck/erroring), never once matched
    `CB2_OVERWORLD_ADDR` or its Thumb-bit variant — `inOverworld()` returned false for the
    entire session. `gMain` itself (0x030022c4, IWRAM, a plain global struct) is a different
    address *class* than `gPlayerAvatar`/`gObjectEvents` (EWRAM) above, so this isn't just a
    repeat of the same finding — it's a new instance of the same underlying mechanism (a full
    recompile can move any fixed ROM/RAM address) hitting a third address family.
    **Resolved, 2026-08-14, same day** — see `verified.md`'s "Archipelago-recompiled
    CB2_Overworld address found" entry for the full evidentiary trail. The vanilla-only
    `inOverworld()` check WAS the bug this predicted: `meshghost_emerald.lua` gates both
    local-gender resolution and remote-ghost rendering itself (`drawRemotes(...)`) behind it, so with only the vanilla address checked, neither ever fired
    on an Archipelago-patched ROM — ghosts would never draw at all, silently, no error. Found
    the real recompiled address (`0x080867F1`) live via `battle_probe.lua`, confirmed
    independently on a second unique seed, and added it to `inOverworld()` in
    `meshghost_emerald.lua` (also `vram_probe.lua`'s `isOverworld()` and `battle_probe.lua`
    itself) alongside the vanilla one, the same pattern already used for the vanilla/Thumb-bit
    variant. **CLOSED, and this bullet's own "still open" line was already contradicted by the
    entry ~45 lines above it** — which records the user reloading `meshghost_emerald.lua` and
    watching a loopback ghost spawn and follow correctly on **both** Archipelago-patched seeds and
    the vanilla ROM. The rendering consequence is watched, not inferred. Corrected 2026-08-18.
- **No game-version check between peers, surfaced by TEVI (Phase 6) — closed 2026-08-14, with
  one real limit, and evidence the limit is the right call, not just an accepted gap.** `hello`
  now carries an optional `game_version` (`protocol.Hello.GameVersion`/`bridge.Hello.GameVersion`),
  sticky per room the same way `game_id` already is; a mismatch is refused at handshake. See the
  ADR in `agent_docs/architecture.md`. **The limit**: each shipped adapter reports its own
  adapter/mod version (e.g. Emerald's `"phase5.5"`, TEVI's BepInEx `PluginVersion`), not the
  actual game/DLC build — there's no cited memory address to read a real game version from in
  any of the four shipped adapters' games, and `CLAUDE.md`'s rule against guessing addresses from memory means
  one wasn't invented for this. So this catches two peers on different *adapter* revisions, not
  a real game-version/DLC mismatch.
  - **User feedback, 2026-08-14, real usage evidence**: TEVI has actually been played across
    different game builds/versions successfully — interoperates fine as long as the map/world
    itself hasn't changed, contradicting the original Phase 6 worry that any version difference
    would cause silent desync. DLC compatibility specifically is still untested either
    direction (the user doesn't own the DLC; the older build predates it existing at all).
  - **This changes the right design for any future real-version check, not just this session's
    scope**: the earlier "wiring in TEVI's actual build/DLC state as `game_version` would be a
    natural, low-risk follow-up" framing was wrong given this evidence — a **hard reject on any
    version difference would incorrectly block a combination already known to work**. If a real
    game-version read is ever added, it should not reuse this field's current hard-reject
    behavior as-is; a softer signal (e.g. a warning surfaced to the user, not a connection
    refusal) or a narrower check (DLC presence/absence specifically, since that's the one
    axis actually untested) would better match what's actually been observed. Not designed —
    just recording the constraint so a future session doesn't rebuild the wrong version check.
- **BepInEx/Harmony coexistence with an already-installed mod, surfaced by TEVI (Phase 6)**: this
  machine's TEVI already runs `Tevi_Randomizer` (the Archipelago integration mod) under the same
  BepInEx. Same shape as the Emerald/Archipelago coexistence risk above: if the randomizer
  Harmony-patches the same methods MeshGhost's adapter wants to read, the two could conflict.
  Mitigation planned the same way — confirm the position read works both with the randomizer
  enabled and disabled, prefer reads that survive patching, record which was tested in
  `verified.md`.
- **Code with no consumer, deliberately accepted 2026-08-17**: this entry used to say the
  `features` field and the `event` message type would be "documented now and implemented never,
  until something needs them", with a procedural mitigation of not building the event plane until
  a Tier 3 feature was approved and a concrete adapter was ready. **That mitigation was overridden
  by an explicit decision to build the whole dumb-relay set ahead of any consumer** (ADR in
  `architecture.md`), so the risk it named is now real rather than avoided, and is recorded here
  honestly instead of being quietly deleted.

  What is actually at risk, and what is not:

  - **Not the verification standard.** The standard is "was the expected thing seen happening on
    screen" *for an adapter*, because a wrong memory address returns a plausible number instead of
    crashing. None of this touches a game: it is `relay`, `core` and
    `protocol`, which CLAUDE.md puts on the opposite footing — confirm with the tools,
    don't ask the user to watch. That was done (invariant tests over racing clients, three fuzz
    targets, the suite at `-count=10`, `internal/e2e` green), and it immediately caught a real
    ordering defect. So this is unproven *in a game*, not unproven.
  - **Genuinely at risk: the shape being wrong for the first adapter that wants it.** An API with
    no user is an API nobody has disagreed with yet. The likeliest places to find that out are the
    ones where a judgement call was made with nothing concrete to check it against — `MaxEventBytes`
    being uniform rather than transport-dependent, the 20s resume grace, the 60s escrow
    timeout/retention, and whether an adapter really wants its own event echoed back.
  - **Also at risk: bit rot.** Seven capabilities and four message types that nothing exercises
    outside their own tests will drift as the rest of the codebase moves. The mitigation is that
    they are all opt-in and inert by default, so drift degrades a feature nobody is using rather
    than the cosmetic path everybody is.

  **The rule that has NOT changed:** these are transport-level primitives, not permission. Anything
  past Tier 2 on `plans.md`'s depth ladder still needs writing game memory, still needs its own
  per-game ADR, and still passes through the memory-write gate. Reading "escrow exists" as "trading
  is approved" is exactly the misreading `beyond-cosmetic.md` §11 warns about.

- **Blueprint-vs-C++ readability, surfaced at Phase 7 start**: Pseudoregalia is largely
  Blueprint-driven (per `adapters/pseudoregalia/README.md`'s brief note and no `.pdb`/managed
  assembly equivalent to decompile the way TEVI's `Assembly-CSharp.dll` was). Player state may
  only be reachable by reflection/property-name lookup through UE4SS rather than a fixed,
  named field the way `pokeemerald`'s C structs or TEVI's decompiled C# fields were. Highest
  single source of uncertainty in Phase 7; the 7.1 Lua probe exists specifically to resolve
  this empirically before committing to the C++ adapter's design.
  **Resolved** — reflection through UE4SS turned out to be enough, the C++ adapter shipped on it,
  and 7.7 closed 2026-08-16 with two players on two machines. `agent_docs/access-models.md`
  records runtime reflection as this adapter's access model.
- **No clip-name animation playback in UE5, surfaced at Phase 7 start**: TEVI's remote ghost
  works by calling `Animator.Play(clipName)` on a cloned GameObject using the real Animator
  clip name sent over the wire. UE5 has no direct equivalent for a cloned actor driven by an
  AnimBP/Blueprint-based character — likely needs either a montage-based approach or a
  simplified driven AnimBP. Unresolved design question, not just an implementation detail;
  expect this to be the hardest single task in Phase 7, not the local-state read.
  **Resolved** — animation sync is live-confirmed; see `adapters/pseudoregalia/README.md` steps
  13/16/17 for what it took. The prediction that it would be the hardest task held.
- **UE4SS version drift already observed mid-Phase-7 (2026-08-12)**: the user updated their
  local UE4SS from v2.5.2 Beta to v3.0.1 Beta mid-session, following a Mar 2026 update to
  `pseudoregalia-archipelago`'s own `RE-UE4SS` submodule pin. Confirms the environment can
  drift out from under an in-progress phase without warning — re-check `environment.md`'s
  UE4SS version before resuming any Pseudoregalia work in a new session, the same standard
  applied to TEVI's Steam updates.
- **UE4SS mod-load-order coexistence with `AP_Randomizer`, surfaced at Phase 7 start**: same
  shape as TEVI's BepInEx/Harmony-vs-`Tevi_Randomizer` risk above — confirm the adapter's
  reads/hooks work with `AP_Randomizer` both enabled and disabled, record which was tested.
  **Confirmed live, both directions, 2026-08-12**: a mismatched `UE4SS.dll` build (83 commits
  ahead of the installed one) broke `AP_Randomizer` outright (`0x7f`, a missing exported
  procedure) — not a theoretical risk, an actual observed break, immediately rolled back and
  re-confirmed working. Any future UE4SS runtime change on this machine needs the same
  before/after check, not just "it built."
- **Building a UE4SS C++ mod requires a private submodule this project has no access to,
  found 2026-08-12**: RE-UE4SS's own C++ mod guide builds the engine from source via CMake,
  and its core `UE4SS` target hard-depends on `deps/first/Unreal` (`Re-UE4SS/UEPseudo`),
  confirmed private (`gh api` 404, SSH host-key-verification failure). No prebuilt import
  library ships in any official release asset (checked both the plain runtime zip and the
  "zDEV" package — DLL and PDB only, no `.lib`). This blocks the "C++ for the shipping
  adapter" decision from earlier in Phase 7 unless UEPseudo access is granted — see
  `agent_docs/phases/phase7.md` for the full investigation.
  **Mechanism confirmed 2026-08-12**, not just inferred: read the actual maintainer/reporter
  thread on `UE4SS-RE/RE-UE4SS` issue #577 (`gh issue view 577 --repo UE4SS-RE/RE-UE4SS
  --comments`). The gate is exactly the Epic-Games-account-linked-to-GitHub mechanism guessed
  earlier — linking a GitHub account to an Epic Games account (epicgames.com account settings)
  sends an invite to the `github.com/EpicGames` org; **accepting that invite** is the fix, per
  a RE-UE4SS collaborator (`Buckminsterfullerene02`) and confirmed working immediately after by
  another reporter (`Jenspi`). One documented wrinkle: a June 2024 Epic bug briefly routed new
  links to a separate "mirror" GitHub org without the same fork access — watch for an invite
  that isn't from the org named plain `EpicGames` if this doesn't work on the first try. No
  other steps reported in the thread (no NDA, no manual approval queue).
  **Resolved 2026-08-12**: user linked their GitHub account to their Epic Games account
  (Connections → Accounts → GitHub, OAuth authorize, propagation took a few minutes as
  expected) and accepted the resulting `EpicGames` org invite. `git submodule update --init
  deps/first/Unreal` in the local `RE-UE4SS` checkout then succeeded — 2498 real files (headers,
  source, `CMakeLists.txt`), not an empty stub. **The C++/UEPseudo path is unblocked.** This
  reopens the Phase 7.2 "C++ for the shipping adapter" option, no longer forced into Lua-only —
  still needs a real build attempt before trusting it (submodule clone success only proves
  access, not that the build itself succeeds).
- **UE4SS Lua *does* expose `package.loadlib`, reopening the socket question, found
  2026-08-12**: contradicts the earlier "Lua has no socket path" reasoning (Phase 7's
  adapter-language decision), which was based only on the *absence* of a first-party socket
  library, not on `loadlib` being disabled. `MeshGhostSocketProbe` Stage 1 confirmed
  `type(package.loadlib) == "function"` live. Untested and risky: UE4SS's Lua is statically
  embedded in `UE4SS.dll`, not a separate `lua54.dll` the way BizHawk's NLua host is — loading
  MeshGhost's already-vetted `lua54.dll`/`socket-windows-5-4.dll` pair here could crash the
  game rather than fail cleanly if the two compiled Lua runtimes' `lua_State` layouts don't
  match, unlike BizHawk where there was only ever one real Lua runtime involved.
  **Downgraded 2026-08-12**: Stage 2 (`adapters/pseudoregalia/probe_socket/Scripts/stage2_loadlib.lua`)
  ran live — preload, `loadlib`, `luaopen_socket_core()`, and `socket.tcp()` create/close all
  succeeded with no crash, `AP_Randomizer` unaffected, extended play session stable (see
  `agent_docs/verified.md`). The `lua_State`-mismatch risk hasn't corrupted anything through
  object creation. Still open: a real `bind`/`connect`/send/receive round trip is untested and
  is where an ABI mismatch would most plausibly surface (e.g. buffer/struct handling under
  actual I/O, not just table construction) — treat as unresolved until that's tried.
  **Resolved 2026-08-12**: Stage 3
  (`adapters/pseudoregalia/probe_socket/Scripts/stage3_roundtrip.lua`) did a real
  connect/send/receive round trip against the actual bridge protocol — a real
  `meshghost.exe` core, a real relay loopback echo, and a real `render_remote` frame read back
  successfully inside UE4SS's embedded Lua. Extended play session stable, no crash/lag/
  weirdness (user-confirmed, see `agent_docs/verified.md`). The `lua_State`-mismatch risk is
  now considered closed for this specific vendored `lua54.dll`/`socket-windows-5-4.dll` pair
  against this UE4SS build (`v3.0.1 Beta`/SHA `733e5969`) — a **Lua-only shipping adapter** is
  viable, no C++/UEPseudo build required.
  **Reopened 2026-08-12, same day, once 7.5 exercised this under real sustained traffic**: Stage
  3's one-shot probe (a handful of hardcoded dummy frames) never hit this; the real adapter
  running at 10Hz two-way for tens of seconds hits it constantly. Confirmed via layered
  diagnostics in `main.lua` (send counters 100% ok; raw receive-line counters showing 83-98% of
  lines failing to decode; a hex dump of the actual bytes showing well-formed JSON up to an
  inconsistent cutoff point, then unreadable data for the rest of a line `#line` still reports the
  full length of) that this is genuine data corruption on receive, not a JSON-format or
  application-logic bug. Neither message size (area_id shortened ~325→~274 bytes, no change in
  failure rate) nor send frequency (100ms→250ms tick, no change) is the trigger; the failure rate
  does drop from ~98% early in a connection to ~83% by 30-45s in, in every test, independent of
  both — consistent with a timing/reentrancy bug in the vendored DLL pair, not a fixed size limit.
  **The `lua_State`-mismatch risk this entry originally raised is not closed after all** — it was
  only ever exercised lightly before. See `agent_docs/phases/phase7.md`'s 7.5 entry for the full
  diagnostic trail. Next steps, neither tried: an alternate vendored LuaSocket build, or the
  C++/UEPseudo path (blocked on private submodule access as of that writing — **that block was
  resolved 2026-08-12**, see the "Resolved 2026-08-12" note on the submodule risk above, and the
  paragraph immediately below is what happened once it was).
  **Resolved by side-by-side comparison, 2026-08-13**: with UEPseudo unblocked (above), a native
  C++ bridge client (`adapters/pseudoregalia/MeshGhostPseudo`) was run *simultaneously* with the
  still-enabled Lua `MeshGhostGhostProbe`, both connected to the same bridge port at the same
  real time, against identical live traffic. `UE4SS.log` shows the Lua side still corrupting
  ~98% of received lines (386 received, 379 malformed) while the C++ side received 6058+ lines
  with **zero** malformed. This isn't a difference in load or timing (same session, same
  wall-clock window) -- it isolates the vendored `lua54.dll`/`socket-windows-5-4.dll` pair itself
  as the cause, not the core, the relay, or the wire format. The C++ rewrite is the resolution;
  no alternate LuaSocket build was ever needed.
- **Spawning the player's own gameplay Blueprint as a placeholder ghost physically dragged the
  player, found 2026-08-12, root cause confirmed the same day**:
  `adapters/pseudoregalia/probe_ghost/Scripts/main.lua` spawned a second instance of
  `BP_PlayerGoatMain_C` 150 units from the player. The user was physically dragged/pulled
  toward another location at high speed on three separate runs, until dying each time. Two
  wrong theories tried and ruled out in turn — disabling `SetActorEnableCollision`/
  `SetActorTickEnabled` on the ghost made no difference, then a rewrite to stop mutating a
  suspected live-reference FVector read from the pawn *also* made no difference (still dragged,
  identically, on the very next run). **Confirmed root cause, via a read-only diagnostic
  script that performed zero repositioning and still let the address logging speak for
  itself**: `BP_PlayerGoatMain_C` auto-possesses on spawn, silently swapping
  `PlayerController.Pawn` to the newly-spawned ghost — every "fix" was moving what it believed
  was a separate, uncontrolled placeholder, but the ghost *was* the actual possessed,
  camera-attached character the whole time. Fixed by calling `controller:Possess(pawn)`
  immediately after spawn to hand control back to the original pawn. See
  `agent_docs/verified.md` and `agent_docs/phases/phase7.md` for the full five-bug history.
  **General lesson for any future UE4SS Lua script in this repo that spawns another instance of
  a controllable pawn Blueprint**: assume it may auto-possess on spawn until proven otherwise
  for that specific class, and re-possess the original pawn defensively right after spawning —
  don't assume a spawned actor is inert just because nothing told it to take control. (A weaker,
  now-superseded version of this lesson — about never writing into a vector/rotator struct read
  from an actor you don't intend to move — turned out not to be the actual mechanism here, but
  is still reasonable defensive practice and is enforced by `main.lua`'s current design either
  way.)

- **Enabling ghost collision can kill the real player's own character, confirmed live
  2026-08-13.** Tried `SetActorEnableCollision(true)` on the spawn-based Pseudoregalia ghost
  (was `false`) as a real fix attempt for the stuck-falling-pose and can't-grab-ledges
  animation bugs (both plausibly need a real physics trace to detect ground/ledge contact).
  **Confirmed live, corrected from an earlier wrong write-up**: the ghost did *not* become
  physically solid — the real player could still walk straight into/through it, no blocking
  collision at all. But it could be attacked and killed with melee, and doing so killed the
  **real player's own character**, not just the ghost. So this one call produced the worst
  combination: no physical solidity (the actual goal), but real vulnerability to being killed
  (a new danger). Consistent with standard UE behavior: `SetActorEnableCollision` only restores
  whatever `CollisionEnabled` query/physics mode the component's existing collision profile
  already specifies — it does not change per-channel collision *responses* (Block/Overlap/
  Ignore). A stock "Pawn" collision preset commonly overlaps (not blocks) other Pawn-channel
  actors by default while still registering weapon-trace hits via that same overlap query — real
  physical blocking would need an explicit response-channel change, separately from this toggle,
  not guessed yet. The real-player-death effect is the more serious finding on top of that: it
  suggests health/damage state on `BP_PlayerGoatMain_C` may not be safely scoped per-instance (a
  `'As MV Game Instance Ref'` object property, found during the animation-state reflection dump,
  is one candidate mechanism, not yet confirmed) — i.e. this game's own gameplay Blueprints were
  plausibly never written to expect two live instances of the player class at once, unlike an
  NPC class. **Reverted same-day.**

  **Second attempt, same day, also failed, real melee-death risk still unaddressed**: added
  `UPrimitiveComponent::SetCollisionResponseToChannel(ECC_Pawn, ECR_Block)` on the ghost's own
  `CapsuleComponent` on top of `SetActorEnableCollision(true)`, via a real UFunction call whose
  parameter offsets come from the function's own reflected properties (not a guessed struct
  layout). Confirmed via log that the function was genuinely found and the call made — no
  reflection failure this time, unlike many other UFunctions on this build. Still no physical
  solidity; the real player could still walk straight through the ghost. Leading theory: UE's
  dynamic-vs-dynamic actor blocking requires **both** actors' collision response to agree on
  Block, and only the ghost's side was ever changed — the real player's own capsule was very
  likely never configured to Block the Pawn channel at all, since two-pawn contact was never a
  real case in a single-player game. Fixing that would require modifying the **real player's
  own live collision component**, not just the ghost's — a materially bigger risk than anything
  tried so far, layered on top of the still-unresolved melee-death danger above. **Reverted
  same-day** (`GHOST_COLLISION_ENABLED` toggle in `Plugin.cpp`).
  **Superseded 2026-08-15 — see the resolution entry at the end of this collision group.** Do not
  attempt modifying the real player's own collision setup without explicit go-ahead, given the
  accumulated risk; that half of this entry still stands.
- **Open question, raised by the user 2026-08-13, not yet investigated**: does *any* in-world
  damage source reach the ghost and propagate to the real player the same way melee did, or was
  that specific to collision-enabled melee hit detection? **Substantially answered 2026-08-15 —
  see the resolution entry below: enemy damage did reach the ghost and propagate, and was fixed
  via the collision object type.** At the time of writing, with collision off, the ghost was
  assumed undetectable by most world hazards, but that had not been checked
  — some UE trigger volumes (hazards, out-of-bounds kill-Z, scripted death triggers) fire on
  overlap events that may not depend on the same collision toggle just tested. Needs its own
  grounded investigation (what actually caused the real-player death above) before any future
  collision-related change, not an assumption that "collision off" fully closes this off.
- **New data point, 2026-08-14, minor and not yet investigated: the ghost may be able to land
  attacks on the real player, in the opposite direction from the 2026-08-13 finding above.**
  During otherwise-successful live testing of this session's rebuild (ghost spawn/follow/
  animate all confirmed working, see `verified.md`), the user did a flip, gained height, and
  spammed attacks; the ghost appeared to land hits back — the real player's hit/hurt (red flash)
  animation played, though the player didn't die, and this reproduced a few times under the same
  conditions (airborne + rapid attack spam). `GHOST_COLLISION_ENABLED` was confirmed `false`
  in the build of that date (it is `true` since 2026-08-15 — see the resolution entry below), so
  at the time of this observation the mechanism was
  unclear — this is the same open question above (does something other than the disabled
  collision toggle let a hit register?), just observed from the other direction: the *ghost's*
  attack reaching the player, not the player's damage reaching the ghost. Two real possibilities,
  neither confirmed: (1) the same shared/not-per-instance state theorized in the 2026-08-13 entry
  (`'As MV Game Instance Ref'`) could mean the ghost's attack-hit trigger and the real player's
  hurt-react are reading/writing the same instance-scoped gameplay state rather than two
  genuinely separate pawns; (2) an attack hitbox/trigger volume keyed off proximity or animation
  state rather than the `SetActorEnableCollision`/response-channel path already tested, which
  would explain it surviving collision being off. **Not yet reproduced with a minimal isolated
  test** (e.g. does it happen with no attack spam, does height/airborne state matter, does it
  happen with the real player *not* attacking at all) — treat the "airborne + attack spam"
  framing as the user's field observation, not a confirmed trigger condition. Low priority (no
  real damage taken), but should be investigated with the same rigor as the collision work above
  before any future combat/animation-adjacent change, since it points at the same
  "two live instances of a class the game never expected to duplicate" risk class.
- **RESOLVED 2026-08-15 — collision is ON as a deliberate feature, and the run-ending vector is
  fixed.** `GHOST_COLLISION_ENABLED = true` (`Plugin.cpp`). This supersedes the "reverted,
  do not re-enable" verdict in the entries above, on the user's explicit call. What changed: the
  genuinely dangerous case turned out to be *enemy* damage, not player melee — an enemy hitting a
  ghost hurt and could kill the real player during ordinary play, with no visible cause. Fixed by
  giving the ghost capsule the `ECC_WorldDynamic` object type instead of `ECC_Pawn`, so enemy
  targeting never queries it. Confirmed live: the ghost takes no enemy damage and can still shove
  enemies around. **Residual, accepted, unchanged**: a player can still deliberately melee a ghost
  and take damage (`bCanBeDamaged = false` was tried and provably did not stop it — this game's
  melee doesn't use UE's standard damage path). **Still hard-forbidden**: setting
  `LOOPBACK_GHOST_OFFSET_X = 0` while collision is on, which reproduces the Phase 7.4 drag/pull
  bug immediately. Whether collision is actually *fun* was gated on Phase 7.7, which is **done
  (2026-08-16, two players on two machines)** — so the keep-or-axe call is now unblocked and
  simply un-re-judged; see `status.md`. Full record: `agent_docs/ideas.md` item 5, and
  `verified.md`'s enemy-damage entry.

- **`send_hz` is prescriptive but unenforced — a non-compliant client can legitimately run at up
  to 6x the room's configured rate before it's disconnected.** Built 2026-08-15 (see the ADR in
  `agent_docs/architecture.md`). The relay advertises a room-wide send rate in `Welcome`, and a
  well-behaved client adopts it, but nothing checks that a client actually *does* — the only
  hard backstop is the scaled per-client flood cap (`max(120, send_hz × 6)`), which exists to
  guard against a genuinely misbehaving/flooding client, not to enforce compliance with the
  advertised rate. A buggy or hostile client that ignores `Welcome.SendHz` entirely and sends at
  its own faster pace is tolerated right up to that cap.
- **Raising a relay's `send_hz` taxes every peer's download, and a client running a pre-change
  build has no way to opt out of a fast room.** `client.max_receive_hz_per_player` lets an
  *updated* client cap its own inbound rate per peer, but an older client (or one whose config
  file hasn't been updated) is uncapped and simply receives whatever the room's configured rate
  produces. Combined with the pre-existing O(n²) room fan-out
  (`relay.DefaultMaxClients`'s own doc comment), a host who raises `send_hz` without
  telling their players is imposing a real, potentially unwanted bandwidth cost on everyone in
  the room. Mitigated by documentation only (`packaging/release/README.txt`'s Hz section states
  the concrete cost and recommends leaving the defaults alone) — there is no protocol-level
  fix, the same shape as the "stale relay" risk above.

## Mitigations

- Keep the contract minimal, and validate it early with a fake adapter (Phase 5).
- Record confirmed facts in `agent_docs/verified.md` and treat everything else as
  provisional — including this file.
- Keep transport abstract and swap-friendly so the relay layer can evolve past no-auth
  without touching the core or any adapter.
- Use phase-based validation to catch contract or rendering issues early rather than after
  a second game is underway.
- Track toolchain versions in `agent_docs/environment.md` as soon as Phase 1 starts.
- Re-check a project's license (`agent_docs/licensing.md`) before treating it as anything
  more than a documentation reference.
- Re-verify a `Closed` risk before trusting it if the conditions that closed it could have
  changed (a mod/tool update, exercising it under new load/scale) — a closure is a point-in-time
  test result, not permanent. Real precedent: the `lua_State`-mismatch risk above closed under a
  light round trip, then reopened the same day once real 10Hz sustained traffic exposed an
  83-98% corruption rate that the light test never exercised.

## Cross-area state fan-out is unmeasured in a REAL SESSION (opened 2026-08-18, halved 2026-08-28)

**The filter now exists (ADR 0041), so the cost this risk describes is no longer paid by any client
that opts in.** Measured against the real binaries on 2026-08-28 with `meshghost-fakeadapter`'s new
`-areas` flag: 16 peers over 8 areas, **93% of offered state bytes suppressed**; the same rig at one
area suppresses 0%, which is the control proving the single-area case is untouched. What remains
open is the half this entry always meant: **that number came from a rig, where areas are assigned by
a flag. A real Emerald or Crystal session with `-introspect` has still never been recorded**, and
only it can say what share a real player's movement produces.

Below is the entry as written on 2026-08-18, kept because its reasoning is what the filter was built
from.

**The risk this closes, and the one it leaves open.** The relay fans every state message to every
room member and never reads `area_id`; the core discards non-matching areas at render time
(`core/core.go`'s `remoteStatesAt`). So cross-area traffic is paid for on both uplinks, parsed and
buffered, then thrown away. Nobody had ever measured how much of the total that is. (Since
2026-08-20 an adapter may declare `render_all_areas` in its bridge hello and take that filter over
— Emerald does, for seam crossings — which changes what the core throws away, not what the relay
sends.)

**Shadow counters shipped 2026-08-18** (`relay/introspect.go`'s `StateFanoutSnapshot`, counted in
`relay.stateRecipients`). Measurement only — nothing branches on them and delivery is byte-for-byte
unchanged.

**Validated, not yet measured.** A synthetic run (relay plus two `cmd/meshghost-fakeadapter`
processes, 4 peers split 2-and-2 across two areas) reported **67%** of forwarded bytes as
cross-area, which is exactly the hand arithmetic — each state reaches 3 peers, 2 elsewhere. That
confirms the counter is correct; it says nothing about real play, because the areas were assigned
by a flag. **Still open: run a real multi-player session on a real game with `-introspect` and
record the number here**, ideally on the same setup the 653 KB/s figure in
`packaging/release/README.txt` came from, so the two are comparable.

Expect it to vary sharply by game — a title with small, frequently-crossed zones should score high,
one with a single always-loaded overworld near zero. Per `plans.md`'s "Efficiency is a standing
goal", the number sizes the win; it is not a threshold the win has to clear to be worth taking.

- **`extras` is bounded by total serialized bytes and nothing else** (audited 2026-08-27).
  `protocol.MaxExtrasBytes` caps the whole map at 1024 bytes; there is no per-field type, range,
  finiteness, key-count or nesting bound anywhere in the Go side, and Pseudoregalia's own source
  says so (*"extras values reach here unchecked"*). **Every adapter is therefore individually
  responsible for clamping every field it reads, correctly, forever** — and an adapter that forgets
  has no backstop. Pseudoregalia does it in 15 places (`clamp_to_uint8`, which exists because
  `static_cast<uint8_t>(double)` is UB for NaN); the two gaps the same audit found are simply where
  it has not been done. This is the standing argument for adapter-declared constraints enforced on
  RECEIVE by the core: `agent_docs/ideas.md`, "The ACE audit" and "Should the Go side stay
  game-blind?". **Not a hypothetical risk and not scheduled** — it is the current design, recorded
  so it is a decision rather than an oversight.

- **A peer can name a thing, in two places** (audited 2026-08-27). Pseudoregalia hands a
  peer-supplied string to an engine-wide `StaticFindObject` lookup (`Plugin.cpp:9383`) — type-checked
  against `AnimMontage` before use, so no type confusion, but the peer may play any montage in the
  loaded game and the miss-warning reveals whether an arbitrary object name exists. TEVI hands a
  peer string to Unity's `anim.Play` (`Plugin.cs:506`) with no validation beyond
  `protocol.MaxAnimLen`. **Neither is ACE**; both are cosmetic misbehaviour plus, for TEVI, a
  per-frame log flood from a peer alternating two bogus names. Fix for both is an allowlist of the
  names the adapter actually mirrors, which is a small fixed set. `ideas.md`, "The ACE audit".
