# Phase 8 — Emerald, dedicated (post-Phase-5.5 ongoing work)

**Status: in progress**, started 2026-08-14. Numbered next in sequence rather than folded back
into 1–5.5 (which bundled Emerald's adapter work together with building the server/client/core
themselves, since Emerald was the first game) — renumbering 1–5.5 would break the many existing
citations to them across `verified.md`/`pitfalls.md`/`status.md`/`risks.md` for no real gain, so
they stay as-is. Phase 6 (TEVI) and Phase 7 (Pseudoregalia) are unrelated games and keep their
own numbers; this phase is specifically "Emerald keeps getting worked on, on its own, after
5.5 closed" — decided 2026-08-14, see `adapters/pokemon/emerald/README.md`'s "How this adapter
was built"/"Further work" sections for the reader-facing summary this phase file backs.

## Purpose

A dedicated home for Emerald-specific work that happens after Phase 5.5's "good enough"
milestone (2026-08-11) — real bugs found via live testing, Archipelago-compatibility work, and
future scoped investigations (surf/bike/fishing movement support, the VRAM/sprite-injection
idea) — instead of that work living homeless across `status.md`'s running log with no phase
file of its own, which is what was happening before this file existed.

## Tasks

- [x] **2026-08-14 review/refactor sweep, Lua side**: partial-line receive, partial send,
      dead-socket-after-hard-error detection, a `pcall` guard around the main loop, and
      control-character JSON escaping — real socket-framing and crash-safety bugs, not
      hypothetical. Live-verified via loopback (a real relay/core round trip, ghost spawn and
      clean despawn on client kill). See `agent_docs/verified.md`'s "Emerald Lua adapter sweep
      fixes, live-verified via loopback" and `agent_docs/pitfalls.md`'s partial-send/receive
      NDJSON-framing entry.
