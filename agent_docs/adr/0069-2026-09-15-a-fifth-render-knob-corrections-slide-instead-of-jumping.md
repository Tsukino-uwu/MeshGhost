# 2026-09-15 — A fifth render knob: a correction slides instead of jumping (`correction`, ships off)

<!-- ADR 0069. Indexed in ../architecture.md, which is the decision log front door. Not a contract revision: nothing crosses the wire or the bridge. Step A3 of prediction-planning.md; the A1 measurement it was sized against is in phases/phase10.md. -->

- **Decision:** the core gains `Correction` (config `correction`, flag `-correction`), a time
  constant. When a received sample changes where a remote is drawn at the current render time, the
  buffer keeps the drawn position and remembers the difference as a per-remote offset that decays
  as `exp(-dt/correction)`; the ghost slides to the corrected place instead of teleporting there in
  one frame. It **ships at `0`**, which skips every line of it: the render is byte-identical to
  before the knob existed (`core/correction_test.go`, the off test). Like `curve`, `extrapolate` and
  `predict` (ADR 0040) it is judged per game on screen, never by matching numbers.
- **Where it snaps instead of sliding**, because sliding would show a place the game never had: an
  `area_id` change or a position-length change between the two renders (the same discontinuities
  `lerp` and `extrapolate` refuse to cross); a correction longer than the peer's own remembered top
  speed could cover in `extrapolate + correction`, times a safety factor (a warp; judged against the
  speed measured BEFORE the sample landed, or the warp would raise its own bound); a local peer
  (replay, chaser: never predicted, never corrected); a despawn (the buffer goes with it).
- **Why:** the reason prediction is off (ADR 0040, twice by measurement) is not that a guess is
  wrong but that the stateless render corrects it in one frame — the left/right snap. No delay
  removes that: any render past the newest sample is a guess, and at the shipped 450ms that is
  every render inside a loss gap. The 2026-09-15 headroom measurement (phase10.md) showed the
  worst-case netsim link dry on about 2% of moving renders and the correlated-loss link on about
  6%; those are the frames this knob is for. The record: `prediction-planning.md` (the reasoning,
  the options table, what was dropped), `pitfalls/INDEX.md` ("a second derivative of network
  samples is visible no matter how you gate it").
- **What it costs:** with the knob on, two extra probe renders per received state under `c.mu`
  (the render at the current render time before and after the buffer insert) and one vector
  multiply per rendered remote per tick; a few floats per remote. Off, nothing. Orientation is
  untouched: the core cannot decay an opaque value, and an adapter that slerps already inherits
  the bracket.
- **What it is not:** it does not lower the delay (that is A2, adaptive per-peer delay, undecided
  until the A1 numbers are read), and it cannot stop a predicted ghost sinking through a floor
  inside a gap — no math on samples alone knows a floor is there; that is Track B, adapter-side,
  with the game's own collision.
- **Verification:** eleven tests in `core/correction_test.go` on the fake clock, including the
  numbers gate: a synthetic walk with a twelve-sample loss burst straddling every reversal through a
  netsim-shaped link (200ms ± 50 transit, reordering) rendered at 60Hz — largest frame-to-frame
  move 128 units with the knob off, 20 on, at a walk of 16 per frame. The screen verdict is the
  user's and is OPEN: `run-netsim.bat` no-arg, two real peers, `interp 450ms`, `extrapolate 100ms`,
  `predict damped`, `correction 100ms`, expected "identical to today, smoother through a loss burst".
