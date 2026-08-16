# Adapter protocol stub

Language-agnostic. Every real adapter (BizHawk Lua, TEVI's BepInEx plugin, Pseudoregalia's
UE4SS/C++ mod) implements this same shape by dialing the local core's bridge port and speaking
NDJSON — see
`agent_docs/contract.md`'s "Adapter bridge" and "Adapter interface" sections for the full,
authoritative spec. This file is a condensed, copy-from starting point, not a replacement for
reading that file first.

## Connecting: where, and send hello first

The bridge listens on `127.0.0.1:7778` by default (`packaging/release/config.json`'s
`local_game_bridge`). **Make the port overridable per instance — an env var, a config entry,
anything — do not hardcode it.** Two copies of the same game on one machine is how every adapter
in this repo got tested, and two instances sharing one default port fail silently, with both
logging a normal "connected" line: it cost a full debugging session once
(`dev-scripts/README.md`). Emerald uses `MESHGHOST_BRIDGE_PORT`, TEVI a BepInEx `BridgePort`
entry. Log the port you actually resolved when you connect.

The very first message on a fresh bridge connection, before any `local_state`:

```json
{"type":"hello","payload":{"game_id":"emerald","game_version":"phase5.5"}}
```

`game_id` is opaque to the core — same rule as `area_id`/`anim`, per `CLAUDE.md`: compare by
equality only, never build a cross-game vocabulary. It's what lets the core connect to the
relay without the user having to type "game" into a config file themselves (the core defers
connecting until an adapter actually shows up and says which game it is — see
`agent_docs/architecture.md`'s ADR). If the core is already connected to the relay under a
*different* `game_id` from an earlier connection, it will refuse this one — a single core
process serves one game at a time.

`game_version` is optional and equally opaque, added alongside room-code auth for relay-safety
hardening (see `agent_docs/architecture.md`'s ADR). It's what lets the relay refuse two peers on
incompatible builds before any state is exchanged, rather than letting them silently
misinterpret each other's `area_id`/`anim`. **Report your own adapter/mod's version, not a game
build number read from memory** — none of the three shipped adapters read one (there's no cited
address for it, and `CLAUDE.md`'s "no addresses/APIs from memory" rule means one isn't guessed
at), and an adapter-script version is the more useful signal anyway: it catches two peers
running different revisions of *this adapter*, the most likely real source of a silent protocol
mismatch. Leave it empty (or omit the field) if you have no version concept at all — an empty
`game_version` is never treated as a mismatch against a room that already has one declared.

## The three functions

```text
get_local_state()          -> snapshot | nil     # sampled once per adapter frame tick
render_remote(id, state)   -> void                # upsert into the adapter's remote-ghost set
despawn_remote(id)         -> void                # remove from that set
```

`nil` from `get_local_state()` means "don't send this frame" — e.g. the local player is in a
menu, loading screen, or otherwise has no meaningful position right now (see
`agent_docs/contract.md`'s closed open question on this for what Emerald decided).

## Wire form (over the bridge, one JSON object per line)

Adapter → core, once per frame:

```json
{"type":"local_state","payload":{"state":{"area_id":"...","position":[0,0],"orientation":"...","anim":"...","extras":{}}}}
```

or, when `get_local_state()` returned nil:

```json
{"type":"local_state","payload":{"state":null}}
```

`player_id`, `seq`, and `timestamp` are stamped by the core, not the adapter — leave them out.
They *are* present on the `state` you receive back in `render_remote` (the core forwards the
full stamped state), so don't treat seeing them inbound as a protocol error.

`orientation` is opaque *any-JSON* to the core (`agent_docs/contract.md`), not specifically a
string — it's whatever shape your adapter needs: a compass string (Emerald), an angle, a
quaternion object. The core never parses it, so nothing here validates its contents; your
adapter's own consumer of a received `orientation` is responsible for treating it as untrusted
(see the peer-controlled-data note below).

`extras` is load-bearing, not decorative — every one of the three shipped adapters relies on it
for real per-game data the core schema has no field for: Emerald carries player gender in it,
TEVI carries its room-grid coordinates for the map marker, Pseudoregalia carries movement/action
state enums for its Animator. Treat it as "your adapter's private channel to itself across the
wire," not an afterthought field.

Core → adapter, zero or more times per frame, one per currently-known remote:

```json
{"type":"render_remote","payload":{"player_id":"p2","state":{"area_id":"...","position":[0,0],"orientation":"...","anim":"...","extras":{}}}}
{"type":"despawn_remote","payload":{"player_id":"p2"}}
```

**Inbound `render_remote` data is peer-controlled — bound every number before feeding your
engine.** The core validates `position` for finiteness and magnitude before forwarding it (see
`agent_docs/architecture.md`'s ADR), but `orientation`, `anim`, and everything inside `extras`
are opaque JSON the core cannot inspect — a malicious or simply buggy peer can put anything in
them, including non-finite numbers, out-of-range enum values, or oversized strings. Every
adapter has needed at least one guard here in practice: Pseudoregalia clamps `extras` movement
enums to their valid range before an unchecked numeric cast (`static_cast<uint8_t>`), TEVI range-
checks `extras.room_x`/`room_y` before they reach a map-lookup call. Write the equivalent for
whatever your engine's own render call would otherwise do with an unbounded value.

## The tick loop (the part every real adapter gets wrong the first time)

```text
loop, once per real game frame:
    clear whatever was drawn last frame (if the render target doesn't auto-clear — confirm
        this for your engine; BizHawk's gui.* does NOT, see the correction in
        agent_docs/contract.md's tick model)

    if not connected to bridge:
        if at least ~2s since the last attempt:      # NOT every frame — see below
            try to connect (non-blocking)
            on success: clear the remote-ghost map, then send hello(game_id)

    if connected:
        state = get_local_state()
        send local_state(state)               # state may be nil — send it anyway
        drain all buffered render_remote / despawn_remote messages, updating the
            adapter-owned remote-ghost map (upsert / delete)
        if any socket error that is not "would block"/"timeout":
            drop the socket, clear the remote-ghost map, reconnect on the schedule above

    redraw every entry currently in the remote-ghost map, unconditionally — not only the
        ones that changed this frame. render_remote is an upsert into a set the adapter
        redraws every frame on its own clock, not a one-shot draw call; network updates
        arrive far slower than the render loop.
```

The "redraw every frame regardless of new data" rule is the one that produces flicker if
skipped — see `agent_docs/contract.md`'s tick model section for the full reasoning, and
`adapters/pokemon/emerald/phase3_loopback.lua`'s header for the specific bug this project hit live
before that rule was written down.

Four things in that loop are there because a shipped adapter got them wrong first:

- **Throttle reconnects (~2s), don't retry every frame.** A per-frame connect against a dead
  core is on the order of 200 socket create/connect/abort cycles per second. TEVI and
  Pseudoregalia independently landed on the same 2s interval.
- **Clear the remote-ghost map on connect *and* on disconnect.** `despawn_remote` is not
  guaranteed to arrive: if the core process exits or is restarted, nothing tells you, and a
  peer's ghost stands frozen on screen indefinitely. All three adapters hit this live.
- **Treat "timeout"/"would block" as the *only* harmless socket result** — everything else is
  fatal. The intuitive inverse (special-case "closed" as fatal, treat the rest as a timeout) is
  what Emerald shipped in Phase 3 and Pseudoregalia repeated in C++; it silently converts a dead
  connection into a permanently frozen ghost.
- **Keep sending `local_state` every frame, including `null`.** The core only emits
  `render_remote`/`despawn_remote` in reply to a local frame (`internal/core/core.go`'s
  `onAdapterFrame`) — there is no independent push. An adapter that optimizes away nil or
  unchanged sends stops receiving ghost updates entirely, and it looks like a frozen ghost, not
  a protocol error. For the same reason, **stay connected through menus and pauses and send
  `null`** rather than closing the socket: closing it is a real relay `leave`, and reconnecting
  gets you a brand-new `player_id` (`agent_docs/contract.md`).

## Framing: NDJSON is fragile in exactly two places

The "drain all buffered messages" line above hides the bug that has bitten every adapter here,
in three different languages:

- **Receive: keep the straddling partial line in a buffer.** A read returns whatever bytes
  happened to arrive; the last line is usually incomplete. Discarding it (easy to do in Lua,
  where a non-blocking `receive` returns `nil, "timeout", partial` and code that checks only the
  first two values drops the third) corrupts the stream from that point on. Bound the buffer too
  — Pseudoregalia caps it at 16 KB.
- **Send: a partial send is a fatal framing error, not a success.** If the socket accepted only
  part of your line, the newline may not have gone out; drop the connection rather than continue.
  The tick loop makes a dropped frame free, so this costs one frame, not correctness.

Also escape control characters when you build JSON by hand — an unescaped `\n` inside a string
turns one line on the wire into two.

**One bad line, or one bad frame, must not kill the adapter.** Wrap the per-frame work so an
error can't escape it, rate-limit the resulting error log (a per-frame error otherwise spams the
console 60 times a second), parse optional fields best-effort with defaults, and never let a
missing or wrong-typed value overwrite known-good state.

## Limits your adapter must respect

Enforced by `internal/protocol/limits.go` and the relay (`internal/relay/limits.go` for the two
handshake fields). Oversized *values* are dropped *silently* — the bridge itself doesn't enforce
them, so a too-big `extras` sails across the bridge and disappears later, which is a miserable
thing to debug:

| Field | Limit | Where |
| --- | --- | --- |
| `extras` | 1024 bytes (serialized) | `protocol.MaxExtrasBytes` |
| `position` | 8 elements | `protocol.MaxPositionLen` |
| `orientation` | 256 bytes | `protocol.MaxOrientationBytes` |
| `area_id`, `anim` | 256 bytes each | `protocol.MaxAreaIDLen` / `MaxAnimLen` |
| whole line | 4096 bytes | `protocol.MaxLineBytes` |
| `game_id`, `game_version` | 128 bytes (refused at handshake) | `relay.MaxHelloFieldLen` |

The whole-line limit is the one exception to "dropped silently": exceeding it kills the
*connection*, not the message, because it trips `bufio.Scanner` at the read itself. In practice
it is unreachable — the per-field caps above sum to well under 2KB.

## Updates are sparse: ~20 Hz, not per-frame

The core throttles sending (default 20 Hz, `protocol.DefaultSendHz`; the effective rate is the
slower of the relay's advertised `send_hz` and your own client's `min_send` — see
`Core.effectiveSendInterval`). Separately and in the other direction,
`max_receive_hz_per_player` caps how fast the relay forwards *each other player's* state to
you; it has no effect on your own send rate. Calling
`get_local_state()` every frame is correct and safe — but only ~20 samples/sec reach peers, so
**peers never observe your intermediate states.** Two consequences that are protocol-level, not
engine-level:

- **Drive animation from your own frame clock, not from packet arrival.** `render_remote` is a
  merge into an existing ghost, not a replacement — a position update every ~50ms must not reset
  which walk-cycle frame is showing. (TEVI's version of this: call `Play()` only on change, or
  the clip restarts from time 0 every frame and never visibly progresses.)
- **Send one-shot events as monotonic counters, not booleans.** A jump/land/hit flag that is
  true for one frame will usually be sampled on a frame where it's false. Pseudoregalia carries
  `land_count`/`jump_count`/`afterimage_count` in `extras` and baselines them on a remote's first
  sample so it doesn't fire a spurious pulse at spawn.

## `area_id` gates rendering — it is not just metadata

The core drops any remote whose `area_id` differs from your last non-nil local `area_id`
(`internal/core/core.go`'s `remoteStatesAt`), and interpolation refuses to blend across an
`area_id` change. So an unstable `area_id`, or returning nil during transitions, makes remotes
despawn and reappear for no visible reason. Note there are **three** ghost states, not two: alive,
hidden-because-the-peer-is-elsewhere (still in your map, just not drawn), and actually despawned.

## Ghost lifecycle: confirm your despawn actually frees

`despawn_remote` must remove the entry from your map, not just hide the visual. TEVI leaked a
clone per reconnect twice by only deactivating the GameObject and leaving the dictionary entry
alive. Where the engine has no reliable runtime destroy (Pseudoregalia), park the actor far
offscreen instead — but still drop the map entry.

Two more traps if your ghost is a clone of the real player, which is how all three adapters
ended up building it:

- **A clone deep-copies transient state at the instant you cloned it.** TEVI cloned a player
  mid-zone-fade and inherited `enabled == false` on a renderer, with no gameplay logic that
  would ever flip it back: a permanently invisible, alive, correctly-positioned ghost. Reset
  only the field you proved was wrong — the first fix forced every renderer on and white, which
  broke the outline effect.
- **A duplicate of the player class may steal control or share gameplay state.** The game was
  never written to have two live instances. Pseudoregalia's ghost auto-possessed and dragged the
  real player around, and later, with collision on, melee-ing the ghost killed the real player.
  Ghosts are visual-only: strip colliders/rigidbodies, suppress the paired SFX, never write game
  memory.

And **measure the anchor offset, don't guess it** — read the real offset at clone time. A
hardcoded constant is how both Emerald and TEVI ended up with a ghost rendering near the
player's head.

### The second object a ghost owns is where lifetime bugs come from

A ghost usually starts as exactly one engine object, and the lifetime handling written for it is
correct. The bug arrives when a peer gains a *companion* object — a dropped weapon, a held item, a
mount, an attached VFX component — because that object silently inherits every lifetime rule the
first one has, and those rules generally do not live in an obvious place.

Pseudoregalia crashed on exactly this (`EXCEPTION_ACCESS_VIOLATION` returning to the main menu,
2026-08-16, `pitfalls.md`). Its ghost pointer had always been safe because a pre-teardown hook
dropped it while it was still valid. A thrown-weapon prop added later was never added to that hook,
so a level transition freed it, and the next despawn moved freed memory.

Three rules that transfer to any engine:

- **Find where the existing reference is dropped, and add the new one there.** Not to the
  destructor, not to your despawn handler — to whatever runs *before* the engine reclaims things
  (a level-unload hook, a scene-change callback). Grep for the existing pointer and match every
  site; do not assume a new field behaves like its neighbours because it sits beside them.
- **A liveness check is not a substitute.** "Is this object still valid?" is only answerable for an
  object that still exists. Once memory is freed, the check is another read of a dangling pointer.
  The only real defence is dropping the reference while it is still valid.
- **In a pre-teardown hook, drop references and call nothing.** The engine is mid-transition; the
  level is about to reclaim all of it anyway. Calling *into* an actor at that moment is its own
  crash source, recorded separately in `pitfalls.md`.

A useful habit: when adding any engine object to a per-peer struct, write down what destroys it and
who else holds a reference, before writing the code that creates it.

## Caches die at scene/area transitions

Whatever your engine's version of "cached" is — an actor pointer, a pawn reference, a save-block
address — a level/scene/area change invalidates it. Recorded independently for UE5, GBA/Lua and
Unity; it's the most recurring bug class in the project (`agent_docs/pitfalls.md`). Related: a
`(0,0,0)` read right after a spawn or load usually means the engine hasn't placed the object yet,
not that it's at the origin.

The same shape applies at startup: **don't latch a value once at init.** An adapter loaded at the
title screen or during an intro reads whatever was true then and keeps it for the session — this
happened twice, to a gender read (before character creation) and to an address-offset detection
(during a cutscene). Gate on real gameplay and retry every frame until the read succeeds.

## Observe before you override

Protocol-adjacent restatement of the hard rule in this folder's `README.md`: **before writing
anything that forces, corrects, or fights the game, log what the game does first, read-only, and
prefer its own mechanism.**

It belongs here as well as there because the tick loop is where the temptation lives. A ghost that
looks wrong for one frame invites a correction written from a guess about what the game intended,
and this project's longest-running adapter bugs are all that shape: the camera fight-back that ended
up fighting every legitimate camera change, a trail reconstructed from predicted triggers instead of
the game's own spawns, and pulse-shaped state mirrored as though it were continuous.

If you are about to write a fix that *restores* or *remembers* a value rather than preventing
whatever changed it, stop and log the change first. The observation usually renames the bug.

## Reference implementations

- `adapters/pokemon/emerald/meshghost_emerald.lua` — the shipped Emerald adapter, including the
  hello send right after connecting (search for `GAME_ID`). Its connection/tick-loop shape
  transfers to a new game; its game-memory reads do not.
- `adapters/tevi/MeshGhostTevi/BridgeClient.cs` / `Plugin.cs` — the same shape in C#/BepInEx.
  Notably, its hello is sent from the main-thread `Update()` loop (`SendHelloIfNeeded`), not
  from the background connect thread that establishes the socket — worth reading if your
  adapter also does networking off the main thread.
- `adapters/pseudoregalia/MeshGhostPseudo/Mod/src/BridgeClient.cpp` / `.hpp` and `Plugin.cpp` —
  the same shape again in plain C++/Winsock over a UE4SS mod, no Lua or managed runtime
  involved. Worth reading for the raw-socket version of the partial-send/partial-receive framing
  concerns this file's tick loop glosses over, and for `Plugin.cpp`'s "move offscreen, never
  destroy" ghost-lifecycle workaround (`agent_docs/pitfalls.md`) if your engine also has no
  reliable runtime actor-destroy call.
- `cmd/meshghost-fakeadapter/main.go` — not a template for a real adapter (it uses the
  in-process `core.Adapter` Go interface, not this wire protocol, since it has no separate
  process to bridge to). Useful only as a minimal example of the same three-function contract
  and tick model from the *core's* side, and as the Phase 5 proof that the core has no
  game-specific leaks — see `agent_docs/verified.md`.
