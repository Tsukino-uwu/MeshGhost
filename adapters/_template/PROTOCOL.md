# Adapter protocol stub

<!-- line-cap: 600 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

Language-agnostic. Every real adapter (BizHawk Lua, TEVI's BepInEx plugin, Pseudoregalia's
UE4SS/C++ mod) implements this same shape by dialing the local core's bridge port and speaking
NDJSON — see
`agent_docs/contract.md`'s "Adapter bridge" and "Adapter interface" sections for the full,
authoritative spec. This file is a condensed, copy-from starting point, not a replacement for
reading that file first.

**Keep this template current.** Anything a shipped adapter learns about speaking the bridge — a
retry rule, a framing trap, a field an adapter must send — belongs back here in the same pass.
`_template/` is the gold standard the next game starts from; see `README.md`'s standing rule at the
top. (Contract *changes* themselves are a different act: they are ADRs against
`agent_docs/contract.md`, and this file follows that file rather than leading it.)

## Connecting: where, and send hello first

The bridge listens on `127.0.0.1:7778` by default (`packaging/release/config.json`'s
`local_game_bridge`). **Make the port overridable per instance — an env var, a config entry,
anything — do not hardcode it.** Two copies of the same game on one machine is how every adapter
in this repo got tested, and two instances sharing one default port fail silently, with both
logging a normal "connected" line: it cost a full debugging session once
(`dev-scripts/README.md`). TEVI takes one port from a BepInEx `BridgePort` entry; Pseudoregalia,
Emerald and Crystal all **walk a small range** instead, which is the better shape and is described
below — the two Lua adapters still honour `MESHGHOST_BRIDGE_PORT`, and an explicitly named port is
then used rather than walked. Log the port you actually resolved when you connect.

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
build number read from memory** — none of the four shipped adapters read one (there's no cited
address for it, and `CLAUDE.md`'s "no addresses/APIs from memory" rule means one isn't guessed
at), and an adapter-script version is the more useful signal anyway: it catches two peers
running different revisions of *this adapter*, the most likely real source of a silent protocol
mismatch. Leave it empty (or omit the field) if you have no version concept at all — an empty
`game_version` is never treated as a mismatch against a room that already has one declared.

`render_all_areas` is a third optional field, added 2026-08-20 (`bridge`'s `Hello.RenderAllAreas`,
ADR in `agent_docs/architecture.md`). Set it and the core delivers **every** remote's state
regardless of `area_id`, handing all area-based hiding — and the despawns that go with it — to your
adapter. **Only set it if your adapter can translate a neighbouring area's coordinates itself**:
Emerald does, because it knows the game's own map-connection graph, and the core's equality test
cannot. It is adapter-local and deliberately **not** a room feature — it changes what your own core
sends you and nothing on the wire, so it cannot fragment room compatibility. Absent means false,
which is the core's own cross-area filter as before.

`features` is the fourth optional field, and the only way an adapter opts into anything past cosmetic
ghosts (`bridge`'s `Hello.Features`, merged into whatever the core itself was configured
with and forwarded to the relay). **Omit it unless you have actually implemented a plane.** A room's
feature set is matched *exactly* and is sticky for that room's life, so advertising a capability you
do not use is not a spare ability — it makes your adapter unable to share a room with any adapter
that did not advertise the identical list. All four shipped adapters omit it. What the planes are:
"Beyond cosmetic" at the bottom of this file.

### Every `hello` is answered — `bridge_ready` or `reject`

Added 2026-08-16 (`bridge/bridge.go`, ADR in `agent_docs/architecture.md`). The core
replies with exactly one of:

| Message | Meaning |
| --- | --- |
| `{"type":"bridge_ready","payload":{}}` | accepted; this core is yours |
| `{"type":"reject","payload":{"reason":"..."}}` | not available — the core closes immediately after |

`reason` is for your log, **not for branching on**: the correct response to any rejection is the
same one, which is to try the next port.

