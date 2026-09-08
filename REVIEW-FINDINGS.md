# Adversarial review — 2026-09-07

Working file, **deliberately untracked** (not committed, so it cannot trip the doc/preflight
gates). Delete it when the list is empty, or ask for it to be committed if it should outlive
the session.

23 read-only review agents over server / client / protocol / four adapters / cross-cutting.
Nothing in the repo was modified by the review itself; the tree was clean at `ed9069e8`.

Legend: `[ ]` open · `[x]` fixed + verified · `[~]` fixed, needs the user's eyes ·
`[?]` needs a decision before it can be fixed · `[-]` dropped (not a defect)

"Verified by me" = I re-read the code or ran the command myself, not just the agent's word.

---

## A. Act first

- [~] **A1 HIGH (scanners FIXED, binaries pending D1) — Leak scanners are blind to binaries; a tracked, shipped DLL carries the username.**
  `packaging/release/games/pseudoregalia/pseudoregalia/Binaries/Win64/ue4ss/UE4SS.dll` (tracked, 16 MB)
  holds the maintainer's Windows home-directory cargo-registry path 86 times (Rust panic paths; UE4SS built locally with no
  `--remap-path-prefix`), plus 65 clone-path strings (`...\RE-UE4SS\deps\first\patternsleuth\...` and
  the build tree). `main.dll`, `dwmapi.dll`, `MeshGhostTevi.dll` each carry 1 clone-path PDB string.
  All three scanners use `grep -I`, defined as "treat a binary file as containing no match":
  `.githooks/pre-commit:40`, `.github/workflows/ci.yml:79`, `dev-scripts/preflight.ps1:140`.
  `preflight.ps1 -TreeOnly` prints **PASS** on the current tree.
  Verified by me: `strings -a | grep -cF` per tracked binary; counts above are exact.
  Two parts: (a) make the gates binary-aware — mine to do; (b) stop shipping the strings — see D1.
  Bounding negative: none of the embedded strings reach `deps/first/Unreal`, so this does **not**
  widen the open UEPseudo licensing question in `agent_docs/licensing.md`.

- [x] **A2 HIGH — CI's leak backstop does not run for most of the tree.**
  `ci.yml` triggers only on `**.go`/`go.mod`/`go.sum`; `docs.yml` only on `**.md`/`preflight.ps1`.
  A push touching only `.ps1`/`.bat`/`.txt`/`.json`/`.cs`/`.cpp`/`.lua`/a binary gets **zero** leak
  scanning. `.githooks/pre-commit:19-21` claims "CI re-runs the same scan over the whole tree".

- [x] **A3 HIGH — `tls_fingerprint` bypass #1: the pin matches any cert in the chain.**
  `netx/tlsx/tlsx.go:197-202` loops over all `rawCerts`; with `InsecureSkipVerify: true` (deliberate,
  documented at `:180-186`) there is no chain validation, so only `rawCerts[0]` is bound to the
  handshake signature. MITM presents `[attacker_leaf, copied_relay_cert]` and passes.
  Fix: compare `rawCerts[0]` only. Verified by me.

- [x] **A4 HIGH — `tls_fingerprint` bypass #2: a pin failure falls back to plaintext under `auto`.**
  `netx/netx.go:299-310`. A failed pin is an error, and `Auto` treats it identically to "relay cannot
  do TLS" → plaintext retry. Nothing escalates `Mode` to `Required` when a pin is set
  (`core/transportpick.go:91`, `cmd/meshghost/main.go:873`). The room code crosses that same leg.
  `docs/security.md` ("refused rather than trusted") is untrue in both senses. See D2 for the decision.

- [x] **A5 HIGH — `CloseGracefully` degrades to a RESET for every non-TLS client.**
  `transport/transport.go:558-563` needs `CloseWrite`; `grep -rn CloseWrite netx/` returns **nothing**.
  `limitedConn` (`netx/limit.go:83`) and `prefixConn` (`netx/tlsx/tlsx.go:415`) both embed `net.Conn`
  as an interface. The relay applies `LimitListener` unconditionally, so every accepted conn is
  wrapped and every reject reason dies in the reset. Third instance of this wrapper bug
  (2026-09-05, 2026-09-06). Verified by me.
  **Must land with A6** — see the note there.

- [x] **A6 HIGH — A rejected hello is not terminal; the drain can complete a real join.**
  `relay/relay.go:1081-1091` (`rejectAndClose`) + call sites `:1412,1420,1433,1451,1463,1468,1503`.
  The rate-limit path latches (`rateRejected`); no handshake path does. `CloseGracefully` keeps
  reading and dispatching for the 2 s drain, so a second hello on a rejected connection re-enters the
  whole hello block — reserving a `max_clients` slot, minting a `player_id`, and broadcasting a `Join`
  over a half-closed socket (phantom spawn + despawn ~2 s later for every real peer).
  **A5 and A6 currently mask each other**: plaintext clients get the reset (no reason), TLS clients get
  the drain (phantom join). Fixing A5 alone exposes A6 to everyone.

- [x] **A7 HIGH — Only `hello` is gated by the one-adapter admission check.**
  `core/bridgeserve.go:209-257`. `local_state`, `replay_control`, `player_frozen`, `event`, `lease`,
  `escrow`, `world` dispatch off any bridge connection with no `nd == c.attachedAdapter` test.
  Any local process on 7778 can speak as the player to the room, read every peer's position/area
  continuously, and drive recordings. Reverse direction: bind 7778 first and both compiled adapters
  attach to whatever answers, unverified. Found independently by two agents + the security trace.
  Also makes `c.lastChaserOfferMs` (`core/recorder.go:258`) a real data race — its justification
  ("runs on the one goroutine that delivers adapter frames") is falsified by this path.

- [x] **A8 HIGH — A shared replay zip is an unbounded decompression bomb.**
  `core/replay.go:159-186` accumulates every entry with **no cap on entry count**; only per-clip
  `replayMaxSamples` (2,000,000) applies, and the roster cap is checked long after everything is in
  memory. Measured: `{}` × 2M gzips to 5,891 B; `protocol.State` is 128 B ⇒ ~256 MB per entry.
  A ~240 KB zip asks for ~10 GB. `StartReplays` runs automatically on adapter attach.
  (Zip-slip itself is genuinely absent — nothing is extracted. That trace is clean.)

---

## B. One missing bound, three symptoms

- [x] **B1 HIGH — `protocol.ValidateState` never bounds `Timestamp`.**
  `protocol/limits.go:227-263` checks position, area, anim, orientation, extras — not the timestamp.
  Three agents found three separate failures from this one gap:
  - [x] **B1a** `core/replay.go:508-518` — `time.Duration(due-now) * time.Millisecond` overflows above
    ~9.2e12 ms; the wrapped value is negative so the 50 ms clamp does not fire, `time.After` returns
    immediately, and the playback goroutine spins a full core until `StopReplays`. Same overflow makes
    `duration()` negative, so every restart/rewind logs "fast-forwarded past the end" and terminates.
  - [x] **B1b** `core/interp.go:131` + `core/remotes.go:188` — one future-stamped sample becomes the
    permanent newest, collapsing the buffer to the 2-sample floor and making that peer immune to
    stale pruning: a frozen ghost with no despawn path for the rest of the session.
  - [x] **B1c** the non-hostile version is plain clock skew: a peer >3 s slow is deleted and recreated
    every tick (spawn/despawn flicker); >3 s fast edge-holds permanently.
  Fix: bound the span in `parseReplay` next to the monotonicity check, and bound `Timestamp` in
  `ValidateState`.

---

## C. Bounds computed on unescaped bytes

- [ ] **C1 HIGH — The 2026-09-01 `maxWelcomeRoster = 32` fix is reopened at 21 members.**
  `relay/relay.go:536` + `contract.md:783`. The sizing argument counts bytes in hand (~60/nametag);
  `SanitizeDisplayName` permits `&`, `<`, `>` (graphic ASCII) and `encoding/json` with HTML escaping
  renders each as 6 bytes ⇒ ~173 B per entry. Measured with the real code: **3927 B at 20 members,
  4115 B at 21, 6183 B at the cap of 32**, against `MaxLineBytes` 4096. Past that the joining core's
  scanner dies with "token too long" — the original incident at a fifth of the player count.
  `TestBigRoomWelcomeStaysUnderLineLimit` misses it because its fixture is unescaped ASCII (2151 B).

- [x] **C2 HIGH — A `ValidateState`-passing state can exceed `MaxLineBytes`, with no send-side check.**
  Measured: maximal-but-legal state + `prev` = **4167 B** envelope. `ValidateState` has three call
  sites, all on receive. `transport.NDJSONConn.Send` never checks length on write. The relay's read
  loop turns it into `bufio.ErrTooLong` and drops the connection **with no reject**, so the core
  reconnect-loops under a new `player_id` each cycle. Redundancy (`prev`) is on by default at 15 Hz.
  One-line test fix available: assert `len(wire) <= MaxLineBytes` in `FuzzValidateStateIsStableAcrossTheWire`.

