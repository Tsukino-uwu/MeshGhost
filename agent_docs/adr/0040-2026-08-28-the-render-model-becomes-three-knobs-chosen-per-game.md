# 2026-08-28 — The render model becomes three knobs, chosen per game rather than one size fits all

<!-- ADR 0040. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** How a ghost moves stops being a single fixed behaviour and becomes three
  independent settings on the client, all of which already have a per-game home in that game's own
  `config.json`:
  - **`interp`** (unchanged, default 250ms) — how far behind live a ghost is drawn.
  - **`curve`** (new, default `linear`) — how a position BETWEEN two samples is computed:
    `linear`, or `catmull-rom`, a spline fitted through four samples.
  - **`extrapolate`** (new, default `0` = off) — how far PAST the newest sample a ghost may be
    carried along its last measured velocity.
- **Status:** **Implemented 2026-08-28, Go side complete and confirmed with the tools**, full
  suite, `-race`, `internal/e2e` included. `core/curve_test.go` and `core/extrapolate_test.go`.
  **Nothing about how any of it LOOKS is confirmed** — that is per-game, on screen, and is the
  entire point of the ADR.
- **Defaults are unchanged**, deliberately: a client that sets none of this renders exactly as it
  did before, so this ADR adds options rather than changing anyone's picture.

## Why: one interpolation setting cannot fit four games

The user, 2026-08-28: *"i do think interp/low hz made pseudo look a bit weird/off. while we also
had to use high interp for pokemon to 'look smooth'. so its probly a good idea to mix/match instead
of trying to do a one size fits all thing."*

That is the observation this exists for, and it matches what the adapters already say about
themselves. A Pokémon game moves 2px on a beat and never 1: it wants enough delay to always have
two real samples to sit between, and anything that invents a position between the beats reads as
shimmer (`adapters/CLAUDE.md`, "never in units the game does not use"). Pseudoregalia and TEVI have
momentum, real velocity, and a player who notices lateness — a different trade entirely.

## The core stays game-blind, and this does not bend that rule

**No game name appears anywhere in this.** The core takes three numbers and applies them without
knowing what game it is serving; `internal/gameblind` still passes. What makes the choice
per-game is WHERE it is set: every game's release folder already carries its own client
`config.json` (`packaging/release/games/client-config-template.json`), which is the file the mod's
own launcher reads. So per-game settings need no new mechanism — they need someone to sit in front
of each game and decide.

**The follow-up this leaves open, deliberately:** an adapter could declare its preferred render
profile in its bridge `Hello`, so a player never edits a file and the setting travels with the
adapter that knows the game. That is a bridge-contract change with its own ADR, and it should not
be designed before the values are known — pick them on screen first, then decide whether they are
worth shipping as declarations.

## What the two new knobs actually do, and what each costs

**`catmull-rom`** fits a curve through four consecutive samples, so an arc renders as an arc rather
than as a series of straight chords. It needs **no protocol change** — the tangents come from
samples already buffered (8 per peer), which is why it is cheap to offer. Its cost is that the
curve is *smoother than the samples imply*: for a game with momentum that is likely closer to the
truth, and for a grid game it is the documented defect. It falls back to the straight line whenever
it cannot see four usable samples, and **on a straight path the two modes are numerically
identical**, which is what makes it safe to try without proving anything first.

**`extrapolate`** continues the last measured velocity past the newest sample, which removes the
visible half of `interp` — a ghost drawn where the peer probably is rather than where they were.
Its cost is a correction every time the peer does something the prediction did not, and that
correction is exactly what has to be judged on screen. Three guards keep it honest: velocity is
measured only over a sample pair between 8ms and 200ms apart (so neither a resume bracket from
ADR 0039 nor a half-second-old sample can be read as a rate), never across an area change, and the
prediction is capped so a peer who goes quiet freezes rather than walking away forever.

**They compose.** `curve` governs the space between samples, `extrapolate` the space past the last
one; either, both or neither is a valid configuration. One honest limit: the prediction is linear
even in `catmull-rom` mode — it extends the measured velocity rather than continuing the spline's
tangent.

## What was considered and NOT built

**Hermite extrapolation** (a predicted path curved by transmitted velocity) needs velocity on the
wire, which is a protocol revision, and it would compound the two costs above rather than trade
between them. **Prediction with server reconciliation** — the authoritative-multiplayer stack — is
inapplicable by design: it exists to reconcile a client against an authoritative server, and no
ghost in this project has authority over anything (`brief.md`, `contract.md`).

## Amended the same day: a fourth knob, and the first sweep's verdicts

**`predict`** (default `linear`) joined the set once prediction was watched under real faults:
`linear` extends the last velocity, `damped` scales that per axis by how consistently the window
agrees on it (floored at 40% so a direction-spamming peer is not abandoned to pure lateness), and
`accelerated` extends curvature too. The full sweep -- thirteen configurations, one variable at a
time, TEVI loopback through `meshghost-netsim` at 60ms/±25ms/2% loss/2% reorder -- is recorded in
`verified.md` ("The render-knob sweep") with the user's on-screen verdict per run.

**The conclusions that bind future work:**

- **`damped` is the recommended prediction**; `interp 100ms` + `extrapolate 100-150ms` won on that
  link. Defaults still unchanged -- per-game values go in each game's own `config.json`.
- **Acceleration is out, by measurement, twice.** Raw and consistency-gated both produced visible
  chop, because a second derivative's contribution fluctuates under jitter however it is gated.
  Two variants failing identically is the stop signal; `core/extrapolate_test.go` pins both.
- **`interp` below the link's jitter causes chop rather than immediacy** -- the render time
  oscillates between interpolating and predicting every frame.
- **Cross-frame confidence smoothing was tried and reverted** -- a lagging confidence applies
  yesterday's damping to today's motion.
- **Two shipped bugs surfaced before any knob could be judged** (datagram reordering snapping
  ghosts; the phase re-seek twitching idles) -- neither visible on a clean loopback, which is the
  argument for netsim being part of judging anything render-related from now on.

