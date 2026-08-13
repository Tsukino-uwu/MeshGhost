# Architecture

System shape and the rationale behind decisions that aren't obvious from the code or the
brief alone. The standing prohibitions (no addresses from memory, human-gated verified.md,
etc.) live in `CLAUDE.md`, not here — this file is reference, not rules.

## System shape

```text
        Relay (internal/relay, cmd/meshghost-relay)
             |  relay protocol: NDJSON/TCP, hello/welcome/join/leave/state/ping
        Core (internal/core, cmd/meshghost)
             |  adapter bridge: NDJSON/TCP, localhost-only
     [ Adapter contract ]
        /    |    \
   Emerald  TEVI  Pseudoregalia   (per-game, rewritten each time)
```

Full field-level detail — packet schema, message types, tick model, transport framing,
limits — lives in `agent_docs/contract.md`. This file covers the shape and the *why*.

## Why the core is out-of-process

Go was chosen for the core and relay (ADR below) so the shipped desktop app is a single
dependency-free binary per OS. That means the core cannot be linked directly into a BizHawk
Lua script or, later, a C# Unity mod — it runs as its own process, and adapters reach it over
a localhost socket (the "bridge" in `contract.md`). This is a deliberate consequence of the
packaging goal, not an accident, and it's why the bridge exists as a named layer instead of
being folded into "the transport."

## Why the tick is adapter-driven

BizHawk's Lua environment owns the frame loop (`emu.frameadvance()`); a hypothetical future
in-process host would want to drive its own loop. Making the *adapter* always the one that
calls into the core — never the reverse — means there's one calling convention for every
adapter, checked for real at Phase 5 rather than discovered as a mismatch then. See
`agent_docs/contract.md`'s tick model section for the reasoning that produced this.

## Package boundaries

Enforced dependency graph for the Go module, added as a compiling type skeleton (zero logic,
`go build ./...` and `go vet ./...` both pass clean) on 2026-08-11:

```text
internal/protocol   — message types + JSON shapes. No internal deps. Lowest layer.
internal/transport  — generic NDJSON/TCP framing. Defines its own Transport interface;
                       no internal deps (byte-level only, doesn't know message shapes).
internal/bridge     — adapter<->core message shapes (LocalState/RenderRemote/DespawnRemote).
                       Imports protocol only.
internal/core       — snapshot buffer, interpolation, remote-player tracking. Imports
                       protocol, transport (bridge import arrives with the Phase 3 listener).
internal/relay      — room membership, forwarding, limits. Imports protocol, transport.
                       Never imports core or bridge — the relay stays ignorant of
                       adapter-side concerns, same as it's ignorant of games.
cmd/meshghost       — desktop app entry point. Imports core (transport/bridge arrive with
                       real wiring in Phase 3).
cmd/meshghost-relay — standalone relay entry point. Imports relay.
```

**Hard rule:** `internal/core` and `internal/relay` may never import anything under
`adapters/`. There's no Go code under `adapters/` today (BizHawk is Lua), but the rule holds
regardless — it's the Go-level enforcement of "the core never touches the game," parallel to
the existing "no `if game == \"emerald\"`" rule. Checked manually at time of writing; a
`go vet` or import-graph lint enforcing it automatically is worth adding once there's a
second package under `adapters/` to violate it.

The one Go interface in the skeleton, `core.Adapter`, is deliberately scoped in its doc
comment to the Phase 5 in-process fake/test adapter only — real adapters (BizHawk Lua, any
future host) speak the `internal/bridge` wire protocol and never implement it. Conflating the
two would wrongly suggest Lua adapters need Go bindings.

## Decision log (ADRs)

Format: Date / Decision / Status / Context / Options considered / Resolution / Consequences.

---

- **Date:** 2026-08-08
- **Decision:** Keep the adapter contract minimal and game-specific.
- **Status:** accepted
- **Context:** The project must support multiple game engines without leaking game-specific
  logic into the core.
- **Options considered:** a larger shared world model, a universal animation vocabulary,
  engine-specific core branches.
- **Resolution:** Use a thin adapter contract and keep all game-specific normalization
  inside adapters.
- **Consequences:** The first game adapter carries most of the work; the core stays reusable
  and easier to validate.

