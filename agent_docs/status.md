# Current status

## Active status

- `Active phase:` Phase 0 mostly done (contract structure written), Phase 1 not started.
- `Current focus:` set up a verified BizHawk/Lua environment (`agent_docs/environment.md`
  is unfilled — do that first), then start `agent_docs/phases/phase1.md`.
- `Blocked by:` no BizHawk build, Emerald ROM, or Lua environment confirmed yet. No Go
  toolchain confirmed installed on the dev machine either — needed before any `cmd/` or
  `internal/` package gets real code, even though nothing there needs it yet (skeleton only).
- `Next step:` fill `agent_docs/environment.md` with the actual BizHawk/Lua versions in use,
  then begin Phase 1's task list.

## Update guidance

- Update this file whenever the active phase changes.
- Keep entries short; this is a one-screen summary, not a log.
