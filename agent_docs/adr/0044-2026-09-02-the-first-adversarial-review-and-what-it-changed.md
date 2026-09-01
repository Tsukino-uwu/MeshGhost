# 2026-09-02 — The first adversarial review, and what it changed

<!-- ADR 0044. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** the relay, its transports and the peer-to-adapter path were reviewed the way an
  attacker would read them, for the first time — five reviewers (agent sessions given only the code
  and "break this", no design documents), one attack class each, plus a sixth checking every claim
  in `docs/security.md` against the code as it stood. Every confirmed finding was fixed with a
  regression test that failed first, and the bounds that were missing became contract limits.
- **Status:** Go side implemented and confirmed with the tools 2026-09-02 (`run-gotests.bat`,
  `-race`, the fuzz target that had been blind). The adapter-side hardening (four files) is BUILT
  and DEPLOYED but unwatched: each game's `UNVERIFIED.md` names what a run needs to show.
- **Why now:** a prospective relay host on Discord (2026-09-01) said, fairly, that networking code
  is where things "function correctly until someone sends an unexpected request", that AI-written
  code deserves extra eyes there, and that they would read the code before hosting. The user agreed.
  The project's own `docs/security.md` had said since 2026-08-14 that the hardening pass "fixed the
  concrete gaps found while scoping it — not a claim that every malicious-peer angle has been
  tried." This ADR closes that sentence with a method rather than a claim. The reviewer's front
  door is `docs/reviewing.md`.

## What was found, and what each fix is

Ranked by what it cost a host. Every one was confirmed against the code by me after the reviewer
reported it; three were also confirmed by the reviewer running the real binary.

1. **One spoofable UDP datagram killed the whole relay process on Windows.** `netx/udpconn`'s two
   read loops used a 1200-byte buffer; a bigger datagram makes Windows return the bytes AND a
   `WSAEMSGSIZE` error, the loop treated any error as the socket dying and closed the listener, and
   the relay binary treats a listener dying as fatal — tcp and quic went down with it. No handshake,
   no cookie, any source address. The same buffer on the dialed side ended a player's session with
   one packet to their port. **Fix:** a 64 KiB read buffer, so no datagram anyone can send is
   larger than it, and anything over `MaxDatagramBytes` is read in full and dropped
   (`readBufferBytes`). **Why the fuzzer never saw it:** `FuzzListenerSurvivesArbitraryDatagrams`
   truncated its own inputs to `MaxDatagramBytes`. It now caps at 60000. Regression:
   `netx/udpconn/oversized_test.go`, both sides.
2. **Descriptor exhaustion was a remote crash.** `relay.Serve` returned on any `Accept` error;
   past the descriptor limit `accept(2)` fails with EMFILE, which is a *temporary* error. **Fix:**
   retry temporary errors with backoff, the `net/http` shape. Regression: `relay/serve_test.go`.
3. **Nothing bounded connections that had not said hello.** `MaxClients` counted joined clients;
   a stranger could hold thousands of pre-hello connections at a few bytes each, for `HelloTimeout`
   apiece, and under TLS a further 10s handshake window before the relay even saw them. **Fix:**
   `netx.LimitListener`, applied BENEATH the TLS layer so handshakes count, closing (not queueing)
   the connection past the cap; `relay.MaxOpenConnsFor` = 8 per seat, floor 64; refusals logged
   once a second. Regression: `netx/limit_test.go`.
4. **One member could refuse every trade in an `escrow.v1` room, renewably.** The open-time cap
   counted terminal records kept for `EscrowRetention`, so 64 open-then-abort pairs — under the
   flood cap — made every other member's open come back rejected for the next minute. Found
   independently by two reviewers. **Fix:** only LIVE exchanges count, and a new per-opener cap
   (`MaxLiveEscrowsPerMember` = 8, counted by opener, never by counterparty). Regression:
   `relay/escrow_cap_test.go`.
