# Pseudoregalia

**Status: Phase 7, in progress (started 2026-08-12).** See `agent_docs/phases/phase7.md`.

- Unreal Engine 5, small movement-focused 3D platformer. Worst starting point (no source, no
  BepInEx) but best genre fit for ghost co-op, per the brief.
- Tooling: **confirmed 2026-08-12** — UE 5.1 (`++UE5+Release-5.1-CL-23901901`, read from
  `pseudoregalia-Win64-Shipping.exe`); UE4SS **v3.0.1 Beta, Git SHA `733e5969`**, installed
  under the newer `Binaries\Win64\ue4ss\` layout. See `agent_docs/environment.md`'s
  Unity/TEVI, UE5/Pseudoregalia section for the full record, including a note that the
  install was updated mid-Phase-7 from an older v2.5.2 — re-check before assuming this is
  still current.
- **Adapter language plan, decided 2026-08-12:** Lua for discovery (no build step, fast
  iteration, used only to find and confirm the real player-state fields), C++ for the
  shipping adapter (UE4SS Lua has no socket support — zero `luasocket` references in
  RE-UE4SS and no networking in its Lua API docs — but the already-installed `AP_Randomizer`
  C++ mod proves a UE4SS C++ mod can hold a real TLS/websocket connection in this exact
  game). See `agent_docs/phases/phase7.md` and `agent_docs/plans.md`'s Phase 7 entry.
- The Archipelago randomizer for this game
  ([pseudoregalia-archipelago](https://github.com/pseudoregalia-modding/pseudoregalia-archipelago))
  was checked into `agent_docs/licensing.md` 2026-08-12: **no LICENSE file, all rights
  reserved.** Consulted for facts only (its `.gitmodules` UE4SS pin, its general mod
  structure) — no source copied, per the standing "facts, never code" rule.
- No source is or will be copied from any randomizer or modding project without checking
  its license first — see `agent_docs/licensing.md`.
