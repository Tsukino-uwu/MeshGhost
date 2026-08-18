# TEVI — flag register

TEVI is the smallest of the shipped adapters, and its switch list is small to match: one
diagnostic bool, a handful of constants, and one setting a player can actually change. It gets a
register anyway, for the reason `adapters/_template/FLAGS.md` gives — an absent register says
nothing at all, where a short one says "audited, this is everything".

**Everything here lives in `MeshGhostTevi/Plugin.cs`** unless a row says otherwise. There is no
`#if` in this adapter and no build-configuration switch: a `const bool` is the only compile-time
kind, and there is exactly one of them.

It is not a description of how the game works — that is `documentation.md` — and not a list of
compensations, which is `BANDAGES.md`. A switch can appear in both this file and `BANDAGES.md`;
this one says what it is, that one says what it costs.

**Keep it in step with the code.** Add a switch, add its row. Change a value, fix its row in the
same edit.

## The kinds

| Kind | Shipped value | What it means |
|---|---|---|
| **Behaviour** | live | Real shipped behaviour. Changing it changes what a player sees. |
| **Probe** | `false` | A diagnostic. Off in every build a user runs. |
| **Runtime** | a default | Settable by the player or the tester without a rebuild. |

There are no Dormant entries — no retired approach in this adapter was kept behind a switch.

## Behaviour

Nothing here is a `bool`; they are all constants that decide behaviour, which is exactly the class
`_template/FLAGS.md` warns gets missed because it looks like arithmetic rather than like a switch.

| Constant | Value | Provenance |
|---|---|---|
| the loopback render offset | `160f` | **Tuned by eye, and it says so** — an inline literal in `UpsertRemoteGhost`, not a named constant. A ghost whose `playerId` ends `-ghost` is drawn this far along X so a loopback ghost can be judged beside the real character. Render-only: it never touches what goes on the wire. The value went `2f` (live-tested, far too small — the ghost rendered basically inside the player) → `80f` (screenshot-confirmed, still close) → `160f`, doubled without a fresh live check on the user's explicit call, since a linear doubling of an already-watched offset on the same render path is not a new guess. Registered in `BANDAGES.md` under Deliberate. |
| `MaxRoomCoordinate` | `100000` | **Not a measured game constant** — its own comment says so; TEVI's real room grid is far smaller. It is a sanity bound on peer-supplied `room_x`/`room_y` so a bogus or adversarial value cannot reach `GetRoomWalkedBool`, whose internals are unknown. `BANDAGES.md` carries it, because a bound nobody measured is exactly the shape worth re-visiting. |
| `RemoteMapMarkerColor` | cyan (`0,1,1,1`) | A deliberate cosmetic choice so a peer's map marker is distinguishable from the local player's own. |
| `GameId` | `"tevi"` | Sent as the bridge `Hello` so the core can reach the relay without the user typing a game name into `config.json`. Opaque to the core; it must match the folder name under `games/tevi/` in the shipped release. |
| `PluginGuid` / `PluginName` / `PluginVersion` | `dev.meshghost.tevi` / `MeshGhost` / `0.2.0` | BepInEx plugin identity. `PluginGuid` is also the name of the config file a tester edits (`BepInEx/config/dev.meshghost.tevi.cfg`). |

## Probes — off, and they must stay off

The convention here is a `DIAG_` prefix, matching Emerald's `DIAG_STEP_CURVE` /
`DIAG_SCREENPOS_PARTS` and Pseudoregalia's `_TRACE` family.

| Flag | Value | What it was for |
|---|---|---|
| `DIAG_REDRAW_TRACE` | `false` | Per-remote redraw trace in `UpsertRemoteGhost`: position, `activeInHierarchy`, scene, local and remote area. Added to chase the 2026-08-14 zone-transition ghost-invisibility bug, which is root-caused and fixed. **It fires every 2 s per remote, forever** — turn it on only while chasing a live repro of that shape. |

Its throttle constants are live even when the flag is off, because the same log path is shared
with the adapter's own state logging:

| Constant | Value | Why that value |
|---|---|---|
| `MaxSilenceSeconds` | `5f` | Log at least this often while state is continuously changing, so a quiet log is not mistaken for a stalled adapter. |
| `MinLogIntervalSeconds` | `0.5f` | The cap that made this affordable. |
| `PositionChangeEpsilon` | `0.5f` | **A measured failure worth keeping.** The first version logged on any position change past this epsilon and produced **7324 lines in one session** — because TEVI's real per-frame movement deltas are themselves ~0.5-0.7 units, so the epsilon sat exactly on the noise floor. The fix was not a bigger epsilon but a fixed cadence for continuous change plus an immediate log on discrete events (direction flip, anim change, area change), which are genuinely rare. |
| the redraw-trace interval | `2f` | An inline literal in the `DIAG_REDRAW_TRACE` condition, not a named constant. Seconds between per-remote redraw lines. |

**A diagnostic can break the thing it measures**, and this adapter has the cheap version of that
lesson (a log flood) where Pseudoregalia has the expensive one (a probe that truncated the effect
it was counting, 2026-08-16). Audit a probe's cost before trusting its output, and re-run with it
off before believing a result.

## Runtime switches — what a tester or player can change without a rebuild

| Switch | How it is set | Default | What it does |
|---|---|---|---|
| `MESHGHOST_NO_AUTOSTART` | environment (any value) | unset — the adapter starts a core itself | Turns autostart OFF, so the adapter uses only a core that is already running and never spawns one. **Supported configuration, not a debug switch**: an antivirus objecting to one program launching another is a real thing that happens to real players, and this is the documented answer — set it and run `meshghost.exe` by hand. Every adapter honours the same name. |
| `BridgePort` | BepInEx config, `[Network]` section of `BepInEx/config/dev.meshghost.tevi.cfg` | `7778` (`DefaultBridgePort`) | Which local core process this instance talks to. **This exists for two-instance local testing**: two TEVI copies on one machine each need their own core on its own port, because a core serves exactly one adapter. A single-instance install should never need to touch it. |
| `BridgeHost` | not settable — `const`, `127.0.0.1` | — | Deliberately fixed. An adapter may hold a socket to its own local core and nothing else; a configurable host would be the first step toward an adapter that talks to a relay, which the contract forbids. |
| `ReconnectInterval` | not settable — `BridgeClient.cs`, `2` seconds | — | How often a disconnected bridge retries. |

**No environment variables and no flag files.** Unlike the two Lua adapters, everything a tester
changes here goes through BepInEx's own config, which means it is visible in a file the player
already knows about rather than in an exported shell variable nobody can see afterwards.

## When a comment and a value disagree

Believe the value, then find out why the comment drifted before changing either. `CLAUDE.md`
states the harder version: **a flag flip is not a revert** — a switch only reverts behaviour if it
gates the *work*, not merely the decision the work feeds.