5. **QUIC never validated a source address.** `quic.ListenAddr` leaves `VerifySourceAddress` nil,
   so a spoofed Initial cost the relay a TLS handshake, 5s of half-open state and a 3x reply toward
   the spoofed address. **Fix:** every unvalidated source gets a Retry first (one extra round trip
   per connect, paid once per session); incoming streams limited to the one the protocol uses,
   receive windows 64/256 KiB instead of 512 KiB/1.5 MiB.
6. **Pre-hello log amplification, 4x.** An oversized line's head was logged quoted, up to 16000
   bytes; 4 KB of NUL bytes wrote 16 KB of log, unauthenticated, per connection. **Fix:** the head
   is 96 bytes, still enough to name the message (the reason it exists, 2026-09-01).
7. **The core's roster had no bound, and the adapters spawn a ghost per announced id.** A hostile
   or broken relay could announce ids without end; TEVI `Instantiate`s per id, Pseudoregalia
   clones a pawn. **Fix:** `protocol.MaxRosterSize` = 512, enforced on welcome and join; a refused
   id stays unknown, so its state is dropped too. Regression: `core/roster_cap_test.go`.

**Adapter side (built, deployed, unwatched):** Pseudoregalia wrote a peer's afterimage count
straight into the game's own spawn count with no upper bound (now 1..64, else 6), let a non-finite
`orientation` reach `FRotator` on the raw path (now zeroed), and never forgot a nametag (now capped
at 1024, evicting names with no live ghost). Crystal's main loop had no `pcall`, so one bad field
ended the script until BizHawk restarted (now guarded like Emerald's `guardedFrame`), a fractional
tile in the cross-map log raised under `%d` (now `%s`), and a non-object `extras` raised on index
(now treated as absent). Emerald's `extras.gender` reached the frame tables unchecked (now `male`
or `female` only). TEVI's `anim_t`/`pause` floats could be NaN into the Animator (now finite or
absent). Each game's `UNVERIFIED.md` carries the watch.

## What was found and deliberately NOT changed

Recorded in `docs/security.md`'s known gaps, each with its reason:

- **Room squatting.** The first hello fixes a room's `game_version` and feature set; with room-code
  auth off, a stranger who connects first can lock a room name. That is the no-auth posture's
  meaning, and the fix is the existing `room_code`.
- **World and lease tables are exhaustible by one member of an opt-in room**, and world entries
  outlive their writer by design (custody). No shipped adapter negotiates either plane; the
  planes' whole reason to exist is that the relay holds what the simulation cannot. A per-member
  bound like escrow's would be the same shape; parked until a plane ships.
- **Resume-grace slot squatting** costs an attacker nothing beyond what holding a connection
  already did; bounded by `MaxClients`.
- **The UDP cookie reply is an 18-byte answer to a 2-byte spoofable hello** — a 1.5x on-wire
  reflector with one HMAC per packet. Negligible, opt-in transport, recorded so nobody rediscovers
  it as news.
- **Lease-holder churn re-sends the world snapshot per handover** (~53 KB per ~200 B in) — real,
  opt-in, and the honest fix is rate-limiting handovers, a contract question for when world ships.

## The lesson worth more than any fix

Five of the seven Go findings were in code that had tests, and the tests were honest: they proved
the property they named. What they had not been asked was **"what does the party we did not write
this for send?"** — a datagram bigger than our own limit, a kernel saying "not now", a member who
opens trades to abort them. The fuzzer case is the sharpest: it was written to hammer the listener
with arbitrary bytes and then truncated those bytes to the very limit whose overflow was the bug.
**A test written by the author encodes the author's model of the input; the only inputs that
escape that model are ones nobody chose** — a fuzzer that is not clipped, and a reader who was told
nothing but "break it". Filed in `pitfalls/by-lesson.md` and `testing.md`.

## Contract changes

`agent_docs/contract.md`'s Limits: escrow's cap is now per live exchange and per opener;
`MaxRosterSize` bounds a core's remote players; the relay bounds open connections per listener.
None changes a message shape.
