# Before touching a BizHawk Lua adapter or probe

`adapters/emulator/CLAUDE.md` loads on contact and carries the host rules (the ROM is never patched, log cost, the 200-local ceiling, breakpoints). This page is the rest.

**Read the three in bold, then skim the rest: one line each, the title IS the lesson, the link is the record.**

- **When a change does nothing, read the loader log for `LOAD FAILED` and per-tick errors BEFORE anything else** — an unloaded adapter looks like a dead relay.
- **Declare a `local` above every use, in file scope and inside a function** — preflight's "Lua globals resolve" now fails it; `luac -p` never could.
- **Absence of output is not absence of pixels**: clear the overlay on every exit path. And `a and b or c` is not a ternary for a boolean.

## Every lesson filed here

- BizHawk Lua: `event.onframeend` outlives its script; use a `frameadvance` loop — [by-host.md](../pitfalls/by-host.md)
- BizHawk Lua: `debug.getinfo` gives no path — use the working directory — [by-host.md](../pitfalls/by-host.md)
- Host-embedded scripting runtimes, vendored DLLs, and ABI mismatch — [by-host.md](../pitfalls/by-host.md)
- A guard that checks "did I get an answer" instead of "is the answer usable" (2026-08-18) — [by-host.md](../pitfalls/by-host.md)
- A Gold/Silver GameShark code run on Crystal writes into the object RAM MeshGhost spawns into (2026-08-18) — [by-lesson.md](../pitfalls/by-lesson.md)
- BizHawk accepts a GBA cheat code it cannot decrypt, and silently activates the garbage (2026-08-18) — [by-lesson.md](../pitfalls/by-lesson.md)
- Crystal: a nil address reads as byte 0, so an unmeasured entry SATISFIES a gate instead of refusing (2026-08-19) — [by-lesson.md](../pitfalls/by-lesson.md)
- Lua 5.4 refuses a bit shift on a float, and a smoothed position is a float (2026-08-19) — [by-lesson.md](../pitfalls/by-lesson.md)
- A hardcoded ROM address slipped past the refuse-if-unmeasured discipline an hour after it was built (2026-08-19) — [by-lesson.md](../pitfalls/by-lesson.md)
- A file can LOAD cleanly and then throw on every frame (2026-08-21) — [by-lesson.md](../pitfalls/by-lesson.md)
- BizHawk's drawing layer persists: "draw nothing" leaves the last frame (2026-08-21) — [by-lesson.md](../pitfalls/by-lesson.md)
- A ghost that is "static, but follows the player around" (Crystal, 2026-08-23) — [by-lesson.md](../pitfalls/by-lesson.md)
- `pcall` catches errors, not loops — a malformed line froze the emulator (Crystal, 2026-08-25) — [by-lesson.md](../pitfalls/by-lesson.md)
- A ghost that VANISHES is usually an adapter that was unloaded, and the loader log says so in one line (2026-08-26, Crystal) — [by-lesson.md](../pitfalls/by-lesson.md)
- Below the mid-step return is where peer state goes to die -- third instance (Crystal, 2026-08-26) — [by-lesson.md](../pitfalls/by-lesson.md)
- A RELATIVE path in the dev loader's control file fails as a "LuaSocket is missing" error — [by-lesson.md](../pitfalls/by-lesson.md)
- THE LUA and/or TERNARY CANNOT CARRY A BOOLEAN (Crystal, 2026-08-27) — [by-lesson.md](../pitfalls/by-lesson.md)
- A seam is not a warp: free a resource unless the engine demonstrably rebuilt the world — "never left the overworld" is the signal that needs nothing armed (Emerald, 2026-09-02) — [by-lesson.md](../pitfalls/by-lesson.md)
- A free needs the identity of the RANGE: scan the sprite table for a live owner before clearing bits, and log why a free was skipped (Emerald, 2026-09-02) — [by-lesson.md](../pitfalls/by-lesson.md)
- A dev-mode "on change" trace with ONE shared key fires per peer per frame with a crowd; key per peer and give it its own flag (Emerald, 2026-09-02) — [by-lesson.md](../pitfalls/by-lesson.md)
- Never Reboot Core with an adapter that registers a memory callback loaded; drop the target to `none` first, or use the game's own soft reset (BizHawk 2.11 + mGBA, Emerald, 2026-09-02) — [by-lesson.md](../pitfalls/by-lesson.md)
