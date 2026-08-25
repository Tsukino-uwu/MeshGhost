# Unverified — the queue waiting on the user

**Split per game on 2026-08-25.** This file held 1,670 lines and 56 entries, and — unlike
`verified.md` — was already 100% per-game: Crystal and Emerald only, with no Pseudoregalia, TEVI or
Go-side entries by design. Every entry moved verbatim and in its original order to a queue beside
the adapter it belongs to:

| Game | File | Entries |
| --- | --- | --- |
| Pokémon Crystal | [../adapters/bizhawk/pokemon/crystal/UNVERIFIED.md](../adapters/bizhawk/pokemon/crystal/UNVERIFIED.md) | 35 |
| Pokémon Emerald | [../adapters/bizhawk/pokemon/emerald/UNVERIFIED.md](../adapters/bizhawk/pokemon/emerald/UNVERIFIED.md) | 21 |

**There is no Pseudoregalia or TEVI queue, and that is not an oversight** — nothing was ever
written for them here. Create one when the first item exists.

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
