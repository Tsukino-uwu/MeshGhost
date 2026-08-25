# Bandages — core, relay, transport (the Go side)

<!-- line-cap: 200 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

Shipped compensations outside any adapter: **a fix that restores, forces, compensates for, or
remembers a value rather than preventing whatever changed it.** The rule, its one narrow exception,
and what it is *not*: `adapters/_template/README.md` ("a bandage fix is not a finished feature").

From the repo-wide audit of 2026-08-16. **The audit's own headline is worth keeping:** most things
that *looked* like bandages are not. The great majority carry the live incident, the rejected
alternative, and the derivation next to them — see "deliberate" at the end, where mislabelling
would cause churn. Ranked by how likely each is to cause a real bug.

Per-adapter registers: `adapters/pseudoregalia/BANDAGES.md`, `adapters/tevi/BANDAGES.md`,
`adapters/emulator/pokemon/emerald/BANDAGES.md`, `adapters/emulator/pokemon/crystal/BANDAGES.md`.

Unlike the adapter registers, everything here is confirmable with the tools — `run-gotests.bat`, a
regression test — without watching a running game.

## Is this a bandage?

The canonical guide — the one mechanical test, the tells while you are writing it, the eight
tells that only show up later, and the one bandage shape to avoid outright — lives in
[`adapters/_template/BANDAGES.md`](../adapters/_template/BANDAGES.md). Read it before adding an entry.

**The Go side has its own dominant shape**, visible in the open items below: a constant in one
package hand-picked as a "margin" against a constant in another, rather than *derived* from it.
Prose asserting the relationship is not the relationship. If the two can drift apart without a test
failing, it belongs here.

## Open compensations

### 1. `DefaultInterpolationDelay` is measured now, but the protocol floor above it is not

**Half of this closed on 2026-08-19.** The constant used to say of itself: *"100ms is a starting
guess for tile-grid movement, not a measured value."* It has now been measured — Emerald with both
renderers on screen at once, judged at each setting: 100ms visibly chops an engine-driven ghost
while running, 250ms is *"1:1:1 perfect"* (`verified.md`). The default is 250ms and the comment
says why, including what it costs.

**What has NOT closed:** `protocol/limits.go:75-91` built the `MinSendHz = 10` floor on top of the
old number, and a client using the documented, supported `min_send: 150ms` still lands in exactly
the degraded regime that floor exists to prevent. The floor was derived from a guess; it now sits
under a measurement it was never re-checked against.

**Fix:** derive it from `effectiveSendInterval()`, the way `DefaultMinSendInterval` is already
rederived from `protocol.DefaultSendHz` specifically "so the two numbers cannot drift apart".

### 2. `DefaultHeartbeatInterval` is a hand-picked margin against another package's constant

`core/core.go:152-163`. The heartbeat itself is the correct fix for a real, live-diagnosed
bug (idle timeout → fresh `player_id` every minute → every peer sees a despawn/respawn). The
**constant** is the bandage: 20s was chosen as "comfortable margin" under `transport`'s 60s, but
`relay.Server.IdleTimeout` is a per-server override, so a relay configured below ~20s silently
reintroduces the exact churn this was chosen to prevent.

**Fix:** `DefaultIdleTimeout / 3`. The repo already does this correctly elsewhere —
`relay/limits.go:65` derives its headroom "so the stated relationship can't silently break".

### 3. `MaxEventBytes` is a margin asserted against a datagram limit it does not actually fit

Exactly the shape this file's "Go side" note describes: a constant in one package hand-picked as a
margin against a constant in another, with prose asserting a relationship that does not hold.
`MaxEventBytes`' own doc comment used to say it keeps an event "comfortably under"
`udpconn.MaxDatagramBytes` (1200), and `contract.md` repeated the claim — it was sized against the
**payload** alone, not the envelope. **The comment was corrected 2026-08-18** and now states the
real relationship; the constant is unchanged, so the compensation is still open. Measured (2026-08-17, figures corrected 2026-08-18 against the assertion tests): a maximal `Event` renders to **1441
bytes** and a committed `EscrowState` to **3302**, against **1182** usable after 18 bytes of
framing. Both are refused by `udpconn.checkWritable` — on the reliable plane too — surfacing only
as a `relay: send to pX failed:` line, so the message is lost for that recipient and never
superseded. Registered here 2026-08-18; the measurement and the full trade-off are in `risks.md`.

**Unreached today** — no adapter uses the event, escrow or world planes at all.

**Fix:** derive the ceiling from the datagram limit the way `MaxWorldBlobBytes` already is (derived
that way from the start, and it does fit). The second half of that fix is already done — since
2026-08-18 `netx/udpconn/world_bounds_test.go`'s `TestMaximalEventDoesNotFitAUDPDatagram` and
`TestMaximalCommittedEscrowDoesNotFitAUDPDatagram` pin the real relationship in both directions,
so the two constants can no longer drift apart unnoticed. Shrinking
them is a contract change with its own trade-offs, weighed against making the bound
transport-dependent (`beyond-cosmetic.md` §9) — its own decision, not a hot-fix.

## Borderline — noted, not urgent

- **`udpconn.go:134-140`.** Retry budget asserted to fit inside `relay.DefaultHelloTimeout` in
  prose only, not derived. Same drift shape as #2, lower impact.
- **`cmd/meshghost/parent_windows.go:31-43`.** Windows PID reuse could make a dead parent look alive forever; not
  called out anywhere.

## Deliberate — do NOT "fix" these

Recorded so a future audit does not churn them.

- **`ClampSendHz` / `ClampReceiveHz`** — clamping a cosmetic knob so a typo cannot stop a relay
  starting, per `contract.md`.
- **The `log.Fatalf` on a bad `-transport`** — deliberate. A silent fallback would hand someone who
  asked for `quic` an unencrypted session.
- **`relay/limits.go`'s derived constants** — the pattern #1 and #2 above should be converted to.
- **`stripBOM` / `applyDespiteBadValue`**
- **The `net.ErrClosed` suppression**
- **The `relayOwner` / `attachedAdapter` split**
