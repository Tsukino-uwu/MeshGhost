# 2026-09-08 — Inputs are their own track, in their own file

<!-- ADR 0056. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** a new bridge message, `input_sample`, adapter → core: what the player **pressed**,
  as an edge-batch of an opaque 32-bit mask plus opaque analog axes, with a label table the adapter
  declares once. The core writes it to a **second, independent NDJSON track** in
  `replay/inputs/`, correlated to the state recording by a shared `recording_id` and by a timestamp
  in the same clock domain. The ring is always on whenever the feature is enabled; the file follows
  the ordinary record controls.
- **Status:** Go side built and tested 2026-09-08. **Shipped off** (`replay.inputs`, default false).
  **No adapter sends it yet** — Pseudoregalia is first, and which input API is reachable there is
  unmeasured (see the open half below).
- **Scope:** capture only. Nothing plays a track back.

## Why a second track and not a field on state

The state recording reproduces **the fields we sync**. Everything the game does that we do not sync —
VFX, sound, montages, ability logic — is absent from a replay, and every gap in it is a 1:1 miss
found by hand. The user's framing, 2026-09-08: an input record *"can't get outdated if we ever start
to sync more things"*, and re-driven it *"would reproduce what the game actually does instead of
missing things we are not syncing"*.

It cannot ride the state plane, on two independent grounds. `beyond-cosmetic.md` already says that
plane *"does not grow new fields for deeper features"*. And it would be a lie at the rate: inputs
change at frame rate and one-frame presses are exactly the presses worth having, so a 15Hz sample of
them records something the player did not do.

`extras` is refused for the same reason deeper data always is — 1024 bytes, coupled to the state
sample rate, and on the wire. **A track never goes on the wire at all.**

## Why a bitmask and a label table, and not button names per sample

Three shapes were considered.

A **list of opaque string tokens** per sample (`["jump","left"]`) is the obvious game-blind form and
is wrong on size: 60–120 bytes per edge against ~10, on the track whose whole premise is being cheap
enough to leave running. It also has no stable ordering, so a future diff of two runs becomes set
arithmetic rather than `a.M ^ b.M`.

A **raw blob** is the most opaque and the least useful: nothing outside the producing adapter can
read it — not a person, not a diff tool, not a visualizer — and ADR 0051 treats hand-readable text as
a first-class property of a recording.

The **mask keeps the core strictly dumber than the token list does.** With tokens the core holds
strings it is tempted to compare. With a mask it holds one integer it compares for equality, and a
label table it copies into a file header and never reads. That is `area_id`'s rule applied to a new
value type, and it is the argument written out in `internal/gameblind`'s frozen field lists.

**32 bits, not 64.** A JSON number is a float64 to every reader that is not Go, so a 64-bit mask
silently loses bits above 2^53. The growth path is an additive second field, no format bump.

## Why the adapter names its own buttons

What counts as input is per game, and none of it is the core's business: eight buttons on a handheld,
a stick and a camera on a 3D platformer, a cursor somewhere else. The adapter declares its own table
and the core carries it.

The recommended source is the **game's already-merged action state**, not raw OS keys. That makes a
track device-agnostic and rebind-proof for free — the game has already merged keyboard, gamepad and
rebinding before we see it — and it has a property worth stating outright: an always-on track reading
raw OS keys would log whatever the player types, including in another window during an alt-tab.
Reading merged game actions structurally cannot.

A consequence, recorded so it is not later mistaken for a bug: on UE/Unity, menu clicks are usually
consumed by widgets and never become named actions, so they will mostly not appear in a track. That
is wanted — a gameplay visualizer does not want pause-menu noise. On the emulated games the opposite
is free: menus and the overworld use the same eight buttons, so the joypad *is* the whole input
surface. Nothing in the format is gameplay-only; a point-and-click adapter would simply declare
`click_left` as a bit and `cursor_x`/`cursor_y` as axes.

## Why `replay/inputs/` and nowhere else

This is a decision about two specific functions, not a filing convention.

`replayLast` plays the newest **file** in `ReplayDir` itself. `StartReplays` reads
`ReplayDir/active/`. A track in either would be picked up and parsed as a clip — and `replayLast`
chooses by mod time, so a freshly written track would win over every real recording the player has.

