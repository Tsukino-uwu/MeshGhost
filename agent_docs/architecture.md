# Architecture

System shape and the rationale behind decisions that aren't obvious from the code or the
brief alone. The standing prohibitions (no addresses from memory, human-gated verified.md,
etc.) live in `CLAUDE.md`, not here — this file is reference, not rules.

## System shape

```text
        Relay (internal/relay, cmd/meshghost-relay)
             |  relay protocol: NDJSON/TCP, hello/welcome/reject/join/leave/state/ping
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
                       protocol, transport, bridge, netx.
internal/relay      — room membership, forwarding, limits. Imports protocol, transport.
                       Never imports core or bridge — the relay stays ignorant of
                       adapter-side concerns, same as it's ignorant of games.
internal/netx       — transport selection (tcp|udp|quic) as net.Listener/net.Conn. Added
                       2026-08-16. No internal deps, same leaf discipline as transport;
                       subpackages netx/udpconn and netx/quicconn hold the datagram
                       implementations. Deliberately NOT a second Transport implementation
                       — see the transport ADR for why the seam sits at net.Conn.
cmd/meshghost       — desktop app entry point. Imports core and netx (the Phase 3 note here
                       once predicted transport/bridge imports; they never arrived).
cmd/meshghost-relay — standalone relay entry point. Imports relay and netx.
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
  (`dev-scripts/run-core-*.bat`, `cmd/meshghost-fakeadapter`) has no `hello` to wait for. A
  single `Core` still serves exactly one game per process: a `hello` for a different `game_id`
  than the one already connected is refused, not treated as a game switch.
- **Consequences:** `packaging/release/config.json` drops `"game"` entirely — the shipped
  package now has nothing for the user to get wrong about which game they're playing, and
  switching games is "load the other one, restart the launcher," not "load the other one, also
  edit a text file to match." The cost is a small ordering contract every future adapter must
  follow (hello before any `local_state`) that a purely-flag-driven adapter never had to think
  about — documented in `contract.md` and `adapters/_template/PROTOCOL.md`, and demonstrated in
  both shipped adapters (`adapters/pokemon/emerald/meshghost_emerald.lua`,
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

---

- **Date:** 2026-08-14
- **Decision:** Add room-code auth and a peer game-version check to `hello`
  (`protocol.Hello.RoomCode`/`GameVersion`), a `reject` message so a refusal carries a reason
  instead of a bare hangup, and a broader malicious-peer hardening pass across
  `internal/transport`, `internal/relay`, and `internal/core`. Supersedes the 2026-08-11
  no-auth ADR above (kept, not deleted, as the historical record of why no-auth was the right
  call for Phases 3–4).
- **Status:** accepted
- **Context:** Set as the explicit next priority 2026-08-13 (see `risks.md`'s "No-auth relay
  window" entry and `plans.md`'s "Room codes / relay safety" section): the relay/core was
  no-auth and safe only for a friend you hand an address to, not for people you don't
  personally know, including someone actively trying to be malicious with the server/client.
  Two named gaps (no auth, no peer game-version check) plus a broader malicious-peer audit.
  Researched CelesteNet's own prior art first (`internal/README.md`'s prior-art section, MIT,
  approved reference per `licensing.md`) rather than designing from scratch — its self-hosted
  default is no-auth too (mirroring our own starting posture), and its version-check pattern
  (reject outright at handshake, before any state exchange) is the shape this ADR reuses for
  both room codes and game version, without copying its heavier public-server account/ban/
  hardware-fingerprinting stack, which solves a problem (an always-on server open to the whole
  internet) MeshGhost doesn't have.
- **Options considered (auth):** (1) a shared secret in `hello`, compared constant-time,
  reject before any state flows — simple, no crypto to design, but the secret crosses the wire
  in plaintext since `internal/transport` has no TLS; (2) an HMAC challenge-response (relay
  sends a nonce, client returns `HMAC(secret, nonce)`) — the secret itself never crosses the
  wire, but costs a new handshake round-trip and two new message types, and still doesn't stop
  a MITM relaying the whole session, which a real TLS layer would (a separate, larger piece of
  work, deliberately out of scope here); (3) a per-room code set by whichever client creates
  the room (lobby-password style) — more flexible for a relay hosting several unrelated
  groups, but the relay has no way to tell an intended host from a race-winning stranger.
- **Resolution (auth):** Option 1. `protocol.Hello.RoomCode`, checked via
  `crypto/subtle.ConstantTimeCompare` (not `==`, so a wrong guess can't be timed byte-by-byte)
  against `Server.RoomCode`. An empty configured code (the default) means auth stays off — the
  pre-existing friend-hosted posture is unchanged unless a relay operator opts in. The relay
  logs loudly at startup when running open, the same pattern `-loopback` already used.
  **Explicit limit, recorded rather than implied:** this raises the bar from "anyone with the
  address" to "anyone with the address and the code," not to "safe against a network-level
  attacker" — the code is still plaintext on the wire. TLS is a real, separate piece of future
  work if that ever becomes the actual threat model; not attempted here.
- **Options considered (version check):** (1) the adapter reports `game_version` over its
  bridge `hello`, forwarded into the relay `hello` — follows the existing 2026-08-12
  "adapter declares `game_id`" ADR's own reasoning (the adapter already knows, don't make the
  user retype it), but dev-scripts/`cmd/meshghost-fakeadapter` have no real adapter to ask;
  (2) same, plus a `-game-version`/`config.json` override — mirrors how `-game` already
  overrides an adapter-declared `game_id` for exactly that case; (3) config-only, no adapter
  changes — fastest, no adapter rebuilds (including TEVI's committed DLL), but reintroduces the
  exact redundancy (a fact the adapter already knows, retyped by the user, another place to go
  stale) the `game_id` ADR removed.
- **Resolution (version check):** Option 2. `bridge.Hello.GameVersion`, forwarded verbatim
  (opaque, same discipline as `game_id`/`area_id`/`anim`); `Core.GameVersion` overrides it when
  set. All three shipped adapters report their own **adapter/mod version**, not a game build
  number read from memory — no cited address exists for a game version in any of the three
  games, and `CLAUDE.md`'s "no addresses/APIs from memory" rule means one isn't guessed at. An
  adapter-script version is arguably the more useful signal anyway: it catches two peers on
  different revisions of the same adapter, the likelier real source of a silent mismatch. A
  room's `game_version`, once set by its first member, is sticky the same way `game_id` already
  is; a client that never declares one is never refused on that basis — only a real mismatch
  between two declared values counts.
- **Options considered (malicious-peer hardening scope):** (1) auth and version check only,
  file the discovered DoS/trust gaps in `risks.md` for a separate pass — smallest change, but
  ships a "safe for strangers" feature with a known remote-OOM still live; (2) the concrete DoS
  holes found while scoping this (unbounded read buffer, no read/write deadlines, a lock held
  across a potentially-slow `Send`, no hello timeout) but not the core-side trust gaps; (3)
  everything found, relay-side and core-side.
- **Resolution (hardening scope):** Option 3, per explicit user direction. Fixed:
  `internal/transport.NDJSONConn`'s unbounded `bufio.Reader.ReadBytes` read (switched to
  `bufio.Scanner` with a real max-token-size, enforced during the read, not after — the
  previous `internal/relay.MaxLineBytes` check ran too late to prevent the allocation), added
  read/write deadlines and a dial timeout (none existed before), fixed
  `internal/relay.Room.Forward` holding `r.mu` across every recipient's `Send` (a stalled peer
  could freeze joins/leaves/roster reads for the whole room once `Send` could legitimately
  block for seconds against it), and added `Server.HelloTimeout` (an unauthenticated connection
  that never completes a `hello` was previously held open forever). On the trust side:
  `internal/core` now keeps its own roster (seeded from `welcome`, maintained by `join`/
  `leave`) and drops `state` for any `player_id` it never actually saw announced — previously a
  hostile or compromised relay could inject state for an arbitrary id, since `welcome.roster`
  was discarded entirely and any incoming `player_id` was trusted outright. The relay's own
  `MaxPositionLen`/`MaxExtrasBytes` caps are now mirrored on the core's receive side too
  (`internal/protocol/limits.go` holds the shared constants so the two enforcement points can't
  drift apart), plus new caps on `orientation`, `area_id`, `anim`, and every `hello` string
  field, none of which were bounded anywhere before.
- **Consequences:** `protocol.Version` stays at `1` — every new field is optional/additive, and
  Go's `json.Unmarshal` ignores fields it doesn't recognize, so an old client against a new
  relay (or vice versa) degrades gracefully rather than breaking outright. The one real residual
  risk this creates, not fully closed: **room-code auth is enforced entirely by the relay, so a
  stale (pre-this-ADR) relay binary silently provides zero protection regardless of what any
  client sends or believes it configured** — a `room_code` field in an old relay's `config.json`
  is invisible to it (unknown JSON fields are ignored the same way), with no error to tell the
  host their room is actually wide open. Worth a follow-up: `internal/README.md` and
  `packaging/README.md` should say plainly that room-code auth requires the *relay* to be
  current, not just the client. Every new size/length limit is a real, if small, behavior
  change: a legitimately-oversized field that was previously silently truncated-by-forwarding
  or merely logged is now dropped outright (state fields) or refused at handshake (`hello`
  fields) — matches the existing "drop, don't truncate" posture already established for
  `MaxPositionLen`/`MaxExtrasBytes`, just extended to the fields that were missing it.

---

- **Date:** 2026-08-14 (same-day follow-up to the ADR above)
- **Decision:** Add lifecycle logging (join/leave/reject) at the relay; classify a relay
  `Reject` as permanent or transient (`core.RejectError`/`core.IsPermanentRejectErr`,
  `protocol.ReasonServerFull` the one transient reason); cache a permanent rejection on the
  `Core` so a retrying adapter doesn't keep re-dialing an already-known-hopeless connection;
  and make `cmd/meshghost`'s eager `-game` startup path retry until the relay is reachable
  instead of crashing the whole process on the first failed dial.
- **Status:** accepted
- **Context:** Three real gaps surfaced in conversation while reviewing the room-code/version
  ADR above, each traced back to something this project's own review missed rather than a new
  request out of nowhere:
  1. The user asked how a host or player would actually find out a `hello` was refused. Answer,
     checked against the code: **nowhere adequate.** `rejectAndClose` (added by the ADR above)
     sent the reason to the client, but never logged anything server-side — a host had zero
     visibility that anyone was ever refused. The reason did reach `internal/core`'s own log,
     but no further: all three shipped adapters, on a closed bridge connection, just log a
     generic "lost, will retry" and loop silently forever with no reason ever reaching the
     player. Separately, the relay's own log had never recorded a successful join or leave
     either — a gap the user had already flagged once before, in the cross-machine session
     entry in `verified.md`, and it was still unaddressed.
  2. The user then asked whether the client had to be started after the server. Checked against
     the code: **yes, for the eager `-game` path specifically.** `cmd/meshghost`'s eager branch
     called `Core.ConnectRelay` once, synchronously, and `log.Fatalf`'d the whole process on any
     failure — including a plain "relay isn't up yet" dial error, indistinguishable in that
     branch from a real permanent refusal. The lazy path (no `-game`, the real shipped
     `config.json`'s actual default) already tolerated this for free, since a failed
     `ConnectRelayOnAdapterHello` only closes one bridge connection and the adapter's own
     reconnect loop drives the next attempt — but that same mechanism had no way to distinguish
     "keep trying" from "this will never succeed," so a wrong room code or version mismatch
     would have silently retried forever too, hammering the relay and this process's own log
     with an identical failure indefinitely once fixed to not crash.
- **Options considered (logging):** (1) log everything, including per-`state` traffic — rejected
  outright, this is exactly the spam the user explicitly warned against and duplicates what
  `MaxMessagesPerSecond` already guards against; (2) log only lifecycle events (hello
  reject/accept, join, leave) — these happen once per connection event, not per frame, so
  logging every one of them cannot spam regardless of session length; (3) option 2, plus
  per-message-content dedup on the *core* side specifically, since a retrying adapter can
  legitimately hit the *same* connect failure many times in a row where the relay's own
  lifecycle events (each a genuinely new occurrence) don't have that problem.
- **Resolution (logging):** Options 2 and 3 together. `internal/relay.rejectAndClose` now logs
  the reason plus the offending `hello`'s `game_id`/`room`/`display_name` before closing; a
  successful join logs the assigned `player_id`, display name, room, and game; a disconnect
  logs the leaving `player_id` and room. `internal/core.ConnectRelayOnAdapterHello` logs a
  connect failure only when the message actually changes from the last one logged
  (`Core.lastConnectErr`), so a long wait for the relay to come up, or a room stuck full for a
  while, produces one line per *actual* state change, not one per retry.
- **Options considered (retry vs. crash):** (1) leave the eager path crashing on any failure —
  simplest, but directly contradicts what the user just asked for; (2) retry inside
  `cmd/meshghost` using `Core.ConnectRelay` directly, with its own backoff loop — works, but a
  real adapter could *also* connect over the bridge and send its own `hello` for the same
  `game_id` while this loop is still waiting, and since `ConnectRelay` doesn't serialize against
  `ConnectRelayOnAdapterHello`'s `relayConnectMu`, the two could race to dial independently;
  (3) route the eager path's retry loop through `ConnectRelayOnAdapterHello` itself instead of
  `ConnectRelay` directly, so both entry points serialize on the same lock and share the same
  permanent/transient classification and logging.
- **Resolution (retry vs. crash):** Option 3. `RejectError` (`internal/core`) wraps a relay
  `Reject`'s reason so it can be distinguished from a plain dial/timeout error without string-
  matching a formatted message. `isPermanentRejectReason` treats every reason except
  `protocol.ReasonServerFull` as permanent — the only one of the named reasons *as of this ADR*
  (`ReasonProtocolVersionMismatch`, `ReasonHelloFieldTooLong`, `ReasonInvalidRoomCode`,
  `ReasonGameMismatch`, `ReasonGameVersionMismatch`, `ReasonServerFull`) that can resolve on its
  own without a config change, if someone else leaves the room. **Superseded by the 2026-08-15
  rate-control ADR below**: the code now works from an explicit *retryable* set of two —
  `ReasonServerFull` and `ReasonRateLimited` — and two more reasons exist that this list predates
  (`ReasonGameNotAllowed`, `ReasonRateLimited`). `Core.permanentRejectGame`/
  `permanentRejectReason` cache a permanent rejection per `gameID`, checked before dialing;
  `IsPermanentRejectErr` is exported so `cmd/meshghost`'s new `connectRelayWithRetry` (backed
  off 1s→15s, doubling) can decide whether to keep retrying or `log.Fatalf` — a permanent
  rejection still ends the process loudly, since that's a real, unresolvable-by-retrying
  refusal, not "the relay isn't up yet." `cmd/meshghost`'s bridge listener now starts
  immediately regardless of relay reachability (the relay connect is backgrounded, not blocking
  startup), matching the tolerance the lazy path already had.
- **Consequences:** Both `cmd/meshghost` startup paths (`-game` set or not) now tolerate the
  relay coming up after the client, with no ordering requirement either direction — confirmed
  live (not just `go test`): real `meshghost.exe` started against a relay address nothing was
  listening on yet, logged the retry message exactly once despite several retry cycles across
  ~15 seconds, then connected automatically the moment a real `meshghost-relay.exe` started on
  that address, with matching join lines appearing in both processes' logs at that same moment
  — see `verified.md`. A permanently-rejected `-game` startup (bad room code, version mismatch)
  still exits the process via `log.Fatalf`, unchanged from before this ADR — only the
  transient/"not up yet" case gained tolerance. `cmd/meshghost-fakeadapter` was deliberately
  left on the old one-shot `ConnectRelay`+immediate-error pattern: it's dev-only tooling meant
  to fail fast and visibly if pointed at a bad address, not something that needs to tolerate a
  slow-starting relay the way the real shipped client does.

---

- **Date:** 2026-08-14 (same-day review/refactor sweep)
- **Decision:** Two review passes (one Go-layer, one adapter) across `internal/`, `cmd/`, and
  all three adapters surfaced roughly a dozen real bugs, dead code, and stale comments; fix
  everything found rather than triaging into a follow-up backlog. Four of the fixes are real
  behavior changes worth recording as decisions, not just bug fixes:
  1. **Core-side finiteness/magnitude validation on remote `position`.** A remote peer can put
     `[1e400,...]` on the wire — syntactically valid JSON that overflows to `+Inf` on decode, or
     `1e308` that overflows to `+Inf` when narrowed to `float32` — and nothing anywhere checked
     for it (zero `math.IsInf`/`IsNaN` calls existed in `internal/`). This reaches Pseudoregalia's
     `sscanf`/`FRotator` and TEVI's `Transform` unfiltered. `internal/core.storeRemoteState` now
     drops (not clamps — same "drop, don't store" posture as the existing size caps) any `State`
     whose `Position` contains a `NaN`, `Inf`, or `|x| > protocol.MaxPositionComponent` (new
     const, `1e7` — generous, not a measured game bound, chosen only to reject "obviously not a
     real coordinate" magnitudes). `orientation` stays opaque JSON the core cannot parse this way;
     each adapter is documented (`adapters/_template/PROTOCOL.md`) as responsible for bounding
     whatever numbers it pulls out of its own `orientation`/`extras`.
  2. **`internal/core/interp.lerp` no longer blends across an `area_id` change.** Two bracketing
     snapshots with different `AreaID` previously had their raw world coordinates linearly
     blended and stamped with the older snapshot's `AreaID` — a phantom-midpoint result, the
     exact failure shape the 2026-08-13 cross-area-filtering ADR (above) exists to prevent, just
     one layer earlier than that ADR's own fix (which filters at render time, not interpolation
     time). `lerp` now returns the older snapshot outright when `AreaID` differs, mirroring the
     existing mismatched-length guard already in the same function.
  3. **`Core.ConnectRelay`'s 7 positional parameters collapsed to read `Core`'s own fields.**
     Every parameter but `gameID` already duplicated a `Core` field
     (`RelayAddr`/`Room`/`DisplayName`/`RoomCode`/`GameVersion`/`DialTimeout`) — the same
     duplication-is-a-bug-magnet shape already fixed once for `applyFileConfig` via
     `configTargets`. All three callers (`cmd/meshghost`, `cmd/meshghost-fakeadapter`,
     `core_test.go`) updated to the new signature; this is a source-breaking change to any code
     calling `ConnectRelay` directly (not the wire protocol, which is unaffected).
  4. **Pseudoregalia ghosts move offscreen on despawn instead of only `SetActive`-equivalent
     hiding.** Cosmetic-only fix, not a lifetime-management change — see the "Actor destroy
     unavailable" pitfall in `pitfalls.md` for why ghosts are never destroyed on this build at
     all. Before this fix, a peer leaving/reconnecting within a single area left their last-known
     ghost frozen in place with no visual indication anything had changed; now `release_ghost`
     moves it far offscreen first (the same proven `call_set_actor_location_and_rotation` path
     used everywhere else), so a same-area leave is visually silent instead of a visible frozen
     statue, while the level's own teardown on the next area transition still does the real
     reclaim, unchanged.
- **Status:** accepted
- **Context:** Set as the explicit next priority once the 2026-08-14 relay-safety ADRs above
  landed — a full review/refactor sweep across the server/client and all three adapters, since
  the hardening work above had been added incrementally across several sessions without a
  dedicated pass to catch what accumulated in the gaps.
- **Options considered:** fix everything found now (all four items above, plus every
  non-behavior-changing bug/race/dead-code item logged individually in `verified.md`/commit
  history rather than here) vs. triage into "must-fix now" and "follow-up backlog." The user
  chose fix-everything explicitly, plus rebuild+deploy Pseudoregalia, and explicitly **rejected**
  one reviewer conclusion: destroying Pseudoregalia ghosts, which would reintroduce the
  world-leak crash the move-offscreen design exists to avoid (see the pitfall entry).
- **Resolution:** All four items above shipped in this pass, along with the non-behavior-changing
  fixes (a wedged-core timeout leak, a `DialTimeout==0` instant-fail bug, a real `-race` data
  race on `playerID`, a cross-game bug where a second adapter's bridge connect could tear down a
  first adapter's already-working relay session, several smaller races/reorderings/dead-code
  removals in `internal/`) and the adapter-side fixes in Pseudoregalia's C++ (partial-send/
  unbounded-recv-buffer, connect backoff, unclamped numeric casts, cached-pointer hardening,
  callback unregistration), Emerald's Lua (partial-line receive corruption — see the pitfall
  entry above — partial send, dead-socket-after-hard-connect-error, a `pcall` around the main
  loop, control-char JSON escaping), and TEVI's C# (a stale-thread generation guard so an
  in-flight reconnect can't clobber a newer connection's state, `TcpClient` disposal, ghost/marker
  `GameObject`s actually `Destroy()`d instead of only deactivated, `OnDestroy`/
  `OnApplicationQuit` closing the bridge, `room_x`/`room_y` range-checked before a map-lookup
  call, and `TryGetValue` in place of unguarded `JObject` casts in `DrainInto`).
- **Consequences:** `protocol.Version` is unaffected — every change above is either server-side
  validation (already-permitted values still round-trip identically; only `NaN`/`Inf`/absurd
  magnitudes are newly dropped) or adapter-internal. The `ConnectRelay` signature change only
  affects Go code calling `internal/core` directly, not the wire protocol or any adapter. The
  Pseudoregalia rebuild was hash-diff-confirmed deployed to the in-repo packaging copy; the live
  Steam install and the TEVI DLL rebuild remain manual follow-ups outside this repo's automated
  reach (packaging/README.md's existing staleness-check note covers the latter). Live in-game
  verification of the Pseudoregalia despawn-visual change and the finiteness/lerp fixes' observed
  behavior is still pending — nothing above is entered in `verified.md` until watched happening
  on screen, per `CLAUDE.md`.

---

- **Date:** 2026-08-14 (found during live testing of the sweep above)
- **Decision:** `Core` now auto-retries a dropped relay connection in the background after any
  *previously successful* `ConnectRelayOnAdapterHello` connect, not just the first attempt.
- **Status:** accepted
- **Context:** Live two-TEVI testing (both clients connected fine, then the shared relay was
  restarted) showed both clients logging `relay disconnected` and then sitting idle forever —
  no reconnect attempt at all, requiring a full client restart. Root cause: the only existing
  retry loop, `cmd/meshghost`'s `connectRelayWithRetry`, drives just the *first* connect attempt
  and returns once it succeeds (see the "client/relay start-order independence" ADR above); a
  real adapter's own bridge-Hello resend — the other trigger for `ConnectRelayOnAdapterHello` —
  only fires when the *bridge* connection itself drops, which a relay-only outage never touches.
  So a relay restart or network blip after an already-successful connect had no path back to
  "connected" short of restarting the whole client process. Separately, this same debugging
  session also surfaced that the actual `meshghost.exe`/`meshghost-relay.exe` binaries at the
  repo root were stale (dated the day before this entire review sweep) — `go build ./...`/
  `go vet`/`go test`, run repeatedly throughout the sweep, compile-check everything but don't
  refresh the named binaries the `dev-scripts/*.bat` files launch. Both issues compounded: the
  user's first repro was against binaries that predated even the start-order-independence fix.
- **Options considered:** (1) leave reconnection entirely adapter-driven (status quo) — simplest,
  but leaves exactly the gap just found; (2) have `cmd/meshghost`'s `connectRelayWithRetry` loop
  forever instead of returning after the first success — fixes the eager `-game` path only, does
  nothing for a real adapter (TEVI/Pseudoregalia/Emerald) whose relay drops while its bridge
  connection stays healthy, which is the actual case that broke live; (3) move auto-retry into
  `Core` itself, armed only by `ConnectRelayOnAdapterHello`'s own success path, so it covers both
  the eager path and a real adapter uniformly.
- **Resolution:** Option 3. `Core.autoRetryGameID`/`autoRetryAdapterGameVersion`/
  `autoRetryBridgeConn` are set on every `ConnectRelayOnAdapterHello` success; `ConnectRelay`'s
  `OnDisconnect` handler spawns `Core.reconnectWithBackoff` (same 1s→15s doubling shape as
  `cmd/meshghost`'s loop, but logs and stops on a permanent reject instead of `log.Fatalf`ing —
  `Core` is a library and must not exit the host process) whenever these are armed. Deliberately
  **not** armed for `cmd/meshghost-fakeadapter`'s direct `ConnectRelay` calls or `core_test.go`'s
  (both leave the fields at zero value, opting out by construction — matches the existing
  documented "fakeadapter fails fast on purpose" posture). A real regression caught by the test
  suite before shipping: `handleBridgeConn`'s existing behavior of closing `c.relay` when the
  *adapter itself* intentionally disconnects (so the relay broadcasts a real Leave) was racing
  against the new auto-retry and silently reconnecting with a fresh `player_id` before the
  disconnect could be observed — `TestReconnectAfterBridgeDisconnectGetsFreshPlayerID` failed.
  Fixed by disarming the auto-retry fields in that same code path, in the same critical section,
  before the deliberate `relay.Close()` — an intentional adapter-driven disconnect must stay
  disconnected until a fresh bridge Hello, not silently reconnect behind the adapter's back.
- **Consequences:** No wire-protocol change. Live-verified (not just `go test`): a real relay
  killed mid-session, a real client kept retrying with backoff and logging exactly once (existing
  dedup logic), then reconnected automatically the instant a new relay came up on the same
  address — see `verified.md`. `meshghost.exe`/`meshghost-relay.exe`/
  `meshghost-fakeadapter.exe` at the repo root were rebuilt from current source as part of this
  fix; there is no automated step that keeps them fresh across a session — rebuild explicitly
  after any `internal/core`/`cmd/meshghost` change before testing via the `dev-scripts/*.bat`
  files, the same discipline already documented for the Pseudoregalia/TEVI adapter builds.

---

- **Date:** 2026-08-14 (retroactively ADR'd — a documentation sweep found this real wire-protocol
  addition had no ADR despite `CLAUDE.md` requiring one for contract changes)
- **Decision:** `Core` sends a `ping` every `DefaultHeartbeatInterval` (20s) on an otherwise-quiet
  relay connection.
- **Status:** accepted
- **Context:** A core with no adapter attached, or one whose adapter reported no local state for
  a stretch (e.g. parked at a menu), sent nothing to the relay at all. `transport.
  DefaultIdleTimeout` (60s) closed that as an idle connection, and the already-existing
  auto-reconnect immediately redialed — but `nextPlayerID` never reuses an id, so every other
  peer in the room saw a leave+join/ghost despawn-respawn cycle roughly once a minute, purely
  from a quiet client sitting still.
- **Options considered:** (1) raise `DefaultIdleTimeout` — treats the symptom, not the cause, and
  weakens idle-connection cleanup generally; (2) send a real heartbeat that keeps the connection
  demonstrably alive. The relay already replied to `Ping` with `Pong` (protocol support existed
  from earlier work) but nothing on the client side ever sent one.
- **Resolution:** Option 2. `Core.sendHeartbeats` sends `Ping` every `HeartbeatInterval`
  (default `DefaultHeartbeatInterval`, 20s — comfortable margin under the 60s idle timeout even
  accounting for scheduling jitter). This is deliberately **not** a liveness/RTT mechanism —
  `Pong`'s `Nonce` is echoed by the relay but not read by anything on receipt. Drop detection is
  unchanged: still entirely `transport.DefaultIdleTimeout` closing the socket on a truly dead
  connection. `HeartbeatInterval <= 0` disables heartbeats entirely, used by `core_test.go` to
  reproduce the pre-fix idle-timeout-churn bug directly.
- **Consequences:** `contract.md`'s Transport section and message-type table updated to describe
  this accurately (an earlier version incorrectly described missed-pong-counting drop detection
  and an RTT-feeds-interpolation-delay mechanism, neither of which was ever implemented — found
  and corrected in the same documentation sweep that added this ADR). See `verified.md`'s
  "Core-relay heartbeat, found live and fixed" entry for the live confirmation.

---

- **Date:** 2026-08-15
- **Decision:** Make the room's state send rate operator-configurable at the relay
  (`server.send_hz`, 20 default, 10–100), advertised to every client via `Welcome.SendHz` and
  adopted as that client's own send rate — unless the client has deliberately configured a
  slower rate of its own, which always wins. Separately, let each client declare its own
  per-peer receive cap (`client.max_receive_hz_per_player`, `Hello.MaxReceiveHz`), enforced at
  the relay by dropping excess forwards to that specific recipient. Both integer Hz, matching
  how game servers are conventionally described ("a 20-tick relay").
- **Status:** accepted
- **Context:** The send rate was previously a single hardcoded constant
  (`core.DefaultMinSendInterval`, 50ms/20Hz) with no way for a host to trade bandwidth for
  smoothness, and no way for an individual player on a poor connection to opt out of a fast
  room without also throttling everyone else. The user specifically wanted the *cost* of raising
  the rate to be visible at the point someone would change it, not just the mechanism.
- **Options considered:**
  - **Units — Hz integers vs. duration strings** (`"50ms"`, matching the existing `interp`/
    `min_send` client fields). Hz chosen: the user's own mental model was explicitly a game-
    server tickrate ("the server is running at 60Hz for Counter-Strike/Overwatch"), and Hz reads
    naturally next to a bandwidth-tradeoff explanation ("20/sec vs 100/sec") in a way a duration
    string doesn't. Costs a style inconsistency with `interp`/`min_send` in the same config
    file — accepted as the smaller cost.
  - **Receive-side throttling: at the relay vs. at the receiving client.** Client-side discarding
    (receive the full stream, drop what you don't want) saves the client nothing — the bytes
    already crossed its downlink, which is exactly the thing a metered/weak connection wants to
    avoid. Relay-side dropping was the only option that actually delivers the stated benefit.
  - **Per-room vs. per-(sender, recipient) receive state.** A single per-room or per-sender cap
    would force every recipient to the same rate for a given sender, defeating the point (two
    recipients on different connections need different effective rates from the *same* sender
    simultaneously). Per-(sender, recipient) is the only shape that allows this, at the cost of
    real complexity: this state cannot use `handleConn`'s existing "OnReceive is serial, no mutex
    needed" shortcut, because it is *read* by the sender's goroutine but *owned* by the recipient
    — up to N−1 goroutines can touch one recipient's gate concurrently in an N-member room. Given
    its own mutex on `Client` (`gateMu`/`lastStateTo`), deliberately kept off `Room.mu` so
    `Room.Forward`'s hard-won "never do work under the room lock" property
    (`TestRoomForwardDoesNotBlockOtherOperationsOnStalledSend`) isn't put back at risk.
  - **Drop vs. coalesce vs. queue excess receive-side traffic.** Queueing/coalescing would add
    unbounded latency or memory for a purely cosmetic overlay. Dropped instead, consistent with
    `contract.md`'s existing state-plane posture (lossy, latest-wins) — a lower effective receive
    rate costs smoothness, never adds lag.
  - **Flood-cap scaling: proportional both ways vs. up-only.** Scaling the per-client flood cap
    (`relay.MaxMessagesPerSecond`) down along with a slower `send_hz` was rejected: an older
    client (or any client with an explicit local override) never learns the room turned down and
    keeps sending at its own built-in 20Hz default — scaling the cap down would then start
    disconnecting well-behaved clients for a config change on the host's side they had no part
    in. Scaling only ever **up** from the historical 120 avoids this; `120` becomes a floor
    (`max(120, send_hz × RateLimitHeadroomMultiple)`, headroom `6`, chosen so a relay left at the
    default `send_hz` computes exactly the historical `120` and nothing changes for an existing
    deployment).
  - **"Send" adoption: prescriptive vs. permissive.** A permissive design (the relay merely raises
    a ceiling; each client's own local config still governs what it actually sends) was rejected
    because it makes the host's `send_hz` setting inert on its own — raising it would do nothing
    until every player *also* reconfigured their own client, defeating "one knob, one visible
    tradeoff." Prescriptive-with-a-floor was chosen instead: `Core.effectiveSendInterval()`
    resolves to the **slower** of the relay's advertised rate and the client's own explicit
    `MinSendInterval`, so raising the room's rate genuinely speeds up every player who hasn't
    opted out, while a deliberately-configured slow client can never be sped up past its own
    floor. Detecting "deliberately configured" needed its own decision: `MinSendInterval`'s
    default changed from `DefaultMinSendInterval` (set by `New()`) to the zero value, so
    "explicitly set" is simply `MinSendInterval != 0` — reusing the zero-means-default convention
    already used by `Server.MaxClients`/`HelloTimeout` rather than threading a separate boolean
    through the existing CLI-flag/config-file precedence layering.
  - **Rejecting a rate-limited client: silent close vs. a `Reject` first.** The existing flood-cap
    close (`relay.go`'s rate-limit block) was a bare `nd.Close()` with no message — replaced with
    a `Reject{Reason: ReasonRateLimited}` sent first, matching the "refused/closed, and why"
    posture `TypeReject` already established at handshake, now extended to an already-joined
    connection. Required a matching fix on the client: `isPermanentRejectReason` previously
    treated every reason except `ReasonServerFull` as permanent (would have cached
    `ReasonRateLimited` and stopped the client from ever retrying); it's now an explicit retryable
    set (`ReasonServerFull`, `ReasonRateLimited`) rather than a blacklist-of-one, so a future new
    reason still defaults to permanent (the conservative posture this classification has always
    had). Also required fixing a real, separate gap this surfaced: a `Reject` arriving
    mid-session (after the handshake's own `select` has already returned) was previously
    discarded by `handleRelayMessage`'s non-blocking channel send with no log line at all — the
    user would have seen only a bare "relay disconnected" with the actual reason lost. Now logged
    when it happens post-connect.
- **Resolution:** All of the above, implemented across `internal/protocol` (shared `DefaultSendHz`/
  `MinSendHz`/`MaxSendHz`/`ClampSendHz`/`ClampReceiveHz`, `Hello.MaxReceiveHz`, `Welcome.SendHz`,
  `ReasonRateLimited`), `internal/relay` (`Server.SendHz`, `resolveSendHz`, `maxMessagesPerSecond`,
  the per-`Client` receive gate, `Room.stateRecipients`, the `Room.remove` gate purge),
  `internal/core` (`effectiveSendInterval`, `serverSendInterval`, `Core.MaxReceiveHz`, the
  `isPermanentRejectReason` fix, mid-session reject logging), and both `cmd/` binaries
  (`-send-hz`/`send_hz`, `-max-receive-hz-per-player`/`max_receive_hz_per_player`, `-min-send`'s
  default changed from `core.DefaultMinSendInterval` to `0`). `cmd/meshghost-relay`'s
  `applyFileConfig` was converted from flat positional pointers to a `configTargets` struct on
  this change (the 4th knob), matching the refactor `cmd/meshghost`'s own config loader already
  went through.
- **Consequences:**
  - **A minimum-interval gate quantizes the achievable receive rate**, not a token bucket:
    effective rate ≈ `senderHz / ceil(senderHz / capHz)`, so e.g. a 15Hz cap against a 20Hz sender
    yields 10Hz, not 15. Documented in the `-max-receive-hz-per-player` flag help and
    `packaging/release/README.txt`, not engineered around — same shape as the pre-existing
    `MinSendInterval` gate, and acceptable for a cosmetic ghost.
  - **`send_hz` is prescriptive but unenforced.** Nothing makes a client actually honor
    `Welcome.SendHz`; the only hard backstop is the scaled flood cap, so a non-compliant client
    may legitimately run at up to 6× the room's configured rate before it's disconnected.
  - **Raising `send_hz` taxes every peer's download, and a pre-change client can't opt out** of a
    fast room the host configures (it has no `max_receive_hz_per_player` to set). Combined with
    the pre-existing O(n²) room fan-out (`relay.DefaultMaxClients`'s own doc comment), 100Hz in a
    full 8-seat room is real, meaningful traffic — measured (not estimated; see the method below)
    at roughly 39 KB/s per player's own upload, up to several MB/s through the host. This is
    surfaced explicitly in `packaging/release/README.txt`'s new Hz section, with the specific
    recommendation to leave both settings at their defaults unless the operator has a concrete
    reason not to.
  - **This silently broke the project's own dev-testing setup, caught and fixed in the same
    change:** all six `dev-scripts/run-core-*.bat` scripts pass `-min-send=10ms`, faster than the
    (now-fallback-only) 20Hz default — under "slower wins," an unconfigured 20Hz relay would have
    quietly capped every one of them back down to 50ms, a 5× regression in exactly the timing-bug-
    surfacing setup Phase 8 chose deliberately (`agent_docs/phases/phase8.md`). Both
    `dev-scripts/run-relay.bat` and `run-relay-loopback.bat` now pass `-send-hz=100` so they never
    become the bottleneck for local testing.
  - **Message-size measurement for the README's bandwidth table:** per `CLAUDE.md`'s
    no-numbers-from-memory rule, the per-message byte figures are not estimated — they come from
    actually marshaling a real `protocol.State`/`protocol.Envelope` through the identical
    `json.Marshal` path `relay.go`'s `sendEnvelope` uses, with field shapes and example values
    matching the two adapters' own real outgoing payloads (Emerald: `adapters/pokemon/emerald/
    meshghost_emerald.lua`'s `encodeLocalState`, `:463-466`; Pseudoregalia: `adapters/
    pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp`'s local-state `std::format` call,
    `:7538-7592`). Measured once via a throwaway `cmd/` program, run, and deleted — not committed,
    since it exists only to produce this ADR's/README's numbers, not as a reusable tool. Result:
    a full NDJSON `state` line (envelope + newline) is **185 bytes** for Emerald's lighter
    2D/no-orientation/single-extras-field shape, **390 bytes** for Pseudoregalia's richer
    3D/orientation/8-extras-field shape — the README's worked table uses the 390-byte figure as
    the representative case, since it's the heavier of the two currently-shipped shapes.
  - **Re-measured 2026-08-15, and the figures above had gone stale — the README's table was
    understating host cost by ~1.5x.** Pseudoregalia's extras grew from 8 fields to 14 over that
    day's VFX/weapon/outfit work (trail colour, capsule height, outfit mesh path, afterimage
    counts), taking its state line from 390 to **597 bytes**. All three shipped adapters
    re-measured together this time, same method: Emerald **206**, TEVI **249** (never previously
    measured), Pseudoregalia **597**. Emerald's 206-vs-185 difference is methodology, not drift —
    this pass included its `orientation` field, which the original omitted.
    **Maintenance rule, relaxed 2026-08-16 on the user's call — the earlier version of this
    paragraph made it a rule that any `extras` change is a change to the published table, and that
    is stricter than the numbers need to be.** The table exists to give a host a rough sense of
    what hosting costs, not to be a 1:1 accounting of the current wire format. Treat the figures as
    a ballpark that ages slowly, in the spirit of `CLAUDE.md`'s dated-fact caveat: right order of
    magnitude, not right to the byte. **Re-measure when asked, not reflexively on every adapter
    change.** For reference, the extras set has grown since the 597-byte measurement (Pseudoregalia
    was 14 keys then, 25 as of 2026-08-16), so the real figure is somewhat higher — treat 597 as a
    floor rather than a current reading. The one thing that *was* worth an actual check, being a
    correctness question rather than a documentation one — whether the grown extras shape still
    fits inside `MaxExtrasBytes = 1024` — was done 2026-08-16 by costing the real `std::format`
    string against the longest object paths seen in this repo (56 chars, `BP_looseWeapon_C`) plus
    25% headroom: **worst case ~826 bytes, so it fits, with roughly 200 bytes spare.** That is
    real but not generous — the four unbounded object-path strings (`outfit_mesh`, `montage`,
    `weapon_class`, `weapon_glow`) are what would consume it, so a future feature adding a fifth
    path field is the case to re-check. Oversized extras are dropped silently by
    `protocol/limits.go:172`, which is exactly the kind of failure that looks like a broken
    feature rather than a limit.
  - **Hosting guidance added to `packaging/release/README.txt` (2026-08-15):** the table is now
    explicitly Pseudoregalia-based and labelled as a worst case, since it is the heaviest of the
    three by more than 2x — a host sizing a room off it can only be surprised in the good
    direction by running a lighter game. It also carries host upload in Mbps (the unit an
    internet plan is actually sold in) against a "budget half your measured upload" rule, plus
    the note that per-ghost *render* cost is a separate ceiling the network numbers say nothing
    about. `max_clients`'s default of 8 is presented as a safe-for-most-connections choice
    rather than a technical limit, which is what `internal/relay/limits.go` already says.
  - **Not done, deliberately, in this change:** advertising `max_receive_hz_per_player` back to
    the sender (a sender has no way to know a given recipient is receiving it throttled) and
    deriving `InterpolationDelay` automatically from the effective rate (a room or cap set below
    ~10Hz needs `-interp` raised by hand or ghosts will visibly stutter, since the 100ms default
    interpolation buffer no longer spans the gap between samples) are both real, known gaps —
    left for `agent_docs/ideas.md` rather than scope-creeping this change.

---

- **Date:** 2026-08-15
- **Decision:** A relay may be restricted to a single game (`server.only_game`), off by
  default.
- **Status:** accepted
- **Context:** The only game gate the relay had was per-room and sticky-on-first-join
  (`joinOrCreateRoom` compares a `hello`'s `game_id` against the room's existing one). That is the
  right rule for keeping two games out of one room, but it says nothing at the server level: a
  relay hosting rooms "a" and "b" happily hosts Emerald in one and Pseudoregalia in the other.
  Someone running a dedicated single-game server -- the case that prompted this -- had no way to
  express "this box is for Pseudoregalia," and would only find out a stranger was using it for
  something else by reading the log.
- **Options considered:** (1) leave it -- per-room stickiness already prevents the *incoherent*
  case (garbage ghosts), and a host who wants exclusivity can already use a room code; (2) a
  comma-separated allow-list of game ids; (3) a single game id, blank means any.
- **Resolution:** Option 3, chosen by the user over (2) explicitly: the ask was a dedicated
  single-game server, and a list would have added parse/whitespace/duplicate rules to an
  end-user-edited config file for a case nobody has. (1) was rejected because a room code is a
  different control -- it gates *who*, not *what*, and a host handing the code to friends who
  play several games still can't say "not on this box."

  Enforced in `internal/relay`, checked in `handleConn` after the field-length and
  protocol-version checks (so the refused `game_id` is already bounded before it is logged) and
  **before** the room table is touched or a client slot reserved -- the same "reject at
  handshake, before any state flows" shape as the room-code and version checks. Refused with a
  new `reject` reason, `ReasonGameNotAllowed`, kept distinct from the per-room
  `ReasonGameMismatch`: the two mean genuinely different things to a player, since no room they
  could pick would fix this one. `internal/core.isPermanentRejectReason` classifies unknown
  reasons as permanent already, so the client does not retry-loop against a relay that will
  never accept it, with no core change needed.

  Compared by exact equality, like every other use of `game_id`. The configured value is
  whitespace-trimmed (it is hand-typed into `config.json`, and a stray space would otherwise
  refuse everyone) but deliberately **not** case-folded, which would diverge from the equality
  comparison the adapters and `joinOrCreateRoom` already rely on. The relay logs the value it
  actually read at startup, since a typo'd id refuses every client with no other visible cause.
- **Consequences:** Nothing changes for an existing relay -- blank is the zero value and the
  pre-existing "host anything" posture. Same stale-relay caveat as room-code auth
  (`agent_docs/risks.md`): the check lives entirely in the relay, so an old
  `meshghost-server.exe` ignores the field and keeps hosting everything. This is also the first
  end-user-facing setting whose valid values are a list that grows when a game is added --
  `packaging/README.md` records the resulting maintenance rule (the ids are listed literally in
  `packaging/release/README.txt` and the top-level `README.md`, and adding a game means adding
  it to both).

---

- **Date:** 2026-08-16
- **Decision:** Keep building `UE4SS.dll` from our own pinned RE-UE4SS submodule rather than
  shipping upstream's published release zip; ship third-party notices alongside it.
- **Status:** accepted
- **Context:** A full-repo licence audit found `licensing.md` covered RE-UE4SS's own MIT code but
  not what RE-UE4SS *statically links into* the `UE4SS.dll` this repo builds and redistributes —
  about a dozen MIT/BSD-2/zlib libraries whose terms each require their notice to travel with a
  binary. The audit also established what the Epic-account-gated `UEPseudo` submodule actually
  is: ~200 headers carrying `// Copyright Epic Games, Inc. All Rights Reserved.`, which is why
  that repo is private and carries no licence. We compile against those headers; we do not
  redistribute them.
- **Options considered:** (1) status quo, unexamined; (2) keep building our own but close the
  notice gap; (3) ship upstream's published `UE4SS_v3.0.1.zip` so the Epic-headers compilation is
  upstream's arrangement rather than ours; (4) stop shipping UE4SS and make users install it.
- **Resolution:** Option 2. Option 3 was investigated with real measurements and rejected: no
  published upstream artifact matches our pinned commit (`733e5969` is **938 commits ahead** of
  the `v3.0.1` tag, 300 files changed, built 2024-02-14), our own `main.dll` is *linked against*
  UE4SS so the mismatch would be ABI-level rather than cosmetic, that zip predates the `ue4ss/`
  folder layout, and it contains no LICENSE file — meaning our staged tree is already more
  complete than upstream's own. Crucially the licence benefit is also narrower than it first
  looked: we remain the redistributor either way, so the notice obligation does not move. Option
  4 was never seriously on the table — it breaks the adapter for no gain. The measured detail
  lives in `agent_docs/licensing.md`; it is not duplicated here.
- **Consequences:** `packaging/release/.../Binaries/Win64/ue4ss/THIRD-PARTY-NOTICES.txt` now ships
  and is hand-maintained — `stage-ue4ss-runtime.bat` does not generate it and carries a comment
  saying so, since nothing there deletes the folder. It must be re-checked whenever the RE-UE4SS
  pin moves, because the dependency set can move with it. The `UEPseudo` question stays open and
  is recorded rather than resolved: what is fact (we ship only a compiled binary; upstream
  publicly ships the equivalent) is separated from what is a legal question this project will not
  assert either way. Revisit only on a concrete concern, not on general tidiness. One dependency,
  `patternsleuth`, has no licence text anywhere upstream — only a `Cargo.toml` declaration — so
  that declaration is quoted verbatim rather than expanded into boilerplate with an invented
  copyright line.

---

- **Date:** 2026-08-16
- **Decision:** `transport.NDJSONConn` guarantees no message is lost between construction and
  `OnReceive` registration — payloads arriving in that window are buffered and flushed, in order,
  when the callback is installed.
- **Status:** accepted
- **Context:** `FromConn`/`Dial` start `readLoop` before returning, so every caller has a window
  between "connection exists" and "callback installed". Anything arriving in it was **silently
  discarded** — no error, no log. Found while isolating an intermittent test failure: `go test
  ./...` failed in 9 of 12 runs, a different test each time, always a timeout waiting for a
  message that had genuinely been sent. Reachable in production, not only in tests: the relay
  installs its callback after `FromConnWithLimits`, so a fast client's `hello` could go
  unanswered, and the same applies to an adapter's `hello` on the bridge.
- **Options considered:** require every caller to register callbacks before any data can arrive
  (unenforceable, and the existing `FromConnWithLimits` already exists because callers got the
  analogous field-ordering wrong); start the read loop lazily on first registration (changes
  connection semantics and breaks connections that legitimately never register one); buffer and
  flush.
- **Resolution:** Buffer and flush. Delivery is serialized on a dedicated mutex, held across the
  callback, so a flushed backlog cannot interleave with a payload `readLoop` is delivering
  concurrently. Safe because no callback re-registers `OnReceive` on its own connection.
- **Consequences:** A guarantee the bridge and relay both quietly depended on is now real rather
  than accidental. Covered by `TestMessagesBeforeOnReceiveAreNotLost`, which fails without the
  fix. The suite went from 9 failures in 12 runs to 0 in 12. First diagnosis — "the 2s test
  deadline is too tight" — was wrong and was disproved by raising it to 10s and watching the same
  tests fail at 10.00s; recorded because the wrong fix looked plausible and would have buried a
  real bug under a slower timeout.

### 2026-08-16 — Selectable transport: `tcp` | `udp` | `quic`

- **Decision:** The relay connection's transport is chosen in `config.json` (`"transport"`), with
  three implementations behind the existing `Transport` interface. The relay may serve several at
  once and a room may hold clients on different transports simultaneously. **Adapters are
  unaffected and cannot observe the choice** — the bridge stays loopback TCP NDJSON permanently.
- **Status:** Implemented.
- **Context:** `brief.md` and `internal/transport`'s own doc comment both call `Transport` "the
  swappable network boundary," but it had exactly one implementation, so the claim was untested and
  nothing forced the boundary to hold. `contract.md`'s hard rule "Transport is swappable behind
  `send(bytes)`/`on_receive(cb)` from day one" was likewise aspirational. The motivation is
  modularity — and the expectation that a future game/adapter may suit one transport better than
  another — explicitly **not** throughput. Two facts found while scoping shaped everything below:
  UDP cannot be encrypted in Go (no DTLS in the standard library), and `NDJSONConn.Send` issued two
  `Write` calls, which is invisible on a stream and fatal on a datagram.
- **Options considered (where to put the seam):** (1) a second `Transport` implementation per
  protocol — the obvious reading of "swappable transport", but it would have moved framing,
  reconnect and callback handling into each one and left `internal/relay` needing a datagram-shaped
  accept path; (2) expose every transport as a `net.Listener`/`net.Conn` pair and keep `NDJSONConn`
  as the only `Transport` — more work inside the new packages, none anywhere else.
- **Resolution:** Option 2. `relay.Serve` already takes any `net.Listener` and `handleConn` any
  `net.Conn`, so **`internal/relay` gained no transport-aware line at all**, and — decisively — the
  per-connection-goroutine model survived untouched. `Client.gateMu`'s comment states that
  everything else in that struct needs no lock *because* "OnReceive is serial", which is true only
  while each connection owns a goroutine; option 1 would have required re-auditing every concurrent
  site in the relay to keep that claim honest. New packages: `internal/netx` (the `Kind` seam),
  `internal/netx/udpconn`, `internal/netx/quicconn`.
- **Resolution (framing):** One datagram carries exactly one NDJSON line. Framing is redundant on
  udp/quic but harmless, and it keeps a single `Transport` implementation for all three. This is
  what made `Send`'s two-`Write` split a real bug rather than a style point: over a datagram
  transport it is two datagrams per message, splitting every line in half with nothing downstream
  able to reassemble it. Fixed, with `TestSendIssuesExactlyOneWritePerMessage` (which fails against
  the old version — verified by reverting it, not assumed).
- **Options considered (reliability):** (1) make every transport fully reliable — simplest, but
  QUIC then head-of-line blocks exactly like TCP and buys nothing but encryption, and UDP would need
  retransmission on the 20Hz hot path; (2) make datagram transports fully unreliable — loses
  `leave`/`welcome`, which are not recoverable at any higher layer; (3) reliable by default with an
  explicit opt-out.
- **Resolution (reliability):** Option 3. `Transport` gained `SendUnreliable`, and the polarity is
  deliberate: `Send` stays reliable on every transport, so **any call site that never learns about
  the new method remains correct**. Exactly two sites opt out — `core.sendState` and the relay's
  `Room.ForwardUnreliable` — because `contract.md` already defines the state plane as lossy and
  latest-wins. A retransmitted position would arrive stale and out of order, which is worse than the
  gap it fills. `ForwardUnreliable` is a separate method rather than a flag on `Forward` so a caller
  who forgets which they wanted gets the safe one. TCP implements it as `Send`; a `net.Conn` opts in
  structurally via an unexported `unreliableWriter` interface, so `internal/transport` keeps its
  no-internal-dependencies property.
- **Resolution (UDP address validation):** A remote must echo back a cookie sent to the address it
  claimed before it gets a `Conn`, which defeats blind spoofing and stops the relay being used as a
  reflector. The cookie is **derived, not stored** — `HMAC(secret, addr || timeSlot)`, current and
  previous slot accepted. A table of unvalidated addresses would itself have been the
  vulnerability: one entry per forged hello is unbounded memory an unauthenticated stranger
  controls. Same technique as a TCP SYN cookie and QUIC's Retry. It does **not** stop an on-path
  attacker, which is the same bar TCP sequence numbers set.
- **Resolution (ports):** TCP and UDP have independent port spaces, so `tcp` and `udp` share
  `listen_on` — pinned by `TestTCPAndUDPShareAPortNumber` rather than left as a comment, because if
  it were ever false the relay would fail to start in a shipped configuration for a non-obvious
  reason. QUIC is carried over UDP and therefore **cannot** share a port with the plain `udp`
  transport, so it gets its own `listen_quic`. A host serving all three forwards three router rules
  across two port numbers.
- **Resolution (defaults):** Both ends default to `tcp`, and the shipped `config.json` says so.
  Considered and rejected: client `udp` with server `tcp`, which cannot connect at all out of the
  box. `tcp` is also the safest default (the only encryptable-later one, and the only one readable
  with netcat for debugging) and the only choice that changes nothing for existing users.
- **Resolution (per-game preference):** Expressible **only as shipped configuration** — a per-game
  `config.json` plus a note in that adapter's README. An adapter must not choose (it never learns a
  relay address and never speaks the relay protocol), and the core must not choose either, because
  branching on `game_id` in game-agnostic code is forbidden outright. Recorded here so the tempting
  version does not get built later. `contract.md`'s adapter invariant was widened at the same time:
  it previously forbade an adapter *doing* relay things but not *influencing* them, so a
  `preferred_transport` field in the bridge `hello` would have violated no written rule.
- **Consequences:** The `Transport` boundary is now load-bearing instead of decorative, and
  `contract.md`'s day-one hard rule is finally true. **`udp` can never be encrypted** — the room
  code crosses it in the clear with no fix available, which is recorded in `risks.md` and stated in
  the flag's own help text. QUIC is the encrypted option, and its `tls.ConnectionState` does expose
  a working `ExportKeyingMaterial` (checked, not assumed — `TestHandshakeIsTLS13`), so the shelved
  room-code channel-binding work in `ideas.md` would drop straight into it. **First third-party
  dependency in the repo** (`quic-go`, MIT, plus three `golang.org/x/*` at BSD-3-Clause), which
  brings a `THIRD-PARTY-NOTICES` obligation for the Go binaries and may shift the antivirus
  false-positive baseline. `go get` also raised the module's Go directive from 1.22 to 1.25.0.
  Clients still cannot discover which transports a relay offers — they must be told out of band.
  Making `Welcome` advertise them, so a client can upgrade itself, is the natural follow-up and is
  filed in `ideas.md`.

### 2026-08-16 — Transport discovery: `transport: "auto"`

- **Decision:** A client set to `auto` opens a short tcp connection, asks the relay which
  transports it serves, disconnects **without joining**, then connects for real on the best of
  them. The query is a `query_only` flag on `Hello`; the answer is a new `transports` message
  carrying kind+port pairs. Shipped `config.json` sets the client to `auto`; the relay still
  defaults to `tcp`.
- **Status:** Implemented, same day as selectable transports.
- **Context:** Selectable transports shipped with no way for a client to learn what a relay
  offers, so a host had to say "use quic, port 7780" out of band and a mismatch produced a bare
  timeout. The user's goal: if a relay enables all three, clients should end up on the best one
  with no configuration.
- **Options considered:** (1) **auto-probe** — impossible, and this is the crux: quic runs on a
  *different port*, and a client only ever knows one address, so there is nowhere to probe;
  (2) **advertise in `Welcome`, then reconnect** — one optional field, no new message type, but
  the client has already joined by then, and `contract.md` guarantees no session resumption, so
  every other player in the room watches it leave and rejoin; (3) **advertise in `Welcome` and
  only log it** — cheapest, fixes the confusing timeout, but automates nothing; (4) **ask before
  joining**.
- **Resolution:** Option 4, chosen by the user for the reason that decides it — no console noise
  and no visible churn, because nothing ever joins twice. Options 2 and 3 were the same protocol
  change and could have been staged, but both leave a leave/rejoin flicker or leave the work
  manual.
- **Resolution (and the thing that made option 4 acceptable):** **the query answers only after
  every check a real join passes — field lengths, protocol version, and the room code.** The
  serious objection to asking first was that it would become the relay's only pre-auth endpoint,
  a hole in exactly what the 2026-08-14 hardening pass closed. Running the checks first removes
  it entirely: a caller learns nothing it could not have learned by joining.
  `TestQueryOnlyStillRequiresTheRoomCode` pins it.
- **Resolution (port, not address):** An offer carries kind and **port only**. A relay bound to
  `0.0.0.0` has no idea which address reaches it from outside, whereas the client necessarily
  knows one — it just connected to it. Sending only the port makes discovery work through NAT and
  port forwarding without the relay ever learning its own public address.
- **Resolution (preference order):** `quic`, then `tcp`, then `udp` — and **`auto` never selects
  `udp` unless it is the only thing offered**, despite `udp` sharing quic's loss behaviour,
  because it cannot be encrypted at all. Auto-selecting it would silently downgrade a user's room
  code to plaintext on a relay that also offered quic. Naming `udp` explicitly still works;
  nothing picks it on someone's behalf.
- **Resolution (failure is never fatal):** Every failure path returns `(tcp, the configured
  address)` — relay down, relay old, wrong room code, no reply, malformed reply. Discovery can
  therefore only improve a connection, never prevent one, and the real connect attempt produces
  the real error. `protocol.Version` stays at 1: `query_only` is an additive optional field, same
  precedent as `room_code`.
- **Consequences:** A host no longer has to explain ports to anyone, which was the actual
  onboarding cost of having three transports. Costs one extra short-lived tcp connection per
  startup. **Against a pre-2026-08-16 relay**, `query_only` is an unknown field, so that relay
  joins the client for real and replies `Welcome`; the client recognises this, logs "older
  build — using tcp", and closes — which such a relay reports to its room as one spurious
  join/leave. That is the price of an additive field over a version bump, it affects old relays
  only, and it is strictly better than the timeout it replaces. Relays still default to `tcp`, so
  `auto` changes nothing until a host opts in.

### 2026-08-16 — Revision: the handshake is always tcp; `transport` is the upgrade target

- **Decision:** Supersedes the two ADRs above in one respect. A client **always** connects over
  tcp first, and that is not configurable. `transport` in `config.json` no longer means "how to
  connect" but "what to move to once connected": `tcp` stays put, `udp` (the shipped default) and
  `quic` upgrade if the relay serves them, `auto` takes the best on offer. **tcp is now mandatory
  on the relay too** — `netx.ParseKinds` prepends it whether or not the operator names it.
- **Status:** Implemented, same day.
- **Context:** The user's framing, and it is better than what shipped hours earlier: discovery
  should be an unconditional property of connecting rather than a special `auto` mode. The first
  design left `tcp`/`udp`/`quic` as three parallel ways to connect, which meant a client had to be
  told which port a transport lived on and got a bare timeout when it guessed wrong.
- **Resolution and what it buys:** (1) **a client never needs to know a port** — quic's differs
  and is unguessable, so it is learned during the handshake and `connect_to` only ever needs the
  tcp address; (2) **a wrong preference degrades to a working tcp session plus a log line**
  instead of a timeout; (3) the one leg that must work is always the transport that works
  everywhere and is readable while debugging.
- **Resolution (tcp mandatory on the relay):** **Found by `internal/e2e`, not by reasoning** —
  a udp-only relay became unreachable by every client the moment the handshake became
  unconditional, including clients configured for udp. `ParseKinds` adds tcp silently rather than
  refusing to start: the operator still gets exactly what they asked for, plus the leg that makes
  it reachable. This is the clearest case yet for the e2e rig existing, since every package-level
  test still passed.
- **Resolution (an explicit preference does not rank):** A client asking for `quic` considers only
  quic, and falls back to tcp if it is absent — it must never silently land on `udp`, which would
  swap an encrypted session for one that cannot be encrypted. Only `auto` ranks.
- **Resolution (default `udp`), and the tradeoff recorded plainly:** the shipped client default is
  `udp`, chosen by the user so that a host who enables more than tcp automatically gets clients off
  the head-of-line-blocking path. Two honest caveats, neither of which changes the decision but
  both of which belong on the record: **`udp` is not lower latency on a link that is not losing
  packets** — all three deliver identically there, and the benefit appears only under real loss;
  and **`udp` cannot be encrypted**, so on a relay serving both udp and quic, a default client
  takes the unencrypted one and its room code crosses in the clear where quic would have protected
  it. `auto` exists precisely to prefer quic and is a one-word change in `config.json`. Relay
  defaults remain tcp-only, so default-vs-default is unchanged and this only bites once a host
  opts in.

  **The full rationale, after the point was pressed three times — udp is the leanest transport,
  and that is the real reason, not latency.** (1) **Overhead**: a raw udp datagram carries 10
  bytes of framing here (2 control + 8 token), where a quic datagram adds a packet header plus a
  16-byte AEAD tag — roughly 30-40 bytes more per packet, ~15-20% on a typical ~200-byte state
  message, plus per-packet encryption CPU. udp is genuinely the cheapest option and quic is not
  free. (2) **Ordering does not matter** to a latest-wins state plane, so udp gives up nothing
  the state plane wanted. (3) **The usual counter-argument does not apply**: udp's headline
  advantage is hole-punching for P2P, and this is a star topology through a relay, so that was
  never on the table either way (`internal/README.md`'s own NAT note).

  **What the default does NOT buy, recorded because it was the initial motivation and is false:**
  lower latency. All three transports deliver at identical speed on a link that is not losing
  packets; what udp and quic remove is head-of-line blocking *when a packet is actually lost*.
  The choice is loss tolerance and low overhead versus confidentiality, not speed versus safety.
- **Consequences:** Every connection now costs one extra short-lived tcp connection *unless* the
  preference is tcp, which short-circuits. `netx.Auto` survives as a supported value rather than
  the mechanism. The e2e transport tests now serve `tcp,<kind>` and point clients at the tcp
  address for every kind, which is what a real deployment looks like.

### 2026-08-16 — UDP per-connection token (the second half of the CelesteNet measure)

- **Decision:** After admission, every udp application datagram carries an unpredictable 64-bit
  per-connection token issued by the listener. Datagrams without it, or with the wrong one, are
  dropped — including bare NDJSON lines, which were previously valid unreliable payloads.
- **Status:** Implemented, same day, prompted by the user asking whether the CelesteNet UDP
  measures were needed here.
- **Context:** The transport shipped with an address-validation cookie, which gates **admission**
  — it proves a source address is real, defeating blind spoofing and reflection. It does nothing
  afterwards: a connection was identified by source address alone, so anyone able to spoof a live
  client's ip:port could inject state into its session. `internal/README.md` had cited CelesteNet's
  unpredictable token as precisely the reason TCP is safer by construction, and then the udp
  transport shipped without it.
- **Options considered:** (1) leave it and document the gap — defensible on threat modelling
  alone, since exploiting it needs the victim's IP from outside MeshGhost (the relay never calls
  `RemoteAddr`), source-IP spoofing that most ISPs filter, and pays out only in cosmetic griefing;
  (2) add the token.
- **Resolution:** Option 2, and the deciding argument was not the threat model but the
  documentation: shipping a udp transport that omits the exact measure our own prior-art notes
  cite as making TCP safer is a claim the code fails to honour. 64 bits clears the bar TCP's
  32-bit sequence number sets. Cost is 8 bytes per datagram, ~4% on a typical state message.
- **Resolution (bare payloads had to go):** Unframed NDJSON datagrams were dropped, because
  leaving them accepted would have made the token optional in practice — a sender could simply not
  use it. This cost the "a datagram is literally a greppable NDJSON line" property, which was
  genuinely nice and is now gone on udp.
- **Consequences:** Two distinct defences with two distinct jobs, documented as such: the cookie
  gates admission, the token gates the session. **Neither is encryption** — an on-path attacker
  reads both straight off the wire, the same limit TCP sequence numbers have, and the reason
  `quic` exists. Covered by a forged-datagram regression test and a bypass test, with fuzz seeds
  for every token-carrying frame shape. Technique taken from prior-art notes only; no CelesteNet
  code was read or copied, per `licensing.md`'s facts-not-code rule.

### 2026-08-16 — An adapter may start its own local core process (autostart)

- **Decision:** A game adapter may spawn `meshghost.exe` itself, hidden, when a bridge connect
  attempt finds nothing listening — and passes it no relay settings, only a working directory.
- **Status:** Implemented for Pseudoregalia the same day (`CoreLauncher.cpp`, plus
  `-exit-with-pid`/`show_console` on the client). **Not yet watched running** — TEVI and Emerald
  deliberately not converted until it is.
- **Context:** A Pseudoregalia speedrunner tried MeshGhost and reported that having to launch a
  second program defeats the point: the interactions worth having were the unplanned ones, both
  people just having it on while practising, and nobody starts a separate client for an encounter
  they haven't planned yet. Every doc said "double-click meshghost.exe, leave the window open,
  then start the game" — a per-session step that converts ambient presence into a deliberate act.
- **Options considered:** (1) a tray app / run-at-login service — best "always on", but a resident
  process is a bigger ask and needs a tray UI and startup registration that don't exist;
  (2) the mod spawns the client; (3) leave it, and treat the friction as inherent.
- **Resolution:** Option 2, chosen by the user, with the window hidden (`CREATE_NO_WINDOW`) so it
  reads as *server + game* rather than *server + client + game*. Reuse-before-spawn falls out of
  hanging it off the connect-failure path: a core that is already running — started by hand, by
  another game, or natively on the Linux side of a Proton prefix — is found and used, never
  duplicated, and never killed by a mod that didn't start it.
- **Resolution (why a working directory and not `-relay`):** The contract says an adapter has no
  say in *how* the core reaches the relay. Passing the address on the command line would have been
  the obvious implementation and would have broken exactly that, in the same shape as the rejected
  `preferred_transport` bridge field. Setting the child's cwd instead means the core reads its own
  `config.json` as if a human had launched it there, and the adapter passes only what was already
  its business: its bridge port, and a pid to exit with. Contract amended in `contract.md`.
- **Resolution (the exe ships beside the mod, and only where it must):** Pseudoregalia and TEVI
  install *into the game's* directory tree, so after a drag-and-drop install nothing points back
  at the unzipped release folder — the exe and a client-only `config.json` have to ride along in
  the mod folder. Emerald does not: its script is loaded from the release folder itself, so it
  reaches the root exe and config with no second copy. The duplication is forced by the install
  model, not chosen, and should not be copied to adapters that don't need it.
- **Resolution (one owner per setting):** `local_game_bridge` is deliberately absent from the
  mod-folder config — the mod passes `-bridge` when spawning. TEVI already had this split (its
  port lives in a BepInEx cfg while the core reads `local_game_bridge`), and a config sitting
  *directly beside* the mod that the mod partly ignores would have been a worse version of it.
- **Consequences:** The client's log stops being a backup and becomes the only channel a remote
  tester can send back, so it now appends rather than truncating (a respawned client used to erase
  the evidence of why the last one died), carries a per-run banner, and says which `config.json`
  it actually loaded — a missing one used to be silent, which with no console is indistinguishable
  from "my settings did nothing". A spawn that fails outright produces no client log at all, so
  the mod logs that outcome to UE4SS's own log. **The real cost is antivirus**: a game mod
  silently starting an unsigned, already-false-positive-flagged exe is the literal shape of a
  dropper, and this raises the priority of the unstarted SignPath code-signing work
  (`risks.md`). `MESHGHOST_NO_AUTOSTART` is the escape hatch, and the manual path is unchanged.

### 2026-08-16 — Amendment to the autostart ADR: the Wine console valve is removed

- **Decision:** Delete the default that turned the client's console window on under Wine. Keep
  `show_console` for real Windows, and keep Wine detection only to say a console cannot appear.
- **Status:** Done same day, after the Linux tester ran v0.7.0 under Proton.
- **Context:** The original ADR shipped a safety valve: under Wine, show a console by default, so
  an autostarted client that outlived its game could at least be seen and closed. Its own code
  comment set the condition for removing it — *"if the client reliably dies with the game there,
  this becomes noise rather than a valve."*
- **What the test showed:** both halves were wrong. The window never appears (Wine emulates a
  console only through wineconsole/conhost, and a Proton-launched game has no backend for it —
  `AllocConsole` can return success and produce nothing), and `-exit-with-pid` reaps the client
  across the Wine boundary anyway, six sessions out of six. The valve guarded a door that was
  already shut, with a lock that did not work.
- **Consequences:** One less platform special case, and one fewer promise the client makes that it
  cannot keep. The honest replacement is a single log line when `show_console` is set under Wine.
  **The general lesson is the one worth keeping**: a mitigation written for an unmeasured risk
  should carry its own removal condition, because the measurement usually arrives later and
  quietly — this one did, in a tester's log, and would otherwise have stayed forever.