- [x] **C3 MED — `world_state` authority/key measured with `len()`, not wire length.**
  `protocol/online.go:808-814` uses `ValidOpaqueString` for `Authority`/`Key` while the blob correctly
  uses `JSONWireLen`. A maximal `world_state` is **2075 B, not 1115** — over `MaxDatagramBytes` (1200),
  so every such message is silently undeliverable to udp/quic-datagram peers.
  `contract.md:616` says every one of these bounds is measured on the wire.

- [x] **C4 MED — `prev.orientation` bypasses the nesting cap.** `protocol/prev.go:195` checks
  `JSONWireLen` only, so a 240-byte `[[[...]]]` is rejected as `state.orientation` and accepted as
  `prev.orientation`; `ApplyPrev` then hands the adapter a reconstruction `ValidateState` would reject.
  Both Lua adapters cap at 64 levels and would refuse it; C#/C++ have no cap. One line closes it.

- [x] **C5 LOW — `Hello.NameColor` is the one hello string outside `ValidateHelloFields`.**
  `protocol/online.go:384-396`. Harmless today only because `SanitizeNameColor` refuses anything not
  4 or 7 bytes. `contract.md:1003` claims every hello string field is bounded.

---

## D. Needs the user's judgement (do not fix unilaterally)

- [~] **D1 (ANSWERED: scanners fixed by me; binaries at next rebuild) — How to stop shipping the embedded strings.** Options: rebuild UE4SS with
  `--remap-path-prefix` / `/PDBALTPATH`, add `<DebugType>none</DebugType>` + `-pathmap` for the C#/C++
  DLLs, or stop tracking the prebuilt binaries entirely. Has release/distribution consequences, and
  the strings are already in git history either way (this only stops shipping them forward).

- [x] **D2 (ANSWERED yes, DONE) — Should a set `tls_fingerprint` force `Mode = Required`?** It is clearly the intent, but it
  turns a currently-connecting setup into a refusing one for anyone who pinned against a relay that
  later stopped serving TLS. My recommendation: yes, and say so in the log line.

- [?] **D3 (ANSWERED: ghosts should NOT collide; adapter work pending) — `cosmetic` is honoured by zero of four adapters, and Emerald/Crystal make ghosts solid
  on purpose** (`meshghost_crystal.lua:1730`, `meshghost_emerald.lua:4202`). So your own chaser/replay
  ghost blocks you in a solo session. The contract says a cosmetic ghost is never solid, whatever
  `ghost_collision` says. Fixing it changes what the player sees ⇒ your call on intent first.
  `packaging/release/README.txt:402` currently promises the opposite of the behaviour.

- [?] **D4 (ANSWERED: port walking is fine, leave it; see the new N2) — All four adapters branch on the reject reason, and the heuristic is inverted.**
  `contract.md:78` forbids branching. Every *permanent* refusal string contains "relay"
  (`core/core.go:48`), and the only one that does not is `"busy"` (`core/bridgeserve.go:91`). So a wrong
  room code / version mismatch is treated as "relay briefly down" and retried forever, silently.
  ADR 0050 already deleted the transient case the branch was written for. Fixing it changes port-walk
  behaviour on a rejected hello — and the comment at `BridgeClient.cpp:487` says the current shape cost
  a 0.9.9 user their session, so this needs your call, not mine.

- [?] **D5 (ANSWERED: go ahead, opt-in flag first) — netsim's fault model is milder than "bad wifi", and ADR 0046's 450 ms rests on it.**
  `cmd/meshghost-netsim/main.go:357` is memoryless Bernoulli with no burst state. At the no-arg
  profile (5% loss, 15 Hz, 66.7 ms spacing) that is a 200 ms triple-gap every ~9 min and a 267 ms quad
  **once every ~3 h**; real bad wifi loses 200-400 ms in bursts many times a minute. The only correlated
  outage is the 1 s partition every 45 s — an order of magnitude longer than any interp value, so it
  produces hold-and-jump, not stutter. **Nothing in the profile exercises the 150-500 ms correlated-gap
  regime an interp buffer is sized for**, which is what ADR 0046's ladder was judging. Error direction
  is that 450 ms may be *under*-sized. Also: the partition is global+simultaneous, so "one peer drops
  while the room keeps moving" has never been produced; and `-reorder-delay` 60 ms sits below 15 Hz's
  66.7 ms spacing, so the documented 3% reordering mostly does not reorder (it was sized for 20 Hz).
  Needs a game and your eyes, not a code fix.

- [-] **D6 (ANSWERED: by design, DROPPED; contract text corrected) — `game_version` has not moved in any adapter since 2026-08-15/25**, across v1.0.0 → v1.2.1.
  Pseudoregalia `"phase7.7"`, TEVI `"0.2.0"`, Emerald `"phase8-spawn"`, Crystal `"phase9"`. The relay's
  sticky check works; it is being fed a constant, so the stale-peer mismatch it exists to catch passes
  silently. Policy question: bump per release, or tie to the mod version?

---

## E. Core / client

- [x] **E1 HIGH — An adapter that goes away while the relay is down never disarms the reconnect loop.**
  `core/bridgeserve.go:296-323` gates the disarm on `ownsRelay = c.relayOwner == nd`, but
  `forgetRelaySessionLocked` (`core/relaysession.go:363`) nils `relayOwner` on *every* relay drop — so
  for the whole outage no bridge conn owns the relay. `reconnectWithBackoff` (`:670-684`) never checks
  its adapter is still attached, unlike its sibling `retryRelayForSoloAdapter` (`:705-710`).
  Result: the core rejoins the room with the surviving resume token, no game attached, and heartbeats
  keep it there forever — a roster seat that never leaves. Verified by me (both halves).
  Found independently by two agents.

- [x] **E2 HIGH — The stuck-adapter verdict never closes the socket.**
  `core/adapterwriter.go:201-209` sets `closed`, logs, calls `onDead` — and nothing closes `nd`.
  `grep '\.Close()' core/bridgeserve.go` returns only the relay conn and the rejected-hello path.
  The mod keeps a healthy socket, sends `local_state` forever, receives nothing ever again, and its
  reconnect logic (keyed on socket close) never fires. Strictly worse than the 2026-09-06 lockout,
  where the game at least saw a RESET and came back in 150 ms. Verified by me.

- [x] **E3 HIGH — `finishBridgeTeardown` acts on a pre-release snapshot and can kill the successor.**
  `core/bridgeserve.go:283-358`. `releaseAdapterSlot` frees the slot and returns a captured
  `ownsRelay`; the teardown then closes that relay before re-reading ownership, and its successor
  check is a separate non-atomic `c.mu` section. The 2026-09-07 `go c.finishBridgeTeardown(...)`
  added unbounded scheduling latency between snapshot and act. A relaunch inside the window loses
  its relay session (peers see leave+rejoin under a new `player_id`), chasers, replays and recording.

- [ ] **E4 MED — `transportDialFailures` is never reset**, contradicting its own doc at
  `core/core.go:948-963` ("Reset by a successful dial"). Verified by me: `grep` over all non-test Go
  finds only the increment and the map init. So "two CONSECUTIVE failures" is "two ever", and quic is
  condemned for the process lifetime — dropping the session onto tcp, which is where E5 bites.

- [ ] **E5 MED — A relay write blocks the adapter's frame goroutine.** `core/sending.go:150-174` →
  `sendState` is called from `onAdapterFrame`, which runs on the bridge connection's read loop. On tcp
  `SendUnreliable` falls through to a blocking `Send` with a 10 s deadline, so a relay that stops
  reading stalls the bridge reader — and the game's next write blocks on its main thread. The
  core→adapter direction was made non-blocking on 2026-09-07; this direction was not.

- [x] **E6 MED — Aged-out peers are removed from `c.remotes` but never from `c.roster`/`c.remoteNames`.**
  `core/remotes.go:187-194` vs `core/remotenames.go:38-50`. After 512 distinct ids on a transport where
  peers vanish without a goodbye, `admitToRosterLocked` refuses everything silently: new players
  invisible, chasers refused, `PeersKnown` pinned at 512 with `PeersRendered` 0, and no log line.

- [x] **E7 MED — A permanent reject can be lost to a race and retried forever.**
  `core/relaysession.go:283-299`. The relay writes `Reject` then closes, so `reject` (cap 1) and `gone`
  can both be ready; Go picks uniformly. ~50% of the time in that window the error is a plain
  "dropped before the welcome arrived", not a `*RejectError`, so `isPermanentRejectReason` never runs
  and a wrong room code retries every 15 s for the life of the process.