It is safe because `replayLast` does `if e.IsDir() { continue }`, so a subdirectory is invisible to
it. Belt-and-braces, the header's first key is `meshghost_inputs` and never `meshghost_replay`, so a
hand-copied file is refused with a sentence rather than misplayed. Both halves are pinned by
`TestReplayScannersIgnoreTheInputTrack`, because a comment does not survive a refactor.

## Edges, not samples

A button is written when it goes down and when it comes up: a one-frame press is two edges with
consecutive `f`, and no rate limit anywhere may erase it. Axes are quantized and throttled instead,
because a stick changes every frame — but an edge carrying a **button** change always emits
immediately and carries the current axes with it, so the throttle can never delay a press.

There is no delta encoding, unlike the state track's. The edge encoding *is* the delta, and a line is
four integers; the 4.4x `extrasDelta` earns comes from 40 jittering keys that do not exist here.
`gzip` still applies.

Measured shape: ~55 bytes per button edge, 10–25 edges a second in real play → **~5MB an hour**
uncompressed, plus ~7MB for axes. The cheaper of the two tracks by a wide margin, which is what makes
always-on affordable.

## Two clocks, both kept

Every line carries `ts`, the core's own stamp on receipt — the same domain `recordLocal` stamps a
state sample in, so correlating the two tracks is a numeric comparison with no offset table, and both
drift together under a virtual clock. Beside it sit `f` and `t`, the **adapter's** frame counter and
millisecond stamp, kept verbatim: one receipt stamp per batch would smear the frame spacing inside
that batch, and a hold's length has to stay expressible in frames.

## What this leaves possible, and what it does not permit

The format is deliberately sufficient to **re-drive a pawn later** without a rewrite: per-frame edges
with a monotonic counter, edges never coalesced or reordered (the adapter drops and *counts* rather
than merges, and a backwards batch is refused whole), axes from day one, and a `source` tag so a
reader built later can refuse a track it does not know how to drive.

That is not permission. Three separate things gate the follow-on:

1. **Determinism, per game.** `beyond-cosmetic.md` §7 already answers it — Emerald *"conceivable"*,
   TEVI and Pseudoregalia *"Never"* — and `ideas.md` states the failure mode: a replay that diverges
   halfway through with nothing to detect it. On the engine games a track is a faithful **record**,
   not a reproduction mechanism.
2. **A drive mechanism that never touches the player's controller.** On Pseudoregalia the ghost is a
   real player-pawn clone deliberately left unpossessed — `Controller`, `InputComponent`, `Owner`,
   `PlayerState`, `PreviousController` all null (`Plugin.cpp:14294-14320`), because the clone once
   stole the player's controller (POSSESS_TRACE, 2026-08-16). The candidate is a **separately
   spawned `AIController`** possessing only the ghost, driven by movement and action calls rather
   than key events — the same "give the ghost its own instance" shape the adapter already uses for
   ghost-only VFX and the faked sword throw. Unverified; the measurement is one session.
3. **Driving the LOCAL player is forbidden in anything that ships**, and no tooling maturity changes
   it. `ideas.md`: *"A ghost driven by inputs is fine — it is ours. Anything that could drive the
   LOCAL player is not, and the two live one bug apart."* As a **dev probe** it is already
   legitimate and already partly built (`joypad.set` in the emulated adapters' drive probes), and
   that is where a TAS-like tool would land.

A future session reading the capture work as a green light for any of the three is misreading it.

## The open half

- **No adapter sends one.** Pseudoregalia is first, and **there is no input read anywhere in
  `Plugin.cpp` today**, so which API is reachable is genuinely unknown. Ranked candidates and the
  one-shot census probe that decides between them are in the plan and in that adapter's `PROBES.md`
  when it lands. The format is source-agnostic, so this does not gate the Go side.
- **G4 applies here too:** nothing closes a recording on Ctrl+C or a closed console, and a gzipped
  track without its footer is refused whole. The input track doubles that blast radius, which is a
  standing argument for `replay.gzip` remaining default-off.
- **Nothing reads a track yet.** `parseInputTrack` ships anyway: the moment one person sends another
  a track the file is a stranger's bytes, and it is what makes the round-trip promise checkable.
