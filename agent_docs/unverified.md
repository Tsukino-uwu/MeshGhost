# Unverified — the queue waiting on the user

<!-- line-cap: none -- index to the per-game queues; size tracks what is unconfirmed. Why: agent_docs/claude-md-cap.md. -->

**Split per game on 2026-08-25.** This file held 1,670 lines and 56 entries, and — unlike
`verified.md` — was already 100% per-game: Crystal and Emerald only, with no Pseudoregalia, TEVI or
Go-side entries by design. Every entry moved verbatim and in its original order to a queue beside
the adapter it belongs to:

| Game | File | Entries at the 2026-08-25 split |
| --- | --- | --- |
| Pokémon Crystal | [../adapters/emulator/pokemon/crystal/UNVERIFIED.md](../adapters/emulator/pokemon/crystal/UNVERIFIED.md) | 35 |
| Pokémon Emerald | [../adapters/emulator/pokemon/emerald/UNVERIFIED.md](../adapters/emulator/pokemon/emerald/UNVERIFIED.md) | 21 |

**Those two numbers are the split's inventory, not a live count**, and the column now says so
(2026-08-27, when they read 55 and 20 and this table still said 35 and 21). A queue's size is a
thing to measure, never a thing to quote: `grep -c '^## ' <file>`.

**All four adapters carry a queue as of 2026-08-27**, and `preflight.ps1` fails an adapter without
one — the user's call. TEVI's and Pseudoregalia's were created that day and seeded from the items
[status.md](status.md) was already carrying for both:

| Game | File |
| --- | --- |
| TEVI | [../adapters/tevi/UNVERIFIED.md](../adapters/tevi/UNVERIFIED.md) |
| Pseudoregalia | [../adapters/pseudoregalia/UNVERIFIED.md](../adapters/pseudoregalia/UNVERIFIED.md) |

This file said "there is no Pseudoregalia or TEVI queue, and that is not an oversight — create one
when the first item exists", which three other files repeated. **The first item existed in both
cases and was sitting in `status.md` instead**, so the exemption was quietly holding
the unwatched work of the two adapters furthest from a confirmation pass.

**What this is, and the rule it serves.** [verified.md](verified.md) is the append-only record of
what is *confirmed*; a queue is its waiting room — things the agent believes work, has self-tested
as far as it can, and **the user has not seen yet**. The agent verifies the Go client/server with
tools; **anything about a running game needs the user to watch it**. A screenshot the agent took is
not a substitute, and neither is a healthy log. *"nothing is considered done/fixed until i actually
confirm it as such."* Full rule: [testing.md](testing.md), and `CLAUDE.md`.

**On confirm:** the item moves to that adapter's `VERIFIED.md` with the date, and is deleted from
its queue. **On decline:** it goes back to being work, with a note of what was actually seen —
usually the most valuable line in the file.

**Emerald's many open items do NOT contradict its "feature complete" call.** Emerald was called
FEATURE COMPLETE on 2026-08-21 by the user, about *animation and effect parity* — the features are
done. What is still queued is the other kind of item: details never watched, edges never reached,
measurements taken but never judged on screen. [status.md](status.md) is the arbiter of what that
means for scheduling — a new Emerald item needs a reason it is not polish, and a real fault is a
defect against a finished adapter. **Do not read a Pending Emerald entry as a missing feature.**

**A Go-side item never belongs in a queue at all.** `core`, `relay`, `transport`, `bridge` and
`cmd/` are confirmed by running the tools, not by waiting on the user — which is exactly why this
file never had any.
