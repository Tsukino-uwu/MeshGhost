# Code map

Every source file, what it's for, and where the notes behind it live. A probe folder has one row; `dev-scripts/`
is described in its own [README](../dev-scripts/README.md). Started 2026-10-01 with the agent guard; the rest of the
tree gets its rows in step A4 of the bug_fables_ap comparison ([phase12.md](phases/phase12.md), 2026-09-30), and
preflight's "Doc coverage" section counts the files still missing one.

## Claude Code

| File | What it does | Notes |
|---|---|---|
| [`agent-guard.py`](../.claude/hooks/agent-guard.py) | Runs before every command, edit and page fetch Claude Code makes here: denies what would get past the git hooks or read an unlisted GitHub project, and asks before a change to the gate data or `.claude/`. | [phase12 § A2.6](phases/phase12.md#2026-10-01--a26-an-agent-guard-ported-from-bug_fables_ap) |
