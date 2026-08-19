# Bandages — Pokémon Emerald

Shipped compensations in this adapter: **a fix that restores, forces, compensates for, or
remembers a value rather than preventing whatever changed it.** The rule, its one narrow
exception, and what it is *not*: `adapters/_template/README.md` ("a bandage fix is not a finished
feature").

From the repo-wide audit of 2026-08-16. Its headline holds here too: most things that *look* like
bandages are not — the great majority carry the live incident, the rejected alternative, and the
derivation right beside them. Ranked by how likely each is to cause a real bug.

Other registers: `../../../pseudoregalia/BANDAGES.md`, `../../../tevi/BANDAGES.md`, `../crystal/BANDAGES.md`,
`../../../../agent_docs/bandages-core.md`.

## Is this a bandage? — the short form

Full version, including all seven after-the-fact tells: `../../../_template/BANDAGES.md`.

**The one mechanical test:** does the fix **prevent** the wrong thing, or **correct** it
afterwards? Correcting afterwards means the cause is still running. Then: *"what would make this
unnecessary?"* (a proper fix has no answer) and *"where did this number come from?"* — measuring
the mechanism, or trying values until it looked right?

**Writing it:** watch for *almost*, *good enough*, *for now* in your own reasoning, and for code
that *restores*, *forces*, *remembers*, *re-applies*, or *offsets* a value.

**Discovering it later — you will not always know at the time.** Add an entry if any of these
happen: its cause got fixed somewhere else and the fix is still there; a second bug gets described
as *"structurally the same bug as X"*; it outlived its purpose and became the bug itself; a
constant needs re-tuning when something unrelated changes; removing it breaks something it was
never about; you can't explain it without describing a sequence; it needs a companion fix elsewhere
to stay correct.

**When in doubt, log it.** A false positive costs one line under "Deliberate".

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

## Borderline — noted, not urgent

- **`getLocalState()` — `FACING[facingRaw] or "south"`.** Turns a bad memory read into a
  plausible value with no counter or log, which is the failure mode `CLAUDE.md` warns about. (The
  neighbouring gender/direction defaults are documented forward-compat and fine.)

## Two render paths at once, until the Archipelago sprite shift is measured (2026-08-18)

**What.** The adapter spawns a real object event on a vanilla ROM and falls back to the old
`gui.drawPixel` overlay on an Archipelago-patched one (`avatarAddrOffset ~= 0`). Both renderers
are in the file and both are live.

**Why it is a bandage.** Two paths for one job is the shape a compensation takes, and the spawn
ADR named this exact risk going in: *"if spawning proves unreliable, the tempting fix is to fall
back to drawing and leave both paths in."* This is not that case — spawning works — but the result
looks identical from the outside, so it is registered rather than left unremarked.

**Why it is nonetheless right today — with a correction, 2026-08-18.** The first version of this
entry said `gSprites`' Archipelago relocation was "unmeasured". That overstated the unknown, and
the evidence was already in this adapter's own README: `sprite_anchor_verify_probe.lua` was
written specifically to check whether `gSprites` (and the sprite coord offsets) were shifted like
`gObjectEvents` was, and the answer was **no** — `playerScreenPos()` uses those three addresses
unmodified and the ghost has been repeatedly confirmed correctly anchored on a patched ROM.

So the honest position is weaker than "we cannot write there" and stronger than "it is fine":
**the address is very likely correct, and was never verified for WRITING specifically.** Reading a
wrong address returns a wrong number, a cosmetic bug; writing one corrupts whatever now lives
there. That asymmetry is why the fallback stays for now rather than because the address is unknown.

**What makes this cheap to close.** The spawn path already performs a live self-check before it
writes a single byte: it reads the player's `objectEvent.spriteId`, then checks that sprite's
`data[0]` holds the player's own object event id. If `gSprites` were wrong on a patched ROM, that
round trip cannot succeed, and the adapter refuses and logs. **So enabling the spawn path on an
Archipelago ROM is guarded by construction** — one live run on a patched seed either confirms it
or refuses safely. That run has not happened yet, which is the only reason this entry still exists.

**How it ends.** Measure `gSprites` on a patched ROM — `probes/avatar_scan_probe.lua` through
`avatar_verify_probe.lua` are the four-stage template that already did this for `gObjectEvents`.
The spawn path's own cross-link check (player's `objectEvent.spriteId` -> that sprite's
`data[0]` == the player's object event id) is a live self-test that would confirm a candidate
address in one run. When it is measured, delete `drawSpriteFrame`, `drawRemotes`,
`advanceAnim`, the frame decode and this entry.

## The drawn overflow tier — a bandage by construction (2026-08-19)

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
    what it DREW, not the LCD what it is displaying — is being followed instead:
    `probes/textbox_probe.lua` reads the BG tilemaps, finding each one's address from its own
    `BGxCNT` screen-base bits so no game symbol is involved. **Half measured:** with nothing open,
    the map sits on BG2/BG3 and **BG0 is entirely empty**, which is the blank-panel-layer shape the
    detector needs. What a text box actually writes, and into which rows, needs a box on screen and
    is therefore waiting on the user. Until then `tiering.panelTopPx()` returns nil and the tier
    stays off — shipping it on would mean painting characters over the text being read.
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

## Deliberate — do NOT "fix" these

Recorded so a future audit does not churn them.

- **`STEP_DURATION_FRAMES`.** Measured live twice with zero variance, and two "smarter"
  self-correcting alternatives were built, traced, proven worse and reverted with the evidence
  left inline. **The reference case for how this repo justifies a constant** — read it before
  arguing any other number here is arbitrary.
