# 2026-09-02 — 450ms interp ships for every game, judged on the worst-case link

<!-- ADR 0046. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** `core.DefaultInterpolationDelay` is 450ms, the release `config.json` and the
  per-game client template carry 450ms, and no game overrides it. The per-game READMEs keep the
  lower tiers a player on a better link may set. The user's call, made after all four games were
  climbed the same night on the proxy profile that `run-netsim.bat` now runs by default.
- **Status:** TEVI, Pseudoregalia and Emerald watched on screen at 375 and 450ms (each adapter's
  `VERIFIED.md`); Crystal adopted on the user's reasoning that a larger buffer only adds delay,
  never stutter, with one worst-case look still owed (`crystal/UNVERIFIED.md`).
- **The rig the number is for:** the worst case a shipped default must survive — NA<->EU ping
  plus bad wifi: 100ms ±50ms one-way per proxy pass (the proxy is crossed twice, ~200 ping peer to
  peer), 5% loss, 3% reorder, a one-second blackout every 45s — at the 15Hz room rate with loss
  cover on and the relay's datagram path fixed (`341a768`). Every earlier interp verdict was on a
  milder link or the broken relay, and the user's rule that night is that a verdict is made on
  nothing milder than this (`CLAUDE.md`).
- **What the ladder showed, all three games alike:** 300ms is arithmetically short (transit
  averages ~205ms, samples 67-83ms apart); 375ms leaves a small stutter every few seconds from the
  5% loss holes (the core's `buffer dry` meter: 3-13 small-hole seconds per run); 450ms leaves only
  the blackout itself, which no interp value covers — the ghost holds its last sample through the
  outage and jumps to the first one after it. A catch-up rule for that jump is a separate decision.
- **Cost:** a ghost renders 450ms plus one-way latency behind its player, roughly two-thirds of a
  second on the worst link and half a second on a good one. The per-game READMEs tell a player on
  a same-continent link that 300ms (a little loss) or 250ms (clean) is safe there.
- **Supersedes:** the 250ms of 2026-08-19 (a loopback measurement on Emerald), TEVI's 175→300ms of
  2026-09-01 (an extrapolation), Pseudoregalia's 375ms of 2026-09-01 (the ocean profile without the
  wifi dropout). ADR 0040's per-game knobs still stand; what changed is the default they start from.
