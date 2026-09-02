# Before a scripted edit

Anything `python`, `perl` or a heredoc writes into a file is unverified until read back. `CLAUDE.md` carries the rule; this page is the record behind it.

**Read the three in bold, then skim the rest: one line each, the title IS the lesson, the link is the record.**

- **Never pipe a multi-line script through bash inline, and never chain `powershell -ExecutionPolicy Bypass` inside a bash command** — Defender flags that shape as Trojan:Win32/PowhidSubExec.B (2026-09-03, blocked mid-session, a Severe alert on the user's screen). Write the script to the scratchpad and run it by path; run `.ps1` files from the PowerShell tool.
- **One edit per script, and grep the RESULT** — a later `assert` discards every earlier replacement that did match, and an unmatched pattern fails silently.
- **`file <path>` must not say CRLF** on anything LF-pinned; normalize, then build, then commit. Preflight checks it, after the fact.
- **Never write a backslash escape inline in a heredoc, and never compute an insert index** — one collapsed in transit four times in a session, the other landed a thousand lines away.

## Every lesson filed here

- Two `git.exe` installs on one machine disagree about whether the tree is dirty (2026-08-15) — [by-host.md](../pitfalls/by-host.md)
- An escape in a heredoc can COLLAPSE in transit, and the compiler is the only thing that notices (2026-08-27) — [by-lesson.md](../pitfalls/by-lesson.md)
- A scripted edit can land a thousand lines from where you meant it (2026-08-23) — [by-lesson.md](../pitfalls/by-lesson.md)
- A parked audit rots faster than the thing it audited (2026-08-25) — [by-lesson.md](../pitfalls/by-lesson.md)
- An inline heredoc plus a bypassing PowerShell in one bash command is a Defender trojan signature (2026-09-03) — [method.md](../pitfalls/method.md)
