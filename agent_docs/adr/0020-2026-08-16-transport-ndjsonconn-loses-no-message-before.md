# 2026-08-16 — `transport.NDJSONConn` loses no message before `OnReceive` is registered

<!-- ADR 0020. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-16
- **Decision:** `transport.NDJSONConn` guarantees no message is lost between construction and
  `OnReceive` registration — payloads arriving in that window are buffered and flushed, in order,
  when the callback is installed.
- **Status:** accepted
- **Context:** `FromConn`/`Dial` start `readLoop` before returning, so every caller has a window
  between "connection exists" and "callback installed". Anything arriving in it was **silently
  discarded** — no error, no log. Found while isolating an intermittent test failure: `go test
  ./...` failed in 9 of 12 runs, a different test each time, always a timeout waiting for a
  message that had genuinely been sent. Reachable in production, not only in tests: the relay
  installs its callback after `FromConnWithLimits`, so a fast client's `hello` could go
  unanswered, and the same applies to an adapter's `hello` on the bridge.
- **Options considered:** require every caller to register callbacks before any data can arrive
  (unenforceable, and the existing `FromConnWithLimits` already exists because callers got the
  analogous field-ordering wrong); start the read loop lazily on first registration (changes
  connection semantics and breaks connections that legitimately never register one); buffer and
  flush.
- **Resolution:** Buffer and flush. Delivery is serialized on a dedicated mutex, held across the
  callback, so a flushed backlog cannot interleave with a payload `readLoop` is delivering
  concurrently. Safe because no callback re-registers `OnReceive` on its own connection.
- **Consequences:** A guarantee the bridge and relay both quietly depended on is now real rather
  than accidental. Covered by `TestMessagesBeforeOnReceiveAreNotLost`, which fails without the
  fix. The suite went from 9 failures in 12 runs to 0 in 12. First diagnosis — "the 2s test
  deadline is too tight" — was wrong and was disproved by raising it to 10s and watching the same
  tests fail at 10.00s; recorded because the wrong fix looked plausible and would have buried a
  real bug under a slower timeout.
