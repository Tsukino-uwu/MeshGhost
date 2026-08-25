# 2026-08-11 — Emerald uses a vendored LuaSocket, not BizHawk's own `comm.*`

<!-- ADR 0008. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-11
- **Decision:** The Emerald BizHawk adapter uses a vendored LuaSocket binary for its bridge
  connection, not BizHawk's own built-in `comm.*` (`CommLuaLibrary`) socket API. Loopback
  (Phase 3's one-client milestone) is implemented as a relay-side `-loopback` flag that echoes
  a client's own `state` back under a synthetic `"<id>-ghost"` player_id, not a core-side or
  third-process echo.
- **Status:** accepted
- **Context:** Phase 3 needed the first real adapter socket in the project. Two ways to hold a
  TCP connection from BizHawk Lua exist in this exact installed build (2.11): the engine's own
  `comm.*` library, and a vendored LuaSocket, the approach the brief's own cited prior art
  (`bizhawk-co-op`) and Archipelago's `connector_bizhawk_generic.lua` both use. Checked against
  real files rather than assumed: `comm.*` is present (confirmed via
  `BizHawk.Client.Common.dll`'s embedded doc strings), but its own documentation states
  responses "must be of the form `{msg.Length:D} {msg}`" — length-prefixed framing, not
  NDJSON — plus a blocking request/response model. Separately, Phase 3 also needed a way to
  exercise the full core→relay→core path with only one physical BizHawk instance, since a real
  second peer doesn't exist until Phase 4.
- **Options considered (socket):** (1) `comm.*` — zero vendoring, zero licensing surface, but
  its framing would have to become a second mode the Go bridge speaks, and *every* future
  adapter (Unity, UE5, anything else) would inherit that choice too, since the bridge is
  meant to be one protocol for every adapter; (2) LuaSocket, vendored — a real MIT-licensed
  binary dependency to track, but keeps the bridge as the one NDJSON protocol every adapter
  speaks, matching `agent_docs/contract.md`'s transport section as already written, no
  contract revision; (3) reimplement a raw socket via BizHawk's `comm.*` framing translated
  transparently at the bridge boundary — rejected as needless complexity solving a problem
  option 2 doesn't have.
- **Options considered (loopback):** (1) relay-side `-loopback` flag, echoing under a
  synthetic ghost id — exercises the real relay round trip and real interpolation, zero
  `core` changes since the ghost id is simply a different id than the client's own;
  (2) core-side flag, feeding local state into the core's own remote buffer directly — simpler
  but the data never actually crosses the relay, and requires loosening the core's own
  "ignore my own player_id" guard; (3) a separate `meshghost-echo` dev client, a second real
  relay peer that re-sends whatever it receives — closest to a real Phase 4 peer, but a third
  process to build and run for a milestone that doesn't need one yet.
- **Resolution:** LuaSocket (vendored `socket-windows-5-4.dll`, MIT, see
  `agent_docs/licensing.md`) for the socket; the specific binary reused is the one already
  vendored by Archipelago for the same BizHawk/Lua-5.4 target (proven working there) rather
  than an independent rebuild from LuaSocket's own source, to avoid a silent Lua-ABI mismatch
  with no error to catch it. Relay-side `-loopback` flag for the echo.
  **Follow-up finding (2026-08-11, live test):** the first real run failed loading
  `socket-windows-5-4.dll` at all — `package.loadlib` returned "the specified module could not
  be found". Diagnosed empirically (not guessed): the DLL's PE import table names `lua54.dll`
  as a dependency; Windows' plain `LoadLibrary` (confirmed against Lua's own `loadlib.c`,
  which passes `LUA_LLE_FLAGS` = 0 by default) resolves a loaded DLL's dependencies via the
  standard search order, which does **not** include the directory the DLL itself was loaded
  from — confirmed by reproducing the exact failure outside BizHawk, then confirming that even
  placing a copy of `lua54.dll` next to `socket-windows-5-4.dll` did **not** fix it. What does
  fix it, confirmed the same way: explicitly pre-loading `lua54.dll` by its own full path
  *before* loading the socket module — Windows' loader reuses an already-loaded module of the
  same name for later dependency resolution regardless of source directory. Fixed by also
  vendoring `lua54.dll` (byte-identical copy of the one already running inside the user's
  BizHawk, confirmed via matching hash — not an independently built copy, to guarantee the
  pre-load binds to a build compatible with the one actually executing the script) and having
  `phase3_loopback.lua` pre-load it before `package.loadlib`-ing the socket core.
- **Consequences:** The bridge stays one protocol for every future adapter; a C#/C++ Unity or
  UE5 adapter later just opens an ordinary TCP socket, no BizHawk-specific framing to carry
  forward. `-loopback` is dev-only and must not ship enabled by default; it becomes dead code
  to ignore (not remove — cheap to keep for future dev/test use) once Phase 4 has a real
  second peer. The LuaSocket binary is now a real third-party dependency this project tracks
  (platform/arch/Lua-version-specific), unlike everything vendored before it, which was source
  citation only.
