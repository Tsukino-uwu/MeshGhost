# The high-rate ceiling — how fast can a room actually run?

<!-- line-cap: 200 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

**Read this before raising `send_hz`, changing `maxSnapshots`/`maxSnapshotAgeMs`, or answering
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

**THE ONE HARD BREAK IS `maxSnapshots = 64`, AND IT IS SILENT.** The buffer holds at most 64
samples, so it spans 64/Hz seconds; interpolation works while that covers the interpolation delay,
and past it `at()` falls off the old edge and edge-holds — no error, just stutter. **Exactly the
2026-08-28 bug at a higher rate**: the count was 8 then and broke at the dev rig's 100Hz; the fix
added a time bound (`maxSnapshotAgeMs`) but kept a count. **MEASURED, not derived**, and pinned by
`core/hzceiling_test.go`:

| interp | last rate still interpolating | first rate that edge-holds |
|---|---|---|
| 175ms (TEVI) | 300Hz | 480Hz |
| **250ms (shipped)** | **200Hz** | **256Hz** |
| 400ms | 144Hz | 200Hz |

**A LARGER interp delay breaks at a LOWER rate** — the counter-intuitive half, and the one that
would bite someone raising `interp` to smooth a bad link while also raising Hz.

**Nothing else has a cliff, and the second axis is NOT a gradient** (corrected 2026-08-30 — an
earlier version of this section said "~5% at 100Hz", which is wrong). `protocol.State.Timestamp` is
MILLISECONDS, so the interval quantizes to **ZERO error whenever the rate divides 1000** and up to
±0.5ms otherwise: 20/100/125/200/250Hz are EXACT; 120Hz is 6.0%, 144Hz 7.2%, 256Hz 12.8%, 480Hz
24.0%. It is bounded jitter in the interpolation fraction, not drift, and it never breaks — but it
means **144Hz is a worse choice than 125 or 200**, and a rate should be picked from the exact set.
The flood cap scales 6x with the rate on its own.

**WHY 100 IS A CLEANER CEILING THAN IT LOOKS.** The buffer is bounded by BOTH `maxSnapshots` (64)
and `maxSnapshotAgeMs` (600). The count only starts binding above **~107Hz** (64 samples span
598ms there, just under the age bound), so **at or below 100Hz the count is irrelevant and any
interp delay up to 600ms works.** MaxSendHz sits just under the crossover — whether by judgement or
luck, it is the last round number where the count constant cannot bite.

**THE CEILING THAT BINDS FIRST IS THE GAME'S OWN FRAME RATE.** An adapter samples on the game's
frame and cannot produce a DISTINCT sample faster than the game renders — Pseudoregalia ticks
~180Hz here, so a 256Hz room yields ~180 real samples plus duplicates, paying full bandwidth for
repeats change suppression then discards. **This is the one true thing in the "align your tick rate
to the engine" advice: the game's rate is a CEILING on useful Hz, not a target to match.**

**WHICH LAYER OWNS WHAT**, because the cliff is not where anyone expects: the **game** sets the
ceiling on USEFUL rate (its frame rate); the **relay** sets the room's rate (`send_hz`, one number,
it pays the fan-out); the **client** sets `interp` — and since the cliff is `64 / interp`, **the
safe rate is a PER-CLIENT property, not a room one.** Two peers in a 200Hz room, one at 250ms and
one at 400ms interp: the first is fine and the second edge-holds, with nothing on either side able
to detect it. That is the strongest argument for keeping the room rate conservative by default.

**So, in the order the limits arrive:** the game's frame rate, then `64 / interp` (silent,
per-client), then bandwidth (linear, the host's), then the ms timestamps (bounded jitter, no
cliff), then Go's CPU (never). **Between 100 and 200Hz at shipped settings nothing degrades at
all**, so "100 to be safe" is a policy choice, not a technical boundary. **And past the cliff a
HIGHER rate is WORSE than a lower one** — more samples span less time, so 480Hz edge-holds where
20Hz interpolates. It is a break, not a gradient. **Raising Hz buys SAMPLING ACCURACY, never
FRESHNESS:** a ghost at 480Hz with a 250ms delay is still drawn 250ms in the past. Lateness is
`interp`'s to fix, and anyone raising the rate to cure a "delayed" look is turning the wrong knob.

