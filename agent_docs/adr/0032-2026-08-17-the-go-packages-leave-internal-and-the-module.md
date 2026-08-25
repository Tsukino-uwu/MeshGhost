# 2026-08-17 — The Go packages leave `internal/` and the module takes its real path

<!-- ADR 0032. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** Rename the module from `meshghost` to `github.com/Tsukino-uwu/MeshGhost` and
  move the six library packages — `protocol`, `transport`, `bridge`, `core`, `relay`, `netx`
  (with `netx/udpconn`, `netx/quicconn`) — from `internal/` to the repo root, making them
  importable from outside. `internal/` survives holding `e2e` alone. `cmd/*` are unmoved and
  remain `package main`. **No API stability is promised**: pre-1.0, and these packages may
  change shape in any release.
- **Status:** Done. A pure import-path change — no logic, no wire format, no bridge change, no
  adapter change. Verified by `dev-scripts/run-gotests.bat` green, `-count=10 -shuffle=on` green
  on the concurrency packages, and a throwaway module outside the repo that imports all six by
  their new paths and runs. That last one is the only check that actually demonstrates the goal;
  the existing suite passes just as happily with the packages still private.
- **Context:** A Go game wanting MeshGhost compiled in could not import any of it, for two
  independent reasons: `module meshghost` is a local-only name that resolves to nothing, and
  every library package sat under `internal/`, which the toolchain refuses from outside the
  owning module. `docs/integrating.md` documented that as deliberate, and `ideas.md` recorded
  the change as "deliberately not scheduled" — the cost being commitment rather than risk, since
  `internal/` is exactly how a Go project says "I reserve the right to reshape this freely".
  **The trigger was the user deciding to do it anyway, not an outside embedder asking.** That is
  worth stating plainly, because the ideas entry had named "a real user asking, not neatness" as
  the bar and this did not clear it; the decision was made with that trade in view.
- **Options considered:**
  1. **Leave it.** Fork-or-vendor stays the only route. MIT permits it outright, and nothing
     outside this repo had asked.
  2. **Export `protocol` only.** Cheap, no dependencies, the most stable code here — but an
     embedder would still write their own framing, transports and client logic. It buys perhaps
     a third of the work while creating a permanent surface anyway.
  3. **A `pkg/` umbrella.** Keeps the repo root uncluttered at the cost of a dead path segment
     in every import line, forever.
  4. **The repo root.**
  5. **A cgo `-buildmode=c-shared` library**, so non-Go games could link it in too.
- **Resolution:** Option 4. The half-measure (2) creates the surface without the payoff, and
  `pkg/` (3) is a convention from an unofficial layout repo the Go team does not endorse —
  `github.com/Tsukino-uwu/MeshGhost/core` is the form a Go reader expects.
  **Option 5 was rejected outright**, and not on effort: every Go build here sets
  `CGO_ENABLED: "0"`, and `release.yml` cross-compiles four targets from one Linux runner
  *because* pure Go cross-compiles for free — `c-shared` needs cgo and a native toolchain per
  target, collapsing that into a per-OS matrix. It would also put the Go runtime inside the game
  process, which is precisely what "Why the core is out-of-process" decided against, and a DLL
  is a worse offender than an exe for the AV false-positive problem this project already has.
  The cross-language need it would serve is **already met by the bridge**: any language can run
  the binary as a sidecar and speak one JSON object per line, which is exactly what the three
  shipped adapters do in three unrelated languages. That answer was under-documented rather than
  missing, so the fix was documentation (`docs/integrating.md`), not a build target.
- **Consequences:** These six packages are a public API surface now, and every later refactor is
  a potential breaking change for people we cannot contact. **The mitigation is an explicit
  refusal to promise stability, not restraint in refactoring** — stated in the README, in
  `docs/integrating.md`, in `go.mod`'s header, and in `core`/`relay`'s package comments, which
  is the version pkg.go.dev renders. Also: `v0.9.0` is the first fetchable tag, cut immediately
  after this change for exactly that reason — tags up to `v0.8.5` carry the old module path and are
  **not fetchable**; only tags cut after this resolve. The packages appear on pkg.go.dev the
  first time anyone fetches them, so package doc comments are now published prose. `internal/`
  keeps its meaning because `e2e` still lives there. **No adapter was opened** — their sources
  still carry `internal/…` path comments, left stale on purpose: they are `eol=lf`-pinned and
  hashed by `release.yml`'s staleness gate, so correcting a comment would force a DLL rebuild
  and a re-baked `*-built-from.txt` or the next release goes red claiming a fresh DLL is stale.
  Fix them the next time those files change for a real reason. `agent_docs/verified.md` and
  `agent_docs/phases/` were deliberately not swept: they are dated records, and entries before
  2026-08-17 naming `internal/<pkg>/…` map 1:1 to `<pkg>/…`.
