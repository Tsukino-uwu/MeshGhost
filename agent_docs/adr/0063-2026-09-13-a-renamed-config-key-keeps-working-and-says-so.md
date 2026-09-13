# 2026-09-13 — A renamed config key keeps working, and says so

<!-- ADR 0063. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** three client config keys were renamed — `room` → `room_name`, `name` →
  `player_name`, `name_color` → `player_name_color` — and with them two general mechanisms every
  later rename reuses:
  1. **An old spelling is aliased on the raw bytes before decode.** `cfg.RenameOldKeys`
     (`internal/cfg/alias.go`) moves the value to the current key and logs one line telling the
     player what to rename. Everything downstream — the decoder, `ApplyDespiteBadValue`,
     `WarnUnknownKeys` — sees only current names, so no second accepted-key list exists to drift.
     It touches **only the top level of the named section**: `client.replay.name` and
     `client.chaser.name` are different settings that share a word.
  2. **A shipped value may mean "not set yet".** `player_name` ships as the word `nickname`, which
     the client resolves back to empty (`namePlaceholder`, case-insensitive and trimmed), and
     `room_name` ships blank, which resolves to the room `default` (`normalizeRoom`). Both are
     resolved in `normalizeIdentity`, called from `loadClientConfig` — the one place **both**
     startup and the reload diff go through, so a blank room never reads as a change and never asks
     for a relaunch nobody earned.
- **Not a contract revision.** The wire is untouched: `protocol.Hello.Room` is still `"room"`
  (`protocol/protocol.go`), `contract.md`'s hello table is unchanged, and anybody integrating
  against the protocol sees nothing. The CLI flags are unchanged too (`-room`, `-name`,
  `-name-color`): `cfg.Override` is keyed on the flag name, adapters and dev-scripts pass flags, and
  the file key was always a separate, end-user-facing surface — which is the same reason
  `connect_to` is not called `relay`.
- **No adapter change, and no adapter-side alias.** Grepped 2026-09-13 across `adapters/**`
  (`*.cpp`, `*.hpp`, `*.cs`, `*.lua`, excluding vendored `build/_deps`): **no adapter reads `room`,
  `name` or `name_color` from `config.json`.** What the mods hand-parse is `autostart`,
  `map_markers`, `ghost_range*`, `replay.indicator*` and `input_display`. The only hits were two
  prose comments in Pseudoregalia's `Plugin.cpp`, corrected in the same pass. Recorded here so the
  next reader does not repeat the grep.
- **Why rename at all.** A tester's config, read 2026-09-13, had `"name": "Default Name 123"` and
  `"name_color": "#facade"` — placeholders they had typed to find out what the fields wanted, which
  is what a shipped blank fails to teach. `name` also sits in the same file as `replay.name` and
  `chaser.name`, and `room` reads like a mode rather than a word you agree on with friends.
- **Why the empty room mattered more than the names.** Before this, `"room": ""` was a REAL room,
  distinct from `default`: `cfg.Override` treats present-but-empty as a value that beats the flag
  default, and the relay keys rooms on the string it is handed (`relay.roomKey`). Two players whose
  files differed only in blank-versus-`default` silently never met, and nothing on either end could
  notice. That is also why the rename needed the alias rather than shipping bare: an ignored old
  `room` would have dropped an existing player into `default` — a real room, just not their
  friends' — with only an "is not a setting" line to explain it.
- **Kept indefinitely.** The alias costs three map entries and one pass over bytes already in
  memory. Dropping it later is a deliberate decision with its own dated line here, not an
  expiry — a player's config.json can be years old and still be the file they use.

## Also decided that day: the shipped hotkeys, and what a system-wide chord costs

The six shipped chords became `shift+4`, `shift+5`, `shift+2`, `shift+F2`, `shift+1`, `shift+3`
(record, save-last, replay-last, restart, rewind, fast-forward) — the set a tester had already
rebound theirs to, adopted on the user's call because the ADR 0048 defaults (`ctrl+shift+F5`…`F11`)
are a three-finger reach mid-play.

**What that costs, measured 2026-09-13 rather than assumed.** `RegisterHotKey`
(https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey) documents
the system matching the chord and posting `WM_HOTKEY` to the owning thread, and documents no
pass-through. Measured with the real client, `-offline`, the six chords bound, against a WinForms
text box driven by SendKeys:

| | what the text box received | what the client saw |
| --- | --- | --- |
| no client running | `!"#¤%` | — |
| client running, `shift+1`…`shift+5` bound | nothing | all five fired |

So a bound chord is **withheld from the focused window** while MeshGhost runs. What it is not is a
keylogger: `WM_HOTKEY` carries which of the six actions fired and nothing else, and no other
keystroke reaches the client at all. The cost runs the other way — those chords stop doing their
usual job everywhere until MeshGhost exits, which on a Nordic layout means `!`, `"`, `#`, `¤` and
`%`. Written into `docs/config.md`'s `hotkeys` row so a player meets it before a puzzle.

**One default everywhere, and a per-game override only once a game is shown to conflict** — the
user's call the same day, after a tester playing under Proton had been using this exact set with no
conflict to report. Proton is the Windows client with Wine's `user32` doing the registration, so
those chords really did bind: it is the same code path a Windows player takes, not a no-op (a
NATIVE Linux client registers nothing at all — `internal/hotkey/hotkey_other.go`).

What that report does not settle is whether a game *loses* the keys, since a game that never used
`shift+1`…`shift+4` produces no conflict to notice, and one reading the keyboard through
RawInput/DirectInput bypasses the window message queue the table above measured. That is accepted
rather than open: if a game is ever shown to conflict, the fix is that game's own
`packaging/config-overrides/<game>.json`, which already replaces a shipped key per game — not a
retreat to a three-finger default for everyone.