- [x] **E8 MED — The post-handshake `Reject` reason is swallowed.** `core/relaysession.go:867-881`:
  nobody reads `reject` after the handshake, but the channel is buffered and empty, so the send
  succeeds and the `default:` branch that logs the reason is dead code. A mid-session rate-limit shows
  only "relay disconnected: EOF".

- [x] **E9 MED — `nowMs` steps backwards on a relay drop in a `clock.v1` room.**
  `core/relaysession.go:380-387` clears the offset *and* the `lastNowMs` clamp together, defeating the
  monotonicity `core/online.go:127-151` calls load-bearing. In a +5 s room the chaser is fed nothing
  for 5 s, exceeds `replayGapSeamMs`, and the whole pack despawns/respawns.

- [x] **E10 MED — A pause longer than `RemoteStaleAfter` despawns the chaser pack** — the thing
  ADR 0053 set out to prevent. `core/remotes.go:185-194` ages out on the **wall** clock with no local-peer
  exemption, while `gameplayNowMs` stands still during the freeze. `TestChaserHoldsWhileThePlayerIsFrozen`
  freezes for 400 ms; raise it past 3 s and it fails.

- [ ] **E11 MED — No discontinuity guard except `area_id`.** `core/interp.go:357-373`. A same-area
  teleport (death → checkpoint respawn in one room) is rendered as a straight-line glide through
  geometry at ~8000 units/s. No distance or speed test exists anywhere in `core/`.

- [x] **E12 MED — `c.writers` grows without bound.** `core/bridgeserve.go:685-707`. Every
  `sendToAdapter` caller reads `nd` under `c.mu` then releases it before sending (deliberately), so
  `writerFor` can register a writer for a connection `dropWriter` already removed. The entry is never
  deleted. `TestBridgeWritersDoNotOutliveTheirConnections` asserts this invariant but closes cleanly
  and never exercises the race.