---

- **Date:** 2026-08-08
- **Decision:** Use JSON as the default wire format for Phase 0 and Phase 1.
- **Status:** accepted
- **Context:** Early work must prioritize correctness, observability, and easy debugging.
- **Options considered:** JSON text, custom binary encoding, CBOR-like binary formats.
- **Resolution:** Start with JSON and defer binary encodings until the contract is stable
  and bandwidth is demonstrably limiting.
- **Consequences:** Easier early debugging and review; wire format may need a later
  performance pass.

---

- **Date:** 2026-08-08
- **Decision:** Treat `area_id` and `anim` as opaque values in the core.
- **Status:** accepted
- **Context:** The core should avoid game-specific assumptions and keep the contract
  reusable.
- **Options considered:** normalized area identifiers, shared animation vocabulary,
  game-specific core branches.
- **Resolution:** Keep `area_id` and `anim` opaque and compare them only by equality in the
  core.
- **Consequences:** Adapters carry game-specific interpretation; the core stays simpler and
  more portable.

---

- **Date:** 2026-08-11
- **Decision:** Core and relay are written in Go, shipped as a single static binary per OS.
- **Status:** accepted
- **Context:** `README.md` commits to a packaged desktop app with no runtime install
  (Python, .NET, JVM, etc.) across Windows/Linux/macOS. No language had been chosen; this
  had to be resolved before any Phase 3 network code could be written.
- **Options considered:** C#/.NET 8 (in-process option for a future Unity adapter, but
  larger binaries and no benefit to BizHawk/UE4SS), Rust (best runtime characteristics, but
  slowest to write for an I/O-bound JSON-plumbing project), Python + PyInstaller (fastest to
  prototype, but works directly against the no-dependency packaging goal).
- **Resolution:** Go. Single static binary, trivial cross-compilation, no runtime for the
  end user, sufficient stdlib for TCP/JSON.
- **Consequences:** The core is out-of-process for every adapter, including a future
  in-process-capable host like Unity/C#. See "Why the core is out-of-process" above. One
  uniform bridge/relay split for all games, at the cost of losing the option of linking the
  core directly into a C# host later without keeping the bridge as a compatibility path.

---

- **Date:** 2026-08-11
- **Decision:** Second target game is TEVI, not Ori: Will of the Wisps.
- **Status:** accepted
- **Context:** The brief and the original `plans.md` named Ori: Will of the Wisps as the
  second game, but neither Ori title is owned, and the `adapter/games/` scaffolding had
  drifted to include an unrelated Ori title (Blind Forest) plus an untracked TEVI folder.
- **Options considered:** Ori: Blind Forest (owned-status same problem, older Unity build,
  matches the stray folder), Ori: Will of the Wisps (matches the brief, not owned), TEVI
  (owned, Unity, movement-focused 2D platformer — same genre fit as the Ori reasoning),
  leaving the second slot undecided.
- **Resolution:** TEVI. It's owned and fits the same "movement-focused, genre where ghost
  co-op shines" reasoning the brief used for Ori and for Pseudoregalia.
- **Consequences:** `agent_docs/brief.md` section 4 keeps the original Ori reasoning as
  historical context; `adapters/tevi/` is the live second-game folder; `adapters/oribf/` is
  kept as a candidate, not deleted, in case Ori is picked up later. TEVI's own IL2CPP/Mono
  status is unverified and must be checked at Phase 6, not assumed by analogy to Ori.

---

- **Date:** 2026-08-11
- **Decision:** Relay runs without authentication through Phases 3–4; room code + shared
  secret is the recorded end goal for later.
- **Status:** accepted
- **Context:** Phase 4 puts a relay on the open internet with no connection or auth model
  defined anywhere in the original docs.
- **Options considered:** no-auth self-hosted (simplest, least friction for proving the
  transport/schema work), room code + shared secret self-hosted (better end-user story, more
  to build before Phase 3 can start), a publicly hosted always-on relay (best UX, adds
  hosting cost, abuse surface, and a privacy/ToS obligation the project otherwise avoids
  entirely).
