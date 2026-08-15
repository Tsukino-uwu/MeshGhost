# Ideas — unscheduled feature backlog

This file is deliberately **not** `plans.md`. `plans.md` is the roadmap: what's committed,
in progress, or done. This file is the opposite — things worth doing someday, researched enough
to act on when picked, not committed to any phase. Nothing here is scheduled until it's moved
into `plans.md`.

Every entry states its tier on the depth ladder (`plans.md`'s "Depth beyond the cosmetic ghost"
section), what it needs, what it risks, and whether it's blocked. Two entries below (Emerald's
Union Room question, TEVI's ghost collision) got a first real investigation pass — see their
own sections.

---

## TEVI — cosmetic / presence (Tier 1, no memory writes)

1. **HUD minimap marker.** The natural sequel to the pause-menu `FullMap` peer marker (Phase
   6.7, shipped and live-verified). `MiniMapDisp` — the always-on HUD minimap, as opposed to the
   full-screen pause map — was investigated during 6.7 and explicitly not built
   (`agent_docs/phases/phase6.md:195-199`). Likely the highest feel-per-effort item on this
   list, since it's visible during normal play rather than only while the map is open.

2. **Bug: the FullMap marker is update-driven, not frame-driven.** `UpdateRemoteMapMarker`
   (`adapters/tevi/MeshGhostTevi/Plugin.cs:179-239`) only runs from inside `UpsertRemoteGhost`,
   which only fires when a `render_remote` arrives (`Plugin.cs:406`). If a peer's state stops
   arriving while the local player has the map open, the marker doesn't hide or refresh — it
   just sits wherever it was, stale, until the next `render_remote`. Real bug in shipped code,
   not a hypothetical.

3. **Nameplates.** Genuinely blocked, not just unbuilt. `Hello.DisplayName` reaches the relay
   (`internal/protocol/protocol.go:83`, sourced from `config.json`'s `"name"`) and is only
   *logged* there (`internal/relay/relay.go:295`, `:537`) — never redistributed. `Welcome.Roster`
   is `[]string` of ids (`protocol.go:107-110`); `Join` carries only `player_id` (+ optional,
   never-populated `State`). **No adapter can learn any peer's display name today.** Two routes:
   a roster/`join` shape revision to actually carry `display_name` (correct, needs an ADR per
   `contract.md:3-5`), or smuggling it through `extras` (cheap, but the wrong layer — `extras`
   is per-state free-form data, not identity). `internal/README.md:79` currently overstates this
   ("chosen `display_name`") — corrected as part of this pass, see below.

4. **Per-remote appearance.** Every ghost is a clone of the *local* player's own
   `spranim_prefer.pixel.gameObject` (`Plugin.cs:258-263, 265-321`) — there is only one
   template, the local character. Two peers on different characters/costumes both render as
   whatever the *viewer's* own character looks like. Needs a real per-character visual source,
   not just a config toggle.

5. **Ghost depth sorting.** Ghost z is hardcoded to `0` (`Plugin.cs:364`) with no sorting-layer
   handling against TEVI's own render layers — currently invisible only because it hasn't
   collided with a real layering bug yet.

6. **Config surface.** Exactly one `BepInEx.Configuration.ConfigFile.Bind` call exists in the
   whole adapter (`BridgePort`, `Plugin.cs:435-441`) — read once at `Awake`, no live re-read.
   Any future toggle (map marker on/off, ghost opacity, nameplates, verbose logging, the
   collision experiment below) needs this pattern established for real, not assumed. Do this
   with whichever toggle ships first, not speculatively ahead of time.

7. **Emotes / chat / area-entry pings.** Tier 1 per the depth ladder, and explicitly sanctioned
   as possible and write-free — but the right home is the **reserved `event` plane**
   (`contract.md:152-198`), not new `state` fields. `contract.md:163-165` states plainly that
   the state plane "does not grow new fields for deeper features," and it's lossy/latest-wins —
   a one-shot emote sent as `state` would either never arrive or repeat every tick until
   overwritten. Building the event plane for real is its own scoped piece of work: relay
   `to`-routing (already shaped for it per `contract.md:188-192`), a real `MaxEventBytes` limit
   (currently just a reserved line in `contract.md:373`), new bridge message types each
   direction, and the first real population of `Hello.Features`.

## TEVI — interaction ("test what's possible", scope stays visual-only)

8. **Opt-in ghost collision.** See "TEVI: ghost collision investigation" below.

## Emerald

9. **Union Room / spawn-based rendering instead of overlay drawing.** See "Emerald: Union Room
   decomp investigation" below — first real research pass done, with a clear recommendation.

10. **Seamless adjacent-map ghosts.** A ghost standing in a visually contiguous connected
    route/town simply isn't drawn — any different `area_id` is treated identically, seamless
    connection or not (`plans.md:167-174`). Would need real `pokeemerald` map-connection offset
    data (new, currently unverified addresses) and an extended screen-position formula near the
    boundary. Adapter-side only; doesn't touch the core's `area_id`-opaque rule.

    **Checked whether Archipelago's `worlds/pokemon_emerald/` data could shortcut this —
    real data, wrong shape.** `groups.py`'s `_LOCATION_GROUP_MAPS` (472 `MAP_*` constants across
    ~72 named groups, comprehensive — every route, town, dungeon) groups a place with its own
    *indoor* sub-locations (`Route 104` includes `MAP_ROUTE104_MR_BRINEYS_HOUSE`), not with its
    physically-*adjacent* outdoor neighbors — `Route 101`/`102`/`103` are each their own separate,
    single-map group. `extracted_data.json`'s per-map entries (checked directly) have encounter
    tables and a warp-table address, nothing about physical adjacency/connection offsets either.
    So this doesn't solve the seamless-route problem above — that still needs real `pokeemerald`
    connection-table data, unfound anywhere so far. **What it does answer, a genuinely different
    and more tractable question**: a same-*place* awareness check (a peer inside a building and
    one standing right outside it, on the same route) — worth as its own separate, much cheaper
    feature (a "friend is nearby" signal, closer to TEVI's map-marker idea than an in-world
    ghost) since it needs no new memory reads at all, just a Lua-side lookup from
    `mapGroup:mapNum` to the `MAP_*` name (derivable from the existing `pokeemerald` checkout)
    into this table. Not scheduled; would be its own idea, not a fix for #10 above.

