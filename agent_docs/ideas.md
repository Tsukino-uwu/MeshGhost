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
   (`adapters/tevi/MeshGhostTevi/Plugin.cs:195`) only runs from inside `UpsertRemoteGhost`,
   which only fires when a `render_remote` arrives (`Plugin.cs:339`, invoked from `DrainInto`). If a peer's state stops
   arriving while the local player has the map open, the marker doesn't hide or refresh — it
   just sits wherever it was, stale, until the next `render_remote`. Real bug in shipped code,
   not a hypothetical.

3. **Nameplates.** Genuinely blocked, not just unbuilt. `Hello.DisplayName` reaches the relay
   (`internal/protocol/protocol.go:89`, sourced from `config.json`'s `"name"`) and is only
   *logged* there (`internal/relay/relay.go:433`, `:706`) — never redistributed. `Welcome.Roster`
   is `[]string` of ids (`protocol.go:125`); `Join` carries only `player_id` (+ optional,
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

5. **Ghost depth sorting.** Ghost z is hardcoded to `0` (`Plugin.cs:371`, `:398`) with no sorting-layer
   handling against TEVI's own render layers — currently invisible only because it hasn't
   collided with a real layering bug yet.

6. **Config surface.** Exactly one `BepInEx.Configuration.ConfigFile.Bind` call exists in the
   whole adapter (`BridgePort`, `Plugin.cs:471-472`) — read once at `Awake`, no live re-read.
   Any future toggle (map marker on/off, ghost opacity, nameplates, verbose logging, the
   collision experiment below) needs this pattern established for real, not assumed. Do this
   with whichever toggle ships first, not speculatively ahead of time.

7. **Emotes / chat / area-entry pings.** Tier 1 per the depth ladder, and explicitly sanctioned
   as possible and write-free — but the right home is the **reserved `event` plane**
   (`contract.md`'s "Extensibility — the event plane" section, from `:193`), not new `state`
   fields. `contract.md:201-203` states plainly that
   the state plane "does not grow new fields for deeper features," and it's lossy/latest-wins —
   a one-shot emote sent as `state` would either never arrive or repeat every tick until
   overwritten. Building the event plane for real is its own scoped piece of work: relay
   `to`-routing (already shaped for it per `contract.md:212`), a real `MaxEventBytes` limit
   (currently just a reserved line in `contract.md:443`), new bridge message types each
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

**Status: Stage 1 ran 2026-08-14; Stages 2–5 not started.** A separate idea from Union Room/spawning
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

**Staged test plan. Stage 1 was written AND run 2026-08-14** — real user sessions, findings
written up in `agent_docs/environment.md`'s BizHawk section (a `VRAM` domain does exist on this
core; `memory.hash_region` is documented in the DLL but is `nil` at runtime, so the probe fell
back to its sampled tier; `getmemorydomainlist()` returns a table, not the newline-delimited
string its own doc string claims). Stages 2–5 remain unstarted. The plan is read-only
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
   **VFX**, not animation — and the two this entry named on 2026-08-15, the cling-gem effect
   and the empty-hand sword glow, **have since been closed** (`adapters/pseudoregalia/README.md`
   steps 25 and 35, both confirmed live). The remaining analogous gap is TEVI's charged-attack
   VFX. Either way, it isn't the gap their `todo.md` names.

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
   color presumably exists even without it. **DONE — this shipped.** Trail colour sync, modded
   colours included, is README step 26; the ultra hop's separate blue trail, which this entry did
   not anticipate, took steps 36–41 and is the hardest work in the adapter. `verified.md` records
   player and ghost as indistinguishable, trailing and not trailing alike. Kept here as the
   research trail that got there, not as an open idea. See
   `agent_docs/effect-investigation.md` for the full investigation.

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

6. **Custom feature: build cosmetic features out of the game's own VFX catalog.** User's idea
   (2026-08-15), raised while watching the `VFX_CATALOG_PROBE` cycle: "we could use these to make
   cool/custom things happen elsewhere later right?"

   **What changed to make this real.** Until the thrown Dream Breaker work, every VFX attempt here
   went "guess a function or property name, call it, watch nothing happen" — a long trail of
   negatives (`afterimageColor`, `manageRecallIdleFX`, four hand-picked `WeaponMesh` properties).
   That work proved something different: a Niagara system can be spawned on a ghost from **nothing
   but its asset path**, with no game function and no trigger involved
   (`spawn_niagara_attached`, `verified.md`). The probe then enumerated the whole catalog — **58
   game systems**, named things like `NS_GoldAura`, `NS_WhiteAura1`, `NS_HealWave`, `NS_RockBreak`,
   `NS_WallRide`. So the raw material is a known, addressable list, and the mechanism to play any
   of it on any actor already ships and is confirmed live.

   **Why this is a genuinely different class of feature from what's been built so far.** Everything
   cosmetic to date *mirrors* something the peer is really doing — their animation, their outfit,
   their sword. This would be MeshGhost drawing things the peer's game never drew: a join/leave
   flourish, a per-peer aura for telling ghosts apart at distance (compare idea 4's trail colours,
   which solves the same problem within the mirror-only constraint), an effect on a shared
   milestone. That is still fully inside the visual-only posture — no game memory writes, no shared
   world state, nothing that changes anyone's run — but it is **authored** cosmetics rather than
   mirrored ones, and that distinction should be made deliberately rather than drifted into.

   **Four constraints to design against, all already learned rather than hypothetical:**
   - **Modded assets don't travel.** The probe's `catalog[0]` was `/Game/Mods/CustomVFX/NS_GreenAura`
     — from a mod on this machine, not the base game. Anything built on a modded asset silently
     does nothing for peers without it. The existing spawn path degrades gracefully (warns once,
     throttles the retry), but a feature should prefer base-game assets or treat resolution failure
     as expected.
   - **Names mislead here specifically.** This repo has burned real sessions on `AnimGraphNode_Trail`
     (bone physics, not the trail effect) and on Cling Gem having no "glide" string anywhere. A
     catalog name is a candidate, never an identification — confirm by watching the probe.
   - **On the local player, not just ghosts, is a bigger step.** Spawning effects on someone's own
     character changes their game's appearance, not a ghost overlay. Still visual-only, but it
     deserves an explicit opt-in the way ghost collision did (idea 5), not a default.
   - **Peer-triggered effects would need the event plane.** Cosmetic state that rides along with
     normal sync fits `extras` fine; "player A causes an effect on player B's screen" is a
     bounded, consensual interaction, which is exactly what `contract.md`'s reserved-but-unbuilt
     event plane is for. Don't grow the state plane into that.

   **Not scheduled, and deliberately downstream of Phase 7.7.** The open Pseudoregalia items are all
   blocked on a real two-player session, and authored cosmetics are the kind of thing that is much
   easier to judge with two real players than in loopback — where, per idea 4's own note, both
   characters are the same person and "does this help me tell peers apart" cannot be answered.

---

## Relay/client — transport security (TLS)

Not an adapter item and not on the depth ladder at all: this is the Go side, so it's
confirmable with the tools rather than by watching a game (`CLAUDE.md`'s split). Researched
2026-08-16 to the point of a full implementation plan; **deliberately not scheduled** — nothing
is broken today, and one of the costs below argues for waiting.

### What's actually missing

Only confidentiality. The application layer is already hardened: server-stamped `player_id`
(`internal/relay/relay.go:739`, never trusted from the payload), constant-time room-code compare
(`:653-660`), hello timeout, per-connection flood cap, global client cap, `ValidateState` that
drops rather than truncates, and a fuzz harness driving the relay over `net.Pipe`. What's left is
that `internal/transport` is plaintext NDJSON over TCP, so `room_code` crosses the wire readable
— already recorded at `risks.md:90`, `contract.md:151`, and the room-code ADR's own "TLS is a
separate, larger piece of work" note at `architecture.md:483`.

**Adapters are not affected by any of this, at all.** An adapter speaks only the *bridge*
protocol to a local core on `127.0.0.1:7778` — a different socket from the relay one. The bridge
stays plaintext loopback. Nothing in `adapters/` changes, now or later.

### The shape it would take

1. **Three-way mode**, `off` / `auto` / `required`, one config key and one flag on each binary.
   `auto` sniffs the first byte of each accepted connection — `0x16` is a TLS ClientHello, `{` is
   NDJSON — so one port serves both and hand-driving a relay with netcat still works. Releases
   would ship `required` on both sides.
2. **No files anywhere.** The relay generates an in-memory Ed25519 self-signed certificate once
   per process. Nothing ever verifies it by fingerprint, so a file on disk would buy zero
   security while putting a private key next to the exe in a zip people re-share.
3. **Identity via TLS channel binding** (`tls-exporter`, RFC 9266), not certificates or pinned
   fingerprints — because the end user configures nothing. After the handshake both ends derive
   the same connection-unique secret via `tls.ConnectionState.ExportKeyingMaterial`; the client
   sends `HMAC-SHA256(room_code, ekm)` in place of the raw code, the relay computes the same and
   compares constant-time, and mirrors its own proof back in `Welcome` under a second label.
   Someone terminating TLS in the middle sees *different* keying material on each leg, so they
   can't forge or forward a valid proof. Net: the room code stops crossing the wire at all,
   interception is blocked, and nobody copies a hex string.
4. Structurally small. `relay.Serve` takes any `net.Listener` and `handleConn` any `net.Conn`
   (proven by the `net.Pipe` fuzz harness), so framing, relay logic and core need no change —
   the work is a new `internal/tlsx` leaf package, two optional `protocol` fields, and the two
   `cmd/` binaries. `protocol.Version` stays at 1 (additive optional fields, same precedent as
   the room-code ADR). Full plan, including the compatibility matrix and the test list, was
   written 2026-08-16 and would need re-deriving — the design above is the durable part.

### Why it's worth doing

Anyone on the network path — shared wifi, a VPN provider, an ISP — currently reads the room code
out of the third packet. This makes that impossible, and makes relay impersonation impossible
too. It would also be the **first security setting a stale binary cannot silently disable**: a
`required` client refuses to send anything to a plaintext relay, which is exactly what
room-code auth could not do (`risks.md:97-107`).

### Costs, honestly

- **Antivirus, and this one is ours specifically.** The exes already draw false-positive trojan
  flags. Certificate generation plus encrypted outbound traffic hits two classic heuristic
  triggers, so this could plausibly make that worse. **This is the reason to sequence it after
  the SignPath OSS code-signing work, not before** — it's the only cost here that would actually
  reach users.
- **Reading a real session off the wire stops working.** netcat-driving survives under `auto`,
  but a packet capture between two real binaries goes opaque — the property
  `internal/README.md:221` argues for. `tls: off` is the way back.
- **~10-15% more traffic.** Roughly 25 bytes of TLS record overhead per message; at 20 Hz that's
  about 1.8 MB/hour per direction against 150-250 byte packets. Post-handshake CPU is
  immeasurable — AES-GCM moves gigabytes per second and this sends four kilobytes.
- **A new way for a version mismatch to break a release.** Today a stale binary silently
  downgrades; after this a `required` client hard-fails. That's the intent, but it's still a new
  support case where mixed versions error instead of limping along.
- **Bug risk in a path that currently works.** The room-code check splits into two branches, and
  getting the split wrong would create a downgrade hole where none exists. The plan's answer is a
  test asserting that a TLS connection sending a *raw* room code is refused, not accepted.

### Two smaller, cheaper items found alongside it

Both are independent of TLS and could land first.

- **The shipped relay default is an open relay.** `packaging/release/config.json` has
  `listen_on: "0.0.0.0:7777"` with `room_code: ""`. Keeping `0.0.0.0` is right — narrowing it
  breaks the host-for-friends flow `packaging/release/README.txt` already walks through — but the
  empty code deserves a louder warning than it currently gets. Auto-generating a random room code
  when none is set would close it properly, at the cost of the zero-config "just give them the
  address" flow; that's a product call, not a technical one.
- **No per-IP connection cap.** `MaxClients` (8, global) is reserved only *after* a successful
  Hello (`relay.go:678`), so N unauthenticated connections each hold a goroutine and a socket for
  `HelloTimeout`. TLS would make each one cost real handshake CPU an unauthenticated stranger can
  trigger, so a handshake timeout is part of the plan above. A real per-IP cap needs
  `conn.RemoteAddr()`, which `internal/README.md:102` currently asserts is never called anywhere
  as a privacy property — so it needs its own decision rather than being smuggled into a TLS
  change.

### Follow-up: let the relay advertise its transports — BUILT 2026-08-16, same day

**Done, and no longer an idea.** Filed here in the morning and implemented the same day as
`transport: "auto"` — see the transport discovery ADR in `architecture.md` and the entry in
`verified.md`.

Kept as a one-paragraph record because the *reasoning* is worth not re-deriving: auto-probing
cannot work (quic is on a different port and a client knows only one address), advertising in
`Welcome` would have meant joining first and then reconnecting — which every other player in the
room would see as a leave and rejoin, since `contract.md` guarantees no session resumption — so
the client asks *before* joining instead. The query answers only after the room-code check, which
is what stops it becoming the relay's one pre-auth endpoint.

### Prior art: how pseudoregalia-multiplayer splits reliable vs unreliable (checked 2026-08-16)

Checked when the user asked whether MeshGhost needs WebSocket, having noticed that project using
it for something beyond its Archipelago connection. Facts read from its own
`docs/application-protocol.md` (MIT, approved read-only reference in `licensing.md`); no code
read or copied.

It uses **both WebSocket and UDP**: "Communication between client and server consists of both
WebSocket messages and UDP packets." The author's stated reason is worth quoting, because it is
the same problem MeshGhost hit and a different answer to it — "I like using UDP for the state
updates, but I didn't want to write my own 'connection based, in order, guaranteed delivery'
protocol on top of UDP. I can get that from WebSockets relatively easily."

**Same split, different solution.** MeshGhost reached the identical conclusion — lossy for
per-frame state, reliable for lifecycle — and expressed it as `Send`/`SendUnreliable` over one
connection. Where they delegated the reliable half to a second protocol, we wrote the retransmit
/ack/dedup layer in `internal/netx/udpconn` that they explicitly chose not to write. Their
reasoning is sound and the cost of ours was real: that layer is where the one genuine bug of the
day lived (acking before delivering, `verified.md` 2026-08-16), which delegating would have
avoided.

**Why we still don't want WebSocket.** QUIC is the better version of what they use it for: the
same reliable-plus-unreliable split, but one connection rather than two, one path through NAT,
standardised, and encrypted — WebSocket being an HTTP-derived framing layer whose reason for
existing (browsers cannot open raw sockets) does not apply to a native client. The one case that
would change this is hosting: some PaaS providers and restrictive networks route only HTTP(S), so
a relay behind such a proxy is reachable over WSS on 443 and nothing else. If that ever comes up,
`internal/netx` makes it a fourth `Kind` with no change to `internal/relay` or `internal/core`.

## Code signing the Windows binaries (SignPath OSS)

**Named publicly as the intended fix 2026-08-16**, when `README.md` gained a "My antivirus flagged
it" section, so it needs an entry of its own rather than the single sequencing mention it had
inside the TLS idea. Unstarted.

**What it is:** SignPath offers free code-signing certificates and a signing service to open-source
projects. The build would sign `meshghost.exe` and `meshghost-server.exe` in
`.github/workflows/release.yml` before they are packaged.

**What it addresses, and what it does not** — worth separating, because they are three different
mechanisms and signing only fully solves one:

- **Authenticode** — "who published this, and has it been altered since". Signing answers this
  outright. This is the part that is simply fixed.
- **SmartScreen reputation** — a per-publisher score built from how many people have downloaded and
  run your signed files. A *new* certificate starts with none, so the first releases can still warn.
  An EV certificate is granted reputation immediately; SignPath's OSS offering is not EV, so this
  is earned over time rather than granted.
- **Defender's `!ml` verdicts** — a machine-learning judgement over a profile, of which signing and
  reputation are two inputs among several (prevalence, network behaviour, whether a process was
  started by a person or by another program). Signing improves the odds. It does not guarantee an
  outcome, and `README.md` deliberately does not promise one.

**Cost:** an application to SignPath's OSS programme, a project/artifact configuration on their
side, and a CI change with a signing step and a secret. The signing itself is a service call, not a
certificate file sitting in the repo — which matters here, since a private key in a public repo
would be exactly the sort of thing `CLAUDE.md`'s "nothing that couldn't be published" rule forbids.

**Why it keeps coming up:** it is now the mitigation named by three separate entries in
`risks.md` — the general false-positive one, the autostart one (a mod starting an unsigned exe is
dropper-shaped), and TLS (which would add cert generation plus encrypted traffic on top). It is the
only one of those where the work is bounded and the benefit reaches users directly.

## The bandage register (audited 2026-08-16)

Every shipped compensation, found by auditing the whole repo against
`adapters/_template`'s rule: **a fix that restores, forces, compensates for, or remembers a value
rather than preventing whatever changed it.** Ranked by how likely each is to cause a real bug.

**The audit's own headline is worth keeping:** most things that *looked* like bandages are not.
The great majority carry the live incident, the rejected alternative, and the derivation next to
them. See "deliberate, do not 'fix' these" at the end — mislabelling those would cause churn.

### 1. TEVI force-enables all five sprite layers, having measured one

`adapters/tevi/MeshGhostTevi/Plugin.cs:330-333` sets `enabled = true` on every child
`SpriteRenderer` of a cloned ghost, working around `Instantiate()` deep-copying a transient
zone-load fade that the logic-less clone can never clear by itself.

**Forcing is defensible here** — the clone carries no animation logic, so nothing else will ever set
it. **The defect is scope.** The live log measured only `basesprite`; the code enables all five
(`basesprite, outlinesprite, effectsprite, flashsprite, supportsprite`). `flashsprite` is a hit-flash
overlay and `supportsprite` similar — layers that are *normally off*, so forcing them on likely
paints a permanent overlay on every ghost. `pitfalls.md:526-528` already states the lesson this
violates: *"only reset the field actually confirmed broken, not everything that plausibly could
be"*, learned from the earlier `color = Color.white` mis-fix that broke `outlinesprite`.

**Fix:** narrow to `basesprite`, or log all five layers' inherited state on a real repro first.

### 2. Emerald proceeds on known-wrong addresses for an unrecognised ROM

`adapters/pokemon/emerald/meshghost_emerald.lua:304-307` (sprite data) and `:359-379` / `:1060-1062`
(avatar offset). When neither the vanilla nor the known Archipelago-shifted address verifies, both
warn and **carry on with vanilla addresses**.

**This is the one that puts wrong data on the wire.** Nothing gates *sending* on
`avatarAddrConfirmed`, so `getLocalState()` reads `GPLAYERAVATAR_ADDR + 0` every frame until
detection succeeds — on a future Archipelago recompile that never happens, and the adapter
transmits garbage facing/anim to real peers while drawing remotes at a garbage screen position.

The two *known* offsets are exceptionally well measured (byte-level ROM diffs, multi-stage live
probes). What was never observed is what the fallback path actually renders or sends.

**Fix:** on "not found", stop sending (`ENCODED_NO_SEND`) and stop drawing remotes. A visibly
disabled adapter beats silent wrong data.

### 3. Emerald's blanket per-frame `pcall` with a 300-frame log gag

`meshghost_emerald.lua:1133-1142`. The resilience posture is right for a Lua script that would
otherwise die for the session — but it cannot tell one malformed line from every frame failing.
A systematically broken read reports once per ~5s and the ghost silently stops updating.

**Fix:** a consecutive-failure counter that logs loudly and disables the offending subsystem, rather
than a constant chosen to protect the console.

### 4. `DefaultInterpolationDelay` is an admitted guess that is now load-bearing

`internal/core/core.go:88-93` says it outright: *"100ms is a starting guess for tile-grid movement,
not a measured value."* Since then `internal/protocol/limits.go:79-83` built the `MinSendHz = 10`
protocol floor **on top of it**. So a guess underpins a protocol constant — and a client using the
documented, supported `min_send: 150ms` lands silently in exactly the degraded regime that floor
exists to prevent.

**Fix:** derive it from `effectiveSendInterval()`, the way `DefaultMinSendInterval` is already
rederived from `protocol.DefaultSendHz` specifically "so the two numbers cannot drift apart".

### 5. `DefaultHeartbeatInterval` is a hand-picked margin against another package's constant

`internal/core/core.go:120-132`. The heartbeat itself is the correct fix for a real, live-diagnosed
bug (idle timeout → fresh `player_id` every minute → every peer sees a despawn/respawn). The
**constant** is the bandage: 20s was chosen as "comfortable margin" under `transport`'s 60s, but
`relay.Server.IdleTimeout` is a per-server override, so a relay configured below ~20s silently
reintroduces the exact churn this was chosen to prevent.

**Fix:** `DefaultIdleTimeout / 3`. The same file already does this correctly elsewhere —
`relay/limits.go:65` derives its headroom "so the stated relationship can't silently break".

### Borderline, noted but not urgent

- `udpconn.go:130-133` — retry budget asserted to fit inside `relay.DefaultHelloTimeout` in prose
  only, not derived. Same drift shape as #5, lower impact.
- `Plugin.cs:528` — `cloneTemplate` literally remembers a value across the thing that invalidated
  it; saved in practice by Unity's fake-null comparison, but it is the pattern the rule names.
- `meshghost_emerald.lua:675` — `FACING[facingRaw] or "south"` turns a bad memory read into a
  plausible value with no counter or log, which is the failure mode CLAUDE.md warns about. (The
  neighbouring gender/direction defaults are documented forward-compat and fine.)
- `parent_windows.go:31-43` — Windows PID reuse could make a dead parent look alive forever; not
  called out anywhere.

### Deliberate, do NOT "fix" these

Recorded so a future audit does not churn them: `ClampSendHz`/`ClampReceiveHz` (clamping a cosmetic
knob so a typo cannot stop a relay starting, per `contract.md`); the deliberate `log.Fatalf` on a
bad `-transport` (a silent fallback would hand someone who asked for quic an unencrypted session);
`relay/limits.go`'s derived constants; Emerald's `STEP_DURATION_FRAMES` (measured live twice with
zero variance, and two "smarter" self-correcting alternatives were built, traced, proven worse and
reverted with the evidence inline — the reference case for how this repo justifies a constant);
`stripBOM`/`applyDespiteBadValue`; `connectionGeneration`; the `net.ErrClosed` suppression; and the
`relayOwner`/`attachedAdapter` split.

## Slide: replace the render-Z bandage with the game's own crouch handling

**Flagged by the user 2026-08-16** as a temporary fix that should be replaced by finding out how
the game itself does it — the case `adapters/_template`'s "observe before you override" rule exists
for, and the same shape as the camera fight-back that had to be deleted the same day.

**What ships today** (`Plugin.cpp`, the `slide_z_comp` block at the receive site): during a slide
the ghost's render target Z is raised by `GHOST_STANDING_CAPSULE_HALF - peer_capsule_half`, i.e.
**+43 units**, so it stops sinking into the floor.

**It is not a guess, and that is why it survived** — the mechanism underneath it was measured, and
the comment records it honestly: a real slide shrinks the player's capsule 65 -> 22 and drops its
origin 567.2 -> 524.2, keeping the feet planted. Mirroring `CapsuleHalfHeight` onto the ghost was
tried, confirmed to apply (read back 22), and did **not** fix the visual, because the skeletal mesh
hangs off the capsule at a fixed relative offset (-65) set at construction. **The thing that
adjusts that offset is the player's own crouch logic, which an unpossessed ghost never runs.**

So the bandage is precisely the tell the rule names: it *compensates* for a value the game would
have set, instead of making the game set it.

**Leads, in order of promise:**

1. **The game's own slide functions.** `slideTick` and `slideOverheadCheck` were already captured
   by the reflection dump (`OBJECT_REFLECTION_DUMP`, noted in `Plugin.cpp`'s own comment as
   "captured for later, not yet used"). If one of those is what moves the mesh, calling it on the
   ghost is the whole fix — the same pattern as `call_manage_recall_idle_fx` and
   `call_update_weapon_equip`, both of which already drive the game's own functions on a ghost.
2. **The engine's crouch path.** `ACharacter::OnStartCrouch`/`OnEndCrouch` receive the half-height
   adjustment and are what normally moves the mesh. A ghost never gets them because nothing calls
   `Crouch()` on it. Worth checking whether they are reflected and whether BP_PlayerGoatMain_C
   overrides them.
3. **The mesh offset directly.** If neither is callable, setting the mesh component's own
   `RelativeLocation` is still closer to the truth than moving the whole actor: it changes the
   thing that is actually wrong, rather than hiding it by moving everything.

**START HERE — the probe is one line, in a block that already runs.** `Plugin.cpp:7133-7140`
already dumps the LOCAL player's `VisualMesh` on the existing trace cadence, but only
`RelativeRotation` and `RelativeScale3D`. Add `RelativeLocation` to that same `Output::send`, build,
and capture two states: **standing, then mid-slide.**

That single number answers the whole question. The ghost's mesh sits at a fixed `-65` set at
construction; whatever the player's mesh reads during a slide is what the game's own crouch logic
moves it to, and that is the value to reproduce on the ghost — by calling whatever sets it, not by
moving the actor. It also says whether the `-65`/`+43` pair is the whole story or an approximation
that only looks right in one pose.

Then, in order: does `slideTick`/`slideOverheadCheck` (already captured by an earlier reflection
dump, noted in `Plugin.cpp` as "captured for later, not yet used") move the mesh? Is
`OnStartCrouch` reflected and does `BP_PlayerGoatMain_C` override it? Failing both, set the mesh
component's own `RelativeLocation` — still the right object, unlike moving the whole actor.

**Why this matters beyond tidiness:** the ghost's Z is being moved for a reason that has nothing to
do with position, so anything else reading that Z inherits the lie. `Plugin.cpp` already notes a
second bug (the thrown-weapon prop) as "structurally the same bug as the slide floor-sinking fix",
which is what a bandage looks like when it starts to spread.

## VFX hunting — let the player mark the moment (untried)

**User's idea, 2026-08-16.** Written up as a procedure step in
`agent_docs/effect-investigation.md` §0b; this is the pointer and the scheduling note.

Instead of logging every animation/VFX and guessing a name filter — which is where the
Pseudoregalia trail investigation lost most of its time — log unfiltered, stand idle, and let the
player press a mark key the instant the effect they mean appears. The person watching already knows
which effect they want; that knowledge becomes the filter without ever being spelled as a string.

**Why it is likely fast, and why it tolerates a sloppy mark:** even a mistimed press leaves the
previous, current, and next event — **3 candidates instead of 50+** — because what it captures is
ordinal, not precise. Marks then intersect: three or four of them and the list collapses to one,
with no theory about naming at any point. The idle periods double as a free ambient baseline.

**It is the first half of a two-pass method, not a whole one.** The marks narrow 50+ to ~3 without
naming anything; the existing catalog probe then plays those 3 onto a ghost, numbered, and the
watcher says which. That probe already exists and was never wrong — it was just unusable at 58
candidates. The pairing fixes each one's weakness: marking is cheap but only gets to "probably",
the catalog proves but does not scale.

**Where it should be tried first:** the two VFX gaps still open — Pseudoregalia's remaining
missing effects, and TEVI's charged-attack VFX that plays no effect while the animation runs
(`status.md`). Both are exactly the "we know what it looks like, we cannot find what it is called"
shape this addresses.

**Design constraints that decide whether it works** (detail in the playbook): the mark key must be
one the game does not use, or it pollutes what it measures; the buffer must capture the ~2s
*before* the press, since human reaction time is many frames; and the buffer holds ids only, with
name resolution deferred to the marked window — which also makes it cheaper than the per-tick
name-lookup probes that caused this project's worst regression.

## Autostart — one core per game, so two games can run at once

**Suggested by the Linux speedrunner 2026-08-16**, after Proton autostart was confirmed working:
*"on detecting that a client already exists somewhere, have a setting to start it anyway with an
increased (unused) port until a free one is found — would enable having each game connect to
different servers."*

**This is a bug report wearing a feature request's clothes.** Running two different games at once
is broken today, and quietly. Both mods connect to `127.0.0.1:7778`; the first game's core owns
that process, and a second game's hello is refused —
`core: already connected to the relay as game %q, cannot also serve %q on the same process`
(`internal/core/core.go`) — after which `handleBridgeConn` closes the bridge connection. The second
game's mod then reconnects every 2s forever, with no ghost and nothing on screen explaining why.
The reuse-before-spawn rule that makes autostart safe is exactly what causes this: it cannot tell
"a core I can use" from "a core that belongs to someone else".

Per-game *configuration* is already solved and needs nothing: each mod folder has its own
`config.json`, and a spawned core reads the one in its own working directory. So Pseudoregalia
already points at whatever relay its own config names. **The only thing colliding is the port.**

**Option A — distinct default port per adapter** (Pseudoregalia 7778, TEVI 7779, Emerald 7780).
Deterministic, no protocol change, fixes two-games-at-once outright, and a manual core is still
findable because the number is fixed and documented. Does not help two instances of the SAME game
(the local two-player testing case), and adds a small port registry that must not drift from the
docs.

**Option B — probe upward, as suggested.** The mod tries 7778, and moves to 7779 if that core
refuses its game. Handles every case including two instances of one game, and needs no registry.
**Its cost is a contract change**: the bridge has no way to say *why* it closed, so an adapter
cannot currently distinguish "wrong game, try elsewhere" from "the core died". Inferring it from
timing (connected, sent hello, closed quickly) would be exactly the kind of guess this project
avoids. Doing it properly means a bridge-level reject message with a reason, mirroring the relay
protocol's own `Reject` — an ADR and a `contract.md` revision, plus every adapter learning to walk
the port range.

**Recommendation:** A first, then B if the same-game case ever matters. A is a day's work and
removes a silent failure; B is the complete answer but should not be smuggled in as a bug fix.
Either way the docs must say which port each game uses, since `MESHGHOST_NO_AUTOSTART` users need
to know what to bind.

## Links

- `agent_docs/plans.md` — the roadmap; move an idea here (with a phase number) once it's picked.
- `agent_docs/architecture.md` — where an ADR for any write-crossing or scope-crossing idea here
  would go.
- `agent_docs/risks.md` — Pseudoregalia's full ghost-collision incident history, required
  reading before touching TEVI's collision idea.
- `agent_docs/contract.md` — the event plane's reserved design, needed before emotes/chat/pings.
