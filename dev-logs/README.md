# dev-logs — every log a development session produces

**This folder is gitignored except for this file, and this file exists so the folder does.** That
is not tidiness: several probes open their log with `io.open(..., "a")` and **nothing creates the
directory first**. `io.open` returns nil when the parent folder is missing, the probe's own
`if f then` guard swallows it, and the result is a probe that runs and silently logs nothing. On a
fresh clone with no tracked file here, that would be every one of them at once. So the folder is
committed, empty, on purpose.

Creating it from the scripts is not an option: BizHawk's Lua has no mkdir, and the shell routes
that would (`os.execute`, `io.popen`) flash a console window in every shape that was tried
(`agent_docs/environment.md`, 2026-08-18).

## What lands here

- **Session scaffolding** an agent redirects: relay, core, fakeadapter and netsim runs.
- **Build output**: `build-*.log` and `build-*.err.log` from `dev-scripts/build-*.bat`.
- **Probe and dev-script logs**, moved here 2026-09-03. `dev-scripts/` had accumulated 123 loose
  `.log` files beside the scripts themselves; the user's call was that they belong with the rest
  rather than in a second log folder nobody would think to look in.

## What does NOT land here

- **`dev-scripts/bizhawk-dev-loader*.target`** — a control file is an INPUT somebody edits by hand,
  and instructions name its path. Only the loader's `.log` moved.
- Three probes open a **bare relative** log name (`bizhawk-input-probe.lua`,
  `bizhawk-input-test.lua`, `bizhawk-savestate-probe.lua`), so their output follows the emulator's
  working directory rather than any folder here. Left alone deliberately: repointing them would put
  their logs somewhere nobody asked for.
- Adapter logs, which live beside their own adapter (`adapters/**/logs/`), and the game installs'
  own `meshghost.log`.

## Housekeeping

Nothing here is tracked, so deleting the lot is always safe and never loses repo state. A record
worth keeping belongs in `agent_docs/` — a verified fact, a phase entry, or a pitfall — not in a
megabyte of raw log.
