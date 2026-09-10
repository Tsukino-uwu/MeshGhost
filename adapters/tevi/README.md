# TEVI

**Status: second target game (chosen 2026-08-11, replacing Ori: Will of the Wisps), shipped —
Phase 6 fully done 2026-08-13.**

- Unity, 2D movement-focused platformer/metroidvania — the genre where ghost co-op is most
  visually satisfying, which is the same reasoning the brief used for Ori, and why it took the
  second slot over the two Ori titles (see
  [agent_docs/architecture.md](../../agent_docs/architecture.md)'s 2026-08-11 decision;
  Pseudoregalia was slated last from the brief onwards, never a second-slot candidate).
- **How the game is read: the shipped artifact documents itself.** `Assembly-CSharp.dll` is managed
  Mono bytecode, decompiled locally with ILSpy to read real class and field names, and the adapter
  compiles against it — so a wrong name is a build error, not a silent runtime nothing. A little C#
  reflection reaches non-public members. This is the easiest of the three access models the project
  has used -- three models across four adapters, since both Pokemon games share the decompilation
  one -- and it is why this adapter was by far the fastest. See
  [agent_docs/access-models.md](../../agent_docs/access-models.md).
- **[documentation.md](documentation.md)** describes how TEVI itself works — reaching the player
  through `EventManager`, the gap between the logic position and the drawn position, the player's
  Unity `Animator` clips addressed by name (the playable characters are *not* Spine, though other
  things in the game are), facing as a sprite flip, the map screen's separate coordinate system,
  and since 2026-09-10 the mechanics behind the newer mirrors: warp devices, the bullet pool and
  what a bullet's death actually is, core expansions, the boost shield, and how the game chooses an
  afterimage trail. It closes with the game questions still open. It was previously argued that a game with a readable managed assembly needed no such
  file; **the user overturned that 2026-08-18** and every adapter now carries one — being able to
  look something up is not the same as having looked
  ([adapters/_template/README.md](../_template/README.md)'s folder convention).
- Owned by the project author, unlike the Ori titles (see
  [agent_docs/ideas.md](../../agent_docs/ideas.md)), which was the deciding factor.
- IL2CPP vs Mono build status: **confirmed Mono** (2026-08-11) — see
  [agent_docs/environment.md](../../agent_docs/environment.md)'s Unity/TEVI section for the
  file evidence (`Assembly-CSharp.dll` present, no `GameAssembly.dll`, `doorstop_config.ini`
  has `[UnityMono]`). BepInEx/Harmony tooling applies directly; no IL2CPP interop/unhollowing
  step needed. BepInEx 5.4.23.3 is already installed on this machine's TEVI copy and confirmed
  loading a third-party plugin.
- Phase 6 is **fully done, confirmed 2026-08-13** (including 6.6, two real players, and 6.7,
  the map marker) — see [agent_docs/plans.md](../../agent_docs/plans.md)'s Phase 6 entry and
  [agent_docs/phases/phase6.md](../../agent_docs/phases/phase6.md). This adapter was built from
  the template Phase 5 extracted (`adapters/_template/`) — see
  [agent_docs/phases/phase5.md](../../agent_docs/phases/phase5.md).

- **Shipped DLL is `PluginVersion` 0.2.0**; `built-from.txt` beside the staged DLL records the
  exact commit and the source hashes it was built from, and is generated rather than hand-written,
  so it is the authority here rather than a date repeated in prose. It carries the projectile and
  core-expansion work below, and looks for `meshghost.exe` and `config.json` in the game's root
  folder only. The 2026-08-28 build before it carried the
  trail/warp/pooled-VFX/hitstop work below, and the 2026-08-18 build before that added
  three bridge/lifecycle behaviours — `bridge_ready` and `reject` are handled explicitly instead of
  falling into the unknown-message default, the bridge is drained only after the local player is
  confirmed to exist, and returning to the **main menu** despawns every peer ghost. The despawn
  half has still not been watched live; the send-gate half has (see `UNVERIFIED.md`/`BANDAGES.md`,
  2026-08-28). The despawn fires on a real main-menu return only: peer ghosts
  stay visible during the Characters/pause overlay, which is the wanted behaviour and is why
  `documentation.md` insists on naming the exact state rather than saying "menu".

## Custom features

Map marker for other player ghosts, shows a constantly tracking/updating tiny tevi bunny icon
for where other players are in your current zone (as long as you have discovered/seen the maps
before). Known limitations: the marker used to refresh only when a `render_remote` arrived, so a
peer who stopped sending left it frozen — fixed 2026-08-28 (a per-frame refresh hides a marker
older than 1s, unwatched so far, see [UNVERIFIED.md](UNVERIFIED.md)) — and it was reported slow to
start tracking again after a peer left and rejoined (2026-08-28, not investigated) — see
[agent_docs/status.md](../../agent_docs/status.md).

## Building it

`dev-scripts/build-tevi.bat` builds the DLL — it needs `MeshGhostTevi/lib/Assembly-CSharp.dll`
and `lib/Newtonsoft.Json.dll` copied in once from your own TEVI install (proprietary, gitignored,
never committed — which is also why CI cannot build this adapter and the DLL is checked in).
After a rebuild, also copy the DLL to the live game install(s), not just `packaging/release/`.
The mod looks for `meshghost.exe`, its `config.json`, `meshghost.log` and the `replay\` folder in
the **game's root folder** (the one with `TEVI.exe`) and nowhere else, since 2026-09-05; a dev
build can point it elsewhere with `MESHGHOST_CORE_DIR` ([FLAGS.md](FLAGS.md)).

## How this adapter was built

Second game, and by far the fastest: about 1 hour from start to a ghost following the player
with all animations working. Server/client and the general approach were already proven by
the `emulator/pokemon/emerald` adapter, so this was adapter-only work. BepInEx plus being able to
decompile the game made this easier and faster than Emerald, even though Emerald had a full
source decompilation available to reference — a lot of things (notably the animations) just
worked as soon as they were wired up, with no equivalent of Emerald's memory-probing phase.

Roughly in order. The narrative for each is in
[agent_docs/phases/phase6.md](../../agent_docs/phases/phase6.md), the evidence in
[VERIFIED.md](VERIFIED.md), and the lessons that generalised beyond this game in
[agent_docs/pitfalls/](../../agent_docs/pitfalls/) — several steps below were found out of order,
during review passes or later sessions, and say so where it matters:

1. Purple box as proof of concept (same first step as Emerald).
2. Cyan box following the player.
3. Replaced the box with the actual sprite.
4. Added animations.
5. Wired up real networking; the first real test hit the relay's 120 msg/sec rate limit for
   real, since TEVI's `Update()` runs uncapped — fixed with a client-side send-rate cap in the
   core, not the adapter. (6.4/6.5)
6. Hit a blocker testing with two players locally — Steam won't run two instances of the same
   game at once — resolved by downloading a second, standalone build via `steamcmd`.
7. Made ghosts hide when the peer is in a different zone (a real gap where remotes weren't
   filtered by area at all). (6.6)
8. Found and fixed a separate bug, later, during a cross-adapter review pass: a ghost
   recreated during a peer's own zone transition could go permanently invisible, because it
   inherited a disabled sprite-renderer field from the live character at clone time.
9. Added a marker on TEVI's own pause-screen map showing where the other player is, gated by
   the local player's own fog-of-war so it doesn't leak undiscovered rooms. (6.7)
10. Gave ghosts the afterimage trail — the blue one a quickdrop leaves. TEVI decides each frame
    whether to trail, from three values it exposes publicly, so the adapter reads the same three
    and mirrors that *decision* rather than listing moves; every move using the system works at
    once. (2026-08-28)
11. Made warp devices wake up for a ghost, the animation only. The game's own trigger would have
    done it for free, but it also autosaves and heals — so the visual is driven from the flag its
    `Update` reads instead, and nothing else fires. (2026-08-28)
12. Gave ghosts the charged attack's effects. Three name-guesses failed, so a probe was written
    that reports the prefab the game itself spawns; it named them immediately. The ghost also holds
    on the impact frame now, which needed the clip's PHASE synced, not just its name. (2026-08-28)
13. Stopped sending what a ghost can derive for itself. The animation phase was the one field TEVI
    sent that changes every frame by construction — an idle is a looping clip — and it alone kept
    the core's unchanged-state suppression from ever firing here. It is now left out while the
    current clip loops (attacks and one-shots still carry it), so a standing player's states stop
    going out: 70% of them suppressed, upload down to a third, and the ghost looked identical to
    the user on the netsim rig (2026-08-28, [VERIFIED.md](VERIFIED.md)).
14. Made a portal settle once the last ghost standing in it disconnects. The per-frame mirror in
    step 11 kept a warp device on its "assembling" glow after the peer closed the game, until
    somebody walked on and off it; the disconnect now releases it, watched by the user with two
    real instances (2026-09-02, [VERIFIED.md](VERIFIED.md)).
15. Made the adapter reload inside a running game, so a test stopped costing a launch. BepInEx's
    `ScriptEngine` loads the plugin from `BepInEx/scripts/`, and one script rebuilds, copies and
    fires the reload with no keypress. It leaves no orphan ghost because the plugin's own
    despawn-all path runs on the way out — read from both instances' logs in a two-instance session
    with real peers, not loopback (2026-08-28, [VERIFIED.md](VERIFIED.md)). Everything after this
    step was built against a loop that costs seconds instead of a relaunch.
16. Ran two release instances against each other and left them alone. A cold launch brings up two
    cores on their own ports with no configuration and no port churn, and when the relay is stopped
    underneath them both ghosts come back without anyone touching anything (2026-08-28,
    [VERIFIED.md](VERIFIED.md)). This is the first check that used the release files rather than
    the dev scripts.
17. Chose the shipped interpolation delay by climbing a ladder rather than guessing. On an
    ocean-tier link 300ms was the first rung with room for one lost sample at 15Hz — 175ms
    stuttered constantly, 250ms still had holes — and it ships. On the worst case the rig can
    make (NA↔EU ping plus bad wifi) TEVI wants 450ms, which was measured and deliberately **not**
    shipped: that call waits until all four games have their number (2026-09-02, ADR 0046,
    [VERIFIED.md](VERIFIED.md)).
18. Mirrored what a peer's character carries with it, in one evening and one piece at a time: the
    two orbitars wearing the peer's own look, their crystal trail, the dodge afterimage fade, core
    expansions (the summoned humanoid, its trail out and back), and the boost shield with its two
    platforms. Two lessons paid for the rest. A clone of a component the game parks INACTIVE is
    born with `Awake` unrun, so its first call threw and the exception aborted the whole ghost
    update — pose, facing and trail with it — which is why **every cosmetic sub-feature is now
    walled in its own try/catch**. And a shader keyword the game strips from its template meant the
    barrier popped instead of blooming: the clone built its materials from the already-stripped
    copy. The timing probe showing the fade starting on the peer's beat is what pointed away from
    timing and at rendering (2026-09-10, [VERIFIED.md](VERIFIED.md)).
19. Gave a peer's projectiles to their ghost — a good state, not a finished one. Shots appear,
    travel, and die where the peer's died: a death is the frame the bullet **stops**, not the frame
    its pool slot frees, and it carries where it stopped; the watcher runs the game's own wall test
    locally so a hit lands with no wire delay. The one that took longest had nothing to do with the
    adapter's logic — the two installs are different TEVI builds, so an enum ordinal meant a
    different bullet on each side and a red orb shot blue rings. The game's own enum **names** ride
    the wire now. Running the game's own bullet behaviour on a ghost is off for good: it damaged
    the watcher. Still unmirrored, and listed rather than claimed: several projectile types and
    their VFX ([UNVERIFIED.md](UNVERIFIED.md)) (2026-09-10, [VERIFIED.md](VERIFIED.md)).

### Further work past "good enough"

- A per-remote redraw trace (position/active-state/scene, throttled to once every 2s per
  remote) was added in `Plugin.cs`'s `UpsertRemoteGhost` while chasing the zone-transition
  invisible-ghost bug in item 8 above. That bug is root-caused and fixed, so the trace is now
  gated behind `DIAG_REDRAW_TRACE` (default `false`) — flip it on only when chasing a similar
  live repro.
- **Closed 2026-08-28:** the charged-attack VFX gap found live on 2026-08-15. The effects turned
  out not to parent to the character at all, which is why watching its hierarchy found nothing; they
  come from the game's shared effect POOL, and a probe that reports the prefab name found them at
  once. See [VERIFIED.md](VERIFIED.md). Whether it is truly 1:1 was never settled and the residuals
  are listed in [UNVERIFIED.md](UNVERIFIED.md).
