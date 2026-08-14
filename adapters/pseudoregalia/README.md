# Pseudoregalia

**Status: Phase 7, 7.0–7.6 done, 7.7 (real two-player test) not started.** First release
package cut 2026-08-13, marked experimental/pre-release pending 7.7. See
[agent_docs/phases/phase7.md](../../agent_docs/phases/phase7.md) and
`packaging/release/games/pseudoregalia/README.txt`.

- Unreal Engine 5, small movement-focused 3D platformer. Worst starting point (no source, no
  BepInEx) but best genre fit for ghost co-op, per the brief.
- Tooling: **confirmed 2026-08-12** — UE 5.1 (`++UE5+Release-5.1-CL-23901901`, read from
  `pseudoregalia-Win64-Shipping.exe`); UE4SS **v3.0.1 Beta, Git SHA `733e5969`**, installed
  under the newer `Binaries\Win64\ue4ss\` layout. See
  [agent_docs/environment.md](../../agent_docs/environment.md)'s Unity/TEVI, UE5/Pseudoregalia
  section for the full record, including a note that the install was updated mid-Phase-7 from
  an older v2.5.2 — re-check before assuming this is still current.
- **Adapter language plan, decided 2026-08-12:** Lua for discovery (no build step, fast
  iteration, used only to find and confirm the real player-state fields), C++ for the
  shipping adapter (UE4SS Lua has no socket support — zero `luasocket` references in
  RE-UE4SS and no networking in its Lua API docs — but the already-installed `AP_Randomizer`
  C++ mod proves a UE4SS C++ mod can hold a real TLS/websocket connection in this exact
  game). See [agent_docs/phases/phase7.md](../../agent_docs/phases/phase7.md) and
  [agent_docs/plans.md](../../agent_docs/plans.md)'s Phase 7 entry.
- The Archipelago randomizer for this game
  ([pseudoregalia-archipelago](https://github.com/pseudoregalia-modding/pseudoregalia-archipelago))
  was checked into [agent_docs/licensing.md](../../agent_docs/licensing.md) 2026-08-12: **no
  LICENSE file, all rights reserved.** Consulted for facts only (its `.gitmodules` UE4SS pin,
  its general mod structure) — no source copied, per the standing "facts, never code" rule.
- No source is or will be copied from any randomizer or modding project without checking
  its license first — see [agent_docs/licensing.md](../../agent_docs/licensing.md).

## How this adapter was built

Third game, and by far the hardest so far: roughly 15-20 hours in and still not fully done
(the ghost follows and animates, but Phase 7.7 — a real two-player test — hasn't happened
yet). Started in Lua, then had to be substantially remade in C++ partway through once Lua
proved unable to reliably send everything the adapter needed.

All of this is one phase, [agent_docs/phases/phase7.md](../../agent_docs/phases/phase7.md) —
the sub-numbers below (7.1, 7.4,
etc.) are that file's own task headings, called out here for anyone jumping straight to the
detailed log instead of reading the whole thing top to bottom. It reads as a much smoother
line than it actually was — the file itself has dozens of individual live-test cycles behind
several of these steps (the camera fight alone took over twenty), condensed here into what
actually mattered.

Roughly in order:

1. Dropped an unanimated model into the level, not moving. (7.1/7.4)
2. Made that model follow the player as a ghost. (7.4)
3. Fought the game's camera, which kept snapping back onto the ghost instead of staying on
   the player. (7.4 — the fix that finally worked: hooking the game's own camera-retarget call
   and forcing it back, not toggling a property on the ghost's camera.)
4. Tried making a statue already present in the stage follow the player, as an alternative
   to spawning a new actor — this is also what proved runtime-`SpawnActor`'d actors weren't
   rendering at all on this build, while hijacking an existing level object did. (7.4)
5. Hit a wall where Lua wasn't reliably sending everything required over the socket — a
   binary-compatibility bug between the vendored LuaSocket build and UE4SS's own embedded Lua
   that only showed up under real sustained traffic, not light testing. (7.5)
6. Remade the networking (and much of the rest of the adapter) in C++, once the C++/UE4SS
   build toolchain access that had been blocking that path got unblocked. (7.5)
7. Tried spawning something not already in the stage (new statues, etc.), then decided
   against it and went back to duplicating the player / reusing an object already in the
   stage — same finding as step 4, re-confirmed in C++: spawned actors could be destroyed but
   never re-rendered cleanly, so the shipping design hijacks an existing level object instead.
   (7.5)
8. Tested with static objects, and had to move rendering/follow logic onto the right thread
   to get it to actually follow instead of stutter or freeze — the mod's own update loop
   wasn't running on the real game thread. (7.5)
9. Figured out how to drive the ghost's facing direction — traced to a marshaling bug in the
   vendored UE4SS SDK that only affects `FRotator` on UE 5.0+, worked around with a local,
   version-aware helper rather than patching the (un-committable) submodule. (7.6)
10. Fixed the ghost getting stuck in a falling animation. (7.6)
11. Fixed the ghost getting stuck in a ledge-hang animation. (7.6)

See [agent_docs/phases/phase7.md](../../agent_docs/phases/phase7.md) for the detailed, dated
log, and [agent_docs/pitfalls.md](../../agent_docs/pitfalls.md) for the transferable lessons
pulled out of this saga (auto-possession on spawn, camera/view-target
ownership, runtime-spawned actors not rendering, the `on_update()`-isn't-the-game-thread bug,
the LuaSocket corruption bug behind the Lua-to-C++ rewrite, and the UE5 `FRotator` marshaling
bug behind the facing-direction fix).

### Further work past "good enough"

Not reached yet — Phase 7.7 (a real two-player test) is still outstanding. Add entries here
once work continues past that point.
