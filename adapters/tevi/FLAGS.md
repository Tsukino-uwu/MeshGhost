# TEVI — flag register

<!-- line-cap: none -- register; size is the number of switches that exist. Why: agent_docs/claude-md-cap.md. -->

TEVI is the smallest of the shipped adapters, and its switch list is small to match: six
diagnostic bools, a handful of constants, and one setting a player can actually change. It gets a
register anyway, for the reason `adapters/_template/FLAGS.md` gives — an absent register says
nothing at all, where a short one says "audited, this is everything".

**Everything here lives in `MeshGhostTevi/Plugin.cs`** unless a row says otherwise. There is no
`#if` in this adapter and no build-configuration switch: a `const bool` is the only compile-time
kind, and all six of them are `DIAG_` probes.

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
| `MarkerStaleSeconds` | `1f` | How old a peer's FullMap marker may get before the frame-driven refresh hides it (added 2026-08-28, replacing the frozen-marker defect). Sized against the send rate: several updates fit inside it. |
| `AnimPhaseTolerance` / `AnimReseekThreshold` / `PhaseCatchupGain` / `PhaseCatchupRange` / `FreezePhaseTimeout` | `0.06f` / `0.25f` / `2f` / `0.25f` / `0.25f` | The mirrored-animation phase corrector (2026-08-28): how far ghost and peer clip phase may drift before speeding up/re-seeking, and how long a hitstop freeze waits for a phase match before landing by timeout. Tuned against `DIAG_HITSTOP_PHASE` measurements. |
| `TrailSpawnRate` / `TrailDecaySpeed` / `TrailSortingOrder` | `0.07f` / `1.5f` / `99` | The ghost's dash-trail parameters, mirrored from the game's own `SpriteAnimation` fields (`trailRate` / `trailDecay` / `trailOrder` — measured, the comments cite the source fields). |
| `MirroredEffectOwnershipRange` | `200f` | How close a pooled effect must appear to a character to be attributed to it when mirroring VFX. |
| `WeaponStrobeHold` | `0.07f` | How long the mirrored weapon strobe holds a colour — sized against the measured 2-of-5-frames cadence. |
| `WarpScanInterval` | `0.5f` | How often warp devices are re-scanned for ghost visibility. |
| `MaxAnimNameLength` / `MaxRejectedAnimNamesPerPeer` | `96` / `4` | Bounds on peer-supplied animation names: longer names are refused, and refusals are logged at most this many times per peer. |

## Probes — off, and they must stay off

The convention here is a `DIAG_` prefix, matching Emerald's `DIAG_STEP_CURVE` /
`DIAG_SCREENPOS_PARTS` and Pseudoregalia's `_TRACE` family.

| Flag | Value | What it was for |
|---|---|---|
| `DIAG_REDRAW_TRACE` | `false` | Per-remote redraw trace in `UpsertRemoteGhost`: position, `activeInHierarchy`, scene, local and remote area. Added to chase the 2026-08-14 zone-transition ghost-invisibility bug, which is root-caused and fixed. **It fires every 2 s per remote, forever** — turn it on only while chasing a live repro of that shape. |
| `DIAG_MARKER_STALENESS` | `false` | How old the position each FullMap peer marker is showing actually is — written against the old update-driven marker (frozen when a peer stopped sending); since the 2026-08-28 frame-driven refresh + 1s stale-hide, it measures whether that fix holds the drawn age under 1s. The AGE is the part no amount of reading the code gives you. One line per marker per second, **only while the map is open**. **Never run.** |
| `DIAG_MENU_GATE` | `false` | What the adapter can see at each play-session transition, and therefore what really distinguishes the pause overlay from the main menu. One line per transition. Written to settle `documentation.md`'s `PlayerControl.instance` claim by measurement rather than by reasoning from code, which is what produced the 2026-08-18 false regression. **Never run.** |
| `DIAG_SPAWN_DIFF` | `false` | What a move actually **spawns** — every GameObject appearing or disappearing near the player and each peer ghost, by instance id. Written for the charged-attack gap. Reports its own scan time; first version measured itself at 19ms/frame and was rebuilt to walk only the anchors' subtrees (0.22ms). **Run 2026-08-28.** |
| `DIAG_POOL_WATCH` | `false` | Which POOLED effect the game just spawned, by prefab name — the widening for effects that never parent to the character. Walks the two `ObjectPooler`s (~375 objects) per sample, measured `avgMs=0.09`. **Run 2026-08-28.** |
| `DIAG_HITSTOP_PHASE` | `false` | Timing and colour of a mirrored attack: freeze phase on ghost vs peer, VFX impulses sent/received, sprite-layer colours. One line per EVENT, never per frame. **Run 2026-08-28.** |

**A `const bool` on its own makes its block provably unreachable and the C# compiler says so
(CS0162), so the older flags sit in compound conditions** — `DIAG_REDRAW_TRACE && <throttle>`,
`DIAG_MARKER_STALENESS && remoteMapMarkers.Count > 0`. Not a style choice: a build that emits
warnings trains people to ignore warnings, and this project's builds are 0-warning. **The three
2026-08-28 probes are used bare** (`if (DIAG_SPAWN_DIFF)` etc., throttle inside the block) —
whether they re-introduce CS0162 has not been re-checked against a build log; if they do, the
compound-condition rule above is the fix (noted 2026-09-01).

