# Unverified — TEMPLATE

**This is the template. Copy it to `<your-adapter>/UNVERIFIED.md`, fix the title and the relative
link depths, delete everything above the horizontal rule below.** Neither the copy nor this
template carries a line cap: caps apply only to files that load as instructions
(`agent_docs/claude-md-cap.md`), and a queue's size is how much the user has not seen yet.

**When to create it:** with the adapter. **Every adapter carries this file** — the user's call,
2026-08-27, and `preflight.ps1` fails an adapter without one. This said "not before ... an adapter
with nothing pending does not need an empty queue, which is why Pseudoregalia and TEVI have none",
and the premise was simply false: `agent_docs/status.md` was carrying unwatched items for both games
the whole time. The exemption was protecting the two adapters that most needed a queue.

**Link depths differ by where the adapter sits** — four levels down for an emulator game
(`adapters/emulator/pokemon/<game>/`), two for everything else. Copy the depth from a shipped
adapter at your own level and let preflight's markdown-link check confirm it.

---

# Unverified — &lt;Game Name&gt;'s queue waiting on the user

**What this is.** [`VERIFIED.md`](VERIFIED.md) is the append-only record of what is *confirmed*.
This is its waiting room: things the agent believes work, has self-tested as far as it can, and
**the user has not seen yet**. It exists so work can continue while the user is away without
either losing track of what still needs checking or quietly drifting into calling it done.

**The rule it serves** (`agent_docs/testing.md`, `agent_docs/environment.md`): the agent verifies
the Go client/server with tools; **anything about a running game needs the user to watch it**. A
screenshot the agent took is not a substitute, and neither is a healthy log. *"nothing is
considered done/fixed until i actually confirm it as such."*

**How to use it.**

- The agent adds an item the moment it believes something works, with **what to look at** and
  **what correct looks like** — enough that the user can judge it without re-deriving anything.
- The user works down the list and answers each **confirm** or **decline**. Decline is a normal
  answer, not a failed handover.
- **On confirm:** move it to [`VERIFIED.md`](VERIFIED.md) with the date, and delete it here.
- **On decline:** it goes back to being work. Note what was actually seen — that is usually the
  most valuable line in the whole file.
- Nothing here is cited as established anywhere else while it sits here.

**This queue drains, and that is what makes it a queue.** A confirmed item does not stay here with
a note explaining why it stayed; it moves. The file this pattern came from had been carrying
confirmed items indefinitely, each explaining that `verified.md` was "the user's to append" — which
is how a queue quietly becomes a second, worse record. **The size of this file is how much the
user has not seen yet**, and it is meant to go down.

Sibling queues: list the other adapters that have one.

---

&lt;Entries go here. One `##` heading each, starting `Pending — `, with what to look at and what
correct looks like.&gt;
