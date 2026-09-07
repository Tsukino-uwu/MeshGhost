# 2026-09-01 — The default room send rate drops from 20Hz to 15Hz

<!-- ADR 0054. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** `protocol.DefaultSendHz` becomes **15**, from 20. This is the rate a room runs at
  when nobody configures one, and it applies to every adapter unless that game overrides it
  (`server.send_hz` on the relay; ADR 0040's per-game principle for the client-side knobs).
- **Status:** accepted, shipped 2026-09-01. Pinned by `protocol/sendhzdefault_test.go`, which fails
  with a message naming this change if anyone puts 20 back.
- **Written 2026-09-07, six days late.** The change shipped without an ADR, and this file exists
  because the decision log is where a shipped default is supposed to be explainable from. The
  evidence below was recovered from `protocol/limits.go:103-131`, `relay/limits.go:56-81` and
  `adapters/pseudoregalia/VERIFIED.md`'s 2026-09-01 evening entry — not from memory. **The gap was
  self-documenting**: `VERIFIED.md:4744` closes that session with *"The cross-adapter
  `DefaultSendHz` 20->15 change was deliberately NOT made tonight -- evidence supports it,
  decision pending."* The decision was then taken and never written down.

## Why 20 was never a measurement

**The number being replaced had no evidence behind it at all**, which is the part worth
stating first. 20Hz was inherited: it was the rate live-confirmed as `core.DefaultMinSendInterval`
across the games shipping in 2026-08, kept so that the two constants were provably equal, and
explicitly not a claim about the right rate. It had simply never been the subject of a test.

## What replaced it

Measured on screen with two real game instances through `cmd/meshghost-netsim`, on Pseudoregalia
**deliberately** — 3D, momentum, long airborne arcs, the most sample-hungry adapter shipped — so
that the other three inherit a rate proven on the hardest case rather than the easiest.

**The rung ladder**, each judged by the user watching:

| rate | what the user saw |
| --- | --- |
| 1Hz, 3Hz | outright teleporting |
| 5Hz | "not teleporting anymore, but constantly snapping" |
| 7Hz | "visually smooth, but it jitter/lag every now and then" |
| 10Hz | "fine, but some stutters every now and then" |
| **15Hz** | **"can't really tell if there are any stutter/jitter things"** |
| 20Hz | clean |

**So the visible floor is near 10, and 15 carries margin over it while 20 buys nothing a watcher
can see.** The sub-10 rungs were reached with a temporary dev build, which matters below.

**Then a five-round blind A/B of 15 against 20**, rate hidden from the watcher. They scored
**2.5/5 — chance.** The one confident "this is the slow one" tell fired on two rounds that were
actually 20Hz, and turned out to be a renderer bug in the thrown sword, fixed separately. At the
ocean tier both rates were equally bad until `interp` was raised, which settles that the rate was
never the lever there either.

## Two things deliberately NOT moved with it

Both are the interesting half of this decision, because both are places the change could have
propagated silently.

1. **`MinSendHz` stays 10.** The ladder's sub-10 rungs only existed under a temporary dev build; a
   floor is not something to lower on evidence gathered by removing the floor.

2. **`relay.RateLimitHeadroomMultiple` stopped deriving from `DefaultSendHz` and went back to a
   literal 6.** It had been `MaxMessagesPerSecond / protocol.DefaultSendHz` (120/20) since a
   2026-08-16 review pass, so that "a relay left at defaults computes precisely the historical 120"
   could not silently break. On the drop to 15 that derivation **would have kept the defaults case
   right (15 × 8 = 120) while quietly RAISING the cap at every configured rate above the default**
   — a 100Hz room going from 600 to 800 messages/second per client, loosening a resource guard as a
   side effect of a cosmetic smoothness decision nobody had connected to it. Pinned at 6, every
   configured rate keeps exactly the cap it had, and the default case is unchanged too: 15 × 6 = 90
   falls under the `MaxMessagesPerSecond` floor, which returns 120 — the same number 20Hz produced.

   **The lesson that came out of it, and it generalises past this constant:** *a derivation is only
   safe while every dependant WANTS to move with the source.* The 2026-08-16 pass was right about
   what it aimed at (three independent literals in two packages); what it missed is that a derived
   constant transmits a change to places the change was never reasoned about.

## Consequences

- **Bandwidth falls by a quarter for every room that never configures a rate**, which is every
  shipped default. `docs/security.md` and `agent_docs/hz-ceiling.md` work from the new figure.
- **`core.DefaultMinSendInterval` follows automatically** — it is `time.Second /
  protocol.DefaultSendHz`, so it moved from 50ms to ~67ms without a second edit. ADR 0009's
  "50ms/20Hz" is superseded on that point.
- **A default is not a ceiling.** A room that wants more sets `server.send_hz`, and any game may be
  swept and raised on its own evidence — which is the whole shape of ADR 0040.
- **Nothing was re-derived for the other three adapters.** They inherit a rate proven on the
  hardest case; if one of them is later found to want more, that is a per-game measurement, not a
  reason to move this number back.
