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
