# `config.json` — every key, what it does, and who reads it

One file ships in the release zip and both programs read their own half of it: `meshghost.exe` (the
client, started for you by your game's mod) reads the `client` section, and `meshghost-server.exe`
(run by whoever hosts) reads the `server` section. A key that is absent keeps its built-in default,
so a config file only ever overrides what it mentions. The shipped file is
[`packaging/release/config.json`](../packaging/release/config.json) and the walkthrough is the
`README.txt` beside it; this page is the reference those two point at.

Everything below is taken from the two programs' own config definitions (`cmd/meshghost/main.go`,
`cmd/meshghost-relay/main.go`) and the shipped file, on 2026-09-02.

## `client` — read by `meshghost.exe`

| Key | Shipped value | What it does |
|---|---|---|
| `connect_to` | `127.0.0.1:7777` | The host's address and **tcp** port. Only the tcp port is ever needed: the handshake is tcp and asks the server what else it serves. |
| `transport` | `auto` | What the session moves to *after* connecting: `tcp` stays, `udp` or `quic` upgrade if the server offers them, `auto` takes the best on offer. Asking for one the server lacks degrades to tcp, never to a timeout. |
| `tls` | `auto` | Encryption of the tcp legs, including the handshake that carries the room code: `off`, `auto` (plaintext fallback with a log warning) or `required` (refuse an unencrypted server). |
| `tls_fingerprint` | empty | Optional pin of the server's certificate: the SHA-256 the server prints at startup, given to you by the host. Empty means encrypted but not authenticated. The server regenerates its certificate on every restart, so a pin has to be re-copied. |
| `room` | `default` | A label, not a password: everyone who wants to see each other uses the same one. |
| `room_code` | empty | The optional actual secret. If the host set one, you need it. |
| `name` | empty | Your nametag, drawn above your ghost for other players. Empty means no tag at all. Sanitized (control and direction-override characters removed) and capped at 24 characters; not an identity, two players may share one. |
| `name_color` | `#A89975` | Hex colour for the box behind your nametag, ignored without a `name`. Blank means no box; a value that is not a hex colour is ignored and never stops you connecting. |
| `ghost_collision` | `enabled` | Your own preference, and it only works in the restrictive direction: `disabled` turns ghost collision off for you whatever the host chose; `enabled` accepts the host's setting. (As of 2026-09-02 no shipped adapter honours it yet: `agent_docs/plans.md`, "Settings: defined once".) |
| `local_game_bridge` | `127.0.0.1:7778` | Where your game's mod talks to this client. Never leaves the machine. Mods walk a small range upward from here so two games on one PC do not collide. |
| `interp` | `450ms` | How far behind real time OTHER PLAYERS' ghosts are drawn, which is what makes their motion smooth. Never set it below your connection's jitter; each game's mod may ship its own value. |
| `local_interp` | `25ms` | The same idea for a ghost your own client invented -- a replay or a chaser -- and a different number for a different job: nothing about it crossed a network, so it is drawn a sample interval or two behind its own schedule rather than `interp` behind. Raise it and a chaser set to 3s falls further back than 3s; zero makes it stutter instead of gliding. |
| `max_receive_hz_per_player` | `0` | The most updates per second you want from each *other* player. `0` means whatever the server sends. Per player, not a total. |
| `replay` | `{"record_on_launch": false, "save_last": "30s", "start_delay": "0s", "seek": "5s"}` | Recording and playback (2026-09-03). `record_on_launch` writes every session to the `replay` folder beside this file, from your first in-game moment to quitting; `save_last` is how much recent play the save-last key writes out after the fact; `start_delay` is how long after you are in the game a replay ghost starts (a file's own `start_delay` overrides it); `seek` is one rewind or fast-forward press; `split_times` (off) puts how far behind or ahead of the ghost you are on its nametag, e.g. `PB +1.2s`. Drop a file into `replay/active/` and it plays as a cosmetic ghost; nothing here names a file. |
| `chaser` | `{"enabled": false, "count": 1, "delay": "3s", "spacing": "2s", "name": "Chaser", "color": "#7A2A2A", "contact": false, "spawn_delay": "0s"}` | Your own past following you: `count` ghosts, the first `delay` behind and each next one `spacing` further back. A chaser appears only once you have been moving for `spawn_delay` (`0s` = its own delay), so none spawns on top of you at the start. Always cosmetic, whatever `ghost_collision` says. `contact` tells a game's mod a chaser may hurt on touch; no shipped mod honours it yet. |
| `hotkeys` | `{"record_toggle": "ctrl+shift+F9", "save_last": "ctrl+shift+F10", "replay_last": "ctrl+shift+F11", "replay_restart": "ctrl+shift+F5", "replay_rewind": "ctrl+shift+F6", "replay_fast_forward": "ctrl+shift+F7"}` | System-wide keys the client registers itself, so they work with the game focused. `ctrl`, `shift`, `alt` plus one key (F1–F24 except F12, letters, digits, space, home, end, page up/down, insert, delete); an empty value unbinds. Windows only; a chord another program already owns is skipped and the log says so. |

Also accepted in the `client` section, not in the shipped file: `game` (normally announced by the mod, not set by you), `game_version`, `min_send`, `keepalive` (how often an unchanged state is re-sent; `0` sends every frame), `extrapolate` (a prediction window; absent holds the newest sample), `curve` (`linear` or `catmull-rom`), `predict` (`linear` or `accelerated`), `stats` (log a one-line summary every so often, e.g. `10s`), `features` (capabilities beyond the cosmetic ghost; every member of a room must list the same set), and `show_console` (open a window for a client an adapter started silently).

## `server` — read by `meshghost-server.exe`

| Key | Shipped value | What it does |
|---|---|---|
| `listen_on` | `0.0.0.0:7777` | The tcp address and port to serve. This is the port to forward, both tcp and udp. |
| `listen_quic` | empty | Where quic listens. Empty reuses `listen_on`'s port number, so hosting means forwarding one number. |
| `listen_udp` | empty | Where the plain `udp` transport listens. Empty reuses `listen_on`'s port unless quic is served too, in which case udp moves aside so quic keeps the shared number. |
| `transport` | `tcp,quic` | Which transports to serve at once, any of `tcp`, `udp`, `quic`. Clients on different transports share a room. |
| `tls` | `auto` | Encryption for tcp: `off`, `auto` (TLS and plaintext on the same port) or `required` (refuse plaintext). quic is always encrypted; plain udp never is. |
| `room_code` | empty | If set, every client must present it. |
| `only_game` | empty | Restrict the server to one game id (`emerald`, `crystal`, `tevi`, `pseudoregalia`). Empty hosts any game. |
| `ghost_collision` | `enabled` | The room-wide policy the server advertises: `enabled` or `disabled`. Advisory; a client may still turn its own off. |
| `max_clients` | `8` | Seats across all rooms. Connections that have not yet said hello are bounded separately, so a flood cannot use up the seats. |
| `send_hz` | `15` | How many times a second the server forwards each player's state to the room. |

Also accepted in the `server` section: `resume_grace_seconds` (how long a dropped client's identity is held for a reconnect before the room is told it left; only used by rooms that negotiated session resumption; default 20).

## Where to read more

- The player walkthrough, with troubleshooting: `packaging/release/README.txt` in the zip.
- How the transports and the limits actually work, traced through the code: [networking.md](networking.md).
- What is encrypted, what is authenticated, and what is not: [security.md](security.md).
