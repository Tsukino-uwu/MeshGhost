# 2026-09-16 — Autoplay is a second Go module that never ships

<!-- ADR 0071. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** the dev-only harness that lets an agent play a game (Phase 13) lives in a top-level
  `autoplay/` folder with **its own `go.mod`** (`github.com/Tsukino-uwu/MeshGhost/autoplay`). It
  imports nothing from the MeshGhost module, MeshGhost imports nothing from it, and nothing of it is
  built, staged or shipped by a release. Its first third-party dependency is the MCP Go SDK
  (`licensing.md`), which the MeshGhost module therefore never requires.
- **Status:** Implemented 2026-09-16 (the user's call at Phase 0's checkpoint, `phases/phase13.md`).
- **Why a second module and not a folder in the first.** Go's `./...` stops at a directory holding
  its own `go.mod`, so the root module's build, vet, test, race shards and `govulncheck` — in CI and
  in `release.yml` — never see the harness, and no exclusion rule is needed that someone could later
  forget. The release was already safe either way (`release.yml` builds only `./cmd/meshghost` and
  `./cmd/meshghost-relay`, and `stage-release.ps1` copies an explicit list), but a dependency in the
  root `go.mod` would still have entered every shipped build's module graph and its vulnerability
  scans. Deleting `autoplay/` removes the whole thing.
- **What it costs.** The harness needs its own checks: `.github/workflows/autoplay.yml` (vet, race
  tests, `govulncheck` inside `autoplay/`) and its own local commands, since
  `dev-scripts/run-gotests.bat` covers only the root module. Preflight's "root binaries vs Go source"
  skips `autoplay/`, or every harness edit would call the shipped `meshghost*.exe` stale. It cannot
  import `internal/` helpers, and the game-blind tests in `internal/gameblind` do not cover it.
- **The shape it follows.** MeshGhost's own: a game-blind core (an MCP server on stdio plus a
  loopback listener) and a thin driver per host inside the game. The link between them is its own
  newline-delimited JSON protocol, documented in `autoplay/driver/driver.go` — not the bridge, which
  stays MeshGhost's contract alone. Nothing that ships writes game state (`CLAUDE.md`); a driver is
  dev tooling, the same class as a probe.