- **Resolution:** No-auth, direct IP:port for Phases 3–4, to keep the loopback and
  two-player milestones focused on schema/transport correctness. Payload size caps and rate
  limits (see `contract.md`) ship from day one regardless — those defend against a malformed
  peer, not an attacker, and cost nothing to add now.
- **Consequences:** Phase 4's "first real milestone" is not yet safe to run on a relay
  reachable by strangers. Room code + shared secret is scheduled as its own piece of work
  after Phase 4, before any relay is exposed beyond a friend the host directly gave an
  address to.

---

- **Date:** 2026-08-11
- **Decision:** Reserve an opaque event plane and a `features` capability list in the
  contract, for potential deeper per-game sync later. Do not implement either now.
- **Status:** accepted
- **Context:** The user asked whether the architecture would trap MeshGhost as visual-only
  forever, or whether a specific game's adapter (Emerald, concretely) could later go deeper —
  trading, battling — without a redesign. Two things about the contract are cheap to change
  now and effectively impossible to change once real clients exist: a capability-negotiation
  field, and a reserved addressed-message type.
- **Options considered:** (1) docs-only, no schema change — cheapest today, but capability
  negotiation genuinely cannot be retrofitted after clients ship, since an old client has no
  way to say what it does or doesn't support; (2) reserve the schema fields but implement no
  routing — costs ~10 lines, keeps the door open, nothing is built without a consumer to
  validate it against; (3) reserve and also implement relay-side event routing at Phase 3 —
  the routing itself is cheap to add on top of the forwarding path the relay needs anyway,
  but with no adapter yet sending an event, it would be unexercised code with nothing to
  watch happening on screen, which is exactly what this project's own verification standard
  (`CLAUDE.md`) rules out.
- **Resolution:** Option 2. Add `features` to `hello` and reserve (but do not implement) an
  `event` message type with a `to` addressee field, documented in `agent_docs/contract.md`'s
  Extensibility section. Shape — but do not feature-gate — the Phase 3 relay forwarding path
  to take a recipient set, so wiring in real event routing later is a small localized change
  instead of a rewrite.
- **Consequences:** The state plane (cosmetic `state` messages) stays exactly what it is and
  never grows new fields for deeper features. Any future deep-sync feature for a specific
  game lives entirely inside that game's adapter, sending opaque event payloads the core and
  relay route but never parse — the same opacity discipline already applied to `area_id` and
  `anim`, extended to messages. This does **not** authorize building anything past the
  cosmetic ghost; the brief's "no shared or authoritative world state" non-goal
  (`agent_docs/plans.md`) remains the default posture. Lifting it for a specific game and
  feature is a separate, deliberate decision that needs its own ADR — including how it
  handles game-memory writes and save-corruption risk, since that is a different risk
  category than anything reading-only work carries. See the depth ladder in
  `agent_docs/plans.md` for the tiers this opens up and where the real cliff is.

  This reservation has a ceiling, and the two reasons something sits above it are different in
  kind, not just degree — a future session must not conflate them. **Tier 3** (trading,
  battling — bounded, consensual, episodic sessions) is *unapproved but architecturally
  possible*: the event plane above is exactly the mechanism it would use, and building it only
  needs its own per-feature ADR. **Full continuous co-op** ("everything synced") is
  *architecturally excluded*, not merely unapproved: the relay has no authority model and
  deliberately never will, since giving it one would require the relay to understand the game,
  which is the one thing this whole architecture exists to prevent. No ADR can lift that one
  the way an ADR can lift the Tier 3 non-goal — it would require a different relay design, at
  which point it is a different project. See `agent_docs/plans.md`'s depth ladder for the full
  reasoning.

---

