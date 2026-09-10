# Contributing

Two things before the first commit, both once per clone: `git config core.hooksPath .githooks`, so
the pre-commit hook can refuse a machine-specific path before it reaches the public tree, and a run
of `dev-scripts/preflight.ps1`, which checks the docs, the adapter file sets and the built artifacts
and says what a change is expected to keep true.

For anything under `core`, `relay`, `transport`, `bridge` or `cmd`, `dev-scripts/run-gotests.bat` is
the whole suite; CI runs the same plus the fuzzers and the race detector on every push.

The rules the project is built under are [CLAUDE.md](../CLAUDE.md), and
[agent_docs/README.md](../agent_docs/README.md) is the map of everything else.

## Repo layout

Grouped by what each thing *is*, not alphabetically — so GitHub's file listing shows these in a
different order. Only the directories worth orienting on are listed; the usual `LICENSE`,
`.gitignore` and friends are omitted.

```text
MeshGhost/
├── cmd/                  # entry points: the client, the standalone relay, and the test rig's
│                         #   fake adapter and network simulator
│
│                         # the library, importable from outside:
├── core/                 # game-agnostic client: relay connection, buffering, interpolation
├── relay/                # game-agnostic server: rooms, forwarding, limits
├── protocol/             # the wire messages both speak
├── transport/            # NDJSON framing over any net.Conn
├── bridge/               # the adapter <-> local core messages
├── netx/                 # transport selection: tcp | udp | quic
│
├── internal/             # not importable: the e2e suite that drives the real binaries, config
│                         #   loading, global hotkeys, text formatting, and the check that keeps
│                         #   the Go side game-blind
├── adapters/             # one folder per game; _template/ is the starting point for a new one
├── docs/                 # for people using MeshGhost
├── agent_docs/           # design brief, contract, architecture, roadmap, verified facts
├── dev-scripts/          # local test rig: launchers, load tests, adapter build scripts
├── dev-logs/             # where a dev session's logs land; gitignored, but the folder is
│                         #   committed because probes cannot create it themselves
├── packaging/            # what goes in the release zip, and how it's assembled
├── .githooks/            # the pre-commit leak check; point core.hooksPath here once per clone
├── .github/              # CI on every push and the manual release button, under workflows/,
│                         #   plus the contributing and security policies
├── .claude/skills/       # the task-scoped reading paths CLAUDE.md points at
├── CLAUDE.md             # the rules this project is built under, for whoever works on it
└── go.mod
```
