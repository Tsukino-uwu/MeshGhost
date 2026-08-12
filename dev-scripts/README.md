# Dev scripts

Developer/testing launchers used while building MeshGhost itself — not what an end user
wanting to play needs. If you just want to play with friends, use the pre-built release
instead: see `packaging/README.md` and the repo's Releases page.

These assume `meshghost.exe`, `meshghost-relay.exe`, and `meshghost-fakeadapter.exe` are
built at the repo root (e.g. `go build -o meshghost.exe ./cmd/meshghost`, run from the repo
root) — each script references them as `..\<name>.exe`.

- `run-relay.bat` — a single relay, default settings.
- `run-core.bat` — a single core client (solo/self-test).
- `run-core1.bat` / `run-core2.bat` — two core clients on distinct bridge ports, for real
  two-player testing (see `agent_docs/phases/phase4.md`).
- `run-bizhawk1.bat` / `run-bizhawk2.bat` — two BizHawk instances paired with the two cores
  above (edit the `EMUHAWK_EXE`/`EMERALD_ROM` paths at the top for your own machine first).
- `run-fakeadapter1.bat` / `run-fakeadapter2.bat` — two headless `cmd/meshghost-fakeadapter`
  instances (circle-motion fake ghosts, no game) for testing the core/relay without BizHawk at
  all — see `agent_docs/phases/phase5.md`.
- `run-relay-loopback.bat` / `run-core-tevi.bat` — TEVI's Phase 6.4/6.5 loopback test: a relay
  that echoes a lone client's own state back as `<id>-ghost`, and a core started with
  `-game=tevi`. Pair with TEVI itself (via `adapters/tevi/MeshGhostTevi`, deployed into
  `BepInEx/plugins/`) to see a real network round trip without needing two TEVI instances —
  see `agent_docs/phases/phase6.md`.
- `build-tevi.bat` — not a launcher, a build step: compiles the TEVI BepInEx plugin and stages
  the result into `packaging/release/games/tevi/` for the release zip. Re-run and commit the
  result whenever `adapters/tevi/MeshGhostTevi/{Plugin.cs,BridgeClient.cs,*.csproj}` change —
  see `packaging/README.md`'s TEVI section for why this one output is committed at all.