11. **Bike / surf / ledge-jump poses.** Deferred since Phase 5.5 (`phases/phase5_5.md:32-42`).
    A ghost on a bike or surfing currently renders as an ordinary walking trainer — each has its
    own `graphicsId` in `sPlayerAvatarGfxIds`, unread today.

12. **Archipelago-patched-ROM facing fallback.** Designed but never built
    (`risks.md`, "Archipelago coexistence" entry): derive facing from the position delta between
    consecutive reads as the *only* code path (not a garbage-detection fallback triggered by
    "does this look wrong"), since `gPlayerAvatar`/`gObjectEvents` read as invalidated garbage
    under an `.apemerald` patch while `gSaveBlock1Ptr`-relative position reads stay correct.

13. **Nameplates via `gui.drawText`.** Same protocol blocker as TEVI's #3 above — this is a
    core/contract gap, not per-adapter, so it only needs solving once.

---

## Emerald: Union Room decomp investigation

**Status: investigated, decomp-only, no game/emulator needed. Recommendation: do not pursue
reusing Union Room's own code — the underlying primitives it's built from are usable, but only
via a MeshGhost-authored spawn path that still crosses the no-writes non-goal.**

Every claim below cites a specific file/line in the local `pokeemerald` decomp checkout
(`C:\dev\pokeemerald`, outside the MeshGhost repo — read with the user's explicit go-ahead,
per `CLAUDE.md`'s "ask before touching anything outside `C:\dev\MeshGhost`" rule, and per
`licensing.md`'s already-cleared "facts only, never code" posture for this project). No code
was copied; every fact here is independently re-describable without pokeemerald's own text.

### Q1 — What function spawns a linked player's avatar, and what does it write?

Two genuinely different mechanisms, not one — this is the single most important finding:

- **Group leaders** (up to 8, one per possible incoming link partner) are real `ObjectEvent`s.
  `CreateUnionRoomPlayerObjectEvent` (`src/union_room_player_avatar.c:174-177`) calls
  `TrySpawnObjectEvent(sUnionRoomLocalIds[leaderId], mapNum, mapGroup)` — a real, generic
  engine function (`src/event_object_movement.c:1530-1541`), not Union-Room-specific.
- **Group members** (up to 4 more per leader's group, `MAX_RFU_PLAYERS - 1`) are **not** object
  events at all — they're "Virtual Objects", created via `CreateVirtualObject`
  (`event_object_movement.c:1600-1643`). The engine's own comment at `:1595-1599` states this
  plainly: "a class of sprites used instead of a full object event. **Used when more objects
  are needed than the object event limit** (for Contest / Battle Dome audiences and group
  members in Union Room). ... do not have movement types or any of the other data normally
  associated with object events."

So even Union Room's own design had to split into two mechanisms specifically because of the
object event budget — a real constraint this investigation would inherit, see Q2.

### Q2 — How many slots exist, how are they allocated, and what reclaims them?

- `OBJECT_EVENTS_COUNT = 16` (`include/constants/global.h:46`) — the entire live `gObjectEvents`
  array, shared with **every other real NPC already on the current map**. Union Room's 8
  possible leaders alone would claim half of this budget if all spawned at once.
- `TrySpawnObjectEvent` → `InitObjectEventStateFromTemplate` (`event_object_movement.c:1287-`)
  first calls `GetAvailableObjectEventId` (`:1358-1377`), which linearly scans for a free slot
  and fails (returns `OBJECT_EVENTS_COUNT`) if none exists — **a full map silently refuses the
  spawn**, no error beyond a sentinel return value.
- Virtual objects draw from the separate `MAX_SPRITES = 64` sprite pool
  (`include/sprite.h:5`, `CreateSpriteAtEnd` at `event_object_movement.c:1614`) — a different,
  larger budget, but still shared with every other sprite the game itself needs that frame
  (battle UI, menus, field effects).
- Reclamation: `RemoveUnionRoomPlayerObjectEvent`/`DestroyUnionRoomPlayerObjects`
  (`union_room_player_avatar.c:179-182, 378-391`) and `DestroyUnionRoomPlayerSprites`
  (`:408-413`) are explicit, called from `union_room.c`'s own state machine
  (`grep` confirmed call sites at `union_room.c:2500-3034`) when the Union Room session itself
  starts/ends — there is no automatic garbage collection; something has to explicitly free a
  slot.

### Q3 — Does a spawned object get correct z-order/priority automatically?

**Partially confirmed, partially not established by this file.** `CreateVirtualObject` does
call `InitObjectPriorityByElevation`/`SetObjectSubpriorityByElevation`
(`event_object_movement.c:1638-1639`) — the same elevation-based sprite-priority mechanism
every real object event and the player's own sprite use, so correct occlusion against terrain
(behind tall grass, on a bridge, etc.) is genuinely automatic, for free, unlike the current
`gui.drawPixel` overlay which has no z-order concept at all.

**What this does *not* establish**: whether a real object event or virtual object renders
under the pause menu or a dialogue box — the original motivating question. That's a BG/window
priority question (how the menu's own background layer composites against the OBJ layer), a
separate mechanism this file doesn't touch. Not answered here; would need its own targeted
read of the menu/dialogue rendering code before claiming it as a win. Per `CLAUDE.md`, not
asserted from plausibility.

### Q4 — What happens to these avatars on a map transition, battle, or menu open?

Not exercised in this pass beyond confirming the lifecycle is explicit, not automatic (Q2). The
whole Union Room object system is driven by `union_room.c`'s own task state machine, itself
gated on being inside a Union Room activity — so "what happens on an ordinary map transition"
isn't a scenario Union Room's own code needs to handle, since a Union Room session has its own
enter/exit points. Genuinely unanswered; would need separate research if this direction is ever
pursued past today's negative-leaning recommendation (see Q5).

### Q5 — Is any of this reachable without real link/Union state? (the make-or-break question)

**No — confirmed, not just suspected.** Every entry point into `union_room_player_avatar.c`
takes a `struct RfuGameData *`/`struct WirelessLink_URoom *`/`struct RfuPlayerList *`
(`SpawnGroupLeaderAndMembers` at `:496-518`, `UpdateUnionRoomPlayerSprites` at `:528-540`,
`HandleUnionRoomPlayerRefresh` at `:547-551`) — all populated by the game's real RFU (wireless
adapter emulation) receive path, which requires an actual link/wireless session with another
real player. There is no code path in this file that fires from anything else. A single BizHawk
instance with no real link partner would never populate any of this data, so none of it can be
triggered by reading memory alone, and there's no "fake it locally" shortcut visible here.

**This is the real finding, and it changes the shape of the idea**: "reuse Union Room's own
spawning" is not viable — not because it's hard to test, but because the code itself only runs
inside a live RFU session. What *is* viable, in principle, is calling the same lower-level,
Union-Room-agnostic engine primitives directly (`TrySpawnObjectEvent` on a pre-existing map
template, or `CreateVirtualObject`) — which is a MeshGhost-authored spawn mechanism built from
general engine facilities, not "the Union Room feature." That's a meaningfully different, larger
piece of work than "turn on a feature that already exists."

### Q6 — What is the minimum write set for one ghost, and what's the blast radius?

Two sub-answers, because the two spawn mechanisms differ:

- **Via `TrySpawnObjectEvent`**: requires a **pre-existing `ObjectEventTemplate` on the target
  map** — confirmed at `GetObjectEventTemplateByLocalIdAndMap`
  (`event_object_movement.c:2430-2448`), which reads either
  `gSaveBlock1Ptr->objectEventTemplates` or the target map's own ROM header
  (`mapHeader->events->objectEvents`) and looks up by local id. **There is no way to spawn an
  object event whose local id doesn't already exist as a template for that specific map** — this
  mechanism cannot put a ghost on an arbitrary map without either patching every map's own
  template data (the brief's own "decomp ROM hack — cleanest, heaviest" tier,
  `brief.md`'s rendering-approach section) or bypassing the template lookup and writing a
  synthetic `gObjectEvents[]` entry directly.
- **Direct write, bypassing the template system**: `InitObjectEventStateFromTemplate`
  (`event_object_movement.c:1287-1312`, truncated read — more fields likely follow) shows the
  actual field list a from-scratch spawn needs: `active`, `triggerGroundEffectsOnMove`,
  `graphicsId`, `movementType`, `localId`, `mapNum`, `mapGroup`, and the three coordinate pairs
  (`initialCoords`/`currentCoords`/`previousCoords`). This is a modest, enumerable write set —
  comparable in size to what MeshGhost already *reads* today — not an unbounded unknown. That's
  a genuinely encouraging data point for feasibility, separate from whether it should be done.
- **Blast radius**: a slot-selection bug (writing to a live slot already used by a real map NPC)
  would corrupt that NPC's own state, not just the ghost's — `GetAvailableObjectEventId`'s own
  scan logic (`:1358-1377`) would need to be replicated correctly, including its "already
  spawned, do nothing" branch, to avoid this. Any write mistake here is a live-game state bug,
  not a save-file corruption in the strict sense (nothing here touches SRAM), but it's the same
  category of risk `plans.md`'s no-writes non-goal exists to avoid.

### Recommendation

**Do not build a Union-Room-based spawn adapter as currently conceived.** The specific feature
the user was curious about is unreachable outside a live link session (Q5) — that's a clean
negative result, not a dead end from lack of effort. The two underlying *primitives* it exposed
(`TrySpawnObjectEvent` against a pre-placed template, `CreateVirtualObject` for a
lighter-weight sprite with automatic elevation-based z-order) are real and could inform a
different, MeshGhost-authored "spawn a ghost object event" design later — but that is a new
piece of work, gated on the same no-writes-without-an-ADR non-goal every other write feature is
(`plans.md:29-34`), a real Archipelago-coexistence test first (since a write could race
Archipelago's own writes into the same object-event/sprite tables, unlike today's two-readers-
never-race posture), and — per Q3 — still an open question on whether it actually solves the
motivating menu/dialogue-occlusion problem at all. The overlay-drawing approach
(`meshghost_emerald.lua`) remains the right shipping default: it's read-only, it's the one that
demonstrably transfers to other BizHawk games and other Pokémon generations, and its known
gaps (base pause list, NPC dialogue — `verified.md:1028-1041`) are already accepted, documented
trade-offs rather than unknowns.

If this is ever picked back up, start by answering Q3 and Q4 properly (menu/dialogue BG-priority
research, and map-transition/battle behavior for a from-scratch write) before writing any Lua,
since either could independently kill the idea before a single write is attempted.

### Addendum — hijacking an already-live NPC instead of spawning one

A sharper variant of the same idea, raised after the write-up above: instead of spawning a new
object event (blocked without a per-map template, Q1/Q6) or synthesizing one from scratch
(the whole `InitObjectEventStateFromTemplate` field list, Q6), **re-skin an NPC the map has
already spawned** so it looks like and tracks a remote player.

This is meaningfully better-targeted than the from-scratch path:

- The game already implements exactly this operation as one function,
  `ObjectEventSetGraphicsId` (`event_object_movement.c:1820-1845`, by-local-id wrapper at
  `:1859-1865`) — re-skins a **live** object event's sprite shape/size/images/anims/palette in
  place, no respawn, no template lookup, none of the `OBJECT_EVENTS_COUNT=16` spawn-budget
  problem (it doesn't spawn anything new). There's a real precedent for this exact "make an NPC
  look like a specific player" pattern already shipping: `apprentice.c`'s Move Deleter
  minigame uses the 16 `VAR_OBJ_GFX_ID_0`..`_F` vars (one per object-event slot — not a
  coincidence) for live NPC reskinning.
- `MOVEMENT_TYPE_NONE` → the explicit empty callback `MovementType_None`
  (`event_object_movement.c:224`, confirmed as a no-op at `:2563`) means some map NPCs already
  have zero movement AI running. Picking one of those as the hijack target avoids the exact
  tug-of-war Pseudoregalia hit when its ghost and the game's own movement logic both tried to
  drive the same actor (`risks.md`'s auto-possession/drag entries) — nothing here would fight a
  position write every frame, unlike a normally-scripted NPC.

**What this doesn't remove**: `ObjectEventSetGraphicsId` is a *function call*, not a memory
write, and nothing in this project's Emerald work has ever called into the game's own code —
every existing capability is a pure external memory read via BizHawk Lua (no hooking, no code
injection; that's so far a Pseudoregalia/UE4SS-only technique). Getting the same effect would
mean either hand-replicating the function's writes (position/facing are already known-writable;
the palette calls it makes, `PatchObjectPalette`/`LoadSpecialObjectReflectionPalette`, do real
VRAM/palette-slot bookkeeping, not plain field writes — unexplored) or finding some other way to
trigger the real function, which has no precedent in this adapter.

**New risk this path specifically introduces, that the from-scratch path didn't have**:
hijacking a real NPC makes that NPC visibly vanish from its usual spot while a friend's ghost
stands there instead, and its dialogue script is presumably still attached to the same local
ID — interacting with "the ghost" could plausibly trigger the real NPC's own conversation. Not
investigated; would need checking before this path could be called viable even in principle.

**Net assessment**: better-targeted than raw synthesis, but doesn't clear the gate — still a
memory-writing feature needing its own ADR and the Archipelago-coexistence test
(`plans.md:29-34`), and now gated on one more open question: how far a hand-written replication
of `ObjectEventSetGraphicsId` can get without literally calling it.

---

## Emerald: VRAM/sprite injection investigation (draw vs. inject)

**Status: real staged test plan agreed, not started.** A separate idea from Union Room/spawning
above — found while researching a reference project (`GBA-PK-multiplayer`, CC BY-NC 4.0, see
`licensing.md`), which renders remote players by writing sprite pixel data directly into GBA
VRAM tile memory (`emu:write32` on mGBA at a fixed tile-bank address) rather than an overlay,
the middle tier `brief.md` itself names ("OAM injection — composites properly, much fiddlier")
and passed over in favor of today's overlay approach.

**Real risk found, not just theorized**: that reference project's own code comments show the
exact VRAM address needing manual re-tuning across just Ruby/Sapphire vs. FireRed/LeafGreen
("CHANGE AGAIN BACK TO 182 due to ruby/sapphire") — a fixed-address technique already proven
fragile across *vanilla* game versions, before any ROM patch is considered. Cross-referenced
against Archipelago's own `worlds/pokemon_emerald/docs/rom_changes_en.md`: the Union Room
receptionist's sprite was reworked, and the base patch is a full recompile — both plausible,
neither confirmed, collision points for a fixed VRAM assumption. See `risks.md`'s Archipelago
entry for the full citation trail, including the previously-undocumented finding that even
today's *shipping* draw-based sprite decode (`gObjectEventPic_Brendan*`/`May*`, fixed ROM
addresses) has never actually been checked against a patched ROM either.

**Staged test plan (agreed; Stage 1 script written 2026-08-14, not yet run)** — read-only
first, following this project's own "staged probe ladder must include sustained real traffic"
lesson (`pitfalls.md`, from the Pseudoregalia LuaSocket saga, where a light one-shot test
passed and a real corruption bug wasn't found until sustained traffic later):

1. Read-only probe of OBJ VRAM through normal vanilla play (walking, battle, menus) — is any
   of it actually free when we'd need it? **Correction, found while scoping the probe: there
   is no "the target VRAM region" to check here — no concrete VRAM/OAM/tile-bank address
   exists anywhere in this repo, only the opaque "182" quoted below from a project that isn't
   cloned locally.** Stage 1's real job is to *discover* a candidate free region empirically
   (cross-checked against the game's own sprite-tile allocator bookkeeping), not to verify a
   guessed one — see `adapters/pokemon/emerald/vram_probe.lua`.
2. Same probe, on a real `.apemerald`-patched ROM — does the patch touch whatever region Stage
   1 found?
3. First real write: one static test sprite, vanilla only, easily reversible.
4. Same write, patched ROM — the step that actually answers the Archipelago question with
   evidence instead of inference.
5. Repeat 3–4 under sustained real traffic (continuous position/anim updates), not a single
   static frame — a one-shot pass is not sufficient per the lesson above.

**Shipping shape, target state — decided 2026-08-14**: two separate scripts, not a mode flag in
one — the same "second script, clearly marked" pattern already scoped for the Union Room/spawn
idea above. **If injection clears every stage of the test plan and genuinely gives a better
result** (correct occlusion under menus/dialogue, the actual motivation for this whole
investigation), **it becomes the default**, with drawing kept as the fallback/compatibility
option — not the other way around. That's contingent, not decided in advance: the test plan
could also show injection is fine on vanilla but not safe under Archipelago (then it'd likely be
an opt-in for vanilla-only players rather than a blanket default), or that it's bad outright, in
which case it's dropped entirely rather than kept around as a permanent second option nobody
should use. **Today, before any stage of the test plan has run, drawing is simply the only
option that exists and works** — that's a fact about the current state, not a standing
preference for drawing over injection. Two real costs to plan for once both scripts exist,
regardless of which ends up default:

- **Sharing code between them is genuinely awkward in BizHawk, not just a style question.**
  Scripts load as in-memory string chunks, not files (`pitfalls.md`) — the existing script
  already needed an `io.popen("cd")` workaround just to find its own directory, since
  `debug.getinfo` can't. A `require`'d shared module would need the same workaround engineered
  around it. The more likely real answer is duplicating the read/send logic across both files,
  which means any future fix to that logic (e.g. the still-unbuilt Archipelago facing-fallback
  in `risks.md`) has to land in both, not one — a real ongoing maintenance cost, not a one-time
  fork.
- **Someone has to choose between them, and needs to know why.** v1: a documented manual choice
  at setup (packaging README states plainly which to use with Archipelago), not automatic
  detection — auto-detecting "is this an Archipelago ROM" would itself need a fixed-address
  check, exactly the kind of fragile assumption this whole investigation is about. Worth
  reconsidering only after the manual version has shipped and been used for a while.

---

## TEVI: ghost collision investigation

**Status: not yet started.** Scoped in the plan this backlog was written alongside — see the
"TEVI collision" deliverable there. Short version: user opted for an ADR-gated, default-off
BepInEx toggle, tested via a five-question live safety protocol on a backed-up save (can the
player damage the ghost, can the ghost damage the player, does the ghost actually block
movement, does it trigger hazards/room transitions, does it survive a zone transition) — not
implemented yet. TEVI's ghost clone carries no `CharacterBase` gameplay logic at all (unlike
Pseudoregalia's ghost, which *was* a second live instance of the player's own controllable
class and could kill the real player when attacked, `risks.md`'s ghost-collision entries) —
a reasoned expectation that TEVI is safer ground, explicitly not a safety claim until the
protocol above is actually run and watched.

## Pseudoregalia

0. **~~Fully visually track the thrown Dream Breaker, hand → flight → ground → pickup.~~ DONE
   2026-08-15 — built and confirmed live at the FULL scope**, not the MVP cut point this entry also
   offered: continuous position/rotation sync through flight and wall bounces, the resting pose, and
   the landed sword's glow ring. See `agent_docs/verified.md`'s "thrown Dream Breaker" entry for the
   measurements and the two wrong turns, and `PLAYER_FIELDS.md` for the fields involved. Kept here
   as a pointer only; the open follow-on is the empty-hand recall glow (item below), whose blocked
   precondition — a real thrown-weapon actor on the ghost — this work now provides.


1. **Reference project compared: [pseudoregalia-multiplayer](https://github.com/highrow623/pseudoregalia-multiplayer)
   (`highrow623`), MIT-licensed** (license confirmed 2026-08-14, source read 2026-08-15 — see
   `licensing.md`). Another Pseudoregalia co-op mod, same problem space as Phase 7. Same modding
   tool (UE4SS) and same overall shape as us — a compiled C++ UE4SS client mod, not Lua — so this
   is an apples-to-apples architecture comparison on that axis, not a maturity gap.

   **More established than this project's Pseudoregalia work, genuinely** — not just an
   alpha-label wash. Real tagged releases (v0.1.0 through v0.2.2), an outside contributor (name
   tags landed via a community PR, not just the original author), and — per the user, who saw a
   YouTube video of it in actual use 2026-08-15 (not independently verified by this project,
   consistent with `CLAUDE.md`'s evidence standard for *our own* claims — this is the user's own
   observation, recorded as such) — real evidence of it working for real players over a real
   network. MeshGhost's own Pseudoregalia adapter has **not** cleared that bar yet: Phase 7.7 (a
   real two-player network test) hasn't been run, so "code-complete" is the accurate status, not
   "confirmed working online." Their last real commit is 2026-03-16 though — inactive, not
   currently being iterated on, which is a different axis from "has it ever worked."

   **Not actually behind on animation** — their `docs/todo.md` has animation sync as an open
   "animations??" question with three unexplored options; this project's own Pseudoregalia
   ghost already has real movement-animation sync, including specific fixes for the
   falling-stuck and ledge-hang animation bugs (Phase 7.6, `adapters/pseudoregalia/README.md`
   steps 13/16/17), all live-verified. The real open gap on our side is narrower — ability
   **VFX**, not animation: the cling-gem effect and empty-hand sword-glow don't render on the
   ghost (`status.md`, found live 2026-08-15, not yet root-caused) — plus TEVI has an analogous
   charged-attack VFX gap. Neither project has this solved; it's just not the same gap their
   `todo.md` names.

   **Worth stealing as an idea:** their ghost is a real Blueprint-authored actor
   (`Content/Mods/PseudoregaliaMultiplayerMod/BP_PM_Ghost.uasset`) with a per-player configurable
   color and a name tag above the head — visibly nicer than this project's current ghost, which
   has neither. (Our ghost is spawned fresh as a clone of the player's own pawn class, not a
   hijacked level actor — `SPAWN_BASED_GHOSTS = true`, `Plugin.cpp:78/1078-1084`; a hijack
   fallback exists in code but is dead, unused.) Their C++ side does no actor work at all — it
   only bridges data into a hand-authored Blueprint (`BP_PM_Manager_C`/`BP_PM_Ghost_C`) that owns
   spawning, confirmed by reading `dllmain.cpp`/`Client.hpp` directly — which is *why* they never
   needed camera-fightback or auto-possess fixes: their ghost was never a live instance of the
   real playable class to begin with. If Pseudoregalia ghost visuals get revisited, a custom
   Blueprint ghost actor (color + nametag, MeshGhost-authored, no asset copying per
   `licensing.md`) is the concrete thing to build toward — at the real cost of standing up an
   Unreal Editor content pipeline this project doesn't currently have.

   **Worth noting as a real trade, not a clean win either way:** their client↔server protocol
   splits into a WebSocket channel (JSON, low-frequency: connect/join/leave) plus a separate raw
   UDP channel (packed binary, per-frame position/rotation) — `docs/application-protocol.md`
   calls this split "admittedly kinda lazy" and says they'd like to go UDP-only eventually.
   MeshGhost's single TCP/NDJSON channel sidesteps the dual-channel complexity, but the tradeoff
   cuts both ways, not just in our favor:

   | | UDP (theirs, state channel) | TCP (ours, single channel) |
   |---|---|---|
   | Packet loss | Drops the one stale update, moves on — next update just arrives | Head-of-line blocking: a lost packet stalls every *newer* packet queued behind it until it's retransmitted |
   | Effect on a ghost, in practice | Smooth degradation — an occasional skipped position, easy to miss | Freezes, then jumps to catch up once the resend lands — worse-looking under the same loss rate |
   | Forgeable packets | Yes — no delivery guarantee to build auth on top of (their `todo.md` flags this, wants HMAC) | No — TCP's own connection state plus our `room_code`/relay checks apply uniformly |
   | Complexity | Two channels, two message shapes to keep in sync | One channel, one schema (`contract.md`) |
   | Player-count ceiling | Real one, tied to fitting all updates in one UDP packet (22) | None inherent to the transport |
   | Implementation/debugging cost | Packed binary, harder to eyeball on the wire | Plain JSON, greppable/typeable over `netcat` (`contract.md`'s own stated reason for choosing it) |

   Net: their UDP-for-state instinct is the conventionally correct one for real-time position
   data — dropping a stale update beats delaying a fresh one, which is exactly what a
   latency-sensitive cosmetic overlay wants. Their actual cost was needing a *second* channel
   (WebSocket) to regain reliability for join/leave. Our TCP choice buys simplicity, no
   dual-channel complexity, no packet-size player cap, and no forgeable-packet risk, in
   exchange for worse degradation specifically under real packet loss (jitter, poor wifi, a
   flaky connection) — a genuine trade against a genuine cost, not a design flaw on their side
   or a free win on ours. Reasonable to leave as-is at MeshGhost's current scale (small
   friend-hosted rooms, `interp` buffering already absorbing normal jitter per the release
   README) — worth revisiting only if real testing surfaces a lossy-connection freeze/jump
   pattern the interpolation buffer doesn't hide.

   **Setup/hosting: ours is documented as simpler, unproven whether that holds for a real
   novice.** Their client install branches into three paths depending on existing UE4SS state,
   two of which recommend a full uninstall/delete/reinstall of the game folder to dodge a version
   conflict (`installing-the-mod.md`) — ours is one step (drag the release folder onto the Steam
   install) because every release vendors its own pinned UE4SS build (`licensing.md`'s RE-UE4SS
   entry), so there's no existing-version conflict to have. Their only documented server-hosting
   path is a full AWS EC2 walkthrough (security groups, SSH keys, manual `wget`); ours is
   "double-click the exe," provider-agnostic. This is a comparison of written instructions, not
   of real first-time users succeeding — see the maturity note above for why their project is
   still ahead on the metric that actually matters most (real people playing it over a network).

   **Not comparable / not adopted:** their server is Rust (ours is Go — language choice, not a
   capability gap); their UDP wire format is packed binary with a hard 22-player cap tied to
   fitting one packet, which MeshGhost's TCP framing has no equivalent constraint for; nothing
   in their docs mentions rate limiting, room auth, or bounded-read hardening, which this
   project already has (`contract.md`'s Limits section) — not raised as a critique of their
   project, just not a place to look for ideas.

2. **Sync the trail (afterimage) color.** Raised by the user (2026-08-15) while investigating the
   base slide/ultra-hop trail effect itself (see `PLAYER_FIELDS.md`'s trail-VFX entry —
   `Spawn After Image(Duration: float)` found on the pawn, base trail sync not yet built).
   **Rescoped 2026-08-15, same day**: originally thought this needed reflecting into a
   third-party mod's own class (the
   [attire-ui-overhaul](https://github.com/pseudoregalia-modding/attire-ui-overhaul) mod exposes
   an in-game color picker for it, `UI_DashColourSelector`/`DashDataLib` — see `licensing.md`),
   but strings-scanning that mod's own `.uasset` binaries (facts-only, per its "no license"
   posture in `licensing.md`) showed its `SetDashColour`/`SetRandomDashColour` functions cast the
   player to `BP_PlayerGoatMain_C` — the exact same base-game pawn class this adapter already
   reflects — and write to a field it calls `afterimageColor`. **Confirmed live the same session**:
   `afterimageColor` (a `StructProperty`, almost certainly `FLinearColor`) is genuinely present in
   this session's own `OBJECT_REFLECTION_DUMP` capture, on the local pawn. So this is **not**
   third-party-mod-dependent state after all — it's a plain first-party pawn property, syncable
   the same shape as `weaponEquipped?` (read `FLinearColor`, send, apply to the ghost's own pawn),
   with zero dependency on the other player having that color-picker mod installed; a default
   color presumably exists even without it. Still genuinely blocked on the base trail effect
   (`Spawn After Image`) actually working on the ghost first, and the exact `FLinearColor` value
   hasn't been read live yet (property confirmed to exist, not confirmed to read/write correctly)
   — not investigated further, not scheduled.

3. **Design principle: let the ghost's own pawn logic do the work; only trigger it.** Raised by the
   user 2026-08-15 after the trail-VFX saga: "we are literally using the player model that is able
   to do everything ... we just need to allow things to start/actually trigger and it should already
   be doing everything else on its own." This is well-grounded, not speculative — the Pseudoregalia
   ghost is a real `BP_PlayerGoatMain_C` instance (`SPAWN_BASED_GHOSTS`), so it carries the full
   AnimBP, movement component, ability logic, and VFX systems the real player has.

   **Direct evidence it's already true**: the Dream Breaker weapon-visibility saga
   (`verified.md`, five entries) ended with the finding that the ghost had been matching weapon
   *and* outfit state correctly since spawning was first built, **before any sync code for either
   existed** — because it's constructed from the same class reading the same local save data. Five
   fix attempts chased a sync path that was never the lever. The camera fight-back and the
   deliberate collision disable are the same fact seen from the other side: those exist precisely
   *because* the ghost is fully alive and does everything a player pawn does unless stopped.

   **The boundary that makes this a principle rather than a blanket rule: cosmetic/animation
   systems yes, movement authority no.** The ghost's position must come from the network, so
   anything that starts its own movement logic puts it in a fight with the per-tick position
   writes — the exact class of bug `register_camera_fightback_hook` exists to solve. So: prefer
   triggering the pawn's own system over reimplementing its behavior, but never hand it authority
   over where it is.

   **SILENCE CLAUSE, 2026-08-15**: triggering the pawn's own systems gets you its AUDIO for free
   too, whether you want it or not — and you generally don't. The cling-gem trigger started a
   looping wall-ride sound on the ghost that kept playing after the peer left the wall. User's
   call, and it matches the project's own premise (MeshGhost is a *visual*-only layer): **ghosts
   should be silent.** A peer's ability sounds coming from across the room are noise, and they
   multiply with player count. Suppress the audio component immediately after the call that starts
   it, not on the way out, so it never becomes audible. Applies to every future ability trigger,
   not just this one.

   **PRECONDITION CLAUSE, learned the hard way 2026-08-15** — this principle is not unconditional.
   Triggering the pawn's own system only works when that system's own preconditions are satisfied
   by state we can actually write. The afterimage trail worked because its only precondition was
   `afterImagesToSpawn`, a plain int. The empty-hand recall glow (`manageRecallIdleFX`) failed
   live: its internal `IsValid` guards most plausibly require `weaponRef`, a reference to the real
   thrown-weapon *actor*, which the ghost has no equivalent of. Cling-gem is expected to fail the
   same structural way (`wallRideHit` needs real geometry contact; the ghost's collision is
   deliberately disabled). **So the useful triage question is not "which function do I call?" but
   "what state does that function read, and can I write it?"** See `verified.md`'s
   "`manageRecallIdleFX`: NEGATIVE" entry.

   **Where this would concretely apply next** (none scheduled): (a) the trail-VFX trigger's
   turn-around false positive — a heuristic guess at *when* to fire disappears by construction if
   the pawn's own ability start is what fires it, though the movement-authority tension above has
   to be solved first; (b) trail color (item 2 above) may partly self-solve, since a spawn-time
   clone would already carry the *local* player's chosen color — correct whenever both players use
   the default, wrong only when they differ, which is cheap to check live before building sync;
   (c) any future ability VFX (cling-gem sparkle, empty-hand glow) should start by asking "what
   does the pawn already do on its own, and what minimal trigger starts it?" before writing
   mirroring code. **Caveat worth carrying**: `agent_docs/verified.md`'s "trail-VFX UFunction hook"
   entry is a real limit on how this can be implemented — Blueprint-function hooks crash this
   build, so "trigger the pawn's own system" has to be done via property writes or direct
   `ProcessEvent` calls, not by intercepting the game's own calls.

4. **Custom feature: per-peer distinct ghost trail colours.** User's own idea (2026-08-15), raised
   the moment the trail-colour write was confirmed working: since `afterimageColor` can be written
   to any arbitrary value on a ghost (proven live — a forced magenta trail rendered correctly while
   the real player's stayed yellow, see `verified.md`), MeshGhost could deliberately assign each
   remote peer its own distinct trail colour so players are visually tellable apart at a glance in
   a multi-peer room.

   **Why this is cheap**: the whole mechanism already exists and is confirmed — the diagnostic
   override built to prove the write path (`AFTERIMAGE_COLOR_TEST_OVERRIDE`) is essentially this
   feature already, just with one hardcoded colour instead of a per-peer one. The remaining work is
   deciding *where the colour comes from*, not whether it can be applied.

   **Design tension to settle first, because it cuts against the project's core contract**:
   MeshGhost's whole premise is showing what the other player *actually* looks like — a deliberately
   wrong colour is the opposite of faithful mirroring. So this should be an explicit opt-in, not a
   default, and the natural shape is a config toggle ("distinguish peers by colour") that overrides
   the synced value only when enabled. Related open question: whether the colour is picked locally
   (each client colours its own ghosts, so two players disagree about who is which colour) or
   assigned by the relay (consistent for everyone, but that's identity data the relay doesn't carry
   today — the same gap `nameplates` hits, see the TEVI section's item 3).

   **Sits alongside the existing "worth stealing" note** about `pseudoregalia-multiplayer`'s
   per-player configurable ghost colour + nametag (item 1 above) — that project chose per-player
   colour as a real feature, which is independent corroboration this is worth having. Not scheduled.

5. **Custom feature: ghost collision as an opt-in "accidental PvP" toggle.** User's idea
   (2026-08-15) after re-enabling `GHOST_COLLISION_ENABLED` for the cling-gem investigation and
   finding it well-behaved in practice — "its not pushing/pulling me, I think we can actually leave
   it on as a feature, intentional optional pvp~ kinda". Fits MeshGhost's cosmetic-first premise
   surprisingly well: the ghost doesn't push the player around, so enabling collision adds a
   playful physical presence without breaking anyone's run by shoving them off a ledge.

   **DECIDED 2026-08-15: kept ON.** `GHOST_COLLISION_ENABLED = true` is now a deliberate feature,
   not a test flag — the user's call, on the reasoning that co-op players won't swing at each other
   by accident and the added physicality is worth it.

   **Accepted residual risk, NOT fixed — and one fix attempt has already FAILED**: the 2026-08-13
   melee-death bug is unchanged. Setting `bCanBeDamaged = false` on the ghost was tried 2026-08-15
   and did not stop it, despite the write provably landing (see `verified.md`) — this game's melee
   doesn't use UE's standard damage path, so the engine-level gate has no authority over it. A real
   fix must target whatever bespoke overlap/trace check the game's melee actually runs, which is
   still unidentified. Deliberate player-on-ghost melee is judged an acceptable, unlikely footgun. **The genuinely untested vector is non-player damage**:
   an enemy attack, AoE, or environmental hazard hitting the ghost was never tried, and the ghost
   stands in the world where enemies fight. If a player ever dies for no visible reason near a
   ghost, this is the first thing to check. The real fix, if it's ever wanted, is making the ghost
   collidable-but-unhittable — no response on whatever channel the damage/weapon trace queries
   (still unidentified per `GHOST_COLLISION_ENABLED`'s own comment).

   **Found dangerous, then FIXED, 2026-08-15 — the feature now stands on its own.** The untested
   vector flagged here (enemy damage) turned out to be real and run-ending: an enemy hitting a ghost
   hurt and could kill the real player, during ordinary play, with no visible cause. Fixed by
   changing the ghost capsule's collision OBJECT TYPE to `ECC_WorldDynamic` instead of `ECC_Pawn`,
   so enemy targeting (which queries the Pawn channel) never sees it. **Confirmed live: the ghost
   takes no enemy damage and can physically shove enemies around** — the physical presence that
   made this worth having is fully intact. Remaining and unchanged: a player can still deliberately
   attack a ghost and take damage, which is the controllable footgun already judged acceptable. See
   `verified.md`'s enemy-damage entry, including the fallback (`activateGuardFrames`) if the
   player-melee case is ever worth closing too.

   **PARTLY ANSWERED 2026-08-15, and the answer is bad**: the concern below was tested by setting
   `LOOPBACK_GHOST_OFFSET_X` to 0 so the ghost overlapped the player. It **immediately reproduced
   the original Phase 7.4 drag/pull bug** — the ghost physically shoves the real player around.
   User: "its dragging/pulling me ... unsafe/should never be enabled." Reverted at once.

   **IMPORTANT SCOPING CORRECTION, same day** — an earlier version of this entry concluded from
   that test that "real peers will shove each other," which **overstated it**. The user's push-back
   was correct: loopback-with-zero-offset is a *pathological* case, not a representative one. The
   ghost is teleported to the player's EXACT position every tick, so the physics engine can never
   resolve the overlap and keeps re-resolving it frame after frame — that is what produces the
   violent continuous drag. Two real peers would at worst partially overlap occasionally and be
   pushed apart once, which is ordinary multiplayer behaviour, not a bug.

   **What remains genuinely unknown** (much narrower than the original claim): whether occasional
   real-peer contact — landing on someone, or crowding the same ledge — pushes hard enough to
   matter in a precision platformer. That is a judgement call needing a real two-player test, not a
   loopback one, and it is *not* a reason to hold the feature by itself. If it ever does prove to
   be a problem, the fix direction is making the ghost block the world but NOT the player's own
   capsule — the reverse of the original `SetCollisionResponseToChannel(Pawn, Block)` attempt,
   which was trying to make it MORE solid to pawns.

   **Standing rule from this**: never test collision behaviour with `LOOPBACK_GHOST_OFFSET_X = 0`.
   It reproduces the Phase 7.4 drag bug by construction and tells you nothing about real peers.

   **USER'S POSITION, 2026-08-15 — decision deliberately DEFERRED, feature not axed**: "a small
   push/actual collision between players and ghosts might be fine. but this does need proper 2 real
   players/online testing before i say yay/nay about axing the collision feature itself." So the
   feature stays ON as-is for now, and the yes/no decision is explicitly gated on a real
   two-player session — **not** on any further loopback result, which cannot answer it. This makes
   Phase 7.7 (the never-yet-run real two-player test, see `status.md`) the blocking item for this
   feature, alongside everything else it already gates. Do not re-open this question from loopback
   evidence.

## Links

- `agent_docs/plans.md` — the roadmap; move an idea here (with a phase number) once it's picked.
- `agent_docs/architecture.md` — where an ADR for any write-crossing or scope-crossing idea here
  would go.
- `agent_docs/risks.md` — Pseudoregalia's full ghost-collision incident history, required
  reading before touching TEVI's collision idea.
- `agent_docs/contract.md` — the event plane's reserved design, needed before emotes/chat/pings.