- **Date:** 2026-08-11
- **Decision:** The Emerald BizHawk adapter uses a vendored LuaSocket binary for its bridge
  connection, not BizHawk's own built-in `comm.*` (`CommLuaLibrary`) socket API. Loopback
  (Phase 3's one-client milestone) is implemented as a relay-side `-loopback` flag that echoes
  a client's own `state` back under a synthetic `"<id>-ghost"` player_id, not a core-side or
  third-process echo.
- **Status:** accepted
- **Context:** Phase 3 needed the first real adapter socket in the project. Two ways to hold a
  TCP connection from BizHawk Lua exist in this exact installed build (2.11): the engine's own
  `comm.*` library, and a vendored LuaSocket, the approach the brief's own cited prior art
  (`bizhawk-co-op`) and Archipelago's `connector_bizhawk_generic.lua` both use. Checked against
  real files rather than assumed: `comm.*` is present (confirmed via
  `BizHawk.Client.Common.dll`'s embedded doc strings), but its own documentation states
  responses "must be of the form `{msg.Length:D} {msg}`" — length-prefixed framing, not
  NDJSON — plus a blocking request/response model. Separately, Phase 3 also needed a way to
  exercise the full core→relay→core path with only one physical BizHawk instance, since a real
  second peer doesn't exist until Phase 4.
- **Options considered (socket):** (1) `comm.*` — zero vendoring, zero licensing surface, but
  its framing would have to become a second mode the Go bridge speaks, and *every* future
  adapter (Unity, UE5, anything else) would inherit that choice too, since the bridge is
  meant to be one protocol for every adapter; (2) LuaSocket, vendored — a real MIT-licensed
  binary dependency to track, but keeps the bridge as the one NDJSON protocol every adapter
  speaks, matching `agent_docs/contract.md`'s transport section as already written, no
  contract revision; (3) reimplement a raw socket via BizHawk's `comm.*` framing translated
  transparently at the bridge boundary — rejected as needless complexity solving a problem
  option 2 doesn't have.
- **Options considered (loopback):** (1) relay-side `-loopback` flag, echoing under a
  synthetic ghost id — exercises the real relay round trip and real interpolation, zero
  `internal/core` changes since the ghost id is simply a different id than the client's own;
  (2) core-side flag, feeding local state into the core's own remote buffer directly — simpler
  but the data never actually crosses the relay, and requires loosening the core's own
  "ignore my own player_id" guard; (3) a separate `meshghost-echo` dev client, a second real
  relay peer that re-sends whatever it receives — closest to a real Phase 4 peer, but a third
  process to build and run for a milestone that doesn't need one yet.
- **Resolution:** LuaSocket (vendored `socket-windows-5-4.dll`, MIT, see
  `agent_docs/licensing.md`) for the socket; the specific binary reused is the one already
  vendored by Archipelago for the same BizHawk/Lua-5.4 target (proven working there) rather
  than an independent rebuild from LuaSocket's own source, to avoid a silent Lua-ABI mismatch
  with no error to catch it. Relay-side `-loopback` flag for the echo.
  **Follow-up finding (2026-08-11, live test):** the first real run failed loading
  `socket-windows-5-4.dll` at all — `package.loadlib` returned "the specified module could not
  be found". Diagnosed empirically (not guessed): the DLL's PE import table names `lua54.dll`
  as a dependency; Windows' plain `LoadLibrary` (confirmed against Lua's own `loadlib.c`,
  which passes `LUA_LLE_FLAGS` = 0 by default) resolves a loaded DLL's dependencies via the
  standard search order, which does **not** include the directory the DLL itself was loaded
  from — confirmed by reproducing the exact failure outside BizHawk, then confirming that even
  placing a copy of `lua54.dll` next to `socket-windows-5-4.dll` did **not** fix it. What does
  fix it, confirmed the same way: explicitly pre-loading `lua54.dll` by its own full path
  *before* loading the socket module — Windows' loader reuses an already-loaded module of the
  same name for later dependency resolution regardless of source directory. Fixed by also
  vendoring `lua54.dll` (byte-identical copy of the one already running inside the user's
  BizHawk, confirmed via matching hash — not an independently built copy, to guarantee the
  pre-load binds to a build compatible with the one actually executing the script) and having
  `phase3_loopback.lua` pre-load it before `package.loadlib`-ing the socket core.
- **Consequences:** The bridge stays one protocol for every future adapter; a C#/C++ Unity or
  UE5 adapter later just opens an ordinary TCP socket, no BizHawk-specific framing to carry
  forward. `-loopback` is dev-only and must not ship enabled by default; it becomes dead code
  to ignore (not remove — cheap to keep for future dev/test use) once Phase 4 has a real
  second peer. The LuaSocket binary is now a real third-party dependency this project tracks
  (platform/arch/Lua-version-specific), unlike everything vendored before it, which was source
  citation only.

---

- **Date:** 2026-08-12
- **Decision:** Cap `internal/core.Core`'s actual send rate to the relay
  (`Core.MinSendInterval`, default 50ms / 20Hz) independent of how often an adapter calls in,
  rather than relying on the relay's `MaxMessagesPerSecond` limit alone.
- **Status:** accepted
- **Context:** Phase 6 (TEVI) hit this live: TEVI's `Update()` calls the bridge every real game
  frame with no engine-level cap, and `forwardLocalState` previously sent to the relay on every
  such call. The relay's `MaxMessagesPerSecond = 120` (`agent_docs/contract.md`'s Limits
  section) *closes* an over-limit connection rather than throttling it, and TEVI's uncapped
  frame rate exceeded it — the connection was closed by the relay after about two minutes of
  real play, confirmed live (`relay: client exceeded 120 messages/second, closing connection`
  in the relay's own log). The contract's prior text ("up to ~60Hz, one per adapter frame") was
  itself already a wrong assumption for a frame-driven engine adapter with no fixed cap — it
  held for BizHawk's ~60fps `emu.frameadvance()`, not for Unity's variable, uncapped frame rate.
- **Options considered:** (1) raise `MaxMessagesPerSecond` on the relay — treats the symptom,
  not the cause, and does nothing for a still-faster future adapter (144Hz+ displays); (2) push
  the cap into every adapter individually — repeats the same throttling logic per adapter,
  exactly the kind of duplicated "genuinely hard, genuinely reusable" work `contract.md`'s tick
  model section already argues against; (3) cap it once in `internal/core`, where the relay
  connection is actually owned.
- **Resolution:** Option 3. `Core.MinSendInterval` (default `DefaultMinSendInterval = 50ms`,
  overridable per-`Core` the same way `InterpolationDelay` is) gates `forwardLocalState`: a
  call before the interval has elapsed since the last actual send is silently dropped (no
  `seq`/`timestamp` stamped, since it never reaches the relay) rather than queued or coalesced.
  50ms (20Hz) leaves comfortable headroom under the relay's 120/s cap for any adapter frame
  rate, and does not claim to be the "right" sync rate — the brief's 10Hz hypothesis and the
  contract's two still-open questions (snapshot frequency, `seq`/`timestamp` semantics) are
  unaffected by this change. Regression-tested: `TestForwardLocalStateRespectsMinSendInterval`
  in `internal/core/core_test.go` drives 1000 calls in a tight loop against a counting fake
  transport and asserts the send count stays capped, not 1:1 with the call count.
- **Consequences:** Every current and future adapter is protected from this failure mode
  without needing its own rate-limiting logic — game-agnostic, matches the core's existing
  "chatty over the bridge is free, chatty over the relay is not" posture. A real behavior
  change worth knowing: local state changes between two sends within the same 50ms window are
  now invisible to remotes (the newest state at send time wins, not a coalesced value) — fine
  for cosmetic ghost rendering, would need revisiting if a future Tier 3 feature (per
  `plans.md`'s depth ladder) needed every intermediate state observed.

---

- **Date:** 2026-08-12
- **Decision:** The adapter declares `game_id` to the core over the bridge (a new `hello`
  message, sent first on every connection), instead of the user supplying `"game"` in
  `config.json`. `-game`/the config field remain as an explicit override for callers that
  don't have a real adapter to ask (dev/testing scripts, `cmd/meshghost-fakeadapter`).
- **Status:** accepted
- **Context:** Raised by the user while reviewing the reworked release `config.json`
  (`plans.md`'s "Release packaging" entry): the adapter already knows which game it's running
  in — it's literally the Lua script or mod the user loaded — so asking them to also type
  `"emerald"`/`"tevi"` into a text file is a second statement of a fact already established
  elsewhere, and a second place for it to go stale or be mistyped.
- **Options considered:** (1) leave `game_id` user-supplied, just documented better — doesn't
  remove the actual redundancy, only explains it; (2) infer the game from which port an
  adapter connects to — would need one bridge port per game, more moving parts than the
  problem justifies; (3) the adapter states `game_id` itself, over the bridge, as connection
  setup.
- **Resolution:** Option 3. `internal/bridge.Hello` (`{"type":"hello","payload":{"game_id":
  "..."}}`) is a fourth bridge message, sent by the adapter as the first message on a fresh
  connection. `internal/core.Core` no longer requires a `game_id` before `ServeBridge` starts;
  `Core.ConnectRelayOnAdapterHello` connects to the relay lazily, the first time a `hello`
  arrives, using new `RelayAddr`/`Room`/`DisplayName`/`DialTimeout` fields set by the caller
  up front. `game_id` stays opaque to the core throughout — forwarded verbatim into the relay
  `Hello`, never inspected, same as `area_id`/`anim` (`CLAUDE.md`). `cmd/meshghost`'s `-game`
  flag (and the config file's `"game"` field) still work exactly as before when set — this is
  additive, not a removal, since dev/testing tooling with no real adapter attached
  (`dev-scripts/run-core.bat`, `cmd/meshghost-fakeadapter`) has no `hello` to wait for. A
  single `Core` still serves exactly one game per process: a `hello` for a different `game_id`
  than the one already connected is refused, not treated as a game switch.
- **Consequences:** `packaging/release/config.json` drops `"game"` entirely — the shipped
  package now has nothing for the user to get wrong about which game they're playing, and
  switching games is "load the other one, restart the launcher," not "load the other one, also
  edit a text file to match." The cost is a small ordering contract every future adapter must
  follow (hello before any `local_state`) that a purely-flag-driven adapter never had to think
  about — documented in `contract.md` and `adapters/_template/PROTOCOL.md`, and demonstrated in
  both shipped adapters (`adapters/pokemon/emerald/phase5_5_sprite.lua`,
  `adapters/tevi/MeshGhostTevi/BridgeClient.cs`).

---

- **Date:** 2026-08-13
- **Decision:** A bridge (adapter↔core) disconnect now closes the Core's relay connection too,
  and a relay disconnect (any cause) clears the Core's relay identity (`c.relay`, `playerID`,
  `relayGame`) so a later bridge `hello` can redial.
- **Status:** accepted
- **Context:** Found live during the first real TEVI two-player test (two local instances
  through one real, non-loopback relay): a player backing out to the main menu stopped sending
  `local_state` (per `forwardLocalState`'s existing nil-means-"don't send this frame"
  contract), but nothing told the *relay* this player was gone. The remote's ghost stayed
  frozen in the other player's world indefinitely — there is no staleness timeout
  (`remoteBuffer.at()` holds the newest sample forever, by design, per its own comment) and the
  only thing that despawns a remote is a real relay `Leave`. Reconnecting made it worse: a
  second, correctly-positioned ghost appeared alongside the frozen one, because the Core never
  actually left the room in the relay's eyes, so there was nothing to distinguish "same player
  resuming" from "a new join."
- **Options considered:** (1) an idle/staleness timeout in `remoteBuffer` — a magic-number
  interval with no non-arbitrary value, and doesn't fix the "reconnect leaves both" half at
  all; (2) an explicit "despawn self" bridge/relay message — a new wire message type for
  something the existing disconnect machinery already does for every other disconnect cause;
  (3) tie the Core's relay connection lifecycle to its bridge connection lifecycle, so an
  adapter going away for any reason (game closes, bridge socket drops) reads as a real
  disconnect to the relay, the same as a network blip already does.
- **Resolution:** Option 3. `handleBridgeConn` (`internal/core/core.go`) now closes `c.relay`
  when the bridge connection ends. `ConnectRelay`'s existing relay-`OnDisconnect` handler
  (previously only `dropAllRemotes()`, added for the unrelated "own relay died" case — see the
  ADR below) now also clears `c.relay`/`c.playerID`/`c.relayGame`, guarded by comparing against
  the specific connection that disconnected so a stale callback can't clobber a newer
  connection. This reuses the relay/core despawn path that was already built and tested
  (`TestDisconnectDespawnsRemote`, `TestOwnRelayDisconnectDespawnsRemotes`) rather than adding
  a third despawn mechanism. Regression-tested: `TestBridgeDisconnectDespawnsForPeer` (the bug
  as reported — closing the bridge, not the relay, must still despawn for the peer) and
  `TestReconnectAfterBridgeDisconnectGetsFreshPlayerID` (a disconnected Core must be able to
  redial and get a new `player_id`, not stay wedged) in `internal/core/core_test.go`.
- **Consequences:** Game-agnostic — every adapter's game-close/reconnect now cleans up for
  free, no per-adapter change. Deliberately scoped to the bridge socket's actual lifecycle:
  TEVI's `Plugin.cs` keeps its bridge connection open across a return to the main menu (it only
  stops sending state), so main-menu cleanup is **not** covered by this change — see the open
  follow-up in `plans.md`/`risks.md` about verifying whether TEVI's `mainCharacter` reads null
  during a pause menu too before wiring an adapter-side disconnect into that transition. A real
  behavior change worth knowing: reconnecting after any disconnect now always gets a fresh
  `player_id` — there is no session resumption under the old identity.

---

- **Date:** 2026-08-13
- **Decision:** `Core.remoteStatesAt` now excludes any remote whose `area_id` doesn't match
  this Core's own most recently known `area_id`, unless the Core's own area is still unknown
  (never received a real local frame), in which case every remote passes through unfiltered.
- **Status:** accepted
- **Context:** Found live in the same real two-player TEVI test session as the bridge-
  disconnect fix above, once the two players moved through genuinely different zones (not just
  different rooms within one always-loaded zone). `internal/core` sends every known remote
  regardless of `area_id` — a documented, previously-untested gap (`plans.md`). The remote's
  ghost kept rendering the whole time, using the peer's raw world coordinates from their own
  zone, with no relationship to the local zone's coordinate space. It only looked correct
  because the two test zones' coordinate ranges didn't happen to overlap anywhere visible on
  screen — confirmed by reading both BepInEx `LogOutput.log`s directly: `area=` changed
  `1→4→1→13→1` across five real zone transitions, but `"real remote ghost visual created"`
  logged exactly once, at initial connect, never again — the remote `GameObject` was never
  destroyed or recreated, just silently repositioned to nonsense coordinates every frame.
  Two zones whose coordinate ranges did overlap on screen would have produced a visible
  phantom ghost instead of a coincidentally-invisible one.
- **Options considered:** (1) leave it — rejected, this session's own log evidence shows it's
  not actually benign, only luck-dependent; (2) filter in each adapter individually — repeats
  per-adapter logic for something `area_id` equality already makes trivial to do once,
  centrally; (3) filter once in `internal/core`, at the same point `remoteStatesAt` already
  builds the per-tick render set.
- **Resolution:** Option 3. Added `Core.localAreaID`, updated in `forwardLocalState` on every
  real local frame (`state != nil`) regardless of `MinSendInterval` throttling or whether a
  relay connection exists yet — filtering needs the adapter's true current area, not just what
  was last actually sent over the network. `remoteStatesAt` skips any remote whose `AreaID`
  doesn't equal `c.localAreaID`, unless `c.localAreaID` is still `""` (no real local frame yet),
  which passes everything through unfiltered rather than hiding all remotes on an unknown local
  area — this keeps every pre-existing test that never sends a local area (most of the
  `fakeAdapter`-driven suite) passing unchanged. Equality-only comparison, per `contract.md`'s
  `area_id` rule — never branches on contents. Reuses the existing render/despawn diff in
  `tickRenders` for free: a remote dropping out of `remoteStatesAt`'s filtered result is
  indistinguishable from one that actually left, so it already gets a real `despawn_remote`,
  and reappears via the normal render path once areas match again. Regression-tested:
  `TestCrossAreaFiltersRemote` in `internal/core/core_test.go` drives a remote through
  same-area → different-area (must despawn) → same-area-again (must reappear).
- **Consequences:** Game-agnostic, benefits every adapter with no per-adapter change — closes
  the `plans.md`/`phase6.md` "genuinely unbuilt" gap. Not yet watched live in-game; next TEVI
  session should confirm a remote in a different zone is no longer rendered at all (not just
  coincidentally off-screen), and reappears cleanly on returning to the same zone.