**Index of what each probe answers, and how to run one:** [PROBES.md](PROBES.md).

Its throttle constants are live even when the flag is off, because the same log path is shared
with the adapter's own state logging:

| Constant | Value | Why that value |
|---|---|---|
| `MaxSilenceSeconds` | `5f` | Log at least this often while state is continuously changing, so a quiet log is not mistaken for a stalled adapter. |
| `MinLogIntervalSeconds` | `0.5f` | The cap that made this affordable. |
| `PositionChangeEpsilon` | `0.5f` | **A measured failure worth keeping.** The first version logged on any position change past this epsilon and produced **7324 lines in one session** — because TEVI's real per-frame movement deltas are themselves ~0.5-0.7 units, so the epsilon sat exactly on the noise floor. The fix was not a bigger epsilon but a fixed cadence for continuous change plus an immediate log on discrete events (direction flip, anim change, area change), which are genuinely rare. |
| the redraw-trace interval | `2f` | An inline literal in the `DIAG_REDRAW_TRACE` condition, not a named constant. Seconds between per-remote redraw lines. |
| `MarkerStalenessLogInterval` | `1f` | Seconds between per-marker age lines while `DIAG_MARKER_STALENESS` is on. |
| `SpawnDiffSampleInterval` / `SpawnDiffRadius` | `0.05f` / `400f` | Spawn-diff scan cadence (20Hz) and how far from an anchor an object counts. Raise the interval if the probe's self-reported scan time is bad. |
| `SpawnDiffAppearBudget` / `SpawnDiffDisappearBudget` / `SpawnDiffCoverageInterval` | `500` / `250` / `5f` | Per-scan line budgets so a scene load cannot flood the log, and how often the probe reports its own coverage/cost. |
| `PoolWatchInterval` / `PoolWatchBudget` | `0.05f` / `400` | Pool-watch cadence and per-sample line budget; the walk itself measured `avgMs=0.09`. |

**A diagnostic can break the thing it measures**, and this adapter has the cheap version of that
lesson (a log flood) where Pseudoregalia has the expensive one (a probe that truncated the effect
it was counting, 2026-08-16). Audit a probe's cost before trusting its output, and re-run with it
off before believing a result.

## Runtime switches — what a tester or player can change without a rebuild

| Switch | How it is set | Default | What it does |
|---|---|---|---|
| `MESHGHOST_NO_AUTOSTART` | environment (any value) | unset — the adapter starts a core itself | Turns autostart OFF, so the adapter uses only a core that is already running and never spawns one. **Supported configuration, not a debug switch**: an antivirus objecting to one program launching another is a real thing that happens to real players, and this is the documented answer — set it and run `meshghost.exe` by hand. Every adapter honours the same name. |
| `BridgePort` | BepInEx config, `[Network]` section of `BepInEx/config/dev.meshghost.tevi.cfg` | `7778` (`DefaultBridgePort`) | Which local core port this instance STARTS from. Since 2026-08-27 the adapter walks `BridgePortCount = 8` ports from here (`BridgeClient.cs`), so a second instance finds its own core without anyone touching this — the setting is now the pin-the-base override, not the two-instance mechanism (`BANDAGES.md`). |
| `MESHGHOST_BRIDGE_PORT` | environment | unset | Overrides the bridge BASE port and **wins over the BepInEx setting** (`CoreLauncher.cs` — same variable name the two Lua adapters use, so one launcher script can aim every game). |
| `MESHGHOST_CORE_DIR` | environment | unset | Prepends a directory to the core-executable search, for running against a dev-built `meshghost.exe`. |
| `BridgeHost` | not settable — `const`, `127.0.0.1` | — | Deliberately fixed. An adapter may hold a socket to its own local core and nothing else; a configurable host would be the first step toward an adapter that talks to a relay, which the contract forbids. |
| `ReconnectInterval` | not settable — `BridgeClient.cs`, `2` seconds | — | How often a disconnected bridge retries. |

**No flag files, and only the three environment variables above** (`MESHGHOST_NO_AUTOSTART`,
`MESHGHOST_BRIDGE_PORT`, `MESHGHOST_CORE_DIR` — the names shared across adapters). Everything
else a tester changes goes through BepInEx's own config, which is visible in a file the player
already knows about rather than in an exported shell variable nobody can see afterwards. (This
paragraph said "no environment variables" until 2026-09-01, while the adapter read three — the
exact drift the register exists to catch.)

## When a comment and a value disagree

Believe the value, then find out why the comment drifted before changing either.
And the harder version: **a flag flip is not a revert** — verify the switch disables the
*work*, not merely the decision the work feeds, or revert the commit instead.
[`agent_docs/pitfalls.md`](../../agent_docs/pitfalls.md#diagnostic-methodology) has the case that established it.
