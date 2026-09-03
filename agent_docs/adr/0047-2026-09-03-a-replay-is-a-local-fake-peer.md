# 2026-09-03 — A replay is a local fake peer: recording, playback, the chaser and split times

<!-- ADR 0047. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** the core gains recording and playback of its own state stream, and both are built
  on the one property the project already has — nothing downstream of `storeRemoteState` can tell
  where a sample came from. A **recording** is the adapter's own `protocol.State` samples, taken
  before rate limiting, written one JSON object per line to a file whose first line is a header.
  **Playback** is a *local fake peer*: the file is read, the player id rewritten to `replay:<file>`,
  the timestamps rebased into the local clock, and each sample handed to `storeRemoteState` at its
  due time. Every renderer, adapter and knob then works unchanged, and no adapter needs a line of
  new code. The **chaser** is the same engine fed from a ring buffer of the live stream instead of a
  file, running `delay + i*spacing` behind the player for chaser `i` of `count`. **Split times** are
  computed in the core from the two position streams and published through the existing nametag
  message. The user's design, 2026-09-03; the seed is `ideas.md`, "Ghost RECORDING".
- **Status (2026-09-03):** built through Stage 7 — the local fake peer seam and `render_remote.cosmetic`,
  the recorder, playback from `replay/active/`, seeks and `replay_control`, hotkeys (ADR 0048),
  save-last, the chaser pack — each its own commit, whole suite and race detector green at each
  (`phases/phase11.md`). Split times and the config/packaging/docs sweep remain. Go side confirmed
  by the suite and by the real binaries offline; anything on screen in a game waits for the user.
- **The file** (`replay/rec-YYYYMMDD-HHMMSS.ndjson`, `.gz` accepted on read): header, then samples.
  Player-editable header keys: `name`, `color`, `speed` (dot decimal, `1.0`), `loop`, `anchor`
  (`launch` | `start` | `area`), `anchor_radius`, `trim_start` (`0s`, or `auto` = first movement),
  `trim_end`, `skip_gaps` (`0s` = keep every pause). Recorder-written: `game`, `game_version`,
  `protocol_version`, `recorded`. Sequence numbers are kept as recorded. Identical consecutive
  samples are written at most once per keepalive; playback cannot tell the difference.
- **What a recording IS (the user's line):** 1:1 with the GAMEPLAY, from the moment the player is in
  the world to the moment they quit. The first state line is the first non-`nil` sample the adapter
  sends — the main menu is never in it, because the adapter already sends nothing there. After that
  **nothing is trimmed by default**: a watched intro cutscene replays as a standstill of the same
  length, a skipped one means the ghost moves earlier, and a pause replays as a pause. Zone changes
  ride on `area_id`, which is in every sample, so a full run is one continuous file and the ghost
  renders only while the viewer shares its area — exactly as a peer would.
- **Folders (the user's rule):** everything recorded lands in `replay/` beside the client's
  `config.json`; `replay/active/` IS the list of what plays — every file in it starts on launch.
  **No config key ever names a file.** The replay-last hotkey plays the newest library file on
  demand without moving it.
- **Playback never pauses.** It runs on `c.nowMs()`, the same clock a real peer's samples are judged
  against. Restart, rewind, fast-forward, the loop seam, an `anchor` restart and any recorded gap
  above 1.5s are a fake-peer **leave + rejoin**: the ghost despawns and reappears, because the
  interpolation buffer would otherwise glide across the seam (`core/interp.go`, `lerp`).
- **Cosmetic, always.** Every `render_remote` for a local peer carries `cosmetic: true`, per frame so
  a late-attaching adapter cannot miss it, and omitted for real peers. **A cosmetic ghost is never
  solid, blocking, damageable or targetable, whatever `ghost_collision` says in the room policy OR
  the client config** (the user, 2026-09-03: "purely cosmetic no matter what"). The only effect a
  chaser may ever have is a separately gated contact hook, `session_policy.chaser_contact`, which
  is an overlap and not solidity, needs a per-game ADR and the user's on-screen confirmation, and is
  not built by this decision.
- **Never on the wire.** The only send path is `forwardLocalState -> sendState`, which reads the
  adapter's own state and never `c.remotes`; the own-player guard in `storeRemoteState` is
  untouched; a relay-issued id never has the `replay:`/`chaser:` shape. Pinned by a test that runs
  a fake peer against a recording transport and asserts nothing left the machine.
- **Safety — a shared file can do what a stranger in a public room can do, and nothing more.**
  The 2026-08-27 audit (`security-design.md`, "The ACE audit") traced every peer field to its sink
  on the recipient's machine and found no code execution, no memory corruption, no file path, no
  unbounded loop or map. A replay inherits that result *structurally*: **there is ONE entry point
  for remote state, and the loader is forbidden a second one** — a test in `internal/gameblind`
  fails the build if another caller of `storeRemoteState` appears. On top: line size capped at the
  wire maximum, the header sanitized by the nametag functions, speed and durations clamped, no file
  content ever becoming a path or a name the core acts on, files opened only under `replay/`, and a
  fuzz target on the loader. No tamper detection, by design: the file is on the player's machine,
  the code is public, and editing (trim, name, colour, cutting the middle) is a supported use.
- **Compatibility:** latest version assumed. An older file plays with whatever it contains; the
  header versions only produce a one-line log warning. No refusal, no migration.
- **Controls:** config first; a hotkey only where the key IS the feature (record start/stop,
  save-last-N, replay-last, restart, rewind, fast-forward) — ADR 0048. An adapter may add its own
  binding by sending `replay_control` over the bridge, an addition never a replacement.
- **Cost:** a ring at 100Hz for 30s is ~3000 states, about 1MB. A 100Hz launch-to-quit file is a few
  tens of MB per hour before dedupe, a fraction after. Replay peers take roster seats (cap 512) and
  adapter render slots, so chasers plus active replays are capped at 16 local peers.
- **Risks carried into the phase file:** the `nowMs` domain is reset when a relay session is
  forgotten, so a player re-bases after any seam and treats a backwards step above 500ms as one;
  the roster is wiped on every reconnect, so a local peer is re-admitted on every fed sample; a
  goroutine stall above the 3s stale window despawns the ghost, so sleeps stay at or under 50ms.
- **Contract revision:** `render_remote.cosmetic`, the `replay_control` bridge message and
  `session_policy.chaser_contact` are new bridge fields; `contract.md` and the frozen field list in
  `internal/gameblind` change with them.
