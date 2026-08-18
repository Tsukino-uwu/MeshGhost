# Project history: how MeshGhost actually got built

A retrospective, written from memory rather than derived from logs or commits. It exists
because it's fun to look back on and because it's a useful reference for scoping the next
game adapter — not as a source of truth for exact dates or facts (see `verified.md` and the
`phases/` files for that). Per-adapter build stories live in each game's own `README.md`
(`adapters/bizhawk/pokemon/emerald/README.md`, `adapters/bizhawk/pokemon/crystal/README.md`,
`adapters/tevi/README.md`, `adapters/pseudoregalia/README.md`) — this file covers only the part before any adapter
existed.

## Pre-planning / concept (~3-5 hours)

Before any code existed, this much time went into figuring out "how could this work at all":
what pieces were needed (relay, client, adapters), how they should be split up, and what
language/stack to build each in. Go was picked for the client/server specifically for
cross-platform support (Windows/Linux/Mac) without per-platform builds.

This estimate covers only the initial concept/shape work. It does not include the ongoing
refactors and changes made to things like the release packaging along the way while building
the actual adapters — those are scattered across the `phases/` files and commit history
instead.

See `brief.md` for what that planning concluded (the vision and rationale it produced), and
`contract.md` for the interface it eventually settled into.
