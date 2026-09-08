# Before a scripted edit

Anything `python`, `perl` or a heredoc writes into a file is unverified until read back. `CLAUDE.md` carries the rule; this page is the record behind it.

**Read the three in bold, then skim the rest: one line each, the title IS the lesson, the link is the record.**

- **Never pipe a multi-line script through bash inline, and never chain `powershell -ExecutionPolicy Bypass` inside a bash command** — Defender flags that shape as Trojan:Win32/PowhidSubExec.B (2026-09-03, blocked mid-session, a Severe alert on the user's screen). Write the script to the scratchpad and run it by path; run `.ps1` files from the PowerShell tool.
- **One edit per script, and grep the RESULT** — a later `assert` discards every earlier replacement that did match, and an unmatched pattern fails silently.
- **`file <path>` must not say CRLF** on anything LF-pinned (`.gitattributes` lists them); normalize with `perl -pi -e 's/\r\n/\n/g' <path>`, then build, then commit — the release staleness gate hashes those sources, so a CRLF tree bakes a hash CI can never match and the DLL reads as stale forever (live twice, last 2026-08-15). Preflight checks it, after the fact; prefer the Edit tool, which never writes CRLF.
- **Never write a backslash escape inline in a heredoc, and never compute an insert index** — one collapsed in transit four times in a session, the other landed a thousand lines away.

## Every lesson filed here

- Two `git.exe` installs on one machine disagree about whether the tree is dirty (2026-08-15) — [by-host.md](../pitfalls/by-host.md)
- An escape in a heredoc can COLLAPSE in transit, and the compiler is the only thing that notices (2026-08-27) — [by-lesson.md](../pitfalls/by-lesson.md)
- A scripted edit can land a thousand lines from where you meant it (2026-08-23) — [by-lesson.md](../pitfalls/by-lesson.md)
- A parked audit rots faster than the thing it audited (2026-08-25) — [by-lesson.md](../pitfalls/by-lesson.md)
- An inline heredoc plus a bypassing PowerShell in one bash command is a Defender trojan signature (2026-09-03) — [method.md](../pitfalls/method.md)
- **An inline shell heredoc mangles backslash escapes on this machine** (2026-09-08): `\n` inside a Python patch written through the Bash tool reached the source as a real newline, and `\x00b7` as a NUL byte plus the text `b7`, twice in one afternoon -- write the patch script to a file with the Write tool and run it by path, and grep the result for the literal you meant.