- [x] **Real non-loopback two-peer test** — two real BizHawk instances, two real cores, one
      real relay, closing the sweep's "Emerald not yet live-verified outside loopback" gap.
      Along the way, diagnosed a real launch-time mistake (double-clicking `EmuHawk.exe`
      directly skips `MESHGHOST_BRIDGE_PORT`, so a second instance silently shares the first
      core's bridge) rather than a code bug — see `agent_docs/pitfalls.md`'s "Running two
      instances of the same emulator/game silently collide on a shared default port". See
      `agent_docs/verified.md`'s "Real two-peer Emerald test, non-loopback" entry. Also cleaned up
      `dev-scripts/`: removed the tracked `run-bizhawk1.bat`/`run-bizhawk2.bat` (couldn't ship real
      personal EmuHawk/ROM paths in a public repo) and the redundant `run-core.bat`, renamed
      `run-core1.bat`/`run-core2.bat` to `run-core-emerald.bat`/`run-core-emerald2.bat` for
      consistency with the TEVI/Pseudoregalia naming, and added two gitignored `.local.bat`
      BizHawk launchers (real paths, set the bridge port explicitly) so this exact mistake can't
      recur silently.
- [x] **Archipelago ROM compatibility investigation** — this adapter had only ever been
      verified against a vanilla ROM; a real Archipelago-patched ROM broke it in four distinct,
      separately-found-and-fixed ways, all confirmed live and cited to the exact ROM-diff/
      memory-scan evidence in `agent_docs/verified.md`:
      1. `CB2_Overworld` recompiles to a different address under Archipelago's patch, closing a
         "ghost never renders" gap (`avatar_scan_probe.lua`/`battle_probe.lua`).
      2. Brendan/May sprite tile and palette data also relocates (a different offset from (1) —
         found by direct ROM-byte comparison, not assumed to share one shift).
      3. `gObjectEvents`/`gPlayerAvatar` also relocate — found via a four-stage live
         investigation (`avatar_scan_probe.lua` → `avatar_hexdump_probe.lua` →
         `avatar_array_probe.lua` → `avatar_verify_probe.lua`, all now committed as a reusable
         template for a future address shift).
      4. A timing bug in the fix for (3): resolving the address shift once at script load could
         permanently latch onto the wrong (vanilla) offset if the script loaded during the
         intro cutscene, before the player's object event existed yet — fixed by retrying every
         frame until found instead of once.
      Each of the four has its own dated `agent_docs/verified.md` entry (search
      "Archipelago-recompiled CB2_Overworld", "decode to garbage", "Archipelago-relocated
      gObjectEvents", "avatar-detection timing bug").
- [x] **Gender-read timing gap**: `readLocalGender()` resolved gender once per session, gated
      only on a save pointer being non-null — not on character creation actually having
      finished, since every prior test happened to run against an already-created save. Fixed
      by also gating on `inOverworld()`. See `agent_docs/verified.md`'s "Gender read correctly
      deferred past character creation on a fresh save".
- [x] **Local dev/testing tuned for instant feedback**: `dev-scripts/run-core-*.bat` (all
      three games) changed from a 200ms interpolation delay to `-interp=0ms -min-send=10ms` —
      local loopback testing has no real network jitter to smooth over, and delay was actively
      hiding real timing bugs (see the next item). A new `-min-send`/`min_send` flag was added
      to `cmd/meshghost` (`Core.MinSendInterval` already existed as a field, just wasn't
      exposed). `run-core-emerald-trail.bat` keeps a real 200ms delay specifically for the
      exact-trail loopback mode, which needs visible lag or the ghost renders invisibly on top
      of the player. See `dev-scripts/README.md`.
- [x] **Sub-tile glide bug, found once the network buffer above stopped hiding it**: live
      measuring each step's glide duration (an Emerald-only mechanism, self-correcting since
      2026-08-11) conflated ordinary tap-then-pause play with genuine slow steps, and a
      same-day attempt to gate that on matching `anim` was itself disproven by live data.
      Reverted to plain fixed per-anim constants (16 walking / 8 running frames), justified by
      a per-frame raw-position trace showing zero real variance across dozens of steps. A
      parallel dead end in the same investigation — `playerScreenPos()` appearing frozen across
      a walked tile — turned out to be pokeemerald's real screen-locked-player/scrolling-world
      camera behavior, not a stale address. See `agent_docs/verified.md`'s "Emerald walk/run
      sub-tile glide" entry and `agent_docs/pitfalls.md`'s "Reconstructing continuous motion
      from discrete, throttled position samples" entry for the full three-attempt history.
- [x] **Loopback ghost offset/exact-trail modes**, generalized to TEVI and Pseudoregalia's own
      remote-ghost placement the same day — see each adapter's own README/pitfalls entries.
- [x] **Relay-safety hardening pass (2026-08-14)** — set as the next priority once TEVI's 6.6/6.7
      wrapped up; not Emerald-specific, but logged here per this file's role as the home for
      cross-cutting infrastructure work done during Phase 8. Full record: the ADR in
      `agent_docs/architecture.md` (search "room-code/version ADR"), `internal/README.md`'s "What
      changed" section, and `agent_docs/plans.md`'s "Room codes / relay safety" section. Short
      version:
      - **Room-code auth**: `hello` carries an optional `room_code`, constant-time-checked
        against the relay's own configured `Server.RoomCode`; empty (still the default) means
        auth stays off. A refused `hello` (bad version, wrong code, game/version mismatch, full
        room) now gets a `reject` message with a reason before the connection closes, instead of
        a bare hangup.
      - **Peer game-version check**: `hello` carries an optional `game_version`, sticky per room
        the same way `game_id` already is. Each shipped adapter reports its own adapter/mod
        version (Emerald `"phase5.5"`, TEVI's BepInEx `PluginVersion`, Pseudoregalia `"phase7.6"`)
        — not a real game/DLC build number, since no cited memory address exists for one in any
        of the three games. Real gap this still leaves open for TEVI specifically: two peers on
        different Steam patch levels or DLC states still aren't caught — see `risks.md`.
      - **Malicious-peer hardening**: a real remote-OOM in `internal/transport` (unbounded read
        buffer, fixed via `bufio.Scanner` with a real max-token-size enforced during the read),
        read/write deadlines and a relay hello-timeout (none existed before), `Room.Forward` no
        longer holding its lock across a potentially-blocking `Send`, and `internal/core` keeping
        its own roster (from `welcome`/`join`/`leave`) and dropping `state` for any `player_id` it
        never saw announced. New size/length caps on `orientation`, `area_id`, `anim`, and every
        `hello` string field.
      - **Live-confirmed**, not just `go test`: real relay + real client through the actual
        shipped `packaging/release/config.json`, correct-code accept and wrong-code reject both
        confirmed via each process's own log output — see `verified.md`.
      - **Explicit limits recorded, not glossed over**: no TLS (`risks.md`) — a room code crosses
        the wire in plaintext. And a stale (pre-2026-08-14) relay binary silently provides zero
        protection regardless of what a client sends — `packaging/README.md`/
        `packaging/release/README.txt` say plainly that room-code auth needs the relay itself to
        be current.
      - **Same-day follow-up, from user questions**: a rejection previously reached nobody but the
        client's own log — the relay now logs join/leave/reject; `internal/core` logs a connect
        failure once per distinct message, not once per retry. `cmd/meshghost`'s eager `-game`
        path no longer crashes via `log.Fatalf` on the first failed dial — it retries with backoff
        (1s→15s) instead, routed through `ConnectRelayOnAdapterHello`/`relayConnectMu` so a real
        adapter connecting concurrently can't race it into a duplicate dial. A genuinely permanent
        rejection (wrong code, version mismatch) still exits loudly. **Confirmed live**: real
        `meshghost.exe` started before any relay existed, retried silently across ~15s of real
        backoff, then connected the instant a real `meshghost-relay.exe` came up — see
        `verified.md` and the ADR in `architecture.md`.
- [x] **2026-08-14 review/refactor sweep** — a full review/refactor pass across `internal/`,
      `cmd/`, and all three adapters. See the ADR in `architecture.md` (search "same-day
      review/refactor sweep") for the four original behavior-changing decisions and the full fix
      list, plus a follow-up ADR (search "found during live testing of the sweep above") for a
      relay-auto-reconnect gap found live. `pitfalls.md` has the partial-send/receive NDJSON-
      framing pattern found independently in Emerald's Lua and Pseudoregalia's C++, and the "move
      offscreen, never destroy" ghost-lifecycle pitfall. The Lua/Emerald side of this sweep is its
      own task item above; the rest:
      - **Go (`internal/`, `cmd/`)**: all sweep fixes applied, plus a same-day follow-up fix found
        during live testing — a relay that drops *after* a successful connect (crash, restart,
        network blip) previously had no path back to "connected" short of a full client restart;
        `Core` now auto-retries in the background. New regression test
        (`TestRelayDisconnectAutoReconnects`). Live-verified via real binaries (kill relay →
        client retries → new relay → client reconnects automatically) — see `verified.md`.
        **Important operational note, also found live**: `meshghost.exe`/`meshghost-relay.exe`/
        `meshghost-fakeadapter.exe` at the repo root are NOT kept fresh by `go build ./...`/
        `go vet`/`go test` — those compile-check packages but don't overwrite the named binaries
        `dev-scripts/*.bat` launches. Always `go build -o meshghost.exe ./cmd/meshghost` (and the
        other two) explicitly before testing via the `.bat` files.
      - **Pseudoregalia (C++)**: all fixes applied, rebuilt, hash-diff-confirmed deployed to both
        the in-repo packaging copy and the live Steam install. **Live-confirmed working**: ghost
        spawn/follow/animate, no crashes. Unrelated to this sweep, found live during the same
        test: a possible ghost→real-player combat interaction (ghost landing hits despite
        `GHOST_COLLISION_ENABLED = false`) — logged as a new data point on the existing
        ghost-collision open question in `risks.md`, low priority, not yet investigated.
      - **TEVI (C#)**: all fixes applied (stale-thread generation guard, `TcpClient` disposal,
        real `Destroy()` on ghost/marker despawn, `OnDestroy`/`OnApplicationQuit` bridge close,
        `room_x`/`room_y` range check, `TryGetValue` in place of unguarded `JObject` casts).
        Rebuilt via `dev-scripts\build-tevi.bat`, deployed to both the Steam install and the
        standalone `tevi-14778703` build, hash-diff-confirmed. Two dedicated dual-instance dev
        scripts added: `dev-scripts\run-core-tevi.bat` (port 7778) / `run-core-tevi2.bat` (port
        7779). **Live two-instance testing found and fixed a real bug**: a peer's ghost went
        permanently invisible after the traveling player returned to a zone — root cause was
        `CreateRealGhostVisual` cloning a live character's visual hierarchy mid-transition,
        inheriting a disabled `basesprite` renderer with nothing to ever re-enable it. Fixed
        (`basesprite.enabled` forced true on recreate) and live-confirmed. See `verified.md` and
        `pitfalls.md`'s "Level/scene transitions invalidating cached references" entry.
      - **Docs**: this entry, both ADRs above, and the `pitfalls.md`/
        `adapters/_template/PROTOCOL.md` updates (Pseudoregalia added to the adapter list,
        `extras` documented as load-bearing, `orientation` shown as opaque any-JSON, a
        peer-controlled-data warning added, the TEVI ghost-invisibility entry) are done.
      - **Pseudoregalia despawn-visual/area-transition live-verified, two more real bugs found and
        fixed**: (1) closing the client left a ghost frozen/visible instead of despawning —
        `on_update()` never detected its own bridge connection dying (same bug class as Emerald's
        Phase 3 fix, never ported here); fixed via `release_all_ghosts_parked`, armed by a
        connected→disconnected edge check and drained on the game thread. (2) a core with no
        adapter attached sent nothing to the relay, hit the 60s idle timeout, and the sweep's own
        auto-reconnect kept reconnecting it under a brand-new player id every ~60s — every peer
        would see a leave+join/despawn-respawn cycle once a minute. Fixed via `Core.sendHeartbeats`
        (a 20s `Ping`). Both confirmed live, `main.dll` rebuilt and hash-diff-deployed to both the
        in-repo packaging copy and the live Steam install. See `verified.md`'s three new entries.
      - **This closed every item from the 2026-08-14 sweep's "Not started" list.**
- [ ] **Surf, Mach Bike, Acro Bike, ledges, and Mach Bike rail sections**: the ghost snaps badly
      on all of these today, since `getLocalState()`'s anim classification and
      `STEP_DURATION_FRAMES` only cover walking/running/idle. Real, cited detection source
      found (not yet live-verified): `pokeemerald`'s `include/global.fieldmap.h:288-295` —
      `PLAYER_AVATAR_FLAG_MACH_BIKE`/`_ACRO_BIKE`/`_SURFING`/`_FORCED_MOVE` are bits on the same
      `PlayerAvatar.flags` byte already read for the dash bit, so no new address is needed, and
      the shift should carry over from the already-working `avatarAddrOffset` detection — still
      needs an on-screen bitfield check per this project's own rule. Real per-tile timing for
      each mode still needs live measurement. A combined probe
      (`adapters/pokemon/emerald/surf_bike_probe.lua`) is ready; not yet run. Fishing rod (a
      stationary action, not a movement speed) is a separate, smaller follow-up.
- [ ] **VRAM/sprite injection investigation** (`agent_docs/ideas.md`) — draw-via-VRAM-write
      instead of `gui.drawPixel` overlay, found via the `GBA-PK-multiplayer` reference project
      (CC BY-NC 4.0, `licensing.md`). A 5-stage test plan is agreed; Stage 1 (read-only vanilla
      probe) ran 2026-08-14 and is written up in `agent_docs/environment.md`; Stages 2-5 not
      started. Per `agent_docs/ideas.md`'s own stated convention, an idea is
      committed by moving it into `agent_docs/plans.md` with a phase number, not directly into
      a phase file's task list — this item is listed here as a forward-looking note for what
      Phase 8 will pick up next, not a claim that it has already graduated.

## Notes

- Every fact cited above already has its own `agent_docs/verified.md` entry with the real
  source/citation — this file doesn't re-derive anything, it's the phase-level index pointing
  at that evidence, matching how Phase 6/7 cite `verified.md` rather than duplicating it.
