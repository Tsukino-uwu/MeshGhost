# The high-rate ceiling — how fast can a room actually run?

**Read this before raising `send_hz`, changing `maxSnapshots`/`defaultSnapshotAgeMs`, or answering
"could we run at 144/240/480Hz to match a game's frame rate?".** Split out of
[scaling.md](scaling.md) on 2026-08-30, which was at its cap and where this had become the largest
single topic. That file keeps the five-line summary and points here.

**Everything below is MEASURED on the dev machine**, by `core/hzceiling_test.go` (the buffer
ceiling), `relay/forward_bench_test.go` (CPU) and arithmetic over the shipped constants (bandwidth,
timestamps). **Nothing above `protocol.MaxSendHz` (100) has ever RUN in a real session** —
`ClampSendHz` prevents it — so this is a statement about the code, not about a game anyone watched.

**Asked: is 100 a technical limit, could someone run 144-480Hz to match a game's fps?** `MaxSendHz`
is **100** and its own comment says *"a bandwidth bound, not a technical one"* — correct, and the
CPU end is not close. **It also has a SECURITY half**: a client adopts the room's rate from
`Welcome.SendHz`, so the cap bounds what a hostile relay can talk YOUR client into sending, which
is why it lives in `protocol/` and both sides clamp (`core/relaysession.go`).

**Relay CPU** (`relay/forward_bench_test.go`): one state fanned out to a room of 8 costs **6.36us**
(Emerald's 14-key shape; TEVI's 3-key is 3.4us), so 8 players at 480Hz = **2.4% of one core**; at
20Hz, 0.1%. **Nobody will hit a Go ceiling here.** **Bandwidth arrives long before that**: at ~288
bytes per state line an 8-seat room fans out 56 streams — **1.2 GB/h** at 20Hz, **5.8 GB/h** at
100Hz, **28 GB/h** (~62 Mbit/s) at 480Hz, carried by the host. Change suppression (ADR 0039) cuts
the idle share hard (70% on TEVI), but a room where everyone moves pays close to full price.

**THE HARD BREAK BELOW WAS FIXED THE SAME DAY — this section is the BEFORE picture, kept because it
is the regression `core/hzceiling_test.go` now defends against.** The window is derived from the
render settings and the count is memory-only, so **nothing edge-holds at any rate up to 2000Hz**
(measured after the fix: at 250ms interp, 480Hz keeps a full 600ms of history, and 2000Hz still
keeps 511ms against a 250ms delay). Skip to "Where the ceiling actually is now" for the current
answer.

**THE ONE HARD BREAK WAS `maxSnapshots = 64`, AND IT WAS SILENT.** The buffer holds at most 64
samples, so it spans 64/Hz seconds; interpolation works while that covers the interpolation delay,
and past it `at()` falls off the old edge and edge-holds — no error, just stutter. **Exactly the
2026-08-28 bug at a higher rate**: the count was 8 then and broke at the dev rig's 100Hz; the fix
added a time bound (`defaultSnapshotAgeMs`, feeding the derived `historyMs` window in
`core/interp.go`) but kept a count. **MEASURED, not derived**, and pinned by
`core/hzceiling_test.go`:

| interp | last rate still interpolating | first rate that edge-holds |
| --- | --- | --- |
| 175ms (TEVI) | 300Hz | 480Hz |
| **250ms (shipped)** | **200Hz** | **256Hz** |
| 400ms | 144Hz | 200Hz |

**A LARGER interp delay broke at a LOWER rate** — the counter-intuitive half, and the one that would
have bitten someone raising `interp` to smooth a bad link while also raising Hz. **A second bug hid
behind the same constant and needed no high rate at all:** a fixed 600ms window meant any
interpolation delay above 600ms edge-held at EVERY rate, including the then-shipped 20Hz (the
shipped default is 15Hz since 2026-09-01; every measurement in this file was taken at the rate it
names, and none was re-run). Nobody had
configured one that large, which is the only reason it never showed.

## Where the ceiling actually is now (post-fix, 2026-08-30)

**The buffer is no longer a limit at any usable rate.** Measured to 2000Hz with no edge-hold. What
remains, in the order it arrives:

| # | limit | value | kind |
| --- | --- | --- | --- |
| 1 | **the game's own frame rate** | ~180Hz Pseudoregalia, 60 for GB/GBA | hard, per game, and the one that binds first |
| 2 | **millisecond timestamps** | **1000Hz** | hard protocol wall — one sample per ms is all `timestamp` can express |
| 3 | bandwidth | 1.2 GB/h at 20Hz, 28 GB/h at 480Hz (8-seat room) | linear, the host's |
| 4 | the snapshot count | ~1700Hz at a 600ms window | memory bound, past the wall above |
| 5 | Go's CPU | 2.4% of one core at 480Hz x 8 players | never |

**1000Hz is the real technical answer**, and it is the wire's time unit rather than anything about
Go: above it, samples share a millisecond, `lerp` sees a zero span and holds instead of
interpolating, so the extra samples carry no information. Measured: at 1200Hz only 600 of 720
sample gaps are distinct. Raising it would mean changing `protocol.State.Timestamp`'s unit.

**And below 1000Hz, PICK A RATE THAT DIVIDES 1000** — 20/25/50/100/125/200/250/500 quantize exactly,
anything else jitters by up to half a millisecond per interval (120Hz 6.0%, 144Hz 7.2%, 256Hz
12.8%). That makes **144Hz a worse choice than 125 or 200**, which is the opposite of picking a
number off a monitor's refresh rate.

