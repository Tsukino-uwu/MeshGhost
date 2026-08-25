# 2026-08-15 — Make the room's state send rate operator-configurable at the relay

<!-- ADR 0017. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-15
- **Decision:** Make the room's state send rate operator-configurable at the relay
  (`server.send_hz`, 20 default, 10–100), advertised to every client via `Welcome.SendHz` and
  adopted as that client's own send rate — unless the client has deliberately configured a
  slower rate of its own, which always wins. Separately, let each client declare its own
  per-peer receive cap (`client.max_receive_hz_per_player`, `Hello.MaxReceiveHz`), enforced at
  the relay by dropping excess forwards to that specific recipient. Both integer Hz, matching
  how game servers are conventionally described ("a 20-tick relay").
- **Status:** accepted
- **Context:** The send rate was previously a single hardcoded constant
  (`core.DefaultMinSendInterval`, 50ms/20Hz) with no way for a host to trade bandwidth for
  smoothness, and no way for an individual player on a poor connection to opt out of a fast
  room without also throttling everyone else. The user specifically wanted the *cost* of raising
  the rate to be visible at the point someone would change it, not just the mechanism.
- **Options considered:**
  - **Units — Hz integers vs. duration strings** (`"50ms"`, matching the existing `interp`/
    `min_send` client fields). Hz chosen: the user's own mental model was explicitly a game-
    server tickrate ("the server is running at 60Hz for Counter-Strike/Overwatch"), and Hz reads
    naturally next to a bandwidth-tradeoff explanation ("20/sec vs 100/sec") in a way a duration
    string doesn't. Costs a style inconsistency with `interp`/`min_send` in the same config
    file — accepted as the smaller cost.
  - **Receive-side throttling: at the relay vs. at the receiving client.** Client-side discarding
    (receive the full stream, drop what you don't want) saves the client nothing — the bytes
    already crossed its downlink, which is exactly the thing a metered/weak connection wants to
    avoid. Relay-side dropping was the only option that actually delivers the stated benefit.
  - **Per-room vs. per-(sender, recipient) receive state.** A single per-room or per-sender cap
    would force every recipient to the same rate for a given sender, defeating the point (two
    recipients on different connections need different effective rates from the *same* sender
    simultaneously). Per-(sender, recipient) is the only shape that allows this, at the cost of
    real complexity: this state cannot use `handleConn`'s existing "OnReceive is serial, no mutex
    needed" shortcut, because it is *read* by the sender's goroutine but *owned* by the recipient
    — up to N−1 goroutines can touch one recipient's gate concurrently in an N-member room. Given
    its own mutex on `Client` (`gateMu`/`lastStateTo`), deliberately kept off `Room.mu` so
    `Room.Forward`'s hard-won "never do work under the room lock" property
    (`TestRoomForwardDoesNotBlockOtherOperationsOnStalledSend`) isn't put back at risk.
  - **Drop vs. coalesce vs. queue excess receive-side traffic.** Queueing/coalescing would add
    unbounded latency or memory for a purely cosmetic overlay. Dropped instead, consistent with
    `contract.md`'s existing state-plane posture (lossy, latest-wins) — a lower effective receive
    rate costs smoothness, never adds lag.
  - **Flood-cap scaling: proportional both ways vs. up-only.** Scaling the per-client flood cap
    (`relay.MaxMessagesPerSecond`) down along with a slower `send_hz` was rejected: an older
    client (or any client with an explicit local override) never learns the room turned down and
    keeps sending at its own built-in 20Hz default — scaling the cap down would then start
    disconnecting well-behaved clients for a config change on the host's side they had no part
    in. Scaling only ever **up** from the historical 120 avoids this; `120` becomes a floor
    (`max(120, send_hz × RateLimitHeadroomMultiple)`, headroom `6`, chosen so a relay left at the
    default `send_hz` computes exactly the historical `120` and nothing changes for an existing
    deployment).
  - **"Send" adoption: prescriptive vs. permissive.** A permissive design (the relay merely raises
    a ceiling; each client's own local config still governs what it actually sends) was rejected
    because it makes the host's `send_hz` setting inert on its own — raising it would do nothing
    until every player *also* reconfigured their own client, defeating "one knob, one visible
    tradeoff." Prescriptive-with-a-floor was chosen instead: `Core.effectiveSendInterval()`
    resolves to the **slower** of the relay's advertised rate and the client's own explicit
    `MinSendInterval`, so raising the room's rate genuinely speeds up every player who hasn't
    opted out, while a deliberately-configured slow client can never be sped up past its own
    floor. Detecting "deliberately configured" needed its own decision: `MinSendInterval`'s
    default changed from `DefaultMinSendInterval` (set by `New()`) to the zero value, so
    "explicitly set" is simply `MinSendInterval != 0` — reusing the zero-means-default convention
    already used by `Server.MaxClients`/`HelloTimeout` rather than threading a separate boolean
    through the existing CLI-flag/config-file precedence layering.
  - **Rejecting a rate-limited client: silent close vs. a `Reject` first.** The existing flood-cap
    close (`relay.go`'s rate-limit block) was a bare `nd.Close()` with no message — replaced with
    a `Reject{Reason: ReasonRateLimited}` sent first, matching the "refused/closed, and why"
    posture `TypeReject` already established at handshake, now extended to an already-joined
    connection. Required a matching fix on the client: `isPermanentRejectReason` previously
    treated every reason except `ReasonServerFull` as permanent (would have cached
    `ReasonRateLimited` and stopped the client from ever retrying); it's now an explicit retryable
    set (`ReasonServerFull`, `ReasonRateLimited`) rather than a blacklist-of-one, so a future new
    reason still defaults to permanent (the conservative posture this classification has always
    had). Also required fixing a real, separate gap this surfaced: a `Reject` arriving
    mid-session (after the handshake's own `select` has already returned) was previously
    discarded by `handleRelayMessage`'s non-blocking channel send with no log line at all — the
    user would have seen only a bare "relay disconnected" with the actual reason lost. Now logged
    when it happens post-connect.
- **Resolution:** All of the above, implemented across `protocol` (shared `DefaultSendHz`/
  `MinSendHz`/`MaxSendHz`/`ClampSendHz`/`ClampReceiveHz`, `Hello.MaxReceiveHz`, `Welcome.SendHz`,
  `ReasonRateLimited`), `relay` (`Server.SendHz`, `resolveSendHz`, `MaxMessagesPerSecondFor`,
  the per-`Client` receive gate, `Room.stateRecipients`, the `Room.remove` gate purge),
  `core` (`effectiveSendInterval`, `serverSendInterval`, `Core.MaxReceiveHz`, the
  `isPermanentRejectReason` fix, mid-session reject logging), and both `cmd/` binaries
  (`-send-hz`/`send_hz`, `-max-receive-hz-per-player`/`max_receive_hz_per_player`, `-min-send`'s
  default changed from `core.DefaultMinSendInterval` to `0`). `cmd/meshghost-relay`'s
  `applyFileConfig` was converted from flat positional pointers to a `configTargets` struct on
  this change (the 4th knob), matching the refactor `cmd/meshghost`'s own config loader already
  went through.
- **Consequences:**
  - **A minimum-interval gate quantizes the achievable receive rate**, not a token bucket:
    effective rate ≈ `senderHz / ceil(senderHz / capHz)`, so e.g. a 15Hz cap against a 20Hz sender
    yields 10Hz, not 15. Documented in the `-max-receive-hz-per-player` flag help and
    `packaging/release/README.txt`, not engineered around — same shape as the pre-existing
    `MinSendInterval` gate, and acceptable for a cosmetic ghost.
  - **`send_hz` is prescriptive but unenforced.** Nothing makes a client actually honor
    `Welcome.SendHz`; the only hard backstop is the scaled flood cap, so a non-compliant client
    may legitimately run at up to 6× the room's configured rate before it's disconnected.
  - **Raising `send_hz` taxes every peer's download, and a pre-change client can't opt out** of a
    fast room the host configures (it has no `max_receive_hz_per_player` to set). Combined with
    the pre-existing O(n²) room fan-out (`relay.DefaultMaxClients`'s own doc comment), 100Hz in a
    full 8-seat room is real, meaningful traffic — measured (not estimated; see the method below)
    at roughly 39 KB/s per player's own upload, up to several MB/s through the host. This is
    surfaced explicitly in `packaging/release/README.txt`'s new Hz section, with the specific
    recommendation to leave both settings at their defaults unless the operator has a concrete
    reason not to.
  - **This silently broke the project's own dev-testing setup, caught and fixed in the same
    change:** every `dev-scripts/run-core-*.bat` script passes `-min-send=10ms`, faster than the
    (now-fallback-only) 20Hz default — under "slower wins," an unconfigured 20Hz relay would have
    quietly capped every one of them back down to 50ms, a 5× regression in exactly the timing-bug-
    surfacing setup Phase 8 chose deliberately (`agent_docs/phases/phase8.md`). Both
    `dev-scripts/run-relay.bat` and `run-relay-loopback.bat` now pass `-send-hz=100` so they never
    become the bottleneck for local testing.
  - **Message-size measurement for the README's bandwidth table:** per `CLAUDE.md`'s
    no-numbers-from-memory rule, the per-message byte figures are not estimated — they come from
    actually marshaling a real `protocol.State`/`protocol.Envelope` through the identical
    `json.Marshal` path `relay.go`'s `sendEnvelope` uses, with field shapes and example values
    matching the two adapters' own real outgoing payloads (Emerald: `adapters/emulator/pokemon/emerald/
    meshghost_emerald.lua`'s `encodeLocalState`, `:463-466`; Pseudoregalia: `adapters/
    pseudoregalia/MeshGhostPseudo/Mod/src/Plugin.cpp`'s local-state `std::format` call,
    `:7538-7592`). Measured once via a throwaway `cmd/` program, run, and deleted — not committed,
    since it exists only to produce this ADR's/README's numbers, not as a reusable tool. Result:
    a full NDJSON `state` line (envelope + newline) is **185 bytes** for Emerald's lighter
    2D/no-orientation/single-extras-field shape, **390 bytes** for Pseudoregalia's richer
    3D/orientation/8-extras-field shape — the README's worked table uses the 390-byte figure as
    the representative case, since it's the heavier of the two currently-shipped shapes.
  - **Re-measured 2026-08-15, and the figures above had gone stale — the README's table was
    understating host cost by ~1.5x.** Pseudoregalia's extras grew from 8 fields to 14 over that
    day's VFX/weapon/outfit work (trail colour, capsule height, outfit mesh path, afterimage
    counts), taking its state line from 390 to **597 bytes**. All three shipped adapters
    re-measured together this time, same method: Emerald **206**, TEVI **249** (never previously
    measured), Pseudoregalia **597**. Emerald's 206-vs-185 difference is methodology, not drift —
    this pass included its `orientation` field, which the original omitted.
    **Maintenance rule, relaxed 2026-08-16 on the user's call — the earlier version of this
    paragraph made it a rule that any `extras` change is a change to the published table, and that
    is stricter than the numbers need to be.** The table exists to give a host a rough sense of
    what hosting costs, not to be a 1:1 accounting of the current wire format. Treat the figures as
    a ballpark that ages slowly, in the spirit of `CLAUDE.md`'s dated-fact caveat: right order of
    magnitude, not right to the byte. **Re-measure when asked, not reflexively on every adapter
    change.** For reference, the extras set has grown since the 597-byte measurement (Pseudoregalia
    was 14 keys then, 25 as of 2026-08-16), so the real figure is somewhat higher — treat 597 as a
    floor rather than a current reading. The one thing that *was* worth an actual check, being a
    correctness question rather than a documentation one — whether the grown extras shape still
    fits inside `MaxExtrasBytes = 1024` — was done 2026-08-16 by costing the real `std::format`
    string against the longest object paths seen in this repo (56 chars, `BP_looseWeapon_C`) plus
    25% headroom: **worst case ~826 bytes, so it fits, with roughly 200 bytes spare.** That is
    real but not generous — the four unbounded object-path strings (`outfit_mesh`, `montage`,
    `weapon_class`, `weapon_glow`) are what would consume it, so a future feature adding a fifth
    path field is the case to re-check. Oversized extras are dropped silently by
    `protocol/limits.go:172`, which is exactly the kind of failure that looks like a broken
    feature rather than a limit.
  - **Hosting guidance added to `packaging/release/README.txt` (2026-08-15):** the table is now
    explicitly Pseudoregalia-based and labelled as a worst case, since it is the heaviest of the
    three by more than 2x — a host sizing a room off it can only be surprised in the good
    direction by running a lighter game. It also carries host upload in Mbps (the unit an
    internet plan is actually sold in) against a "budget half your measured upload" rule, plus
    the note that per-ghost *render* cost is a separate ceiling the network numbers say nothing
    about. `max_clients`'s default of 8 is presented as a safe-for-most-connections choice
    rather than a technical limit, which is what `relay/limits.go` already says.
  - **Not done, deliberately, in this change:** advertising `max_receive_hz_per_player` back to
    the sender (a sender has no way to know a given recipient is receiving it throttled) and
    deriving `InterpolationDelay` automatically from the effective rate (a room or cap set below
    ~10Hz needs `-interp` raised by hand or ghosts will visibly stutter, since even the 250ms default
    interpolation buffer no longer spans the gap between samples) are both real, known gaps —
    left for `agent_docs/ideas.md` rather than scope-creeping this change.
