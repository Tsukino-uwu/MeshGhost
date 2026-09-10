# 2026-09-10 — The contract catches up with the code it describes

<!-- ADR 0058. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** `contract.md` is corrected, not extended. Nothing about the wire or the bridge
  changes; the document is brought back into agreement with `protocol/`, `bridge/` and `core/`,
  which had moved past it in five places. Recorded as an ADR because `CLAUDE.md` makes any change to
  `contract.md` a contract revision, and because two of the five were **stated backwards** rather
  than merely omitted — a reader implementing against the document would have got them wrong.
- **Status:** documentation only. Every claim below was re-read against the code on 2026-09-10
  before it was written; no code was changed by this ADR.
- **Found by:** a full fact/stale sweep of the repo's documentation, the same pass that produced the
  adapter build-story backfill and the `docs/reviewing.md` corrections.

## What was wrong, and what it now says

**1. Versioning was described as exact-match; it is a floor.** The document said *"a relay that
sees a mismatched major version refuses the connection outright"*. The code is
`AcceptsPeerVersion(v) { return v >= MinProtocolVersion }`, used at both ends, with
`MinProtocolVersion = 2` — so a peer announcing a version ABOVE this build's is **accepted**, which
is the opposite of what the document promised. That is deliberate and load-bearing: additive change
is the only kind this protocol makes, so a newer peer's extra fields are ignored rather than fatal.
The field name `protocol_version` and both constants appeared nowhere in the document at all.

**2. `reject` was documented as reason-only, with "do not branch on it" attached.** The document
said the reason is *"for the adapter's log, not for branching on"* and *"plain text and not a closed
set"*. Since 2026-09-08 a `reject` carries `code` (a frozen token), `retryable`, and `reason`, and
`bridge/bridge.go` says in as many words that the codes are *"the strings an adapter MAY branch on,
and they are frozen the moment they ship"*. `core.isPermanentReject` reads the code first and falls
back to the prose. The document now gives the ladder in order — branch on `code`, fall back to
`reason` only for a relay older than 2026-09-08 — and keeps the forward-compatibility rule where it
still applies, which is the reason string.

Both halves of this had been open in `status.md` as *"deliberately not done"* since 2026-09-08,
which was true when written and stopped being true the same week. **No adapter reads `code` yet**;
all four still substring-match the prose, so the fallback is not hypothetical.

**3. `input_sample` was forward-referenced and never written.** The `remote_input` field table
said *"as recorded (see `input_sample`)"*, pointing at a section that did not exist — the only
bridge message with no entry of its own. Written now, with the point that matters for a reviewer:
**every field in it is opaque to the core**, which writes the track to `replay/inputs/` and drives
nothing with it.

**4. Six bounds existed only in the code, and they are the load-bearing ones.**
`bridge/inputlimits.go`'s caps were absent, along with the fact that makes them matter: the bridge
tolerates a **64 KiB** line for `input_sample`, not `protocol.MaxLineBytes`' 4096, because a batch
of edges is bigger than a state sample. That file's own header calls them *"the only thing standing
between a broken adapter and the core's memory"*. Also added: `MaxTimestampMs` (the one field on a
`state` that `ValidateState` never bounded until 2026-09-08) and `MaxPayloadBytes` — the sender-side
4095, whose absence let a sender build an envelope of exactly 4096 that passed its own check and
then killed the receiver's read loop with the very error the check existed to prevent.

**5. The Limits section claimed to be the authoritative list of every bound.** It is not, and
`docs/reviewing.md` was telling auditors it was. The `world.v1` bounds are documented in the
world-custody section instead, and a few smaller ones are code-only. The section now says the code
is the authority when the two disagree, and names the three files.

## Two smaller corrections in the same pass

`session_policy`'s field table listed only `ghost_collision`, while `chaser_contact` — added
2026-09-03 by ADR 0047 and described in the prose below the table — was missing from the table
itself. And `replay_control` is specified in detail but sent by **zero** shipped adapters (checked
2026-09-10), which the document now says, so nobody goes looking for the sender.

## Why this is a revision and not a rewrite

The wire did not change. Every correction here makes the document agree with code that already
shipped, and each was verified against that code rather than against the record — which is the rule
this sweep also wrote into `CLAUDE.md`, after a build-story entry written from a dated `VERIFIED.md`
entry asserted an interpolation default that an ADR had superseded the same night it was recorded.

The pattern worth keeping: **a contract that drifts does not announce itself.** All five gaps were
additive changes to the code whose author updated the implementation, the tests and an ADR, and did
not come back to the document those three describe. Nothing checks this, and nothing here proposes
that anything could — `contract.md` is prose about behaviour, and a grep cannot tell whether a
paragraph still matches a state machine. The mitigation is that the code is named as the authority
wherever the document states a bound, so a reader who checks has somewhere to check.
