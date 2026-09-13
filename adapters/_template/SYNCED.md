# What `<game>` sends

## Before adding anything to this file

**KEEP THIS SECTION when you copy this file.** It is repeated at the top of every adapter's
`SYNCED.md` so the rules are in front of whoever is about to edit a row.

- **This page is for players and developers alike.** It says what this game shares with other
  players, what their game does with it, and how each value is checked when it arrives. No history,
  no investigation notes, no "found on" dates — those go to `VERIFIED.md`, `UNVERIFIED.md` or the
  phase file.
- **Every row is read off the code, not off a record.** Check the send code and the receive code
  before writing or changing a row. A row names the game's own field and OUR function, never a line
  number.
- **Every key has a *Checked on arrival* cell, and it is never empty.** A value from another player
  can be anything, so a key with no check today says exactly `not checked yet`. That makes this file
  the checklist: `dev-scripts/preflight.ps1` fails when the code sends a key this page does not list
  (or the other way round), and it refuses a rising count of `not checked yet`.

---

<!-- Template only: everything from here to "The page" is for whoever copies this file. Delete it in the copy. -->

## How to fill this in

Copy this file next to the adapter's `README.md` when the adapter first sends a state, and add a row
the moment a key is added to the send code — preflight will not let the two disagree.

**Write for someone who has never read the code.** "The other player's game" rather than
"receiver"; "server" rather than "relay"; "whole number", "number", "text", "list" rather than
language types. Game field names stay as the game spells them, in backticks.

**Group keys by what a person SEES**, not by where they are read from: Movement & pose, Looks,
Effects & trails, Combat & health, Objects in the world — whichever of those this game has, in
that order, plus any the game needs. Each group is a short summary table and a fold-out details
block with the same keys in the same order.

**The *Sent* column uses these words only:**

| Word | Means |
| --- | --- |
| `always` | In every update. |
| `while <state>` | Only while the named thing is happening; absent otherwise. |
| `counter` | A running total that only goes up. The other game acts when it rises, so a lost update never loses the event. |
| `for a moment after <event>` | A short window after something happens, then gone. |

**A key whose value holds rows, cells or a list of words** gets a layout sub-table inside its
details block: one row per cell or word, each with its own *Checked on arrival*.

**Leave out a section that does not apply** (a game with one build has no "Different builds").

<!-- End of template-only part. -->

## The page

- **How often:** your game hands the MeshGhost client an update every frame; the server sets how
  often it goes out to other players (15 a second unless the room chooses otherwise).
- **What is in an update:** four basics every game fills, plus this game's own extras, listed
  below by what they change on the other player's screen.
- **Details** under each table say what a value is, where it is read from, and how the other
  player's game checks it before using it.

## Saying hello

What the game tells the MeshGhost client when it connects.

| Field | Value | What it does |
| --- | --- | --- |
| `game_id` | `"<game>"` | Only players running the same game see each other. |
| `game_version` | the adapter's version | A room can refuse a client whose version differs. |
| `min_protocol_version` | `2` | The oldest client this adapter can talk to. |

## The basics

| Field | What this game puts in it | Example |
| --- | --- | --- |
| `area_id` | `<which room/map you are in>` | `"<example>"` |
| `position` | `<where you stand>` | `[0, 0]` |
| `orientation` | `<which way you face>` | `"<example>"` |
| `anim` | `<what you are doing>` | `"idle"` |

<details><summary>Details</summary>

| Field | Type | Read from | Checked on arrival |
| --- | --- | --- | --- |
| `area_id` | text | `<game field>` (`<our function>`) | `<check>` |
| `position` | list of numbers | `<game field>` (`<our function>`) | the MeshGhost client drops a non-number or out-of-range position before it arrives |
| `orientation` | `<type>` | `<game field>` (`<our function>`) | `<check>` |
| `anim` | text | `<game field>` (`<our function>`) | `<check>` |

</details>

## `<Group, e.g. Movement & pose>`

| Key | On the other screen | Sent |
| --- | --- | --- |
| `<key>` | `<what the other player sees>` | always |

<details><summary>Details</summary>

| Key | Type | Read from | Checked on arrival |
| --- | --- | --- | --- |
| `<key>` | whole number | `<game field>` (`<our function>`) | kept to 0–255 |

</details>

## Other messages

Messages besides the regular update: what this game sends, and what it does with the ones the
MeshGhost client sends it. A message the game ignores is listed with "ignored".

| Message | Direction | What happens | Checked on arrival |
| --- | --- | --- | --- |
| `despawn_remote` | to the game | The other player's ghost is removed. | `<check>` |

## When nothing is sent

`<What the other player sees while you are on the main menu, in a loading screen, or anywhere the
game has no player to read.>`

## Different builds of the same game

`<Only if this game has more than one build that can play together: what changes in an update
between them, and what the other player's game does about it.>`

## Taken from your own game, not sent

`<Optional: values the ghost gets from YOUR copy of the game because they are the same on every
machine.>`