- [x] **E13 MED — A marshal bug is reported and handled as a dead socket.**
  `core/bridgeserve.go:411-413` does not discriminate `errBridgeMarshal` (documented as "a bug in this
  process, never a peer's doing") from `errBridgeGone`, so a per-message defect tears down the whole
  session and points the next debugger at the socket layer.

- [x] **E14 MED — Extrapolation: `minVelocitySpanMs` does not protect the damped/accelerated path.**
  `core/interp.go:463-555`. `PredictDamped`/`PredictAccelerated` discard the guarded outer baseline and
  use `midSample`, which under change-suppression *is* the 1 ms resume bracket. Worked example in the
  agent's report: a standing peer that starts walking is fired ~2 s of walking (damped) or clean off
  the level (accelerated) in one frame. Gated behind `-extrapolate`, which ships off.

- [x] **E15 MED — The orientation bracket has no lower span bound and uses a different pair than
  position.** `core/interp.go:288-300` hard-codes the adjacent pair while position searches for the
  longest usable baseline, and applies only the upper guard — so `T` is unbounded as span → 1.
  Worked example: body still, head whipping through ~101× the turn. Also `-extrapolate` only.

- [x] **E16 MED — `Core.Predict`'s zero value is `PredictAccelerated`, not `PredictLinear` as
  documented** (`core/interp.go:464-466` vs `core/core.go:596-599`). Masked by `cmd/meshghost`
  defaulting the flag, so only in-process/embedder/fuzz `Core` literals get the mode that failed on
  screen twice.

- [x] **E17 MED — A failed recording write never tells the adapter.** `core/recorder.go:228-236`
  calls `closeLocked()` and nothing else — no `pushRecordingState`, no `rearmTap`. The on-screen REC
  indicator stays lit for the rest of the session and the run is lost silently.
  **The obvious fix deadlocks**: `rec.mu` is held there, and `pushRecordingState` takes it again
  (the 2026-09-04 hang at `bridgeserve.go:576-582`). The push has to go after the unlock at `:236`.

- [x] **E18 LOW/MED — `replayFileName` loops forever on any non-`ErrNotExist` `Stat` error**
  (`core/recorder.go:526-531`) — while holding `rec.mu`, so `recordLocal` blocks on every adapter frame
  and the bridge wedges.

- [x] **E19 LOW — `SaveLast` leaves a partial file on every error path** (`core/recorder.go:685-712`,
  no `os.Remove`), and `replayLast` picks the newest by mod time — so the next `replay_last` selects
  the corpse. A truncated `.gz` has no footer and is refused whole (the ADR 0051 failure).

- [x] **E20 LOW — Pack shutdown joins are sequential on the bridge hello goroutine**
  (`core/chaser.go:385-391`, `core/replay.go:816-824`): 1 s each, uncapped count, so a starved pack can
  hold the attach path for minutes with the game already told `bridge_ready`.

---

## F. Relay / transport

- [ ] **F1 MED — `resumeInto` leaks an outbox goroutine** on the member-missing early return
  (`relay/resume.go:289-297`): `newOutbox` spawns `go o.run()` before the `r.members` check and the
  `!ok` path never closes it. The window is real — `finishLeave` calls `r.remove` *before*
  `forgetSessionsOf`.

- [ ] **F2 MED — A resume snapshot is unbounded against a 256-line outbox.** `relay/resume.go:364-378`
  emits one message per lease (≤256) + per world authority (≤256) + per escrow + the state snapshot,
  all reliable; `maxOutboxLines` is 256 and a reliable line at a full queue closes the connection.
  One member holding many leases can make *another* player's resume disconnect-loop.

- [ ] **F3 MED — `r.escrows` has no total bound** (`relay/escrow.go:62-77`): only *live* exchanges are
  counted and terminal records are retained 60 s, so open/abort at the rate cap grows the map to
  ~3,600 entries — and `escrowTableFullLocked` scans the whole map on every open, under `r.mu`.

- [ ] **F4 MED — Resume loses nametags in both directions.** `relay/resume.go:275-291` builds the new
  `Client` without `nametag`, and its `welcome` omits `Nametags` (the fresh-join path sets both).
  A named player who blips is nameless to every later joiner for the rest of the session.

- [x] **F5 MED — No per-member lease cap** (`relay/leases.go:65-72`) — escrow got one in the 2026-09-02
  review, leases did not. Already listed as an accepted risk in `docs/security.md`; noting the fix
  shape here (`MaxLiveEscrowsPerMember`'s shape) since it is the same one-liner.

- [x] **F6 MED — Reliable control-plane messages to a suspended member are dropped and never
  replayed.** `relay/relay.go:441` skips suspended members; `resumeSnapshot` replays state/leases/
  escrows/world but **not events**, while `contract.md:474` calls the event plane "reliable, ordered".
  Undetectable by the client because events are addressed, so no `seq` gap shows.

- [x] **F7 MED — `FallbackUDPAddr` hardcodes a loopback host.** `cmd/meshghost-relay/main.go:172`
  returns `127.0.0.1:7780` wholesale, discarding the operator's bind interface, and the startup banner
  then instructs forwarding 7780 and advertises it to remote clients. Four places in the shipped
  README repeat the instruction (`packaging/release/README.txt:524,535,980,1021`, `docs/config.md:50`).

- [x] **F8 MED — No signal handling in the relay at all** (`cmd/meshghost-relay/main.go:616-628`, no
  `os/signal` import): Ctrl+C sends nothing on **quic, the shipped default**, so every client waits out
  its ~17 s idle timeout with ghosts aged out at 3 s.

- [x] **F9 MED — `sniffListener` turns any Accept error into a permanent silent hang.**
  `netx/tlsx/tlsx.go:449-458`: the loop returns on the first error and delivers it once, so
  `relay.Serve`'s temporary-error retry (added 2026-09-02 for EMFILE) parks forever on `l.out`.
  The relay looks alive and accepts nothing, with one misleading "retrying" line. `auto` is the default,
  so this wrapper is always in the path.

- [x] **F10 MED — UDP admission blocks the single demultiplexer read loop.**
  `netx/udpconn/listener.go:166-169` does a blocking send into a cap-16 accept channel *on the one
  goroutine that reads the socket for every connection*. Compare `deliver()` (`conn.go:477`), which is
  deliberately non-blocking for exactly this reason.

- [x] **F11 MED — The udp client accepts its cookie and token from any source address.**
  `netx/udpconn/dial.go:25,50,76` — the socket is unconnected and both handshake reads discard the
  sender. An off-path attacker spraying the ephemeral range during the connect window can make the
  client adopt an attacker-chosen token; every later datagram is then dropped by the real relay and the
  player sees a session that connects and never works.

- [ ] **F12 MED — `MaxOpenConns` does not bound QUIC.** `netx/quicconn/quicconn.go:403-430`:
  `awaitStream` holds a fully handshaked conn for up to 10 s before it ever reaches `LimitListener`,
  which counts only what `Accept()` returns. `LimitListener`'s doc claims handshaking connections count.

- [ ] **F13 MED — Introspection counters are recorded before the per-recipient receive-rate gate**
  (`relay/introspect.go:255-263` vs `relay/relay.go:811-818`), so `Recipients`/`PayloadBytes` report
  traffic that was never sent — up to ~30% high for a peer using `max_receive_hz_per_player`.
  The file's own comment forbids exactly this.

- [ ] **F14 LOW — The resume path builds an unbounded `Welcome` roster**, bypassing `maxWelcomeRoster`
  (`relay/resume.go:310-322`); it omits `Nametags` (per F4) which is what currently hides it.

- [x] **F15 LOW — `dropIfEmpty` takes `r.mu` under `s.mu`** (`relay/relay.go:1185-1197`), contradicting
  the invariant `relay/introspect.go:203-208` states it relies on. Latent, not live.

- [x] **F16 LOW — `TransportName` is hidden by the limiter wrapper** (`netx/limit.go:59-63`), so the
  shipped relay logs every udp and quic client as "tcp" — in the per-client label a remote tester is
  asked to send back.

- [x] **F17 LOW — `netx/limit.go:75` prints the limit twice and never the open count**
  (`l.max, l.max, n` into a `%d already open (limit %d); %d refused` format). Verified by me.

- [x] **F18 LOW — A udp `Conn`'s write deadline is set on the listener's shared socket**
  (`netx/udpconn/conn.go:228-237`), so two concurrent writes clear each other's deadline.

- [x] **F19 LOW — `retryLoop` abandons all pending retransmits on one transient write error**
  (`netx/udpconn/conn.go:274-278`), so `maxRetries` exhaustion never fires and a vanished peer lingers
  to the 60 s idle timeout.

- [ ] **F20 LOW — `handleWorld`'s op dispatch fails open** (`relay/world.go:88,107,114-123`): the entity
  cap and the create-must-be-reliable rule test `Op == WorldSet` while `default` treats anything
  not-`WorldDrop` as a set. Currently unreachable thanks to `ValidateWorld`; free to close.

- [ ] **F21 LOW — `-room-code` as a flag puts the shared secret in the process command line**
  (`cmd/meshghost-relay/main.go:242-245`). Worth a line in the flag help.

---

## G. Config / CLI

- [x] **G1 MED — `rotatingLog` loses its 1 MiB cap permanently after one failed rename.**
  `internal/cfg/cfg.go:139-155` restores `r.size` from a re-`Stat` after the rename, so if the rename
  failed the size is still over the cap and *every* subsequent write does Close+Rename+Open+Stat.
  The trigger is ordinary: two game copies from one folder share `meshghost.log` (the contract calls
  that the standard test setup) and Go opens without `FILE_SHARE_DELETE`. Same code is the relay's
  disk bound under ADR 0044.

- [ ] **G2 MED — An unknown/typo'd config key does nothing, silently.** `cmd/meshghost/main.go:323`.
  Not fixable with `DisallowUnknownFields` (the same file legitimately carries adapter-only keys), so
  it needs a curated known-key audit. `internal/cfg/cfg.go:246-250` already names this class as having
  cost a real tester their room code.

- [x] **G3 MED — `max_receive_hz_per_player` is never validated client-side.** Flag help says
  "Valid range 10-100"; `cmd/meshghost/main.go:935` assigns it raw and the relay clamps silently.
  `protocol/limits.go:181-186` explicitly tells callers to compare against the clamp and warn.

- [ ] **G4 MED — Nothing closes a recording on Ctrl+C or a closed console.** No `os/signal` in
  `cmd/meshghost`; the ADR 0051 fix went into the `-exit-with-pid` path only. Running the core by hand
  is a *supported* configuration for AV-affected players (`crystal/FLAGS.md:23`), and a gzipped
  recording without its footer is refused whole.

- [-] **G5 (skipped: parent_windows.go, deliberately not touched this pass) LOW/MED — One transient `OpenProcess` failure kills the core mid-session**
  (`cmd/meshghost/parent_windows.go:36-38`, single sample, no retry). Reverse direction unhandled too:
  a recycled parent pid keeps an orphan core alive holding the bridge port.

- [x] **G6 LOW — A negative `-exit-with-pid` logs a watch that never happens** (`main.go:998` guards
  `!= 0`, `:484` guards `<= 0`).

- [x] **G7 LOW — Duplicate hotkey chords are undetected** and reported as "another program may already
  own this chord" (`main.go:957-964`).

- [x] **G8 LOW — `replay.save_last` is the one duration with no ceiling** (`core/recorder.go:123-130`);
  every neighbouring knob is clamped.

- [x] **G9 LOW — The "(the shipped defaults)" log line ignores `predict`**, and the release ships
  `damped` while the flag defaults to `linear` (`main.go:911-916`).

- [x] **G10 LOW — `ApplyDespiteBadValue` names only the first mistyped value** while silently dropping
  the rest, and prints Go type names (`main.replayFileConfig`, `[]string`) to non-developers
  (`internal/cfg/cfg.go:261-301`).

---

## H. Tests and instruments

- [x] **H1 HIGH — `waitAdapterDrained` does not wait for the write; the flake is live.**
  `core/ghostcollision_test.go:286` polls `queueLen() == 0`, but `adapterwriter.go:246-252` sets
  `w.q = nil` *before* writing the batch. **Reproduced: `-count=500` → 9 failures, `-count=1000` → 6,
  no `-race`, fast box.** CI runs `-race -count=3` on a slower runner. The negative assertion in the
  same test can no longer catch its own regression, and calling it on a connection with no writer
  creates one and returns 0 immediately.

- [x] **H2 HIGH — `ci-fuzz.sh:44` exits 0 when the target name matches nothing.** `-fuzz` is a regexp;
  a non-match prints "no fuzz tests to fuzz" and PASSes. Verified empirically. Renaming a fuzz target
  silently deletes a 45-60 s campaign per push with CI green. One-line fix: grep for that string.

- [x] **H3 HIGH — `bridge_test.go:31-40` pins 8 of 18 bridge wire names.** Missing `remote_name`,
  `recording_state`, `player_frozen`, `event`, `lease`, `lease_state`, `escrow`, `escrow_state`,
  `world`, `world_state` — all hard-coded as literals in the adapters. The mechanical backstop
  (`preflight.ps1:1707`) runs in `docs.yml`, which a `.go` push does not trigger. Same gap in
  `internal/gameblind`'s `bridgeSamples` (`gameblind_test.go:387-395`), so those payloads' field lists
  are not frozen either.

- [x] **H4 HIGH — No test asserts the relay emits any reject reason by value.**
  `ReasonServerFull`, `ReasonProtocolVersionMismatch`, `ReasonInvalidRoomCode`,
  `ReasonGameVersionMismatch`, `ReasonGameMismatch` appear in no `_test.go`. The core side tests the
  *mapping* over constants. `core/core.go:87-97` classifies anything unrecognised as **permanent**, so
  a drift in `ReasonServerFull` makes clients stop retrying forever, with the whole suite green.

- [ ] **H5 MED — TEVI's fuzz harness asserts nothing.** `BridgeFuzz.cs:332` sends
  `anim_time`/`temp_pause`; the decoder reads `extras["anim_t"]`/`["pause"]`
  (`BridgeClient.cs:727-728`). Every value decodes to null, so the `FiniteOrNull` loop inspects nothing
  and prints "0 non-finite (want 0)" unconditionally. Verified by me. The file's own header cites the
  2026-09-03 "passed while exercising nothing" lesson. No test feeds `room_x`, `room_y`, `trail`,
  `weapon_rgba`, `vfx_*` at their real keys either.

- [ ] **H6 MED — `expectWelcome` asserts the Welcome is the FIRST message** at ~145 call sites
  (`relay/relay_test.go:83`), the exact helper `testing.md` records as a 2026-08-16 CI failure that
  passed locally three times. `awaitWelcome` (the fix) is used ~5 times.

- [ ] **H7 MED — `MaxLeasesPerRoom`/`LeaseTooMany` has zero coverage** while its twin `WorldTooMany`
  is asserted (`relay/world_test.go:600`).

- [x] **H8 MED — Every bridge-ordering test runs with an empty queue**, because `fakeAdapter` drains
  instantly — so coalescing never happens and the ordering they assert is the trivial case.
  `adapterQueueCap`, `forgetPending` and the `behind → recovered` transition have no coverage at all;
  `TestTheSlowAdapterIsReportedOnceEachWay` builds the writer with **no `run()` goroutine**.

- [x] **H9 MED — Every test double aliases `SendUnreliable` to `Send`** outside `relay/world_test.go`,
  so moving a control message onto the lossy plane is invisible to the whole suite.

- [x] **H10 MED — `netx/conformance_test.go` never sends on the unreliable plane** — the most
  transport-divergent promise in the contract, in the file whose stated job is to pin them.

- [x] **H11 MED — `WriteTimeout` has no test anywhere**, and line limits are tested only at the
  no-delimiter extreme (nothing at exactly `MaxLineBytes`, nothing at `+1` *with* a delimiter,
  nothing for resync). Same shape in `protocol/prev_test.go:131` — every case is `cap+1`, none is `cap`,
  so flipping `>` to `>=` silently rejects legitimate states and stays green.

- [x] **H12 MED — `expectNothingOfType` is wall-clock-bounded with no positive control**
  (`relay/online_test.go:111`, 20 uses): the assertion gets *weaker* on a slower machine, so it flakes
  toward false PASS, and the helper drains every non-matching envelope out from under later assertions.

- [x] **H13 MED — `fakeAdapter.despawns` is a blocking send (cap 16) inside the read-loop callback**
  (`core/core_test.go:158`), while `StopChasers` drops 99 or 512 peers with nothing draining.

- [ ] **H14 — The fake adapter bypasses the bridge entirely.** `RunAdapter` → `tickRenders` calls
  `adapter.RenderRemote` as a direct Go method call, not `sendToAdapter`. No marshal, no queue, no
  coalescing, no backpressure, no line framing. Structurally incapable of finding a bridge ceiling —
  which is why it hid the ~350-ghost one. Its headline renders/s is `tick_rate × remotes` (renders fire
  per tick per known remote regardless of arrivals), i.e. a restatement of the flags, and the ticker
  divisor is nominal so the number *inflates* under load.

- [ ] **H15 — The synthetic ghost is a constant-speed circle** (`cmd/meshghost-fakeadapter/main.go:139-191`):
  no stops, no turns, no landings, C^∞, sampled on the tick. The most flattering possible input to every
  interpolator, against `dev-scripts/README.md`'s own "judge the CORRECTION" rule. Extras are a static
  map cloned once, so suppression rates measured here are meaningless.

- [ ] **H16 — netsim tcp gets almost none of the fault model**: `pumpTCP` sleeps inline in one goroutine
  per direction, so at the default 100 ms latency the path is capped at ~10 read→write cycles/s and a
  15 Hz stream is clumped by the proxy rather than delayed. Loss/reorder/duplicate are tcp-skipped by
  design. Any verdict where the negotiated transport was not read from the log may be a clumped-delay
  test wearing a hostile-network label.

- [ ] **H17 LOW — The checkers attach after the cores are connected** (`main.go:628-644` vs `:566`),
  an unsynchronised field write against a live reader goroutine plus a blind window covering every
  client's connect.

- [ ] **H18 LOW — Nothing fails a netsim run that lost peers**; `summarize` catches total silence, not
  attrition, so a soak that loses half its peers prints "no invariant violations" and exits 0.

- [ ] **H19 LOW — Only 4 of 43 `core` test files use `newFakeClock`**; `core_test.go` alone has 29
  `time.Sleep`s. `preflight.ps1:657` exempts `_test.go`, so nothing pulls them along.

---

## I. Adapters

### Pseudoregalia

- [ ] **I1 HIGH — A peer can remote-kill another player's bridge with 18 bytes.**
  `BridgeClient.cpp:466-485` classifies every line by bare substring **before** parsing and with no
  `continue` between the malformed counter and the checks — so the `"bridge_ready"` / `"reject"` /
  `"relay"` searches run over `render_remote` lines too. `Orientation` is `json.RawMessage`
  (`protocol/prev.go:55`), peer-authored raw JSON bounded only by 256 B and depth 32.
  `"orientation":{"reject":"relay"}` ⇒ victim closes the bridge, parks 10 s, drops every ghost, and
  logs that *the relay* is unreachable. Verified by me.

- [ ] **I2 HIGH — `~Plugin` unregisters 7 of 11 detours** (`Plugin.cpp:9999-10030`), all capturing
  `this`: `init_game_state_pre`, the fade guard (whose `UFunction*` is a local that is **never stored**,
  so it is structurally impossible to unregister), the damage guards (up to 3, and the lambda takes
  `state_mutex` and walks `remotes`), and `pause_reset_hook_id`. Found independently by two agents.
  **Plausible root cause for `UNVERIFIED.md:2062` — "Fatal Error! on game exit, never root-caused."**

- [ ] **I3 HIGH — `lerp_angle_deg` produces NaN from two finite peer angles.**
  `Plugin.cpp:3327-3338`: the inputs are `isfinite`-guarded but `to - from` is not, so two finite
  doubles near ±DBL_MAX overflow to inf and `fmod(inf, 360)` is NaN — written straight into an FRotator
  by `K2_SetActorLocationAndRotation`, which does no NaN check. `GHOST_ROTATION_SLERP` is the shipped
  path. The 2026-09-02 review closed this on the raw orientation path and left the bracket path open.

- [ ] **I4 HIGH — Ghost released by the in-tick staleness check keeps all its component handles.**
  `Plugin.cpp:20418` and `:20505` null `remote.ghost` but do not clear `nametag_component`,
  `vfx_components`, `weapon_*`, `projectile_component`, `recent_one_shot_components` — which
  `release_ghost`/`release_all_ghosts` both do. The next `ensure_ghost_spawned` then sees a stale
  non-null pointer and calls `ProcessEvent` on freed memory: identical to the symbolized 2026-09-01 AV.
  `UNVERIFIED.md:1728` records this for `release_all_ghosts` only, which *is* fixed.

- [ ] **I5 HIGH — `sweep_afterimage_outlines`' "no ghosts" branch calls into freed components.**
  `Plugin.cpp:20138-20149`: raw `ctx.Context` pointers guarded only by a key comparison against
  `afterimage_owners`, and the liveness prune lives in the *other* branch. `release_all_ghosts` clears
  `afterimage_pos_by_ptr` but not `afterimage_owners`/`afterimage_pending_reenable`.

- [ ] **I6 HIGH — `player_frozen` is marked sent before it is sent, from the wrong thread.**
  `Plugin.cpp:16297-16303`: `player_frozen_sent` is flipped before the call, `send_line` returns `true`
  on `WSAEWOULDBLOCK` and drops the line, and the result is discarded — on an edge-triggered message
  that is never re-sent. It is also the *only* `bridge->` use inside `game_thread_tick`; all thirteen
  others are on the UE4SS thread, and `send_line` has no mutex. A dropped freeze = the chaser clock
  runs through the whole pause, which is the drift ADR 0053 exists to fix.

- [ ] **I7 — Bitfield audit (the queued "FIRST THING next session"): done.**
  **64 call sites, not 65** — `Plugin.cpp:3227` is prose inside a doc comment. `mg_read_bool` itself is
  **correct**, verified against the submodule's `FBoolProperty::GetPropertyValueInContainer`
  (right byte offset *and* mask). Premise correction: Blueprint-declared bools on this build are
  **not** packed (`VERIFIED.md:2418`, `PLAYER_FIELDS.md:281`), so the split is engine-property = unsafe,
  BP = safe. **38 UNSAFE / 26 SAFE / 0 unknown.** Live-in-shipped-path, ranked:
  - [ ] `:21595` `bVisible` per ghost per mesh per tick — either a per-frame engine call forever, or a
    ghost body/sword that can never be re-shown.
  - [ ] `:21145` `bIsCrouched` **read and write** per ghost per tick; `pitfalls/method.md:371` records
    that it shares a byte with `bPressedJump`, `bWasJumping`, `bClientWasFalling` and two more on this
    build. The write stamps all of them.
  - [ ] `:23454` `bHidden` **write** `true`/`false` per ghost every 120 ticks, deliberately ungated —
    zeroes the `AActor` flag byte, and if `bHidden` is not bit 0 the intended nudge is a no-op.
  - [ ] `:14669` `bOrientRotationToMovement` **write** `false` once per spawn, ungated — clobbers the
    CharacterMovement bitfield neighbours on every ghost.
  - [ ] `:21678`, `:21777` `bRenderCustomDepth` (the "keeps this cheap" early-out never fires).
  - [ ] `:20306` `bRenderCustomDepth` on afterimage components.
  - [ ] `:4567` `dump_object_property_values` — the already-filed "~30 bools uniformly true" defect,
    still live via the un-gated camera-rig dump at `:13677`. Its sibling `snapshot_scalar_properties`
    was converted; this one and three flag-gated cousins were not.
  Plus 28 more behind dev flags (list in the agent report; `:21454`, `:21539`, `:21641` are the prime
  suspects behind `UNVERIFIED.md:2157` "two subtraction toggles LIE").

- [ ] **I8 MED — `14444`/`14526` corrupts the player pawn's class default object** permanently when
  `ghost_no_overlap` is armed: the saved byte collapses to `true` and the restore writes `0x01`, so
  every other bit in that `UPrimitiveComponent` byte is lost on the CDO — affecting every pawn spawned
  from it afterwards, including the real player after the next level load.

- [ ] **I9 MED — Two of three dev-toggle subtraction sweeps only restore the FIRST ghost.**
  `Plugin.cpp:21425-21475`, `:21491-21551`: the `static` latch is cleared *inside* the per-remote loop.
  With the two-real-peers default setup, one ghost's nametag comes back and the other's stays hidden —
  and the log reports the sweep as complete.

- [ ] **I10 MED — `afterimage_count` is missing from the `is_new_remote` baseline**
  (`Plugin.cpp:16077-16100`), so a peer who has been playing pops in trailing a burst of afterimages
  they never made. The identical bug for land/jump was fixed twenty lines above.

- [ ] **I11 MED — `tick_remote_mirrored_vfx` is O(n²) on a peer-controlled string**, ten times per
  ghost per frame (`Plugin.cpp:11541-11576`): `find(':', pos)` scans to the end of the whole string and
  only breaks early on a match. ~1 KB of commas ⇒ ~4.5 M char scans per ghost per frame, remotely
  triggered, free to the sender, and it looks like the game got slow.

- [ ] **I12 MED — The failed-asset log throttles are defeated by alternating two names**
  (`Plugin.cpp:22815`, `:22905`, `:22920`, `:22507`): the gate keys on equality with the single last
  failed name. A peer alternating two unresolvable paths gets one `Output::send` per ghost per frame.

- [ ] **I13 MED — The mod re-reads and re-parses `config.json` six times per poll, ~7×/s.**
  `Plugin.cpp:23483-23488` → each of six `config_*_value` calls opens and slurps the whole file, and
  they run *before* the `rec_indicator.txt` existence check, so the "one failed file open" comment is
  wrong. Related: `tick_count` is incremented from **two threads** unsynchronised and advances at
  double rate while paused, so several tick-based windows and their commented wall-clock equivalents
  are wrong (`:19590` "~5s" is ~1.5 s).

- [ ] **I14 MED — The fade guard has no ownership test and is not in `BANDAGES.md`.**
  `Plugin.cpp:13766-13809` zeroes `FromAlpha`, `ToAlpha` **and `Duration`** on *any*
  `StartCameraFade` within 10 ticks (~50 ms) of a ghost spawn, while asserting in a comment that real
  fades are untouched. Its sibling camera guard has a primary ownership test and *is* registered.

- [ ] **I15 LOW — `ghost_fixlights_off.txt` is documented in two places and read by no code**
  (the gate at `:16238` reads `ghost_fixlights_on.txt`), so the A/B a developer would run has both arms
  the same. `g_ghost_fix_lights` is also a dead flag.

- [ ] **I16 LOW — The sustained world-spawned VFX branch is unreachable** (`Plugin.cpp:11665-11689`),
  and `world_spawned` silently means "one-shot" — with 22 lines of measured commentary telling a future
  author the opposite.

- [ ] **I17 LOW — `dev_toggle_contains` treats any body containing "all" as a match for every needle**
  (`Plugin.cpp:12321`), so `decouple_off.txt` containing `install`, `wall` or a pasted path arms all
  three skips.

- [ ] **I18 LOW — `STATE_SEND_TRACE` ships ON** (`Plugin.cpp:144`), logging the local player's world
  position every ~1.5 s. Its own justification is dev-rig-only.

- [ ] **I19 LOW — `poll_lines` has no per-call read budget** (`BridgeClient.cpp:415-437`); the 16 KB cap
  is only consulted after every complete line is extracted.

- [ ] **I20 LOW — `BridgeClient.hpp:83-86` documents the reverted "silence is acceptance" behaviour**,
  which `BridgeClient.cpp:99-110` correctly no longer does.

### TEVI

- [ ] **I21 HIGH — The bridge write is a blocking socket write on Unity's main thread with no
  `SendTimeout`** (`BridgeClient.cs:663`, `:561`; default is infinite; only `NoDelay` is set). The
  shipped core can stop reading the bridge for up to 10 s (`onAdapterFrame` → a synchronous relay
  `Send` bounded by `DefaultWriteTimeout`), so the game hard-freezes for seconds with no log line.
  The other three adapters are all non-blocking (`FIONBIO` / `settimeout(0)`).

- [ ] **I22 HIGH — `room_x = -2147483648` defeats the sanity bound and kills `Update()` every frame.**
  `Plugin.cs:378-380`: `Mathf.Abs(int.MinValue)` throws `OverflowException`, and if it did not,
  `int.MinValue <= 100000` passes the bound. Since the 2026-08-28 frame-driven refresh this runs at
  `Plugin.cs:2369`, **outside** `DrainInto`'s per-line try/catch — so `SendLocalState` (`:2392`) never
  runs and the victim vanishes from every other player's screen.

- [ ] **I23 MED — `position` never gets the `FiniteOrNull` treatment** `anim_t`/`pause` got
  (`BridgeClient.cs:720` → `Plugin.cs:691`), so a NaN reaches `transform.position`, `OverlapPoint`
  and `Vector3.Distance`.

- [ ] **I24 MED — The read loop reads the `stream` field, not its own connection's stream**
  (`BridgeClient.cs:418`), so a stale reader can consume a newer connection's bytes — two threads
  splitting one byte stream into two `StringBuilder`s. One-line fix: capture `c.GetStream()`.

- [ ] **I25 MED — The receive buffer has no size cap** (`BridgeClient.cs:415-431`) — Pseudoregalia caps
  at 16 KB and reconnects; `protocol.MaxLineBytes` (4096) is the number to mirror.

- [ ] **I26 MED — UTF-8 is decoded per read chunk** (`BridgeClient.cs:420`), so a multi-byte character
  split across a TCP read boundary becomes U+FFFD on both sides — the line stays valid JSON and is
  silently *wrong*, so a non-ASCII `anim`/`area_id` mutates and that peer's marker disappears.
  One-line fix: hold an `Encoding.UTF8.GetDecoder()` across the loop.

- [ ] **I27 LOW/MED — `DrainInto`'s catch swallows every Unity exception raised by the callbacks**
  and reports it as a malformed bridge message (`BridgeClient.cs:688`, `:811-814`), unthrottled and
  peer-rate-driven.

- [ ] **I28 LOW — Per-connection state is reset after `connected` is published** (`BridgeClient.cs:385`
  vs `:400-401`), so a main-thread tick in the gap can cool a fresh connection's port for 10 s.

- [ ] **I29 LOW — `SweepOrphanGhosts` cannot see inactive orphans** (`Plugin.cs:998`,
  `FindObjectsOfType` excludes inactive in Unity 2021.3) — and map markers are inactive nearly always.

### Emerald

- [x] **Hardest rule: CLEAN.** No `savestate.*`, no `client.*`, no `mainmemory.*`, no ROM writes.
  Every write goes through `w8/w16/w32` into `gObjectEvents`, `gSprites`, the sprite-tile bitmap,
  OBJ VRAM and the shadow-OAM window, gated on `avatarAddrConfirmed` + `inOverworld()` + the
  player object/sprite cross-link. Save blocks are read sources only.

- [ ] **I30 HIGH — A non-string `player_id` permanently kills the frame loop.**
  `meshghost_emerald.lua:2103` admits a peer on truthiness alone; `:9672` then does
  `playerId:match("%-ghost$")` with **no area/tier guard above it**, which raises on a number in
  Lua 5.4. `guardedFrame`'s pcall swallows it, so every tier after that point stops for the rest of the
  session with one throttled line every 300 frames, and no despawn is ever sent. A table id also grows
  `remotes` without bound. This exact case is already a row in `tests/json_fuzz.lua`'s `WRONG_TYPES`,
  whose comment says rejecting it is the dispatch's job.

- [ ] **I31 MED — `w8(d + 0x2a, remote.sanim)` with `remote.sanim == nil`** raises the same way
  (`:6894-6895`); the other three mirror sites are guarded and this one is not.

- [ ] **I32 MED — The savestate OAM sweep bypasses all three gates the hardware tier enforces**
  (`:10878-10885`): not `tiering.hw.on`, not `avatarAddrOffset == 0`, not `inOverworld()`. The slot
  machine and the confetti effect own OAM entries 64-119 (`documentation.md:103-105`), and
  `MESHGHOST_EMERALD_HW_OVERFLOW=0` does not disable this path. The orphan-blob sweep at `:10904-10925`
  likewise has no `inOverworld()` guard, against `despawnGhost:4149`'s own "This is a SHIPPED bug"
  comment.

- [ ] **I33 MED — `recvPartial` has no length bound** and is re-copied through `receive()` every frame
  (`:2256-2262`) — O(n) per frame, quadratic in the stall length, on the emulator thread.

- [ ] **I34 LOW — `chooseSpawned`'s coordinate gate fails open for ~7 s after every load**
  (`:4609-4611`, `xmW == 0` until the self-location scan completes), and `teleportGhost` writes
  `w16(a + 0x0c, mapX + 7)` unbounded.

- [ ] **I35 LOW — `mapGroup`/`mapNum` are read signed on the wire and unsigned for the cross-map key**
  (`:1308-1309` vs `:1800`), so the two would never match for any id ≥ 128. Latent with real map data.

- [ ] **I36 LOW — Per-frame allocation in the painted tier**: `reflectiveSpans` allocates ~35 tables per
  peer per frame (`:10619`, `:1445`); ~700 tables/frame at the 19-peer Route 111 count.

### Crystal

- [x] **Hardest rule: CLEAN.** No `savestate.*` anywhere; every `w8` call site is behind
  `COMPARE.spawnTier` (default false) or `OAM_TIER` (default false), and no write address is ever
  derived from peer data — only bounded values.

- [ ] **I37 HIGH — `extras.face` reaches a bitwise operator with no integer/range guard.**
  `meshghost_crystal.lua:6284` `((o.face or 0) & 3) + 1` — and `:7895` is the only one of seven peer
  numerics that is neither floored nor bounded. In Lua 5.4 `1.5 & 3` and `(1/0) & 3` both raise.
  There is **no pcall anywhere inside `drawOverflow`**, so the shipped drawn tier stops for *all*
  peers and the previous frame's overlay is never cleared. `tests/json_fuzz.lua:317-323` already warns
  that both decoders return non-finite for `1e999`.

- [ ] **I38 HIGH — A partial socket send corrupts the NDJSON stream for the rest of the connection.**
  `:9291-9294` discards LuaSocket's `lastByteSent` and treats every timeout as benign, on a
  non-blocking socket. Emerald (`:1226-1240`) and the C++ `BridgeClient::send_line` both fixed exactly
  this; the comment there spells out the consequence.

- [ ] **I39 MED — `"autostart": false` can never be read.** `scriptDir()` returns **without** a trailing
  separator on all four paths while Emerald's returns **with** one on all three, and the autostart
  block (`:9409-9410`) was copied from Emerald and concatenates `dir .. "config.json"`. All three
  candidates miss and the IIFE falls through to `return true`. Verified by me.

- [ ] **I40 MED — Same missing separator makes the per-game `config.json` never win the core's working
  directory** (`:9519-9523`), while the console line tells the player the opposite. The bridge-port
  scan at `:665-689` searches own-folder *last*, the opposite order, so the two disagree even once fixed.

- [ ] **I41 MED — Two build-specific WRAM addresses bypass the per-build `ADDRESSES` table**:
  `W_OBPALS` (`:2163`) and `MENUBOX` (`:3782`), both used by the shipped drawn tier on the Archipelago
  build, which was *measured* to rearrange WRAM non-uniformly (`:341-347`). Same class as the camera
  pair that `UNVERIFIED.md:807-829` opened and that cost a live mixed-room session.

- [ ] **I42 MED — `classifyRom` cannot recognise V1.1 or speedchoice**, the two builds the adapter
  targets (`:983-998`), so both fall to `unknown` and lose emotes, fishing, jump shadow and Fly landing
  silently — even though the file already records the measurements at `:393` and `:9721-9727`.

- [ ] **I43 MED — The one per-second pacing line that ships reports three constants that can never be
  non-zero**, one of which (`facingFrames.backwards`) is **never assigned anywhere in the file**
  (`:6944-6948`). Prints "0px, 0 backward refused, 0 catch-up frames" in every ordinary session, which
  reads as a clean run.

- [ ] **I44 LOW — The twitch detector is the only per-frame diagnostic in `drawOverflow` with no flag**
  (`:6525-6528`); every neighbouring instrument is gated.

- [ ] **I45 LOW — `rxBuffer` has no cap and only one 4096-byte read per frame** (`:9246`, `:9592`),
  where Emerald loops until the socket is empty.

- [ ] **I46 LOW — The jump shadow claims an object struct nothing ever releases** (`:7371-7401`) and
  stores a struct index `despawnGhost` can recycle — the Emerald underwater-bob shape.
  Spawn-tier only, so dev-path only today.

- [ ] **I47 LOW — A truncated `\uXX` escape drops the whole message** (`:817-823`, unconditional
  `pos + 6` consumes the closing quote), differing from the fix's stated "anything above stays `?`".

---

## J. Contract / docs / packaging

- [x] **J1 MED-HIGH — The shipped README promises two behaviours no adapter implements.**
  `packaging/release/README.txt:915-924` tells the host "the game mods honor it… an old mod that
  predates the setting will ignore it entirely. If ghosts are still solid after you set this, the mod
  is the thing to update" — there is no mod to update; all four ignore it
  (`adapters/CLAUDE.md:172-173`). And `:402-404` "Replay and chaser ghosts are ALWAYS just
  pictures" is false in Emerald and Crystal (see D3).

- [ ] **J2 MED — `session_policy` is gated on a relay `welcome`, so it never reaches a solo session** —
  `core/bridgeserve.go:525` returns early on `!c.relayPolicyKnown`, set only on a welcome. The client's
  own `ghost_collision` needs nothing from the relay, and **`chaser_contact` rides the same message**
  while the chaser is explicitly a solo feature (ADR 0047). So the one mode where the chaser exists
  without a room is the one mode where its opt-in can never be delivered.

- [ ] **J3 MED — The bridge writer became asynchronous *and coalescing* on 2026-09-07 with no ADR and
  no contract update.** `contract.md`'s tick model still says the core "pushes already-interpolated
  `render_remote` calls to the adapter every frame"; `core/bridgeserve.go:653-679` now sheds superseded
  renders (270,872 in one measured run). The relay's structurally identical change got ADR 0042.

- [ ] **J4 MED — The contract's datagram guidance names only `udp`, but quic is the shipped default**
  and has the same ceiling on the state plane (`netx/quicconn/quicconn.go:266-267` — refused, not
  fragmented, error logged and dropped). "Large `extras` therefore means `tcp`" applies to the default
  configuration and the contract does not say so.

- [x] **J5 MED — `docs/reviewing.md` pins `CGO_ENABLED=0`; the Windows release build does not set it**
  (`release.yml:264,267` vs `:144`). `docs/code-signing.md:21-22` stakes the signature's value on that
  reproducibility, and a reviewer getting a non-matching hash cannot tell which half is wrong.

- [x] **J6 MED — `.gitattributes:66-67`'s CRLF pin misses both Pokémon READMEs** (a gitattributes `*`
  does not cross `/`). `git check-attr` confirms `unspecified` for both; they are CRLF today only
  because the blob bytes happen to be — the exact failure the rule's own comment records from
  2026-09-06. `packaging/unix/README-*.txt` and `packaging/release/config.json` are unpinned too
  (and currently CRLF, wrong for the unix tarballs).

- [x] **J7 MED — `packaging/README.md:11-14` says no game overrides anything and both override files
  are empty**; `packaging/config-overrides/pseudoregalia.json` carries three `ghost_range*` values.
  Same file calls the shipped TEVI DLL "~27 KB"; it is 52 KB.

- [ ] **J8 MED — `release.yml` grants `contents: write` and publishes through
  `softprops/action-gh-release@v3`** — the only non-`actions/*` action in the tree, pinned to a mutable
  major tag, in the job holding write scope. No secrets are referenced anywhere (that part is clean).

- [ ] **J9 LOW-MED — Five wire shapes escape the frozen-fields gate**: `BridgeReady`, `RemoteName`,
  `RecordingState`, `PlayerFrozen`, and `protocol.StatePrev`'s own nine fields
  (`internal/gameblind/gameblind_test.go:388-397`); the loop errors only for a frozen entry with no
  sample, never for a type that was never added.

- [x] **J10 LOW — Three dev provenance `*-built-from.txt` files ship inside the release zip.**

- [x] **J11 LOW — The Pseudoregalia install README has a sentence broken in half** by an inserted
  paragraph (`README.txt:44-51`), in the one paragraph a player with other mods is told to read; and
  line 34's "nothing already in your install is deleted" contradicts line 43's UE4SS replacement.

- [x] **J12 LOW — TEVI's README points at a `config.json` key that `stage-release.ps1` strips**
  (`games/tevi/README.txt:96-100`). Pseudoregalia's README gets this right.

- [x] **J13 LOW — `docs/reviewing.md:110-111` describes CI fuzz coverage as it was before 2026-09-06.**

- [x] **J14 LOW — Two stale line-number citations in `contract.md`**: `:230` cites `core/core.go:172`
  for `DefaultRemoteStaleAfter` (now `:209`); the heartbeat bullet cites `core/stats.go:143-144`
  (now `:157-158`).

- [ ] **J15 LOW — `protocol/displayname.go:32` cites `relay's uniqueDisplayName`, which does not
  exist.** Repo-wide grep matches only that comment. Two places rest the anti-impersonation argument on
  disambiguation code that was never written, and Pseudoregalia (the only adapter drawing nametags)
  shows `display_name` and never `player_id` — so two peers with the same name are indistinguishable.
  Found independently by two agents.

---

## K. Already known — demoted, no action

- [-] Resume grace holds a seat with no socket — `docs/security.md:422-428`, accepted.
- [-] A `lease.v1`/`world.v1` member can fill the room's tables — same page, accepted, fix shape named.
- [-] The UDP admission cookie is a small reflector (1.5× on the wire) — same page, "recorded so it is
  not rediscovered".
  One agent read that page and excluded them; three others reported them as new. Verified by me.

---

## L. Traces that came back CLEAN

Recorded so nobody re-derives them:

- Peer → `player_id` spoofing: `relay/states.go:53-57` stamps the sender's id over the payload on every
  plane. A peer cannot claim another peer's id.
- Newline/quote injection into the bridge or the relay's log: every bridge line goes through
  `json.Marshal`, and every relay log site uses `%q`. `SanitizeDisplayName` is idempotent and strips
  all `Cc`/`Cf`/zero-width/bidi.
- NaN/Inf/out-of-range positions: rejected at three independent layers (relay, core, and Pseudoregalia's
  own `isfinite` guards, which deliberately do not trust a correct core).
- Replay zip-slip / path traversal: nothing is extracted; entry names are `filepath.Base`'d for display
  only. Gzip bomb at the line level is capped before decode.
- The UDP cookie construction (HMAC-SHA256 over `addr||slot`, 30 s slots, constant-time compare, no
  state allocated before validation) and the constant-time session-token check.
- No slice/length panic reachable from a hostile datagram on the udp listener or dialer path.
- Pseudoregalia's three needle-shadowing classes (raw orientation, `prev`+omitempty, sorted map keys)
  are genuinely closed by the scoped readers; the two remaining unscoped reads are safe by field order.
- `resolve_peer_named_asset` bounds the path and resolves only against a catalog of already-loaded
  objects of the requested class, with a second type check at the call site.
- No adapter holds a relay address, hostname or port; every autostart launcher passes only
  `-exit-with-pid` and `-bridge`.
- `internal/gameblind` genuinely enforces core/relay game-blindness (game tokens, generic imports,
  eight forbidden import edges). `area_id`/`anim` are equality-compared everywhere.
- `git ls-files '*.dll'` is exactly the six files `licensing.md:28` claims; no game-derived binary is
  tracked; no secrets referenced in any workflow; no `continue-on-error` anywhere.
- Lock ordering in `core` (`rec.mu → c.mu`, `replayMu → rec.mu`) has no inverse today, so no second
  instance of the StartRecording-class deadlock — but `pushRecordingStateValues`' comment ("the two
  locks are never held at once") is factually wrong; the invariant that holds is the one-way order.

---

## N. Raised by the user during the fix pass (2026-09-08) — contract changes, need an ADR each

Both came out of comparing against Archipelago, whose `MultiServer.py` was read for facts only
(it is cleared MIT in `agent_docs/licensing.md`, and has been read for facts before).

- [?] **N1 — `protocol_version` should be a FLOOR, not exact equality.**
  `relay/relay.go` refuses on `hello.ProtocolVersion != protocol.Version`. Archipelago's default is
  `minver > args['version']` against a `min_client_version` (`Version(0, 5, 0)`) that is bumped
  rarely and deliberately; their exact-match is an opt-in mode (`ctx.compatibility == 0`).
  **So MeshGhost currently runs Archipelago's strict mode as its only mode.** The user's goal —
  "anything older than v2 is unsupported once v2 ships" — is precisely a floor, and today's
  equality cannot express it: a protocol bump refuses even a patch-level difference between two
  v2 builds, forcing a flag day. Change: declare a minimum and compare `>=`.
  Bump the minimum when the WIRE changes, not when the release number does.
  Do NOT copy their per-slot minimum (`ctx.minimum_client_versions[slot]`) — the analogue here is a
  per-game floor, which cuts against the D6 decision to never separate game builds.

- [?] **N2 — the reject reason should be a machine-readable code, not prose.**
  Archipelago sends `errors: ['IncompatibleVersion']` — an enum the client branches on. MeshGhost
  sends a human sentence, which is the ROOT of D4: all four adapters substring-match it, every
  permanent refusal happens to contain the word "relay", and only `"busy"` does not, so a config
  error is silently retried forever. Fixing the heuristic in four adapters treats the symptom;
  adding a code to `bridge.Reject` (and to `protocol.Reject`) removes the reason anyone was
  string-matching. Also the enabler for N1 being visible to a player at all.
  Related and already listed: **H4** (no test asserts the relay emits any reason by value) and
  **A5/A6** (a reject that dies in a reset teaches the player nothing) — a version floor that
  silently retries forever is worse than no floor.

  One thing NOT to copy from Archipelago: they keep the connection OPEN after a refusal so a client
  can retry with different credentials. MeshGhost closes, which is right for us (no credential
  retry exists) — but it is exactly why the reject has to survive the close, i.e. A5+A6.

- [x] **N3 — nothing tests a "coherent but wrong game" peer.** (user, 2026-09-08)
  `game_id` is self-declared and `only_game` is a plain string compare
  (`relay/relay.go:1504`), so an Emerald Lua script editing one constant joins a
  `only_game=pseudoregalia` relay and is forwarded. The relay CANNOT detect this without
  becoming game-aware, so this is a consequence of the invariant, not a defect — the fix is
  not "stop it" but "know what it does".
  Damage is bounded and mostly self-limiting: a foreign `area_id` is dropped by the cross-area
  filter (no ghost at all); a matching `area_id` with foreign-scale coordinates draws a ghost
  somewhere odd, bounded by `MaxPositionComponent`; an unknown `anim` is refused by each
  adapter's own validation (TEVI `Animator.HasState`, Pseudoregalia's catalog).
  **The gap is that nothing tests it.** Every existing fuzzer feeds INVALID values; this case is
  interesting because every field is individually valid and only the combination is wrong.
  Worth: one cross-game test per adapter parser (a state carrying another game's area/anim/scale
  must not crash, must not spawn at a nonsense transform), plus a note in `docs/security.md`
  saying plainly that `only_game` filters mistakes, not lies.

