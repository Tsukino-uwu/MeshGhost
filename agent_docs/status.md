# Current status

## Active status

- `Active phase:` Phase 0 mostly done (contract structure written), Phase 1 not started.
- `Current focus:` set up a verified BizHawk/Lua environment (`agent_docs/environment.md`
  is unfilled — do that first), then start `agent_docs/phases/phase1.md`.
- `Blocked by:` no BizHawk build, Emerald ROM, or Lua environment confirmed yet. Go toolchain
  is confirmed installed (`go1.26.5`) and the type skeleton in `cmd/`/`internal/` builds and
  vets clean — that blocker is cleared.
- `Next step:` work through the BizHawk items in `agent_docs/environment.md`'s onboarding
  checklist (install BizHawk, confirm the Emerald ROM revision, verify Lua console access),
  record the versions there, then begin `agent_docs/phases/phase1.md`'s task list.

## Update guidance

- Update this file whenever the active phase changes.
- Keep entries short; this is a one-screen summary, not a log.
