# 2026-09-15 — Chaser contact is a mode: `off`, `hurt` or `kill`, and the game does the hurting

<!-- ADR 0068. Indexed in ../architecture.md, which is the decision log front door. A contract revision: session_policy.chaser_contact carries "hurt" or "kill" instead of "enabled"; chaser.contact in config.json is a string, with the old bool still read. -->

- **Decision:** `chaser.contact` is one of three words. `"off"` (the shipped default) is the
  cosmetic ghost every other rule describes. `"hurt"` means touching a chaser does **exactly what
  an enemy's touch does in that game** — the same reaction, the same health cost, the same
  invulnerability window, nothing more. `"kill"` is a guaranteed death, through the game's own
  death path. `session_policy.chaser_contact` carries that word — `"hurt"` or `"kill"` — and is
  absent when the mode is off or the chaser is disabled. A `config.json` written while the key
  was a bool (2026-09-03 to 2026-09-15) still reads: `true` is `"hurt"`, the one effect it ever
  promised, and `false` is `"off"`. Any other value is refused: the flag exits at launch with the
  three words, and a saved file keeps its previous value and says so in the log.
- **Status:** Go side built and tested 2026-09-15 (`core/chaser_test.go`
  `TestChaserPolicyIsPushedOnlyWhenContactIsOn` and `TestParseChaserContactReadsTheLegacyBool`,
  `cmd/meshghost/reload_test.go`, `internal/e2e/chaser_e2e_test.go` through the real binary). **No
  adapter honours it yet.** Pseudoregalia is the first candidate and its side is measurement,
  not code, until the user has seen each step on screen: `agent_docs/chaser-planning.md`.

## Why a mode and not a bool

ADR 0047 reserved the hook as a bool because the only thing settled then was that a chaser MAY
have one effect. What the effect IS was left to the per-game ADR. Designing that with the user
on 2026-09-15 produced two effects, not one: a touch that costs what an enemy's touch costs, and a
touch that ends the run. Both are legitimate game modes — the first is Celeste's Badeline chase,
the second is a deathless-run challenge — and a player chooses one, never both. A bool cannot say
which, so the bool became the word, and the bridge carries the word rather than a second flag,
for the reason `ghost_collision` is a word: the adapter reads one field and never has to combine
two.

## What the core knows, and what it does not

The core knows three strings and that two of them are "on". It does not know what a hurt IS,
what a death IS, how long an invulnerability window lasts, or when a touch has happened — every
one of those is a fact about a game, and the core never becomes game-aware (root `CLAUDE.md`).
The overlap test, the grace after a chaser spawns, the skip during the player's own invulnerability
or death, and the damage itself are all the adapter's, under its per-game ADR.

**The grace window is adapter-side and needs no wire change.** A chaser that reappears at the
player after a seam (`core/chaser.go`: a live gap despawns the pack and it comes back where the
player is) arrives as a `despawn_remote` and a fresh `render_remote`, which the adapter already
sees; a player who respawns after a death is a fact the adapter already has. So the window
starts from what the adapter observes, and its length is measured in the game, never fixed here.

## How this sits with "nothing that ships writes game state"

Root `CLAUDE.md` says nothing that ships writes a save, game state or a ROM patch. The user's
call on 2026-09-15 was to leave that rule as it is: contact does not write state. The adapter
triggers the game's own damage or death path — the same call the game makes when an enemy's
hitbox meets the player — and the game does what it does with it. Writing a health value would
be a state write and is not what either mode means; "exactly what an enemy's touch does" is a
requirement on the mechanism, not just the picture. The user noted the rule may be reworded
later if something else ever needs the same carve-out; nothing does today.

## What did not change

- A chaser is still cosmetic: never solid, blocking, damageable or targetable, whatever the mode.
  `render_remote.cosmetic` is unchanged and still outranks `ghost_collision`.
- Replay ghosts and real peers never hurt anyone. The mode applies to `chaser:<n>` ids only.
- `player_frozen` (ADR 0053) still gates it: a chaser holds while the player cannot move, and an
  adapter skips the contact test while the flag is set. The frozen signal existing BEFORE contact
  is turned on was the fixed order in `adapters/pseudoregalia/UNVERIFIED.md` from 2026-09-04; the
  Pseudoregalia mod has sent it since 2026-09-05, for the pause menu and the item-pickup popup.
- `internal/gameblind`'s frozen field list is unchanged: the field names did not move, only the
  words they carry.

## Files

`core/chaser.go` (the type and parser), `core/core.go`, `core/settings.go`, `core/bridgeserve.go`,
`bridge/bridge.go`, `cmd/meshghost/main.go` (`-chaser-contact`, the bool-or-string reader),
`cmd/meshghost/reload.go`, the five shipped `config.json` files (`"contact": "off"`),
`packaging/release/docs/config.txt`, `agent_docs/contract.md`, `adapters/_template/PROTOCOL.md`
and `README.md`.