---

## O. Found while fixing, 2026-09-08 — recorded rather than fixed

- [?] **O1 — the clock re-anchor E9 could not do.** E9 stopped `nowMs` from stepping BACKWARDS on a relay
  drop (which left every peer's interpolation buffer unsorted and despawned the chaser pack). The
  cost of that fix is the other direction: the monotonic clamp now holds the emitted clock STILL
  until real time catches up, so in a room with a +5 s offset, outgoing timestamps freeze for up to
  five seconds after a drop — and chasers and replays read the same clock, so they stall with it.
  A freeze is bounded and self-heals where an unsorted buffer is a persisting corruption, so the
  trade is the right way round, but it is a trade.
  **The fix that avoids both** is to re-anchor at the drop: carry the offset forward as a baseline so
  the emitted value stays continuous instead of either rewinding or freezing. That needs a new
  persistent term in `nowMsLocked` — the root every outgoing timestamp, every render time and every
  playback due-time comes from — and `clockAdjustLocked` returns 0 once `activeFeatures` is cleared,
  so the carry cannot simply live in `clock.offsetMs`. Deliberately not attempted in the same pass;
  the reasoning is written into `core/reconnect_test.go`'s assertion so the next reader inherits it.

- [?] **O2 — a local ghost can survive a relay reconnect nameless.** `forgetRelaySessionLocked` wipes
  `c.roster` and `c.remoteNames` on a relay session change. `feedLocalPeer` re-admits the roster seat,
  but nothing restores the nametag, and the chaser goroutine's `admitted` stays true so
  `admitLocalPeer` (and with it `storeRemoteName`) never re-runs. Same shape as the E10 age-out bug
  and fixed by the same reasoning, but a different trigger — a relay reconnect rather than a pause.
  Found by the agent fixing E10, 2026-09-08, in a file it did not own.

- [ ] **O3 — an UNIDENTIFIED core flake, seen once on 2026-09-08 and not reproduced.**
  During a full `run-gotests.bat` (which runs packages in parallel, `-count=2`), `./core/` failed
  once. The captured tail held only teardown log noise -- "use of closed network connection" from a
  relay and two cores shutting down -- and not the test name, and the run was not re-captured before
  the output was lost.
  **Not reproduced since**: seven consecutive `go test ./core/ -count=2` runs and a subsequent full
  `run-gotests.bat` (exit 0) are all clean. So it is either a genuine rare flake or port contention
  between `./core/` and `./internal/e2e/`, which both bind loopback while the suite runs packages
  concurrently.
  Recorded rather than dismissed because this repo's own history says a flake seen once and waved
  through is the one CI finds on a slower machine (the 2026-08-16 and 2026-09-05 cases). **Next step
  if it recurs: capture the WHOLE output, not the tail** -- the test name is what is missing, and
  without it there is nothing to bisect.