**None of which changes the shipped policy:** `MaxSendHz` stays 100. It is a bandwidth and
trust-boundary decision (a client adopts the room's rate, so the cap bounds what a hostile relay
can make YOUR machine send), and above ~180Hz no shipped game can even produce distinct samples.
The open design question for ever raising it is in `plans.md` step 3 — the safe rate depends on
each CLIENT's `interp`, which the relay cannot see, so an opt-in wants a negotiated ceiling rather
than a raised constant.

**Nothing else has a cliff, and the second axis is NOT a gradient** (corrected 2026-08-30 — an
earlier version of this section said "~5% at 100Hz", which is wrong). `protocol.State.Timestamp` is
MILLISECONDS, so the interval quantizes to **ZERO error whenever the rate divides 1000** and up to
±0.5ms otherwise: 20/100/125/200/250Hz are EXACT; 120Hz is 6.0%, 144Hz 7.2%, 256Hz 12.8%, 480Hz
24.0%. It is bounded jitter in the interpolation fraction, not drift, and it never breaks — but it
means **144Hz is a worse choice than 125 or 200**, and a rate should be picked from the exact set.
The flood cap scales 6x with the rate on its own.

**THE COUNT NO LONGER BINDS ANYWHERE NEAR THE CEILING.** `maxSnapshots` was raised to **1024**
(`core/interp.go`), a pure memory bound: 1024 samples cover the default 600ms window up to
**~1700Hz**, seventeen times `MaxSendHz`. The functional bound is the TIME window
(`defaultSnapshotAgeMs` = 600, or the larger derived `historyMs` when render settings need more),
so **at any permitted rate the count is irrelevant and any interp delay up to 600ms works.**
(This paragraph argued a ~107Hz count-vs-age crossover while the count was 64; that crossover is
gone — corrected 2026-09-01.)

**THE CEILING THAT BINDS FIRST IS THE GAME'S OWN FRAME RATE.** An adapter samples on the game's
frame and cannot produce a DISTINCT sample faster than the game renders — Pseudoregalia ticks
~180Hz here, so a 256Hz room yields ~180 real samples plus duplicates, paying full bandwidth for
repeats change suppression then discards. **This is the one true thing in the "align your tick rate
to the engine" advice: the game's rate is a CEILING on useful Hz, not a target to match.**

**WHICH LAYER OWNS WHAT**, because the cliff is not where anyone expects: the **game** sets the
ceiling on USEFUL rate (its frame rate); the **relay** sets the room's rate (`send_hz`, one number,
it pays the fan-out); the **client** sets `interp`. **Pre-fix that made the safe rate a PER-CLIENT
property**, since the cliff was `64 / interp`: two peers in a 200Hz room, one at 250ms and one at
400ms, and the second edge-held with nothing on either side able to detect it. **The fix removed
that particular asymmetry** — no client edge-holds now below 2000Hz — but the LAYERING is the
lasting point, and it is why an opt-in past 100 wants a NEGOTIATED ceiling rather than a raised
constant: the relay still cannot see a client's render settings, so it cannot know what it is
promising. `plans.md`, step 3.

## "At high Hz you would not need interpolation at all" — half right, and the half that is wrong matters

**Asked 2026-08-30.** Two different things wear the name `interp`, and raising Hz retires one of
them and not the other.

- **Interpolation as SMOOTHING does fade out.** At 1000Hz a sample lands every 1ms while the game
  renders every ~5-16ms, so there is essentially always a fresh sample and the gap being filled is
  smaller than a frame. Slerp likewise: a 360 deg/s spin steps 0.36 degrees per sample at 1000Hz,
  which is invisible. On a clean link there is genuinely nothing left to smooth.
- **The interpolation DELAY does not fade out, at any rate.** Its job was never filling the gap
  between samples — it is insurance against **jitter, loss and reordering**, and none of those
  shrink when the send rate rises. A 30ms jitter spike is 30ms at 20Hz and 30ms at 1000Hz. That is
  why the shipped config carries a hard rule of its own: never set `interp` below the link's
  jitter. At 1000Hz with no delay you would have exquisitely precise samples and still hitch every
  time one arrived late.

**So high Hz removes the need for interpolation only on a link with no jitter and no loss — which
is localhost**, and localhost is precisely the condition that hid the interpolation delay behind a
stutter until 2026-08-28. Judge this on netsim, never on a clean loopback.

**The economics are the real answer, and they generalise past this project: INTERPOLATION IS
BANDWIDTH COMPRESSION.** Buying Pseudoregalia's smooth facing through rate instead of slerp would
have cost 10-20x the bandwidth — and was not even purchasable, since the game cannot sample past
~180Hz. A full 8-seat room at 480Hz is 28 GB/h on the host's uplink; slerp cost ~15 lines and zero
bytes. Every netcode interpolates rather than sending faster for exactly this reason: a trivial
amount of CPU replaces an order of magnitude of traffic.

**Raising Hz buys SAMPLING ACCURACY, never FRESHNESS.** A ghost at 480Hz with a 250ms delay is
still drawn 250ms in the past. Lateness is `interp`'s to fix, and anyone raising the rate to cure a
"delayed" look is turning the wrong knob. That is the single most useful line in this file.
