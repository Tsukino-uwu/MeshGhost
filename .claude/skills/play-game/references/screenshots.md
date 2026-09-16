# Screenshots — the navigation sense

Read before taking or reading a picture of a running game. **A screenshot is never proof**:
`agent_docs/verified.md`'s human gate on anything visual stands exactly as written, and
`agent_docs/testing.md` owns why. This file is about pictures as a driver's SENSE, not as evidence.
The stories behind each rule are in `agent_docs/playing-rationale.md`.

## Where they go

- **One folder per game AND per patched variant** under `dev-scripts/shots/`: `emerald/`,
  `crystal/`, `apemerald/`, `apcrystal/`, and the same pattern for any other game. Create yours if
  it does not exist.
- **The whole tree is gitignored** (`/dev-scripts/shots/`): a picture is a working aid, never project
  content and never evidence. It is still the agreed place, so the user can look at any instance's
  output without asking which folder some agent invented.
- **Never a session scratch directory** — it is per-session and disappears with the session.
- **Every capture, from any tool, stays out of the public repo** (user, 2026-09-16).

## Tools that take them

- **`cmd_drive.lua`'s `shot NAME`** writes `dev-scripts/shots/<game>/NAME.png`, then `status` — a
  picture and a state dump from one command (vanilla only; `building-a-state.md`).
- **`dev-scripts/bizhawk-screenshot-loop.lua`** writes a numbered PNG every
  `MESHGHOST_SHOT_INTERVAL` frames (default 120) into `MESHGHOST_SHOT_DIR` (default the vanilla
  Emerald folder) with prefix `MESHGHOST_SHOT_PREFIX` — set the folder on any other game or variant.
  A strip of pictures answers "what has been happening".
- **`dev-scripts/bizhawk-screenshot.lua`** takes one shot 600 frames after it loads, always to
  `shots/emerald/shot.png`; **`adapters/emulator/pokemon/emerald/probes/shot_once.lua`** takes one
  at once.

## When playing, a picture is the primary sense

A player navigates by looking: a door up and to the right, a person rather than a rock, a step that
is a ledge, a menu that is open and which entry is highlighted. **Memory reads cannot supply that —
they give precision, not situation.** Tile 12,8 says nothing about what is around you unless you
have already built a map; a screenshot says it at once. An agent that has taken no pictures is
navigating blind, whatever else it is doing right.

**LOOK FIRST, then act.** Take a screenshot when you arrive somewhere new, before deciding what to do
— not after something has failed. One picture answers the whole orientation problem, and it costs a
frame. (The same rule for probes: `adapters/_template/probes.md`, "Look first, then write the
script".)

The picture and the memory read are a **pair, and neither replaces the other**:

| Question | Answer it with |
|---|---|
| *What is around me? Where can I go? What is this thing?* | **A picture** |
| *Did my input actually do anything?* | **A memory read** (coordinates, map id, menu state) |
| *Is this rare/periodic thing happening?* | **A counter over time** — one frame cannot see it |

*"I pressed a direction and did not move"* is the same signal for a wall, a ledge, an NPC
mid-sentence and an open text box. **The picture says which one it is; the memory read says whether
it changed.** Pictures also answer what no memory read does — whether a sprite is garbled, what a
menu looks like — and they let the user check a claim without driving the game.

## Capture the GAME, not the window

- **Where the host can capture its own frame, use that and nothing else.** On BizHawk that is
  `client.screenshot()` — no `PrintWindow`, no `PW_RENDERFULLCONTENT`, no DPI-aware window grab.
- **A host with no frame capture may use a window capture** (user, 2026-09-16), kept out of the repo
  like every other capture.
- **A drawn-tier ghost is a Lua overlay painted after the frame, so `client.screenshot()` never shows
  it** — a screen full of ghosts photographs as an empty map. A SPAWNED ghost is an engine sprite and
  does appear. The answer is not a bigger camera: **judge the drawn tier NUMERICALLY**, with counters
  sampled over time — "14-36 of ~40 peers were mid-stride at every sample, and none ever fell back
  for want of a facing" settles what no photograph can, and one frame could not see a walk cycle
  regardless.

## Photograph the reference, count the painted one

The same blind spot makes a screenshot the RIGHT instrument for the other half: it captures exactly
what the drawn tier is not, the BG layers and the engine's own sprites. When the question is *"what
should the painted version look like here"*, photograph the engine doing it and measure the pixels.
That is how the surfing reflection's clipping was pinned down (2026-08-19): the engine's own
reflection, captured at a shoreline and read row by row — ink to y=103, the pond's stone lip at 104,
grass below — gave an exact target that no reading of the decomp had produced.

## Take the picture and the numbers in the SAME FRAME

If a dump is meant to line up with a picture, the same code takes both, one after the other, with no
`frameadvance` between. A probe screenshot on one schedule and an adapter log on another, seconds
apart, once described two different scenes — and the difference got blamed on a player who was
idle.

## Two things learned the hard way

- **One frame cannot see a blinking thing** (`adapters/_template/probes.md`, "One sample cannot see a
  blinking thing"). Sample over time, at an interval that cannot align with what you are watching.
- **An agent can lose the ability to READ images mid-session** (2026-08-19, after a long
  conversation had accumulated many). **Keep taking them anyway**: the user can still look, and they
  remain the record of what happened. Then answer the question numerically — counters, invariants,
  register reads — which is the better evidence regardless.