**Silence is not acceptance, and this is the trap worth taking on faith.** Before the ack existed,
an adapter could only infer success from the absence of a hangup — indistinguishable from a core
still binding its port, from a crashed core, or from an unrelated program holding a port in your
range. **An adapter that gets neither answer within a short window (Pseudoregalia allows 1.5s) must
drop that socket and move on**, not assume it worked. This shipped the other way round for one
build, treating silence as an old core and committing to it, and a test that squats a port with a
listener that never speaks (`internal/e2e`'s `TestPortWalkFindsAFreeCore`) showed the trade was
backwards: skipping a core that is merely old costs nothing, because you then start your own on a
free port and everything works, while committing to a squatter costs the whole session.

### One core per adapter, so walk a range rather than taking one port

**A core serves exactly one adapter at a time** (`agent_docs/contract.md`) — a second bridge
connection is answered with `reject` and closed. This is enforced because it was not, and the gap
was not theoretical: two adapters on the *same* `game_id` were both accepted and then shared one
relay session, fighting over one `player_id`, one `seq`, one send-rate budget and one `area_id`,
with both sides logging a normal connect. Two copies of one game on one machine is a normal thing
to do — it is how most adapters here were tested.

So the shape to copy is a **port walk**: probe `7778` upward across a small range (Pseudoregalia
sweeps 8 ports) and take the first core that answers `bridge_ready`. Three things it got wrong
first:

- **Sweep the whole range per cooldown, not one port per cooldown.** Each candidate costs a couple
  of milliseconds, so a full sweep still fits inside a frame — whereas one port per 2s reconnect
  interval takes 16 seconds to find a free core eight ports up.
- **Remember a port that said `reject`, and skip it for a while** (Pseudoregalia: 10s). It is a
  live core that simply is not yours; re-probing it every sweep is noise.
- **Log which port you landed on.** With a walk, "connected" no longer implies a known port, and
  the port is the first thing you need when two instances behave as one.

### Starting a core yourself (autostart)

**An adapter MAY start its own local core process** (added 2026-08-16, ADR in
`agent_docs/architecture.md`) — hang it off the connect-failure path, so a core that is already
running is *found and reused*, never duplicated. That is a lifecycle act, not a protocol one, and
the bridge invariant is unchanged by it. Three rules, each of which is the whole point:

- **Pass no relay settings. Ever.** Not the address, not the transport, not the rate. `-relay` on
  the command line would be the obvious implementation and would break the contract's "an adapter
  has no say in how the core reaches the relay" — the same shape as a rejected `preferred_transport`
  bridge field. Set the child's **working directory** instead, and it reads its own `config.json`
  there exactly as if a human had launched it in that folder. The only arguments that are yours to
  pass are ones that were already your business: your bridge port, and a pid for the core to exit
  with.
- **Only ever stop a core you started yourself.** One you merely found belongs to whoever started
  it. For the same reason, spawn on the lowest port that had *nothing listening*, never on one that
  answered and said it was busy.
- **Give the user an escape hatch and expect antivirus trouble.** A game mod silently starting an
  unsigned exe is the literal shape of a dropper. `MESHGHOST_NO_AUTOSTART` skips the spawn, and the
  manual path stays unchanged. See `agent_docs/risks.md`.

Because the core is then hidden, its log becomes the only channel a remote tester can send back:
append to it rather than truncating, and say which `config.json` was actually loaded.

### The bridge is always loopback TCP, whatever the relay is doing

The relay connection is selectable (`tcp`, `udp`, `quic`) and, since 2026-08-16, defaults to
**quic** — every connection still handshakes over tcp and only then upgrades, and quic shares the
relay's own port number so hosting means forwarding one port. **None of that reaches an adapter.**
The bridge is loopback TCP NDJSON in every configuration, and nothing you send across it may
influence which transport the core picks. If a new game seems to want one, that is shipped
configuration on the core side, never a bridge field.

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

## Two core -> adapter messages this document used to omit, and every adapter that skipped them

**Added 2026-08-30, because `_template/` had lagged and it cost real behaviour.** An adapter built
from this file handled `render_remote`, `despawn_remote`, `bridge_ready` and `reject` — the four
described above — and silently ignored the two below, because nothing here said they existed. That
is why `ghost_collision` currently does nothing in any game and why nametags reach one adapter of
four. **They are not optional, and they are not new: both ship today.**

```json
{"type":"session_policy","payload":{"ghost_collision":"enabled"}}
{"type":"remote_name","payload":{"player_id":"p2","display_name":"Alice"}}
```

- **`session_policy`** carries the room-wide policy the host set, resolved by the core against this
  client's own preference before it reaches you. `"disabled"` is BINDING — no ghost blocks anything,
  at any time. It arrives right after `bridge_ready` and may arrive again if the policy changes.
  **HOW you honour it is yours** (do not spawn a solid object, free a collision slot, clear a
  capsule's collision — whatever this game requires); THAT you honour it is not. **An adapter that
  genuinely cannot honour `"disabled"` must say so in its own log, once, rather than silently
  appearing to comply** — nothing checks and nothing can, so the log line is the only signal a
  player or a maintainer will ever get.
- **`remote_name`** carries a peer's chosen nametag, sent when it becomes known: on join, and again
  for every already-present peer when an adapter attaches to a room that is already populated.
  Drawing it is per-game work — Pseudoregalia draws text on a coloured plate above the ghost — and
  a game where readable text is genuinely impractical should log that once, for the same reason.

**The general rule, which is why these two are called out rather than just listed:** a setting in
the shared config template is generic by definition — it is what the PLAYER wants, not a fact about
any game — so every adapter honours it with its own mechanism. Only the mechanism and its tuning are
per-game, and the tuning belongs in this adapter's `FLAGS.md`, never in the player's config. See
`adapters/CLAUDE.md` and `agent_docs/plans.md`'s "Settings: defined once, honoured everywhere".
They *are* present on the `state` you receive back in `render_remote` (the core forwards the
full stamped state), so don't treat seeing them inbound as a protocol error.

`orientation` is opaque *any-JSON* to the core (`agent_docs/contract.md`), not specifically a
string — it's whatever shape your adapter needs: a compass string (Emerald), an angle, a
quaternion object. The core never parses it, so nothing here validates its contents; your
adapter's own consumer of a received `orientation` is responsible for treating it as untrusted
(see the peer-controlled-data note below).

`extras` is load-bearing, not decorative — every one of the four shipped adapters relies on it
for real per-game data the core schema has no field for: Emerald carries player gender in it,
Crystal carries the sprite id its spawned object event should wear, TEVI carries its room-grid
coordinates for the map marker, and Pseudoregalia carries movement/action state enums for its
Animator. Treat it as "your adapter's private channel to itself across the
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

Those four types are the whole cosmetic contract, and three of them are the three functions above.
The bridge defines **nine more** (`bridge/bridge.go`), every one of them inert unless your
`hello` asked for the matching plane: `bridge_ready`/`reject` are the handshake pair above, and the
other seven are in "Beyond cosmetic" at the bottom of this file.

## The tick loop (the part every real adapter gets wrong the first time)

```text
loop, once per real game frame:
    clear whatever was drawn last frame (if the render target doesn't auto-clear — confirm
        this for your engine; BizHawk's gui.* does NOT, see the correction in
        agent_docs/contract.md's tick model)

    if not connected to bridge:
        if at least ~2s since the last attempt:      # NOT every frame — see below
            sweep the port range (non-blocking connects), taking the first that accepts
            on connect: clear the remote-ghost map, then send hello(game_id)
            if nothing was listening anywhere, optionally start a core yourself

    else if no bridge_ready yet:
        drain messages looking for the core's answer
        on reject, or ~1.5s with no answer at all:
            drop the socket, mark that port busy, and sweep again next time

    if connected AND the core answered bridge_ready:
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
`adapters/emulator/pokemon/emerald/probes/phase3_loopback.lua`'s header for the specific bug this project hit live
before that rule was written down.

Six things in that loop are there because a shipped adapter got them wrong first:

- **Drain the bridge *below* your "am I in play" gate, not above it.** The drain is what creates
  ghosts, so draining first means a peer's `render_remote` can spawn one during the exact frame
  the gate exists to protect — and the gate then destroys it again on the same frame, which reads
  as a flicker rather than as the ordering bug it is. Send `local_state` (possibly `null`)
  unconditionally; only drain once you have confirmed the local player exists. TEVI moved its
  drain below the gate on 2026-08-18 for exactly this reason.

- **Do not start sending `local_state` until `bridge_ready` arrives.** "The socket connected" is
  not "a core accepted me" — see the handshake section above for what silence actually turns out to
  be.

- **Throttle reconnects (~2s), don't retry every frame.** A per-frame connect against a dead
  core is on the order of 200 socket create/connect/abort cycles per second. TEVI and
  Pseudoregalia independently landed on the same 2s interval.
- **Clear the remote-ghost map on connect *and* on disconnect.** `despawn_remote` is not
  guaranteed to arrive: if the core process exits or is restarted, nothing tells you, and a
  peer's ghost stands frozen on screen indefinitely. All four adapters hit this live.
- **Treat "timeout"/"would block" as the *only* harmless socket result** — everything else is
  fatal. The intuitive inverse (special-case "closed" as fatal, treat the rest as a timeout) is
  what Emerald shipped in Phase 3 and Pseudoregalia repeated in C++; it silently converts a dead
  connection into a permanently frozen ghost.
- **Keep sending `local_state` every frame, including `null`.** The core only emits
  `render_remote`/`despawn_remote` in reply to a local frame (`core/core.go`'s
  `onAdapterFrame`) — there is no independent push. An adapter that optimizes away nil or
  unchanged sends stops receiving ghost updates entirely, and it looks like a frozen ghost, not
  a protocol error. For the same reason, **stay connected through menus and pauses and send
  `null`** rather than closing the socket: closing it is a real relay `leave`, and reconnecting
  gets you a brand-new `player_id` (`agent_docs/contract.md`).
  **The one case where disconnecting is the right answer is leaving the session for real** — a
  return to the main menu or title, where you genuinely are gone and a peer seeing your ghost
  vanish is correct. Name the state exactly when you implement this: TEVI drops the bridge and
  despawns every peer ghost on a **main menu** return, and deliberately does neither on the pause
  overlay, where peer ghosts staying visible is the wanted behaviour. In a game with both, "menu"
  alone is not a specification — it produced a false regression report on 2026-08-18.

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

Enforced by `protocol/limits.go` and `online.go`, and the relay (`relay/limits.go`
for the two handshake fields). Oversized *values* are dropped *silently* — the bridge itself doesn't enforce
them, so a too-big `extras` sails across the bridge and disappears later, which is a miserable
thing to debug:

| Field | Limit | Where |
| --- | --- | --- |
| `extras` | 1024 bytes (serialized) | `protocol.MaxExtrasBytes` |
| `position` | 8 elements | `protocol.MaxPositionLen` |
| `orientation` | 256 bytes | `protocol.MaxOrientationBytes` |
| `area_id`, `anim` | 256 bytes each | `protocol.MaxAreaIDLen` / `MaxAnimLen` |
| whole line | 4096 bytes | `protocol.MaxLineBytes` |
| `game_id`, `game_version` | 128 bytes (refused at handshake) | `protocol.MaxHelloFieldLen` |

The whole-line limit is the one exception to "dropped silently": exceeding it kills the
*connection*, not the message, because it trips `bufio.Scanner` at the read itself. In practice
it is unreachable — the per-field caps above sum to well under 2KB.

Each deeper plane brings its own bounds, with the same silent-drop behaviour and one extra hazard —
see "Beyond cosmetic" below.

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
(`core/core.go`'s `remoteStatesAt`) — unless your `hello` declared `render_all_areas`, which turns
that filter off and makes area visibility entirely your adapter's job — and interpolation refuses
to blend across an `area_id` change. So an unstable `area_id`, or returning nil during transitions, makes remotes
despawn and reappear for no visible reason. Note there are **three** ghost states, not two: alive,
hidden-because-the-peer-is-elsewhere (still in your map, just not drawn), and actually despawned.

## Ghost lifecycle: confirm your despawn actually frees

`despawn_remote` must remove the entry from your map, not just hide the visual. TEVI leaked a
clone per reconnect twice by only deactivating the GameObject and leaving the dictionary entry
alive. Where the engine has no reliable runtime destroy, park the actor far offscreen instead —
but still drop the map entry. **Re-test that premise before inheriting it**: Pseudoregalia was the
worked example of "no reliable destroy" and is no longer one. The finding turned out to be a
property of the *hijacked* actor it used at the time, not of the engine, and once the ghost was one
it had spawned itself, `K2_DestroyActor` worked. The park survives there only as a fallback.

Two more traps if your ghost is a clone of the real player, which is how all four adapters
ended up building it (Crystal's is the loosest: a live NPC used as the template, wearing the
player's own sprite):

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

And once you have looked: **a fix that compensates rather than prevents is not a finished feature**
— see this folder's `README.md` for the rule and its one narrow exception. "Almost right" in an
adapter has a habit of becoming the next bug rather than staying put.

## Beyond cosmetic: seven more message types, all opt-in, none of them used yet

Read this section when you actually want one of these, not before. **No shipped adapter uses any of
them**, the core forwards nothing it never receives, and an adapter that omits `features` behaves
exactly as if none of it existed. `agent_docs/contract.md` is authoritative for what each plane
*means*; what follows is the bridge-side vocabulary and the rules that bite an adapter author.

| Type | Direction | Needs | What it is |
| --- | --- | --- | --- |
| `event` | **both ways** | `event.v1` | one addressed, reliably-ordered message to another player. The only bridge message that travels in both directions. |
| `lease` | adapter → core | `lease.v1` | claim / renew / release an exclusive, *timed* grant over an opaque key. |
| `lease_state` | core → adapter | `lease.v1` | who holds a key right now, and until when. |
| `escrow` | adapter → core | `escrow.v1` | one step of a both-or-neither exchange: open / deposit / commit / abort. |
| `escrow_state` | core → adapter | `escrow.v1` | what the exchange actually is now. |
| `world` | adapter → core | `world.v1` **and** `lease.v1` | `set` or `drop` one entity's opaque blob, under an authority lease you already hold. |
| `world_state` | core → adapter | `world.v1` **and** `lease.v1` | a live write from the current host, the whole world on adoption or join, or a refusal. |

Asking for them is one field on the `hello` you already send:

```json
{"type":"hello","payload":{"game_id":"emerald","game_version":"phase5.5","features":["lease.v1","world.v1"]}}
```

**`world.v1` needs `lease.v1` named separately in the same list.** Neither implies the other and the
relay will not add it for you — implying it would change the sticky feature-set string and silently
stop matching rooms that already agreed on the old one. A room with `world.v1` and no `lease.v1`
denies every world write and says so once, in the relay's own log, which you cannot see.

Five rules, each of which fails silently rather than loudly:

- **Ask before acting, never announce after.** A `lease` is a request; the answer is a `lease_state`,
  asynchronously. An adapter that acts locally and then claims has put the refusal *after* the effect
  is already on screen, and this project does not solve rollback.
- **A request and a fact are separate types on purpose.** Never treat your own unanswered request as
  the room's state.
- **Apply an exchange on phase `committed` and on no other phase.** Every other phase, including
  "both sides deposited", can still end in an abort.
- **Apply `world_state` in `seq` order, and ignore anything older than what you already applied for a
  key.** The relay guarantees a total order, but reliable and lossy delivery to one peer are
  independent, so a lossy write can land ahead of the reliable snapshot meant to seed it. And **never
  roster-filter a `world_state`** — a world entry legitimately outlives the player who wrote it, and
  `holder` may name someone who has already left.
- **A world write that creates a key must be `reliable`, and a lossy write replaces the whole blob.**
  So never put a continuously-superseded field and one that must never regress in the same blob: an
  inbound reorder drags the whole thing backwards, the relay's copy becomes the stale one, and the
  next snapshot spreads the regression instead of repairing it. Discrete state on its own key,
  reliable; position on another, lossy.

Bounds (`protocol/online.go`), dropped silently like the cosmetic ones — and derived from
the **datagram** limit rather than `MaxLineBytes`, because an oversized datagram is refused *even on
the reliable plane* and reported only as a line in the relay's log:

| Field | Limit | Where |
| --- | --- | --- |
| `event` payload | 1024 bytes | `protocol.MaxEventBytes` |
| `event` `corr_id` | 64 bytes | `protocol.MaxCorrIDLen` |
| lease `key`, world `authority` | 128 bytes | `protocol.MaxLeaseKeyLen` |
| escrow `id` / one escrow blob | 64 / 1024 bytes | `protocol.MaxEscrowIDLen` / `MaxEscrowBlobBytes` |
| world `key` | 64 bytes | `protocol.MaxWorldKeyLen` |
| world `blob` | 768 bytes | `protocol.MaxWorldBlobBytes` |
| entities per room | 64 | `protocol.MaxWorldKeysPerRoom` |
| `features` | 16 names, 64 bytes each | `protocol.MaxFeatures` / `MaxFeatureLen` |

**And custody is not permission to write a save.** The relay handing you a canonical world makes "I
am the host now, so write it in" the most plausible-sounding version of the one thing this project
never does — see this folder's `README.md`.

## Reference implementations

- `cmd/meshghost-fakeadapter/world.go` — the only worked example of the planes above: it drives a
  shared world through repeated host handovers and checks five invariants while doing it. Read it
  before writing an adapter that uses `world.v1`, not after.
- `adapters/emulator/pokemon/emerald/meshghost_emerald.lua` — the shipped Emerald adapter, including the
  hello send right after connecting (search for `GAME_ID`). Its connection/tick-loop shape
  transfers to a new game; its game-memory reads do not.
- `adapters/tevi/MeshGhostTevi/BridgeClient.cs` / `Plugin.cs` — the same shape in C#/BepInEx.
  Notably, its hello is sent from the main-thread `Update()` loop (`SendHelloIfNeeded`), not
  from the background connect thread that establishes the socket — worth reading if your
  adapter also does networking off the main thread.
- `adapters/pseudoregalia/MeshGhostPseudo/Mod/src/BridgeClient.cpp` / `.hpp` and `Plugin.cpp` —
  the same shape again in plain C++/Winsock over a UE4SS mod, no Lua or managed runtime
  involved. **The first adapter to implement the port walk and the `bridge_ready` handshake**, and
  the shape both Lua adapters then copied, so read it for those; `CoreLauncher.cpp` beside it is
  the reference for autostart. Also worth reading for the raw-socket version of the
  partial-send/partial-receive framing concerns this file's tick loop glosses over, and for
  `Plugin.cpp`'s despawn path (`agent_docs/pitfalls.md`), which destroys the ghost and keeps
  "move offscreen" only as the fallback for an engine with no reliable runtime destroy call.
- `cmd/meshghost-fakeadapter/main.go` — not a template for a real adapter (it uses the
  in-process `core.Adapter` Go interface, not this wire protocol, since it has no separate
  process to bridge to). Useful only as a minimal example of the same three-function contract
  and tick model from the *core's* side, and as the Phase 5 proof that the core has no
  game-specific leaks — see `agent_docs/verified.md`.
