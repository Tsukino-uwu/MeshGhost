# Bandages — Pokémon Emerald

<!-- line-cap: none -- register; growth is a smell you must be able to SEE, never one to hide by trimming. Why: agent_docs/claude-md-cap.md. -->

Shipped compensations in this adapter: **a fix that restores, forces, compensates for, or
remembers a value rather than preventing whatever changed it.** The rule, its one narrow
exception, and what it is *not*: `adapters/_template/README.md` ("a bandage fix is not a finished
feature").

From the repo-wide audit of 2026-08-16. Its headline holds here too: most things that *look* like
bandages are not — the great majority carry the live incident, the rejected alternative, and the
derivation right beside them. Ranked by how likely each is to cause a real bug.

Other registers: `../../../pseudoregalia/BANDAGES.md`, `../../../tevi/BANDAGES.md`, `../crystal/BANDAGES.md`,
`../../../../agent_docs/bandages-core.md`.

## Is this a bandage?

The canonical guide — the one mechanical test, the tells while you are writing it, the eight
tells that only show up later, and the one bandage shape to avoid outright — lives in
[`adapters/_template/BANDAGES.md`](../../../_template/BANDAGES.md). Read it before adding an entry.

## Open compensations

### 1. Proceeds on known-wrong addresses for an unrecognised ROM

`meshghost_emerald.lua`, `detectSpriteAddrOffset()` (sprite/palette data) and
`tryDetectAvatarAddrOffset()` (the avatar offset, retried from `runFrame()` until it succeeds).
When neither the vanilla nor the known Archipelago-shifted address verifies, both warn and **carry
on with vanilla addresses**.

*(Cited by function name, not by line. This entry's line numbers had drifted a hundred lines out
of date by 2026-08-18 — the spawn work shifted the whole file — and a citation that points at the
wrong code is worse than one that makes a reader search. Name the function.)*

**This is the one that puts wrong data on the wire.** Nothing gates *sending* on
`avatarAddrConfirmed`, so `getLocalState()` reads `GPLAYERAVATAR_ADDR + 0` every frame until
detection succeeds — on a future Archipelago recompile that never happens, and the adapter
transmits garbage facing/anim to real peers while drawing remotes at a garbage screen position.

The two *known* offsets are exceptionally well measured (byte-level ROM diffs, multi-stage live
probes). What was never observed is what the fallback path actually renders or sends.

**Fix:** on "not found", stop sending (`ENCODED_NO_SEND`) and stop drawing remotes. A visibly
disabled adapter beats silent wrong data.

### 2. Blanket per-frame `pcall` with a 300-frame log gag

`meshghost_emerald.lua`, `guardedFrame()` — a `pcall` around `runFrame()` whose error log is gagged
to once per 300 frames. The resilience posture is right for a Lua script that would
otherwise die for the session — but it cannot tell one malformed line from every frame failing. A
systematically broken read reports once per ~5s and the ghost silently stops updating.

**Worse than described, until 2026-08-19:** the limiter started at frame 0, so `frameCounter -
0 > 300` was false for the whole first 300 frames — the window that contains connecting, the port
walk, address detection and the first spawns. A startup error could not be logged at all. Proof it
mattered: the `drainBridge()`/`reject` defect fixed the same day threw on **every** bridge
rejection and appears in none of the eight session logs that record one. The first error now
always logs, and the message carries a consecutive-failure count.

**Still open, and this is what closes it:** the count is reported but nothing acts on it — a
subsystem failing every frame is now visible, not disabled. **Fix:** disable the offending
subsystem on a sustained run of failures, rather than a constant chosen to protect the console.

### 3. Fishing alignment falls back to the frame boundary on an Archipelago ROM

`meshghost_emerald.lua`, `alignFishingGhost()` and the `BuildOamBuffer` hook registered near the
bottom of the file.

**What the shipped compensation is.** A fishing sprite's offset is recomputed by the game every
frame from the frame being displayed, *inside* the frame update. To match that, the adapter hooks
`BuildOamBuffer` (`0x08006A0C`) with `event.onmemoryexecute` — animations final, OAM not yet built
— and recomputes the ghost's offset there. That is what makes it 1:1 (`VERIFIED.md`, 2026-08-19).

**The hook is registered only when `avatarAddrOffset == 0`, i.e. on the vanilla ROM.** An
Archipelago build relocates code, so `0x08006A0C` is not `BuildOamBuffer` there, and hooking it
would run our callback at an arbitrary point in whatever now occupies that address. On a patched
ROM the adapter therefore falls back to writing the offset at the frame boundary — which is the
path that was **measured to be one step out of phase** with the image, and which produced a visible
8px flick on vanilla before the hook existed.

**So the compensation is: a known-imperfect render on Archipelago, silently.** It is a bandage and
not a bug because it is deliberate and it degrades safely — a slight flick during fishing, never
wrong data on the wire and never a crash — but the adapter does not say it is happening, and
nobody has watched fishing on a patched ROM to see how bad it looks.

**Fix:** measure `BuildOamBuffer` in the Archipelago build (its symbol table or a ROM diff against
the same shift used for the graphics-info table), and gate the hook per detected ROM rather than
per `avatarAddrOffset == 0`. Failing that, log once when the fallback is in use, so a report of
"the ghost flicks while fishing" is immediately attributable rather than re-investigated from
scratch — the whole investigation this came from cost about ten live cycles.

## Borderline — noted, not urgent

- **`getLocalState()` — `FACING[facingRaw] or "south"`.** Turns a bad memory read into a
  plausible value with no counter or log, which is the failure mode `CLAUDE.md` warns about. (The
  neighbouring gender/direction defaults are documented forward-compat and fine.)

## CLOSED — two render paths at once, until the Archipelago sprite shift is measured (2026-08-18, closed 2026-08-19)

**What it was.** The adapter spawned a real object event on a vanilla ROM and fell back to the
`gui.drawPixel` overlay on an Archipelago-patched one, because `gObjectEvents`' relocation under
that patch was measured while `gSprites`' was not — and a wrong *read* returns a wrong number
where a wrong *write* corrupts whatever now occupies the address. Two paths for one job is the
shape a compensation takes, and the spawn ADR had named this exact risk going in.

**How it closed.** `probes/gsprites_scan_probe.lua` measured `gSprites` on a patched build
(`VERIFIED.md`, 2026-08-19): `gObjectEvents` shifts by `0x284` on the Archipelago
build and **`gSprites` does not shift at all**. The split is gone — `meshghost_emerald.lua` runs
one render path on both builds. Nothing rests on that measurement holding for some future patched
build either: `spawnGhost()` refuses to write a byte unless the player's own object/sprite
cross-link resolves through `gSprites` first, so a build that did move it gets a logged refusal
rather than a corrupted sprite.

**What survived, and why it is still registered.** `drawSpriteFrame`, `drawRemotes`, `advanceAnim`
and the frame decode were *not* deleted, because the drawn path found a second job the same day —
the overflow tier below. Deleting them is no longer what ends this; the entry below is.

## The drawn overflow tier — a bandage by construction (2026-08-19)

**Updated 2026-08-21: it is no longer the SECOND rung, it is the third, and that shrinks the
exposure without closing this entry.** A hardware-sprite tier now sits between spawning and
painting (`FLAGS.md`, `plans.md` Phase 8.1, the 2026-08-21 ADR): peers past the engine's object cap
get a real hardware sprite -- with the background priority and live palette that every cost below
is about faking -- and painting is reached only when a peer can get neither an object slot nor a
VRAM tile range. Measured: 56 peers cost nothing on that tier and 39.6 fps on this one.

**This entry stays open, and deliberately.** The painted tier is not removed, because it is the only
one of the three with no ceiling, and *"every peer visible all the time"* needs exactly that.
Everything below is still true of it; it is simply reached less often. **One cost has also moved
the other way**: the shared movement filter both non-engine tiers use was found to have a real bug
on 2026-08-21 (it could not follow a running player), which means this tier had been shipping with
it -- see `pitfalls.md`, and `UNVERIFIED.md` for the re-judgement that owes.


**What it is.** Peers past the engine's object-event cap are painted with `gui.*` primitives
instead of being spawned, so that every peer is visible instead of the ones past the cap simply not
existing on screen. Asked for by the user in those terms — *"npc's always shown, ghosts try to
fill, drawn otherwise"*, *"i don't want things to pop in/out all the time"* — and designed in
`agent_docs/ideas.md` ("Spawn to the game's cap, then DRAW above it"), which called it a bandage
before a line of it was written. Off by default (`MESHGHOST_EMERALD_DRAWN_OVERFLOW`, `FLAGS.md`).

**Why it is a bandage and not a feature.** It does not make the game able to hold more characters;
it paints over the game's finished frame to hide that it cannot. Every one of these costs is
structural, not a rough edge to polish out:

- **No occlusion, and this is the blocking one.** A drawn ghost is painted after the PPU has
  finished, so nothing hides it: not a house, not the START menu, not a text box. The spawned tier
  gets all of that free from the engine. **The clipping is built and proven; the DETECTOR is what
  is still missing**, and the two are separate halves:
  - *Clipping* — the drawn path renders cached horizontal runs, and a run at or below a panel's
    top edge is skipped, so a ghost standing behind a text box keeps drawing above it rather than
    over it or vanishing entirely. Proven by counter, 2026-08-19: with a forced panel at row 0 and
    32 painted ghosts, 1.1M runs were skipped over 300 frames; 0 with nothing to clip
    (`MESHGHOST_EMERALD_FAKE_PANEL_ROW`, `FLAGS.md`).
  - *Detection* — where the panel actually is. The hardware route is a dead end: the GBA's window
    registers (`WIN0H`/`WIN0V` and `DISPCNT`'s enable bits) **change every frame during ordinary
    walking**, values that are mid-frame states rather than panel geometry (probed 2026-08-19,
    `probes/uiregion_probe.lua`, now throttled). The route that worked on Crystal — ask the game
    what it DREW, not the LCD what it is displaying — is what shipped instead:
    `tiering.scanPanel()` reads BG0's tilemap, finding its address from `BG0CNT`'s own screen-base
    bits so no game symbol or decomp address is involved. **Measured 2026-08-19 with
    `probes/textbox_probe.lua`:** nothing open — BG0 entirely empty, the map on BG2/BG3; a text box
    — BG0 rows 14-19, full width; the START menu — BG0 rows 0-13, right-hand columns only. So BG0
    is the UI layer and it is quiet until the game puts a panel on it, which makes the detector
    style- and revision-independent: it asks WHERE something was drawn, never WHICH tiles. First
    clip driven by the real detector rather than the forced panel, 2026-08-19: one drawn loopback
    ghost with a real panel on screen, 475 runs skipped in a 300-frame window against 0 with
    nothing open. **Not yet a controlled repeat** — the loopback ghost shares the player's row, so
    it only meets a bottom-of-screen text box when the camera puts the player low; that run was
    reached by warp, not played to.
- **No collision and no interaction.** A drawn ghost is a picture. Arguably right for an overflow
  tier, but it makes peers visibly unequal in a way nothing on screen explains.
- **Nobody animates it but us.** The walk cycle, the pose per direction, and the frame timing are
  re-implemented in this adapter, against a decode of the ROM's own sprite tiles. The spawned tier
  deleted all of that; this brings it back.
- **Two rendering paths that will drift.** The real long-term cost. Every future change has to be
  made twice or deliberately once.

**What it costs to run**, measured 2026-08-19 with synthetic peers standing on one indoor map, at
the emulator's own frame rate (wall clock, not a feeling):

| Peers in the area | Spawned | Painted | fps |
|---|---|---|---|
| 40 | 13 | 27 | 59.7 — full speed |
| 150 | 13 | 0 (tier off, control) | 53 |
| 150 | 13 | 137-172 | 22-31 |

The control row is the one that says where the cost actually is: receiving 150 peers over the
bridge costs ~7fps on its own, and painting the characters costs the rest. Two optimisations are
already in and are counted in those numbers — each frame's opaque pixels are collapsed into
horizontal runs once and cached (one `gui.drawLine` per run instead of one `gui.drawPixel` per
pixel), and peers whose sprite falls outside the 240x160 screen are skipped entirely.

**What would make it unnecessary:** nothing available. The 16-entry object array is the engine's,
and no adapter-side cleverness adds an entry to it. The honest alternative is the pre-existing
behaviour — peers past the cap are not shown at all — which is what the flag falls back to.

## A hand-drawn shadow under a jumping ghost (2026-08-19)

**What it is.** When a peer hops a ledge, the adapter paints a dark ellipse on the tile the ghost
left, in `drawGhostShadows()`. It is our art, not the game's — an ellipse rather than the field
effect's own graphic — and it exists because the engine's shadow cannot be made to attach to a
ghost.

**Why the engine cannot do it.** It genuinely tries: a two-tile jump runs `InitJumpRegular` ->
`DoShadowFieldEffect` -> `StartFieldEffectForObjectEvent`, which binds the effect by passing the
object's **localId**, and the shadow then re-finds its object every frame with
`GetObjectEventIdByLocalIdAndMap`. Every ghost wears `LOCALID_PLAYER` (0xFF), so that lookup
returns the **player**: a ghost's hop puts a shadow under the local player instead.

**Why not simply give ghosts their own id.** That id is load-bearing for something more important:
`GetInteractedObjectEventScript` returns NULL for any object whose localId is `LOCALID_PLAYER`,
which is what makes a ghost non-interactable **using the engine's own check** rather than a guard
of ours. A unique id re-opens a script lookup with no template behind it — a NULL dereference the
decomp marks as a known bug, and the cause of the slot-machine bug the user hit on 2026-08-18.
Trading a crash risk for a shadow is the wrong way round.

**What keeps it honest.** Almost nothing about it is invented any more, because guessing did not
converge and measuring did:

- the ARC is the engine's — a jumping sprite carries its hop in `pos2.y`, so the shadow is drawn at
  the sprite's position *without* that term, the exact ground it left;
- the COLOUR is measured — three rounds of tuning alpha all read too light, and dumping the OBJ
  palettes during a real hop showed every candidate entry is pure black;
- the GEOMETRY is measured twice — the sprite is 16x8 (`SHADOW_SIZE_M`, matching the player's
  graphics info against `field_effect_objects.h`), and decoding the pixels the game had loaded
  showed the INK is 16x5 in rows 3..7 of that box. Filling the box read as *"pretty big on the
  ghosts compared to the player"*; 16x5 at +11 is the shape the game actually draws.

What remains ours is one ellipse standing in for that 16x5 sprite's exact silhouette.

**What it does NOT cover.** A peer rendered by the DRAWN tier has no arc to sit under: its
position is the peer's smoothed coordinates, which do not hop, so it slides across a ledge. A
shadow there would sit exactly beneath the character and read as nothing. Giving the painted tier
its own jump arc means inventing motion the engine is not providing for it, which is a larger step
than an ellipse and is deliberately not taken here.

**RETIRED IN PRACTICE, 2026-08-19 — the adapter now draws the game's own shadow.** Three rounds of
"too big / too dark / too high" made the point that an approximation of someone else's art is
always judged against the original and always loses. So it is not approximated any more:
`learnShadowArt()` waits until the LOCAL player hops a ledge, finds the shadow sprite on screen by
what it IS (in use, 16x8, beside the player, mid-jump — never by an address), decodes its pixels
and palette, and every ghost is drawn with those exact runs from then on, through the same
`drawRunList` the rest of the drawn tier uses — so it clips and dims like everything else.

**FULLY RETIRED FOR THE SPAWNED TIER, 2026-08-21, user-confirmed.** That tier no longer paints a
shadow at all: it builds a REAL shadow sprite from the engine's own template, at the engine's own
subpriority 148, so it sits UNDER the character and under the landing dust -- the two things an
overlay can never do, since an overlay is drawn after the hardware has finished. The painted path
survives only as the fallback when the sprite cannot be built (a relocated ROM, or OBJ tiles
exhausted), and for the two tiers that have no engine object of their own. The reset that kept this
sprite disabled was a NULL sprite callback, written up in `agent_docs/pitfalls.md`.

**What is still a bandage, and why this entry stays open.** The ELLIPSE remains as the fallback for
one case: a ghost that hops before the local player ever has, where nothing has been seen to learn
from yet. Closing that means finding the field-effect template table in ROM, which is a real
address hunt for a case that resolves itself the first time the player jumps. The user's call, 2026-08-19, was to bandage it: the same reasoning as the drawn
tier, where the hardware cannot do what is wanted and we compensate visibly and on the record.

## Deliberate — do NOT "fix" these

Recorded so a future audit does not churn them.

- **`STEP_DURATION_FRAMES`.** Measured live twice with zero variance, and two "smarter"
  self-correcting alternatives were built, traced, proven worse and reverted with the evidence
  left inline. **The reference case for how this repo justifies a constant** — read it before
  arguing any other number here is arbitrary.

## The hardware tier's entry pools are a real ceiling (2026-08-21)

The tier has 56 OAM entries and now spends them across five pools, in the engine's own back-to-front
order (reflection 152, ripple 151, blob 150, shadow 148, the character, dust 135):

| Pool | Entries | What it costs |
| --- | --- | --- |
| dust | 4 | four live landing puffs |
| **bodies** | **26** | **the tier tops out at 26 peers, down from 44** |
| shadow | 4 | four peers mid-hop at once |
| blob | 4 | four peers riding at once |
| ripple | 12 | one surfer's full trail plus headroom; a second surfer overflows |
| reflection | 6 | six peers reflecting at once |

**Why this is registered rather than just noted:** bodies losing 18 entries is a genuine reduction
in what the tier can carry, taken to buy effects it had none of. It has not bitten, because OBJ
TILES run out well before entries do — the fill-the-screen run put 56 characters up and exhausted
tiles first — but the honest statement is that this tier's peer ceiling is now 26, not 44.

**Every pool logs when it is exhausted rather than truncating silently**, and that is what sized the
ripple pool correctly: it was set to 8 by eye, reported itself full at nine live ripples within a
minute of real surfing, and the arithmetic (one per tile, 80-frame life, 8 frames per tile = ten
live) said 12. A ceiling that does not announce itself reads as "covered everything" when it did
not.
