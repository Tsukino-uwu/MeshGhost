# Contributing

Two things before the first commit, both once per clone: `git config core.hooksPath .githooks`, so
the pre-commit hook can refuse a machine-specific path before it reaches the public tree, and a run
of `dev-scripts/preflight.ps1`, which checks the docs, the adapter file sets and the built artifacts
and says what a change is expected to keep true.

For anything under `core`, `relay`, `transport`, `bridge` or `cmd`, `dev-scripts/run-gotests.bat` is
the whole suite; CI runs the same plus the fuzzers and the race detector on every push.

The rules the project is built under are [CLAUDE.md](../CLAUDE.md), and
[agent_docs/README.md](../agent_docs/README.md) is the map of everything else.
