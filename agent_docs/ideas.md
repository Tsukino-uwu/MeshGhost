# Ideas — the place future plans and brainstorming are kept so they are not forgotten

**What this is** (the user's words, 2026-09-02): *"just a place to store future plans/brainstorming
somewhere so i don't forget them later"* — cool new features (time-trial ghosts, a replay you race),
things that might be good to fix (culling, scaling), candidate games, research done once so it is not
done twice. **Nothing here is scheduled**, and nothing has to leave: an idea is picked from here into
`plans.md` when its time comes, and stays here otherwise. Until 2026-09-02 the header said this file
"drains into `plans.md`"; zero entries ever had, so the header was changed to say what the file is.

**Two kinds of entry live elsewhere now, for findability:** the security design work is
[security-design.md](security-design.md) (the design behind `docs/security.md`'s posture), and the
candidate games and prior-art reads are [candidate-games.md](candidate-games.md). Ideas that shipped
or were closed keep a short stub here; their full text is archived in
[doc-history.md](doc-history.md), "Archived idea texts".

**Reference projects named here have NOT had their licences checked** — the user's call: brainstorm
citations need none. `licensing.md`'s gate exempts this file; the moment anything from a project here
is USED, that project is checked and recorded there first.

## Index — every idea in this file

- TEVI — cosmetic / presence (Tier 1, no memory writes)
- TEVI — interaction ("test what's possible", scope stays visual-only)
- Emerald
- Emerald: Union Room decomp investigation
- Emerald: VRAM/sprite injection investigation (draw vs. inject)
- TEVI: ghost collision investigation
- Pseudoregalia
- Go side: carry the previous state in every unreliable packet, quic datagrams and udp alike (loss redundancy, 2026-09-02)
- Go side: quic datagrams are congestion-controlled, so a loss paces the samples after it — measure, then decide (2026-09-02)
- The bandage register (audited 2026-08-16) — moved
- Slide: the render-Z bandage is gone — DONE 2026-08-17
- Relay-steered transport per game — possible, but the wrong lever (Tier 0, no blockers)
- VFX hunting — let the player mark the moment (untried)
- Autostart — one core per game, so two games can run at once
- Unmoddable games — a scanner and an overlay, NOT our own mod loader
- A reusable game driver — agents that can understand and play any of our games (unscheduled)
- Spawn to the game's cap, then DRAW above it — SHIPPED, both Pokémon adapters
- A THIRD tier: a hardware sprite with no engine object — CLOSED 2026-08-21
- A SPEEDRUN toggle: spawned and hardware only, never painted — filed 2026-08-21
- Crystal: a ghost you can talk to — and eventually battle
- Links
- Emerald: turning ghost collision off, if it ever needs turning off
- Driving the game itself: scripted input — DONE for BizHawk, OPEN for Pseudoregalia
- BizHawk on Linux: the adapters are portable, the socket is not — filed 2026-08-18
- Enemy/boss kill credit and participation, filed 2026-08-19
- A per-game blocklist for a relay, alongside `only_game` — filed 2026-08-20
- A "share items" room toggle, in the shape of the collision one — filed 2026-08-20
- Split releases: platform-only and per-category bundles beside the full one — filed 2026-08-20
- "Hide every ghost, but still be one" — a client-only invisibility setting — filed 2026-08-20
- Adapter-specific settings in the per-game config.json, read by the mod itself, instead of in-game menus — filed 2026-09-03
- Scaling and efficiency — MOVED to `scaling.md` (2026-08-30)
- BUG: with MESHGHOST_BRIDGE_PORT set, a rejected adapter hot-loops and its own log line is a lie (2026-08-28)
- Sweep: rules that live in one code path and are missing from their sibling
- TEVI: the orbitars are not synced at all, projectiles included (2026-08-28)
- Interpolation delay should be PER ADAPTER, not one number for every game (2026-08-28)
- Two Go file splits, scoped and deliberately not done (2026-08-27)
- Four refactors still deferred from the 2026-08-18 audit-and-refactor pass
- Doc restructuring: what was done — moved to `doc-history.md` (2026-08-25)
- Fuzz the SCHEDULE, not just the bytes — randomized ordering and timing (2026-08-28)
- Fuzz the REPLAY schedule under the race job: attach, first frame, files, seeks, gaps, detach (filed 2026-09-03; DONE 2026-09-03, and it found that every generated clip was being refused)
- Adapter-side fuzzers, one per adapter in its own language, in a CI job gated on that adapter's paths (filed 2026-09-03; Lua and TEVI BUILT 2026-09-03, Pseudoregalia not started)
- A virtual clock for the core, so a fuzz step can say "eight hours pass" with no sleep (filed 2026-09-03; stage 1 BUILT 2026-09-03)
- Pseudoregalia: mirror a peer's REAL light state onto their ghost (filed 2026-08-30)
- Ghost RECORDING and racing a replay — the wire format is already a replay format (filed 2026-08-30)
- Recording file size: gzip now, per-KEY delta encoding later (measured 2026-09-03)

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
   (`protocol/protocol.go:126`, sourced from `config.json`'s `"name"`) and is only
   *logged* there (`relay/relay.go:846`, `:1295`) — never redistributed. **Whenever this is
   built, the display name becomes the project's FIRST peer-controlled string rendered on
   another player's screen, and it must be sanitised at that point, not merely length-bounded** —
   reject control characters outright, the way Archipelago's `Say` handler requires
   `.isprintable()` and not just `str` (`MultiServer.py:2141`, read for facts 2026-08-24,
   `licensing.md`). Today `area_id`/`anim` are UTF-8-validated but not control-character-filtered,
   which is harmless only because nothing displays them. See the security umbrella entry below.
   `Welcome.Roster` is `[]string` of ids (`protocol.go:224`); `Join` carries only `player_id` (+ optional,
   never-populated `State`). **No adapter can learn any peer's display name today.** Two routes:
   a roster/`join` shape revision to actually carry `display_name` (correct, needs an ADR per
   `contract.md:3-5`), or smuggling it through `extras` (cheap, but the wrong layer — `extras`
   is per-state free-form data, not identity).

4. **Per-remote appearance.** Every ghost is a clone of the *local* player's own
   `spranim_prefer.pixel.gameObject` (`Plugin.cs:258-263, 265-321`) — there is only one
   template, the local character. Two peers on different characters/costumes both render as
   whatever the *viewer's* own character looks like. Needs a real per-character visual source,
   not just a config toggle.

5. **Ghost depth sorting.** Ghost z is hardcoded to `0` (`Plugin.cs:371`, `:398`) with no sorting-layer
   handling against TEVI's own render layers — currently invisible only because it hasn't
   collided with a real layering bug yet.

6. **Config surface.** Exactly one `BepInEx.Configuration.ConfigFile.Bind` call exists in the
   whole adapter (`BridgePort`, `Plugin.cs:469`) — read once at `Awake`, no live re-read.
   Any future toggle (map marker on/off, ghost opacity, nameplates, verbose logging, the
   collision experiment below) needs this pattern established for real, not assumed. Do this
   with whichever toggle ships first, not speculatively ahead of time.

7. **Emotes / chat / area-entry pings.** Tier 1 per the depth ladder, and explicitly sanctioned
   as possible and write-free — but the right home is the **reserved `event` plane**
   (`contract.md`'s "Extensibility — the event plane" section, from `:193`), not new `state`
   fields. `contract.md:247` states plainly that
   the state plane "does not grow new fields for deeper features," and it's lossy/latest-wins —
   a one-shot emote sent as `state` would either never arrive or repeat every tick until
   overwritten.

   **The plane itself is ~~its own scoped piece of work~~ BUILT, 2026-08-17.** Everything this
   entry listed as remaining — relay `to`-routing, a real `MaxEventBytes`, new bridge message types
   each direction, and the first real population of `Hello.Features` — now exists and is tested
   (`contract.md`'s Extensibility section, the ADR in `architecture.md`). What is left is purely
   per-adapter: nothing sends or renders an emote yet, and no adapter asks for `event.v1`. So this
   stays open as an *adapter* idea, with the transport half struck off.

## TEVI — interaction ("test what's possible", scope stays visual-only)

8. **Opt-in ghost collision.** See "TEVI: ghost collision investigation" below.

## Emerald

9. ~~**Union Room / spawn-based rendering instead of overlay drawing.**~~ — **DONE 2026-08-18**,
   user-confirmed (`verified.md`). Emerald's shipped adapter spawns a real object event. The
   220-line investigation below is history, not a lead — read it for method, not for a plan.

10. ~~**Seamless adjacent-map ghosts.**~~ — **BUILT AND USER-CONFIRMED 2026-08-20**
    (`verified.md`; `meshghost_emerald.lua`'s cross-map block). The entry said this needed
    "currently unverified addresses"; they were measured and it shipped. The Archipelago-data
    analysis below stands on its own and is still the answer to the *different* question it
    raises. Original text: a ghost standing in a visually contiguous connected
    route/town simply isn't drawn — any different `area_id` is treated identically, seamless
    connection or not (`plans.md`'s Phase 4 "deferred idea" note). Would need real `pokeemerald` map-connection offset
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

11. ~~**Bike / surf / ledge-jump poses.**~~ — **DONE.** Peer state reaches the wire and all of
    bikes, surfing, diving and fishing are user-confirmed on screen (`verified.md`, 2026-08-21).
    The "what is still missing" line below is the 2026-08-18 state. Original text:
    deferred since Phase 5.5 (`phases/phase5_5.md:32-42`).
    A ghost on a bike or surfing still renders as an ordinary walking trainer — each has its
    own `graphicsId` in `sPlayerAvatarGfxIds`. **Updated 2026-08-18: no longer "unread".** The
    spawn adapter reads and writes `graphicsId` directly (`meshghost_emerald.lua`, `graphicsInfo`
    and the object-event write), so rendering an arbitrary state is a solved mechanism. What is
    still missing is the *peer's* state travelling over the wire — see `status.md`, and
    `phases/phase8.md` for the scoping (all player states share one palette tag).

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

Every claim below cites a specific file/line in a local `pokeemerald` decomp checkout
(outside the MeshGhost repo — read with the user's explicit go-ahead,
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

### The question this investigation never asked — raised 2026-08-17, still open

**Can the Lua adapter CALL the game's own spawn function, instead of writing what it would have
written?** Q6 above goes straight to "direct write, bypassing the template system" and enumerates
a write set. Nothing in this entry asks whether the function could be invoked — it was treated as
given that imitation is the only option.

That is the difference between two tiers (see `adapters/_template/README.md`'s create/borrow/draw
table). Pseudoregalia does not write an actor into memory: it calls the engine's own
`SpawnActor`/`ProcessEvent` and lets the game do its own writing, which is why it gets animation
and lifetime for free and why the no-writes rule was never in tension there. Emerald's equivalent
would be invoking `TrySpawnObjectEvent` — which this entry already identifies as **a generic
engine function, not Union-Room-specific** — rather than reproducing its effects byte by byte.

**Unknown, and the thing to settle first:** whether BizHawk's Lua API can invoke a GBA ROM
function safely at all (set up arguments, jump, return, without corrupting the frame the core is
mid-way through). UE4SS hands us a real call mechanism; BizHawk may simply not have one, in which
case "imitate the writes" is correct and this entry's recommendation stands unchanged — but it
would then stand on a *stated capability limit* rather than on an assumption nobody examined.

**Why the framing was wrong to begin with.** This whole entry studies Union Room because it is the
game's *multiplayer* feature. The user's later observation is the better one: the game spawns the
player character every time a save loads, so the general mechanism runs constantly and is far
easier to observe than an obscure link-cable mode. Union Room was a special case of a thing that
happens every session — the reason to look at it was thematic, not technical.

### Recommendation

> **SUPERSEDED 2026-08-18 by the Emerald spawn ADR** (`architecture.md`). Emerald's shipped
> adapter now spawns a real object event, and the `no-writes-without-an-ADR` gate this section
> defers to was cleared by exactly that route. What survives: the *Union-Room-specific* framing
> below is still the wrong way in (the feature really is unreachable outside a live link session),
> and the two primitives it identified really did inform the design that shipped. What is stale:
> every claim below that drawing is the only working option, that it "remains the right shipping
> default", or that a write path is unbuilt. Read the rest as the investigation it was.

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
   guessed one — see `adapters/emulator/pokemon/emerald/probes/vram_probe.lua`.
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
should use. **At the time of writing, before any stage of the test plan had run, drawing was the
only option that existed and worked** — a fact about that state, not a standing preference for
drawing over injection. **No longer true as of 2026-08-18**: spawning a real object event is a
third option, it is built, and it is what the Emerald adapter ships on a vanilla ROM
(`architecture.md`'s Emerald spawn ADR). Drawing survives only as the patched-ROM fallback,
registered in that adapter's `BANDAGES.md`. VRAM injection remains unstarted past Stage 1. Two real costs to plan for once both scripts exist,
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
  reconsidering only once the manual version has shipped and seen real use.

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
   network. **MeshGhost's own Pseudoregalia adapter has since cleared that bar too**: Phase 7.7,
   a real two-player session on two machines, was confirmed 2026-08-16 (`status.md`,
   `verified.md`) — an earlier version of this entry said it "hasn't been run" and that
   "code-complete" was the accurate status, which is no longer true. Their last real commit is
   2026-03-16 though — inactive, not
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
   hijacked level actor — `SPAWN_BASED_GHOSTS = true`, `Plugin.cpp:387`; a hijack
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

   **Overtaken 2026-08-16 — read the table as of 2026-08-15.** Transports became selectable
   (`tcp`/`udp`/`quic`) with a reliable *and* an unreliable plane on each, and the shipped default
   is now `auto` on the client against `tcp,quic` on the relay, so a default session runs on
   **quic**, not tcp. That closes the head-of-line-blocking row (per-frame state rides
   `SendUnreliable`) and the forgeable-packets row (quic's handshake is TLS 1.3) without needing a
   second channel — see `architecture.md`'s transport ADRs and the "how pseudoregalia-multiplayer
   splits reliable vs unreliable" section further down this file. The row that still stands is
   debugging cost: plaintext tcp remains the readable-on-the-wire option.

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
   still unidentified. Deliberate player-on-ghost melee is judged an acceptable, unlikely footgun.
   ~~**The genuinely untested vector is non-player damage**: an enemy attack, AoE, or
   environmental hazard hitting the ghost was never tried, and the ghost stands in the world
   where enemies fight. If a player ever dies for no visible reason near a ghost, this is the
   first thing to check.~~ (Struck — it was tested, it was real, and it was fixed the same day;
   see the next paragraph. Kept because the prediction was right.) The real fix, if it's ever
   wanted, is making the ghost
   collidable-but-unhittable — no response on whatever channel the damage/weapon trace queries
   (still unidentified per `GHOST_COLLISION_ENABLED`'s own comment).

   **New lead, 2026-08-17 — it may not be a trace problem at all.** The user reports that killing a
   ghost leaves the real player respawning with 0/empty health, and suspects shared health state
   between player and ghost. The HUD is explicitly *not* the problem — the bar renders fine, the
   value behind it is 0 — so this is a health-state bug, not a UI one. If that is right, it
   reframes everything above: `bCanBeDamaged = false` landing and doing nothing is exactly what you
   would expect when the damage never travelled through the ghost's damage path to begin with,
   because both characters resolve to the same health state. That would make "find the bespoke
   melee trace" the wrong search. It also explains the respawn half: respawn restores health on
   something that isn't what the bar reads, or the shared value is never reset — both of which are
   what one health state driven to 0 by the ghost's death would look like. **The cheap
   discriminating test: read the ghost's and the player's health property identity — same
   object/address or two — before swinging at anything.** Note
   `HEALTH_TRACE` (`Plugin.cpp:668`) was flipped off precisely because it never resolved a health
   property on this build, so finding where health actually lives is step zero. See `verified.md`
   2026-08-17 and `status.md`.

   **Wanted end state (user, 2026-08-17): attacking a ghost is a pure toy.** You can swing at a
   ghost and it reacts — hurt/flinch animation, a red blink — but it cannot be killed and it cannot
   cost you anything. No damage to the real player, no death, no respawn. The attack does something
   visible and means nothing, which is the whole point.

   This is on-brief rather than a stretch: the project is a visual-only layer, so a hit reaction
   with no gameplay consequence is Tier 1 cosmetic work, not the shared-combat-state question that
   `beyond-cosmetic.md` gates. Two parts, and they are independent:

   - **Separate the health** (the prerequisite, and probably the current bug). Until the ghost stops
     sharing health state, "cannot cost you anything" is not achievable by any amount of animation
     work. This is the same investigation as the lead above.
   - **Play the reaction.** Largely proven machinery already: stock `Montage_Play` on the ghost's
     `animBPref` works (`Plugin.cpp:897`), and the 2026-08-15 montage-mirror session confirmed the
     mirror already carries **attacks, flinch and knockback** among others (`Plugin.cpp:909`). So a
     flinch on demand is a call this codebase has already made work, not new ground. The red blink
     is the genuinely unknown half — no hit-flash material has been identified on this game, and the
     nearest solved analogues are the recall glow and the afterimage colour work
     (`effect-investigation.md` is the playbook for that search).

   **Design decision worth making up front: keep the reaction LOCAL.** The ghost flinching when you
   hit it should be a local visual event, not something sent to the peer. If it were networked, the
   peer's character would be reacting to a remote player's action and it stops being cosmetic — that
   is a sync-model change and belongs behind `beyond-cosmetic.md`, not here. Local-only keeps it a
   toy, keeps the peer authoritative over their own character, and needs no protocol change at all.

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
   two-player session — **not** on any further loopback result, which cannot answer it. Do not
   re-open this question from loopback evidence. **Phase 7.7 — the blocking item this entry
   named — was run and confirmed 2026-08-16** (two players, two machines), so the yes/no call is
   now unblocked and simply hasn't been re-judged; `status.md` lists it under "was blocked on a
   two-player session".

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
     bounded, consensual interaction, which is exactly what `contract.md`'s event plane is for
     (built 2026-08-17, opt-in, used by no adapter yet). Don't grow the state plane into that.

   **Not scheduled, and deliberately downstream of Phase 7.7** — which has since been run and
   confirmed (2026-08-16), so the sequencing reason no longer holds it back; it remains unscheduled
   on its own merits. Authored cosmetics are the kind of thing that is much easier to judge with two
   real players than in loopback — where, per idea 4's own note, both characters are the same person
   and "does this help me tell peers apart" cannot be answered.

---

## The bandage register (audited 2026-08-16) — moved

Split into one file per adapter, so each game's compensations sit next to its own `README.md`:
`adapters/pseudoregalia/BANDAGES.md`, `adapters/tevi/BANDAGES.md`,
`adapters/emulator/pokemon/emerald/BANDAGES.md`, and `agent_docs/bandages-core.md` for the Go side.
The rule itself lives in `adapters/_template/README.md`, with a blank register beside it.

## Slide: the render-Z bandage is gone — DONE 2026-08-17

Shipped. The ghost is posed by the game itself, and needed five mechanisms **together**, each of
which tests negative alone. Full text: `doc-history.md`, "Archived idea texts"; evidence in
`adapters/pseudoregalia/VERIFIED.md`; method in `pitfalls.md`'s slide case study.

## Relay-steered transport per game — possible, but the wrong lever (Tier 0, no blockers)

**User's idea, 2026-08-16**, asked as: if a future feature needs players actually in sync (a VS
battle in Emerald), could the relay *force* a client onto a particular transport based on
`game_id`?

**Mechanically yes, with no protocol change at all.** The `QueryOnly` discovery Hello already
carries `game_id`, and the relay answers it with a `Transports` offer list before it touches the
room table. Filtering that list per game would steer the client invisibly — no redirect, no
reconnect, and therefore none of the leave/rejoin churn every other player in the room would
otherwise see. There is no redirect mechanism today (`Reject` carries a reason string and nothing
else), so this is the only cheap way to do it.

**Two constraints if it is ever built:** it must be *operator config compared by equality*, like the
existing `Server.OnlyGame` gate — a hardcoded game table in `relay` would break CLAUDE.md's
no-branching-on-`game_id` rule. And the handshake is always tcp and cannot be changed, so this gates
the *upgrade*, not the dial.

**But it is a fallback, not the answer, and the reason matters.** `send` is reliable **and ordered**
on every transport (ordering added 2026-08-16 — see `verified.md`), so an adapter that needs
guaranteed delivery or ordering simply uses the reliable plane and needs no transport policy at all.
The general rule is in `beyond-cosmetic.md`: **capability is adapter-opt-in via `features`, never
relay-imposed via `game_id`.** Steering from the server is the same idea pushed to the wrong layer.

Worth keeping recorded anyway: if a future transport ever gains a property the others lack and an
adapter genuinely depends on it, this is the mechanism, and it is cheaper than it looks.

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
(`core/core.go`) — after which `handleBridgeConn` closes the bridge connection. The second
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
Its cost was a contract change: the bridge had no way to say *why* it closed, so an adapter could
not distinguish "wrong game, try elsewhere" from "the core died".

**Option B was chosen and built 2026-08-16, so most of this entry is now history.** The contract
change landed — `bridge` gained `TypeReject` and `Reject{Reason}` (see
`agent_docs/contract.md`, "A core serves exactly one adapter at a time"), so a core now says why
it refused and the correct answer to any rejection is simply to try the next port. Pseudoregalia
walks the range: `BridgeClient.hpp`'s `BRIDGE_BASE_PORT = 7778` sweeping up through 7785.

**Updated 2026-08-18:** both Pokémon adapters walk now — `meshghost_emerald.lua` and
`meshghost_crystal.lua` each sweep `BRIDGE_BASE_PORT` (7778) up across `BRIDGE_PORT_COUNT` (8) and
require `bridge_ready`. **Not yet watched live.** **Still open:** TEVI (`Plugin.cs`,
`DefaultBridgePort`) is the last adapter pinned to a single port and does not walk. Option A is moot.

## Unmoddable games — a scanner and an overlay, NOT our own mod loader

**Status: scoped 2026-08-17 in conversation, nothing built, nothing scheduled.** Raised as "could
we add multiplayer to a game nobody can mod". The answer is yes, at a specific and limited tier,
and the shape is smaller than it first looks.

### The question that decides everything: what does the engine keep about itself?

Getting code into a process is engine-agnostic and already solved (a proxy DLL named after a
system DLL the game loads — exactly how UE4SS gets in via `dwmapi.dll`). **What you can do once
inside is not.** Reflection is a property of the ENGINE, not of how you got in:

| Engine | After injection |
|---|---|
| Unreal | full reflection — names, properties, callable functions (UE keeps `UClass`/`UProperty` live because Blueprints and GC need them) |
| Unity + Mono | full type metadata via the Mono API |
| Unity + IL2CPP | partial; metadata largely stripped |
| Custom C++ engine | **code execution and nothing else** — names were destroyed at compile time |

### Why we should NOT build our own BepInEx/UE4SS

A loader is only needed where none exists — i.e. custom engines. And on a custom engine a loader
buys code execution and no type information, so you end up memory-scanning and overlay-drawing
anyway. **The loader has near-zero value exactly where it would be needed**, and where it would
have value (Unity, Unreal) mature loaders already exist and we already use them.

Building one means writing per-engine reflection backends — reimplementing two mature projects to
reach somewhere we can already reach for free. Note also what UE4SS actually is: `UE4SS.dll` is
~16 MB and pulls in PolyHook, Zydis, asmjit, patternsleuth, Lua and ImGui. The injection is
perhaps 1% of it; the other 99% is per-engine work.

### What the useful version actually is

Three pieces, none of them a framework:

1. **An external memory scanner** (`cmd/meshghost-scan`, Go). Enumerates a process's committed
   regions (`VirtualQueryEx`) and samples them (`ReadProcessMemory`) — the mechanism Cheat Engine
   wraps in a GUI. **The trick worth building in:** rather than the manual scan/narrow cycle,
   sample at ~10 Hz while the player walks a known route, then correlate every candidate float
   triple against that trace. We have a strong prior — three contiguous floats that move smoothly
   like a position — so one pass replaces many rounds.
2. **A ~100-line proxy DLL** to get our overlay into the process. This is "our own loader" only in
   the sense that it loads one thing; nobody would call it a BepInEx, and that is the point.
3. **An overlay renderer** — hook the swapchain (D3D11/12, GL, Vulkan) and draw peers, ideally
   with the depth buffer so ghosts do not show through walls. This is the real work.

**It is an adapter, not a new architecture.** It would speak the same bridge, and `relay`/`core`
would never know the difference — the same reason three adapters in three languages already share
no code.

### What it can and cannot deliver, honestly

This is the template's **"draw over the top"** tier, the one Emerald sits in — and it is *harder*
than Emerald in 3D, on three counts:

- **A camera matrix is needed, not just a position.** Emerald is 2D: world → screen is an offset,
  which is why its adapter needed only player X/Y and a camera offset. In 3D you need the
  view-projection matrix — 16 floats, changing every frame, and a second thing to find.
- **Depth.** Emerald's overlay drawing over a dialogue box is tolerable. A 3D ghost with no depth
  test is visible through walls and terrain permanently, which reads as broken rather than rough.
- **The ghost will not look native.** Emerald draws the game's own character sprites decoded from
  the ROM. Without engine access there is no way to get a character model, so we would ship our
  own — every peer a foreign mesh in someone else's art style.

**So the honest product is a presence marker, not a ghost of your friend.** Still a real feature —
"where is everyone" in a game with no mod scene — but it should be named as what it is rather
than sold as parity with Pseudoregalia.

### First step if it is ever picked up

**Validate the scanner against a game where the answer is already known.** Point it at
Pseudoregalia and see whether it independently finds the position `STATE_SEND_TRACE` already
prints. A scanner that cannot rediscover a known-correct address is not one to trust on a game
where nothing can be checked.

### How the proxy DLL actually works, since "bundle a DLL" hides the mechanics

It is **not** named after our project, and it **replaces nothing**. Both matter:

- **The filename must be exactly the DLL it impersonates** — `dwmapi.dll`, `version.dll`,
  `winmm.dll`, `dinput8.dll`, `d3d9.dll`. The game asks for that name; a file called
  `meshghost.dll` would never be loaded, because nothing asks for it. Which name works is
  per-game: read the exe's import table first.
- **Nothing of the game's or Windows' is overwritten.** The real DLL stays in
  `C:\Windows\System32`. Ours wins only because Windows searches **the exe's own directory before
  System32**. That is why the whole technique is non-destructive and undone by deleting one file.

The sequence: game starts → its import table asks for `dwmapi.dll` → Windows finds ours first →
`DllMain` runs → we `LoadLibrary` the real System32 copy and **forward every export** to it so the
game's actual calls still work → we spawn a thread and do our own work.

This is exactly what is in the Pseudoregalia install today: a 61,952-byte `dwmapi.dll` next to
`pseudoregalia-Win64-Shipping.exe`, which is UE4SS wearing the name. Renaming it is also the clean
way to get a **vanilla** run for A/B testing (used when ruling MeshGhost in or out of a bug).

Caveats before assuming it always works: the game must import a DLL you can impersonate, every
export must be forwarded or the game breaks oddly, `DllMain` runs before the engine exists (so
wait for a renderer on your own thread), and packers/DRM/anti-cheat or a UWP sandbox can defeat it
entirely.

### The antivirus question, and the split that answers it

**The APIs that alarm scanners are the ones for reaching into ANOTHER process.** Once our code is
inside, reading memory is a pointer dereference in our own address space — no `OpenProcess`, no
`ReadProcessMemory`, no handles, nothing to flag. That single fact decides the architecture.

Rough exposure, worst last:

| Component | Exposure | Why |
|---|---|---|
| Proxy DLL, loaded by the game | mild | The game loads it voluntarily |
| …named after a system DLL | moderate | Search-order hijacking is a catalogued technique (MITRE T1574.001) |
| API hooking (PolyHook/Detours) | moderate-high | `VirtualProtect` + patching live code pages |
| Swapchain overlay | moderate | Same technique cheat overlays use |
| External scanner (`OpenProcess`/`ReadProcessMemory`) | **high** | Cheat Engine is classified outright as a hacktool, deliberately, not as a false positive |
| `CreateRemoteThread` injection | **highest** | The canonical signature |

Not theoretical: UE4SS, BepInEx and ReShade are all flagged periodically despite being mature and
widely installed. We would have the same behaviour with none of their reputation, on top of the
false positives this project already documents in `docs/antivirus.md` — where "no download
reputation" is already named as one of the two causes, and code signing is still unstarted.

**So the mitigation is a packaging decision, not a technical one:**

| | Ships? | Does what |
|---|---|---|
| `meshghost-scan.exe` — external, out-of-process | **never** | Discovery only, during development. High exposure, and irrelevant because only we run it |
| the proxy DLL | yes | Reads at already-known offsets in-process and draws. No scanning in the shipped artifact at all |

The external tool exists for **iteration speed**, not capability: out-of-process it can be re-run
against a live game repeatedly, where in-process means rebuild → relaunch → walk back to the spot
for every experiment. That loop cost real time on 2026-08-17 and is worth designing away.

This is the same shape the repo already uses — probes are dev-only and off, shipped code does the
known thing, and `cmd/meshghost-fakeadapter`/`cmd/meshghost-netsim` never appear in a release.

**One caveat that will bite otherwise:** fixed offsets break on every game update. The shipped DLL
should find things by **byte-pattern scan** rather than hardcoded address — still just reading its
own memory, so still not AV-interesting. UE4SS bundles `patternsleuth` for exactly this.

### Boundary

Single-player games only. Every game this project targets qualifies. Anything with anti-cheat is
out — not because the technique differs, but because reading another process's memory is precisely
what those systems detect, and shipping something that gets users banned is not a trade this
project makes.

## A reusable game driver — agents that can understand and play any of our games (unscheduled)

**The user's framing, 2026-08-19: *"being able to automatically understand/play all of the games
will be useful in the future"* — and then the sharper version: *"or at least understanding 'how a
game works' in a general sense. how to progress/backtrack and do things."***

**That second sentence is the actual goal, and it is a smaller and better one than a playthrough
bot.** What is worth having is a *model of the game*: what advances it, how to get back, and what
the game does when it will not let you. A driver that can play is a consequence of having that
model; a driver without one is a button-masher that gets stuck and writes "story-blocked" into the
record.

**The model, per game — and it belongs in that adapter's `documentation.md`**, which already
exists to describe how the GAME works rather than how our code does:

- **Topology.** Maps and how they connect: warps, edge connections, which are one-way, what a door
  actually is. This is the difference between "backtrack a bit and go up/around" being a hint a
  human gives and a route an agent computes.
- **Progression gates.** What advances state (an NPC spoken to, a flag, a badge, an item) and, just
  as importantly, **how the game says "not yet"** — a temporary interruption, a permanent refusal,
  and a wrong tile all look identical to a driver that only sees "I did not move".
- **The verbs.** What A does in each context, what menus exist, what closes them. Mundane, and the
  thing that actually costs an agent its time.
- **The tells.** How the game shows it is busy, in a script, in a battle, or waiting for input —
  which is exactly the family of gates every adapter here already had to work out for its send
  loop, so the knowledge is half-written already.

Recorded as a capability rather than a one-off, because tonight made the argument for it: two separate measurements were gated behind game states nobody had
reached, and one agent turned an NPC's dialogue into a false "story-blocked" claim in the record
while trying to reach one.

**What it would buy, in order of how soon it pays:**

1. **States that gate measurements.** `wBattleMode` on Archipelago Crystal needs a **trainer**
   battle; surfing and fishing need water and a rod; "does a ghost survive X" needs an X. Each one
   currently waits for a human to walk there.
2. **Regression testing across a whole game.** Walk a long route with the adapter attached and
   watch for faults nobody scripted — the crowd test found three leaks in one evening precisely
   because it drove the adapter through situations no one had thought to try.
3. **Untested states, found rather than predicted.** The interesting bugs this project has had
   were all in transitions somebody had not visited yet.
4. **A savestate library**: every milestone banked once and inherited by every later session. This
   is the compounding part — a state that costs ten minutes of play costs nothing the second time.

**What it actually needs** (none of it exotic, and most already exists in pieces):

- **Position and state from the adapter, not from pixels.** Every adapter already reads the map and
  coordinates each frame; that is a position fix with no screenshot and no ambiguity. Screenshots
  are for the things only a picture shows — and one picture cannot see a blinking prompt.
- **Route data from the decomp**: map connections, warp events, per-map object lists. Planning a
  route from data is the same discipline as planning a probe from data, and it is what separates
  "walk here, press this" from "wander and hope".
- **A verify-by-state loop**: issue input, confirm the coordinate actually changed, retry or
  re-plan. Every failure phrased as *"scripted input did not get past X"*, never as a claim about
  the game.
- **Speed control**, measured rather than assumed — 200% delivers 2x, 400% delivered ~2.3x on a
  loaded host (`environment.md`).
- **One agent per emulator instance**, which is already the standing rule.

**Hard constraints.** This is dev tooling and never ships: `CLAUDE.md`'s rule is that nothing
shipped writes a save or game state, and the carve-out for dev-only test tooling is exactly this
case — a driver may cheat, an adapter may not. And a driven session is still only evidence of what
it actually did: a route that worked once is not a route that works, until it works twice.

**Not scheduled.** Filed because the pieces keep arriving anyway (the decomps are built, adapters
already read position, speed control is confirmed, the per-instance agent convention exists), and
the day someone wants a full playthrough as a test, this entry is the plan.

## Spawn to the game's cap, then DRAW above it — SHIPPED, both Pokémon adapters

Shipped for Emerald (`plans.md` 8.1) and Crystal (9.1), user-confirmed on screen. The reasoning a
third adapter should read before choosing a renderer is now the tier ladder in
[`adapters/_template/README.md`](../adapters/_template/README.md); the original entry is in the
`doc-history.md`, "Archived idea texts".

## A THIRD tier: a hardware sprite with no engine object — CLOSED 2026-08-21

Both halves resolved: the OAM tier shipped, and HBlank multiplexing is closed by decision, not left
open (ADR, `architecture.md`). Full text: `doc-history.md`, "Archived idea texts".

## A SPEEDRUN toggle: spawned and hardware only, never painted — filed 2026-08-21

**The user's rule, and the reasoning is theirs:** *"a 'speedrun' toggle should have drawn
disabled. only spawned & OAM. so that it can never hurt performance/make the run slower for
them."*

**Why this deserves a switch rather than a note.** The three tiers are not merely different
qualities of ghost, they are different COST CURVES, and only one of them can take the frame rate
down (`verified.md`, 2026-08-21):

| tier | cost as peers grow | ceiling |
| --- | --- | --- |
| spawned | rides along with work the engine already does | the engine's object array, ~11 in practice |
| hardware sprite | flat -- 56 measured identical to a bare emulator | the 56-entry OAM window, then OBJ tiles |
| painted | ~0.6ms per visible ghost, every frame | none, and that is the problem |

The first two have HARD CEILINGS, and a hard ceiling is exactly what a runner wants: whatever else
happens in the room, the cost of other players is bounded by the game's own limits and cannot
exceed them. The painted tier has no ceiling at all -- 56 painted peers measured 39.6 fps and 150
measured 10.4 -- so a crowded room can cost a runner their run through no action of their own.

**What the toggle does, and it is small:** force the painted tier off while leaving the other two
alone. Peers past both ceilings are then simply not shown, which is the pre-2026-08-19 behaviour
and is the right trade here. The standing rule against pop-in was about ORDINARY PLAY; a runner is
explicitly buying predictability with visibility, which is a different bargain.

**Do not implement it as a new rendering path.** It is a policy over the existing ladder, not a
fourth tier: the same dispatch with the last rung disabled. Anything more is a second way for the
tiers to disagree.

**Open questions before it is scheduled:**

- **Is it the runner's switch or the room's?** A local toggle protects one player and lets the room
  stay mixed; a room-wide one makes every client behave the same and becomes a `features` question,
  with all the compatibility weight that carries (`architecture.md`'s room-code ADR).
- **Should it also cap the SPAWNED tier?** Spawning is cheap but not free, and a runner may prefer a
  known small number to the engine's whole budget.
- **Does it need to be visible to other players?** A ghost not drawn for you is still drawn for
  them; nothing here is negotiated, and it probably should stay that way.

**Not scheduled.** Nothing here is committed until it moves into `plans.md`.

## Crystal: a ghost you can talk to — and eventually battle

**Status: the TALK half is confirmed working; the BATTLE half is unbuilt and unscheduled.**
Discovered by accident 2026-08-18 and user-confirmed the same day — a spawned ghost is solid and
talkable (`verified.md`, "a spawned ghost is solid, TALKABLE, and can be knocked off its tile").
Recorded because it is the largest new possibility this project had turned up to that date, and
because it arrived as a *bug report*, which is exactly how such things get thrown away. Note the
inherited script pointer has since been a fault three times over — it is what let a ghost clone a
trainer and hang the game (`pitfalls.md`); anything built here starts from that.

**What happened.** Crystal's ghost is built by copying a live NPC, and a map object carries a
`MAPOBJECT_SCRIPT_POINTER`. The copy took it, so the ghost inherited that NPC's dialogue — the user
walked up to a ghost, talked to it, and got *"Oh! Your POKéMON is adorable!"*. Wrong behaviour, and
in fixing it the real finding surfaced:

> **A ghost is a real object event, so the game will let you INTERACT with it. That mechanism is
> already there and already works — we did not add it and could not have designed it in.**

Every other adapter in this project renders presence and stops. **This is the first time a peer's
representation can be *approached and engaged* using a system the game already ships.**

**What it plausibly opens, cheapest first.** None of this is designed; the point is the ladder:

- **A ghost that says something.** Point the script pointer at our own text rather than an NPC's:
  the peer's name, where they are going, how long they have been playing. Cosmetic, no game state
  touched, and it makes a ghost legible instead of anonymous.
- **A ghost that responds.** The script system supports branching and conditions, so "press A on a
  peer" could carry an intent back over the wire — a wave, a ping, a "follow me". The event plane
  already exists on the Go side (`contract.md`, built 2026-08-17) and has **no live consumer**;
  this would be its first one.
- **Battling a peer.** `OBJECTTYPE_TRAINER` exists, and trainer battles are a normal thing a map
  object can start. The pieces the game provides are real. **What is NOT provided is any of the
  hard part** — see the caution below.

**The caution, and it is not a formality.** Everything past the first rung leaves cosmetic
territory, which is governed by `beyond-cosmetic.md` and by `plans.md`'s depth ladder, and needs a
deliberate decision rather than momentum. Specifically:

- **A battle is shared, authoritative gameplay** — two machines agreeing on turn order, damage,
  and an outcome that matters. That is the deep end of `beyond-cosmetic.md`, not an extension of
  presence, and the honest comparison is that Dolphin's lockstep netplay solves it by making one
  session rather than two independent ones (`access-models.md`).
- **`CLAUDE.md`'s never-write-a-save rule ends any version that persists a result.** A battle whose
  outcome changes a party, an item or a badge is out, permanently and without an ADR being able to
  rescue it. A battle that changes nothing is a demo; deciding whether that is worth building is a
  product question, not a technical one.
- **It would need the peer's actual party data**, which is a much larger sync surface than a
  position and a sprite id, and a much larger trust surface too.

**Do the first rung first, and treat it as complete in itself.** A ghost that can be talked to and
says who it is would be a genuinely new thing for this project, needs no new plane, persists
nothing, and would tell us how the interaction feels before anything is committed to the rest.

**Left switchable in the meantime**: `walk_test.lua` has `KEEP_TEMPLATE_SCRIPT`, default off. On,
the ghost speaks whichever NPC it was copied from — wrong, but a working demonstration that the
door exists.

## Links

- `agent_docs/plans.md` — the roadmap; move an idea here (with a phase number) once it's picked.
- `agent_docs/architecture.md` — where an ADR for any write-crossing or scope-crossing idea here
  would go.
- `agent_docs/risks.md` — Pseudoregalia's full ghost-collision incident history, required
  reading before touching TEVI's collision idea.
- `agent_docs/contract.md` — the event plane (built 2026-08-17), needed before emotes/chat/pings.

---

## Emerald: turning ghost collision off, if it ever needs turning off

**Decided 2026-08-18: ghosts stay SOLID.** Recorded here are the two alternatives that were
weighed and not taken, at the user's request — *"log the other 2 as potential changes afterwards.
if we ever want to disable collission specifically for that part"* — so a future session picks up
the analysis rather than redoing it.

**Why solid won.** It matches Crystal, whose shipped README already tells players *"It is solid,
the same way an NPC is; you cannot walk through a friend."* It costs nothing, and it fights
nothing — which the alternatives cannot both claim.

**How collision actually works** (`DoesObjectCollideWithObjectAt`, `event_object_movement.c:4724`):
two objects collide when they share a tile *and* `AreElevationsCompatible` says yes, which is true
when their elevations are **equal** or when **either is `ELEVATION_TRANSITION`, which is 0**
(`global.fieldmap.h:16`). A ghost inherits the player's elevation and the engine then recomputes it
from the tile — observed live going 3 -> 0 within a frame. Elevation 0 collides with everything,
which is why a ghost is solid everywhere, doorways included.

**The known hazard this accepts:** a peer parked in a one-tile doorway blocks it, and in the worst
case can shut someone into a room. Not seen in practice yet; it is a real possibility, not a
theoretical one, and the reason the alternatives are kept on file.

### Option A — solid, but never on a warp tile

Keep collision; despawn (or nudge) a ghost whose target tile is a door/warp. Targeted at the actual
hazard rather than changing physics globally, and it leaves normal "you cannot walk through a
friend" behaviour intact. Needs a way to identify a warp tile — the map's warp events are in the
map header, so this is a lookup, not a guess. **This is the one to reach for first** if the
doorway problem ever bites.

### Option B — pass-through ghosts

Force a non-zero elevation that differs from the player's, every frame. Removes the hazard
entirely and is a two-line change. Two real costs: it **fights the engine's own per-tile elevation
recompute**, which is exactly the pattern this project keeps having to unlearn; and elevation also
drives sprite priority (`SetObjectSubpriorityByElevation`), so a deliberately wrong elevation
changes occlusion — the ghost may draw in front of or behind terrain it should not. If this is ever
adopted, it is a compensation and belongs in `BANDAGES.md`.

## Driving the game itself: scripted input — DONE for BizHawk, OPEN for Pseudoregalia

**The BizHawk half is built and in routine use** — `joypad.set` drives the Crystal and Emerald
probes, `square_drive` hunts for faults, and the technique is written up in `_template/probes.md`
and `pitfalls.md`.

**The Pseudoregalia half is still unbuilt, and that is the open item here.** The entry's scope
quietly widened from that one game to "and beyond" without anyone restatusing it, which is how a
half-done idea reads as done. Full original text: `doc-history.md`, "Archived idea texts".

## BizHawk on Linux: the adapters are portable, the socket is not — filed 2026-08-18

**The gap.** BizHawk ships a native Linux build (`BizHawk-<ver>-linux-x64.tar.gz`), so a Linux
player can run Emerald and Crystal. **Our adapters cannot follow them there**, for exactly one
reason: they reach the network through LuaSocket, and what we ship is
`lib/x64/socket-windows-5-4.dll` loaded by `package.loadlib` next to `lua54.dll`. The filename says
it. Everything else in those scripts — the memory reads, the spawn recipe, the JSON codec, the
bridge framing — is plain Lua and portable.

**`packaging/unix/README-linux.txt` claimed the opposite** ("the scripts and their libraries are not
Windows-specific") and shipped in v0.9.5 saying so. Corrected the same day; the claim had never been
tested, which is the whole reason it survived.

**What it would take**, roughly in order:

1. A LuaSocket `.so` built against **BizHawk's own Lua 5.4** — the version must match, the same way
   the Windows pair does. Licensing is already settled: LuaSocket is MIT and `licensing.md` covers
   the pair we ship, so a Linux build of the same library raises no new question.
2. Platform detection in the loader. `loadSocketCore()` already walks a candidate list and logs
   every path it tried; this is one more branch in that list, not a rewrite.
3. Ship it beside the Windows DLLs in `games/pokemon/*/lib/`, and say so in the Linux README.
4. **Someone has to actually run it.** Until then this is untested, and the README must keep saying
   so rather than implying it works.

**Two things to check before starting**, because either could make this shorter or pointless:
- Whether BizHawk's Linux build exposes `package.loadlib` at all, and with which Lua. If its Lua is
  built without the C loader, no `.so` helps and the answer is "run BizHawk under Proton instead".
- Whether the Proton route already works. A Windows BizHawk in a Proton prefix would load the DLLs
  we already ship and talk to a Windows `meshghost.exe` in the same prefix — the arrangement TEVI
  and Pseudoregalia already use, and the one confirmed with a Linux tester on 2026-08-16. If that
  works it is zero code, and it may be the honest recommendation regardless.

**Not scheduled.** Filed because a Linux user asking "why do only two of the four games work for
me" deserves an answer better than silence, and because the README was actively wrong about it.

## Enemy/boss kill credit and participation, filed 2026-08-19

**The problem.** The moment several clients share an enemy, "is it dead?" and "who gets the
reward?" stop being the same question, and neither has an obvious default. If the server just
broadcasts "boss died", it dies for everyone who never touched it — they lose the fight and the
reward both, and the enemy can't be killed again for the drop. If it doesn't, nobody's kill ever
resolves.

**The rule.** **Damage buys participation.** Deal even 1 damage to an enemy and you are in — when
it dies, it dies for you, and you get the reward exactly as if you had killed it solo. Never damage
it and it stays alive on your client; when it dies for the others, nothing happens for you. The
target feel is *not* a new mechanic — it is "you killed an enemy in this game", unchanged, just
reachable by contributing rather than only by landing the last hit.

**Fully designed 2026-08-19 — see [kill-credit.md](kill-credit.md).** The model, the per-game
policy axes (liveness, credit, difficulty, player-count scaling), the difficulty ratchet, 19 hard
cases, and the MMO/co-op prior art all live there. The short version: don't sync "the enemy is
dead", sync *damage*, and let every client's own game arrive at death by itself — which needs no
change to `relay`, `core` or the wire contract.

**Why it's filed here and not under a game.** This is the general precondition for any
full-enemy/boss sync (see the Dark Souls entry above): without a credit model there is no
principled answer to whether a shared enemy is dead, so shared enemies aren't buildable, in any
game.

**Not scheduled**, and gated behind an ADR per game like everything at Tier 3.

**Amendment, 2026-08-20: a room toggle, and OFF must mean cosmetic-pure.** The user: kill credit/
participation *"should also have a config toggle for the server (for example if someone is
speedrunning, so that items/enemies etc are not affected for them, while still being able to just
visually see other players)"*. Same shape as `ghost_collision` and the share-items idea -- a room
policy the relay advertises at join -- and the speedrun case sharpens what OFF means: not "less
interaction" but a GUARANTEE that nothing in the game's state is touched by peers, so a run is
submittable. That guarantee is exactly the shipped cosmetic default, which means the toggle's off
position costs nothing to build -- it is the on position that waits for the Tier 3 ADR. Worth
noting for any future toggle's docs: a speedrunner's burden of proof is to a THIRD party
(moderators), so "off" should be verifiable from logs, not merely true.

**Refined by the user in the same breath into something better than per-feature toggles: ONE
"speedrunner" mode** -- *"could maybe just be a 'speedrunner' toggle or something, to force visual
only and less interactions between people, so its sterile/sane for speedrunning without affecting
things"*. That is a PROFILE, not a setting: one switch that forces cosmetic-only regardless of what
individual toggles say, the way the depth ladder in `plans.md` already frames tiers. It composes
cleanly with everything above: collision off, no item sharing, no kill credit, no event plane --
each of those toggles gains a master override rather than a sibling. And it is the right shape for
the moderator-proof point: "the room ran in speedrun mode" is ONE log line to verify instead of
five settings to audit. A client-side counterpart ("I am speedrunning, force MY session sterile
whatever the room says") is the same one-way override direction the collision policy already
established -- a client may always choose LESS interaction, never more.

## A per-game blocklist for a relay, alongside `only_game` — filed 2026-08-20

**The gap.** A relay host can already say *"this server hosts exactly one game"* — `only_game` in
`config.json`, logged at startup, and everything else is refused. What they cannot say is *"host
anything EXCEPT these"*. Those are different wishes and the second one has no expression today:
a host who is happy to run a mixed lobby but does not want one particular game in it has to choose
between allowing it and locking the relay down to a single title.

**Requested by the user, 2026-08-20**, in exactly those terms: *"we have the 'allow just 1 game' but
we don't have so people can specifically filter out game/s they don't want in the lobby."*

**Shape, if it gets scheduled.** A list rather than a string -- `"block_games": ["tevi", "emerald"]`
-- checked at the same place `only_game` is checked, which is the join. Two decisions worth making
deliberately rather than discovering later:

- **What happens when both are set.** `only_game` is an allowlist of one and a blocklist is its
  complement, so a config carrying both is either a contradiction or a redundancy. Refusing to start
  with a clear message beats silently picking a winner -- the relay already refuses to start when
  its transport selection cannot work, and that is the precedent to follow.
- **What the refused client is told.** The join refusal is the only thing a player sees, so it
  should say the game is not hosted here rather than something a player would read as a bug. The
  existing `only_game` refusal path is where that wording already lives.

**Why it is small.** `game_id` is already on the wire, already opaque to the core, and already
compared by equality at join. This adds one comparison against a list -- no new packet field, no
contract revision, and nothing an adapter has to know about.

**Not scheduled.** Nothing here is committed until it moves into `plans.md`.

**Amendment, same day, and it is probably the better first move.** The user, on reading the above:
*"would it be better to just make the allow list to be game/s? instead of 1 game, instead of having
a blacklist?"* Yes, mostly -- `only_game` being a list rather than a string is a smaller change than
adding a second setting, it needs no rule about what happens when both are set, and it covers the
mixed-lobby case the blocklist was asked for.

**Where the two genuinely differ, and it is the only place they do: what happens to a game nobody
has thought of yet.** An allowlist is default-DENY -- add support for a new game and every existing
relay refuses it until its host edits a config. A blocklist is default-ALLOW -- the new game is
hosted everywhere immediately, including by hosts who would rather it were not. Neither is right in
the abstract; they are two answers to "who has to act when the world changes", and a host who wants
a curated server wants the first while a host running an open lobby wants the second.

So: **generalise `only_game` to a list first**, because it is strictly better than a list of one and
resolves the original request. Revisit a blocklist only if someone actually wants default-allow --
and if both ever exist, the allowlist filters and the blocklist subtracts, which makes a blocklist
redundant whenever an allowlist is set and removes the contradiction the note above worried about.

**One compatibility point, since this is a config schema change on a shipped setting:** accept both
forms, a bare string and a list. Every relay config in the world today has the string, and silently
failing to parse one is exactly the failure mode `stripBOM` exists to prevent (`main.go`'s own note:
a config that silently loses `room_code` and `only_game` is worse than one that refuses to load).

**Decided by the user, 2026-08-20: default-deny is the point, not a side effect.** *"Yee thats
intended, 'allow just these games' dont allow other games to use my server at all."* So a new game
being refused by every existing relay until its host opts in is the wanted behaviour, and the
blocklist half of this entry is dropped rather than parked -- it exists only to serve default-allow,
which nobody has asked for. **What is left to build is one thing: `only_game` takes a list, and
still accepts a bare string.**

**The whole specification, in the user's words: two states and no third.** Unset -- host everything.
Set -- host exactly the listed games and nothing else. There is no partial mode, no precedence rule
and no interaction with anything, which is what makes this a small change rather than a policy.

## A "share items" room toggle, in the shape of the collision one — filed 2026-08-20

**The ask.** A relay-side switch a host flips for the room, the same way `ghost_collision` works
today: advertised to every client at join, advisory in exactly the same sense (the relay states the
policy and cannot verify an adapter honoured it). Requested by the user, 2026-08-20.

**The config half is genuinely small.** `ghost_collision` already does all of this -- a room policy
string, advertised at join, logged at startup, overridable by a client one way. A `share_items`
sibling is that pattern again, and the plumbing beneath it exists: the **escrow plane** was built
and Go-tested 2026-08-17 precisely so an item can move between two players without either side
being able to lose or duplicate it, and it has **no live consumer**
(`beyond-cosmetic.md`, `architecture.md`'s ADR).

**The adapter half is where the real decision is, and it is not a technical one.** `CLAUDE.md`'s
standing rule: **nothing that ships writes a save or game state -- ever, not even as a feature.**
That rule names this exact temptation by name -- the deeper planes make "just write the item in"
newly tempting -- so a shipped item-sharing feature is not something an adapter can quietly grow.
Turning it on means either revisiting that rule deliberately, or finding a route that does not
write.

**And there may be a route that does not write, which is the interesting part.** These games
already have a first-class mechanism for moving items and Pokémon between two players: the trade.
Driving the game's own trade path is the same principle every other part of this project runs on --
trigger the system, do not reimplement it -- and it would put every consistency guarantee, every
"can this item legally exist here" check, and every animation in the game's hands rather than ours.
It is also much harder than a memory write, which is precisely why it should be costed before
anyone reaches for the easy version.

**Order of work, if it is ever scheduled:** the toggle and its advertisement first (small, and it
lets everything else stay off by default), the escrow plane's first real consumer second, and the
question of HOW an item actually arrives last -- because that answer decides whether this is a
feature or a rule change.

**Not scheduled.** Nothing here is committed until it moves into `plans.md`.

## Split releases: platform-only and per-category bundles beside the full one — filed 2026-08-20

**The ask, in the user's own structure** (*"to kinda be future proof if we ever get a lot of
adapters/games"*), keeping the full release at the top:

- FULL — what ships today: Windows binaries plus every adapter
- emulator games
- indie games
- AAA games
- windows server/client only
- linux server/client only
- mac server/client only

**Why it is cheap to build and worth having.** The release zip is assembled by staging in
`release.yml`, and every split above is a different staging list over artifacts that already
exist -- the Go side already cross-compiles in CI, so the linux/mac server-client rows are mostly
"stop discarding what CI already builds". The category split maps cleanly onto the repo's own
layout (`adapters/emulator/` IS the emulator category; TEVI/Pseudoregalia are the indie one; AAA is
empty today, which is fine -- the row exists so the scheme does not need reshaping when it stops
being empty).

**The two decisions worth making deliberately:**

- **Category names: DECIDED by the user, 2026-08-20 -- emulator / indie / AAA, by what type of
  game it is.** Engine-based names were raised as the drift-proof alternative and rejected for the
  right reason: *"the average gamer wont even know the difference between the game engines"* --
  the categories exist for the person downloading, and "indie" tells them more than "Unity". The
  drift cost is accepted knowingly; if a game ever sits awkwardly between indie and AAA, that is a
  judgment call at release time, not a schema problem.
- **The server-client-only rows change who downloads MeshGhost.** A relay host today downloads a
  zip full of game adapters they will never load. A small server-only artifact is also the natural
  thing to point a VPS guide at (the hosting question the user asked 2026-08-20), and it makes the
  "run your own relay" story one download with nothing scary in it.

**Prerequisite worth naming:** the release staleness gate hashes the committed DLLs; a split
release must reuse the SAME staged artifacts, not rebuild per bundle, or the gate's guarantees
fragment across zips.

**Not scheduled.** Nothing here is committed until it moves into `plans.md`.

## "Hide every ghost, but still be one" — a client-only invisibility setting — filed 2026-08-20

**The ask, user 2026-08-20:** a client setting meaning *"don't show others' ghosts / can't see other
ghosts at all, just yourself"* while **still connecting and still showing up for everybody else** --
for speedrunners who want zero visual distraction but do not want to drop out of the room. Client
only, explicitly **not** a client/server pair: nobody else's view changes because you set it.

**Why it is its own thing, not part of the speedrunner profile.** The "speedrunner" mode above is
about *interaction* -- forcing a session cosmetic-pure so a run is submittable, which is a claim a
moderator can check. This one changes nothing about what peers may do to your game, because in the
shipped default they already may do nothing; it changes only what your own screen draws. Two
different guarantees, and folding them together would make the sterile-run claim mean "and I
couldn't see anyone", which is not what it is for. They compose -- a speedrunner will often want
both -- and that is the argument for keeping them separate switches with one profile able to set
both, exactly as the profile idea already frames it.

**It is genuinely one-sided, which is what makes it cheap.** Send is untouched: the adapter keeps
reporting local state, the core keeps publishing it, and every other client still sees you move.
Only the RENDER path is suppressed. That asymmetry also means nothing needs advertising at join and
no policy has to be advertised or verified -- unlike `ghost_collision`, there is nothing for a
relay to state, because a peer cannot tell and does not need to.

**Where the switch belongs is SETTLED, 2026-08-20: the core, as a receive-side filter** (ADR in
`architecture.md`). The user ruled the principle first -- the client/server never learns anything
about any game or adapter, no matter what config or feature gets added -- and then asked the
question that resolves it: can the core hold this and still be dumb, so it is reusable for every
game? It can. Dropping remote peer states needs no game knowledge; it operates on the contract's
own data, the same as the receive-rate cap. The two layers considered, and why the core won:

- **In the core**, dropping remote state before it reaches the bridge. Saves the adapter all
  per-peer work, applies to every game at once for free, and is the only version that also saves
  the per-frame cost of tracking peers -- which on Emerald is real: object slots, VRAM copies, and
  the drawn tier's per-peer painting. Risk: the adapter's ghosts must be torn down cleanly when it
  flips, not merely starved of updates, or they freeze in place instead of disappearing.
- **In each adapter**, drawing nothing. Simple per game, but it is the same work repeated per
  adapter and it keeps paying the tracking cost it was meant to remove.

The core version looks right for exactly the reason the core/adapter split exists, and the small
efficiency win is a feature rather than a side effect (a hidden ghost should cost nothing, not cost
the same and be invisible). Worth confirming the teardown behaves before committing to it.

**Also worth deciding when it is built:** whether it can be toggled mid-session (a speedrunner
practising, then running) or only at startup -- mid-session is much more useful and is precisely
the teardown case above -- and whether "just yourself" should still show peer *names* or counts
anywhere in the HUD, or truly nothing. The ask says zero visual distractions, so the default answer
is nothing at all.

**Not scheduled.** Nothing here is committed until it moves into `plans.md`.

## Scaling and efficiency — MOVED to `scaling.md` (2026-08-30)

**Six entries left this file for `agent_docs/scaling.md`:** the four efficiency axes, the general
culling model, distance culling the downlink, "stop sending when nobody can see you", the wire
format (JSON vs binary, ratified), and coalescing writes. They were scattered across ~700 lines
here and are one subject — what the Go side can carry — so they now live together, with the scale
principle at the top of that file. **New efficiency or scale ideas go there, not here.**

## BUG: with MESHGHOST_BRIDGE_PORT set, a rejected adapter hot-loops and its own log line is a lie (2026-08-28)

**Found live**, in the Emerald session that tested relay-side area filtering. Not caused by that
work -- it is pre-existing, and only shows when the relay is unreachable while the port override is
set. The user's console filled with this, hundreds of times:

```
MeshGhost: bridge connected on 127.0.0.1:7779.
MeshGhost: rejected (core: dial relay: dial tcp 127.0.0.1:7777: ... actively refused it.)
MeshGhost: port 7779 is a core that already has an adapter -- skipping it for 10s.
MeshGhost: bridge connection lost, will retry connecting.
```

repeating immediately rather than every 10s.

**Two defects, and the same line states both wrongly.**

1. **The cooldown is bypassed.** `connectBridge` returns early when `BRIDGE_PORT_OVERRIDE` is set
   (`meshghost_emerald.lua:964`, `meshghost_crystal.lua:9268`) and that early path never consults
   `busyUntil`, which is checked only in the port-walk loop below it. So `markPortBusy` logs
   *"skipping it for 10s"* and the next frame retries the same port anyway. The 10s is real for the
   walk and fiction for the override.
2. **The reason is invented.** `handleBridgeLine` passes a hardcoded *"is a core that already has an
   adapter"* to `markPortBusy` for EVERY rejection (`meshghost_emerald.lua:1941`). The actual reason
   string is printed on the line above and, here, said the relay could not be dialled. The code
   comment is right that no rejection should be BRANCHED on; it does not follow that every rejection
   should be DESCRIBED as the same thing.

**Why it has never been seen before.** Both conditions are needed: the override set (the dev
launchers set it; a shipped single-instance player has no override and gets the working cooldown)
and a core that keeps rejecting (relay down). Normal play meets neither.

**Why it is worth fixing rather than tolerating.** `crowd-limits.md` already records console spam as
a frame-rate killer in this exact adapter -- ~1,400 `console.log` writes a second took Emerald to
3fps, and throttling them restored 59.7. This loop writes four lines per reconnect with no delay at
all, so a player whose relay is not up yet pays for it in frame time while seeing a message that
misdescribes what is wrong.

**Both Pokémon adapters have it identically**, which is `ideas.md`'s own "rules that live in one
code path and are missing from their sibling" sweep, in its less usual form: not a rule missing from
one sibling, but a defect present in both.

**The fix is small**: have the override path respect `busyUntil` like the walk does, and pass the
rejection's real reason through to `markPortBusy` instead of a fixed string. Untested and
unscheduled -- it needs a live check with the relay deliberately down, which is cheap to arrange but
was not worth interrupting a test in progress for.

## Sweep: rules that live in one code path and are missing from their sibling

**Unscheduled.** Three instances surfaced in a single session (2026-08-22) and each reached the user
as a fresh bug report rather than as a known issue — see the table in `pitfalls.md`, "the learned
frame measured its parts from OAM entry 0". The shape is always the same: a rule is discovered,
fixed correctly, and written down, in ONE of the two or three places that need it.

**Why it is worth a deliberate pass rather than waiting.** These do not look like known issues when
they resurface, so each costs a full diagnosis from scratch — and the existing write-up actively
misleads, because it says the thing is fixed.

**Known multi-consumer rules in the BizHawk adapters, as a starting list:**

- **The four OAM entries mirror when the sprite flips** — consumed by the anchor calibration and the
  frame learner. Both correct as of 2026-08-22; check any third reader.
- **A value read from OAM belongs to the PREVIOUS frame** — consumed by the position model and the
  facing learner.
- **Place only on a settled camera** — the spawn path and the teleport path, in both adapters.
- **"Is this the player's sprite?"** — the learner validates it; the anchor calibration still assumes
  entries 0-3 without checking, which is the same assumption that produced the facing bug.

**Method:** for each rule, grep for every reader of the underlying data rather than for the rule's
own wording — the sibling path never mentions the rule, which is exactly why it was missed.

## TEVI: the orbitars are not synced at all, projectiles included (2026-08-28)

**The user's own framing:** *"we haven't added the 'orbitar' orbs yet -- basically 2 balls that fly
around with the player and can do ranged attacks + some other fancy skills, but we do have to add
those as well + sync up their ranged/projectiles as well sometime"*.

**Two halves, and they are not the same problem.**

- **The orbs themselves are cosmetic** and should follow the pattern that worked three times on
  2026-08-28: read what the game decided, send it opaquely, let the game render it. The probe
  already saw them -- `Orb Trail (1..7)` and `GemaOrbTrail` showed up in a hierarchy scan -- so
  finding the mechanism starts from evidence rather than from names.
- **The projectiles are NOT obviously cosmetic**, and that is the part to think about before
  building. A bullet that exists on the watcher's machine can hit things. `ChargeShot` spawns real
  ones through `BulletManager`, alongside its `OrbChargeFlash`, and the two are tangled in one call
  -- the same shape as the warp's animation being tangled with an autosave, and the charged
  attack's burst with a global hitstop. **The visual half is the deliverable; a peer's bullet
  damaging your enemies is a gameplay plane, not a cosmetic one** (`beyond-cosmetic.md`).

**What is already known and does not need rediscovering:** `chargeheld` is a public byte on the
physics component and is the ORB charge (it drives `chargeTips` and `orbUsing`), not the melee one
-- established while hunting the melee charge on 2026-08-28. `GemaChargedShotCombo` holds the
charge combo state.

**The mirroring mechanism to reuse, and its one trap:** `MirroredCommonEffectTable` in
`Plugin.cs` already carries pooled effects by index with per-effect placement. Adding an effect is
adding a row. **But read `pitfalls.md`'s echo-loop entry first** -- detecting effects by watching a
shared pool makes symmetric peers feed each other, and the guard is identity, not distance.

## Interpolation delay should be PER ADAPTER, not one number for every game (2026-08-28)

**The user's observation, and it is about the shape of the games rather than about tuning:** a
tile-based game plausibly needs more interpolation delay than a free-movement one. Pokemon moves a
character in whole-tile steps at a fixed cadence; TEVI and Pseudoregalia move it continuously in
world units. One delay that suits both is unlikely to be the best either could have.

**Today there is exactly one number.** `core.DefaultInterpolationDelay` is 250ms, set with `-interp`
per launch. Nothing about it is game-aware, and **nothing about it may become game-aware in the
core** -- `CLAUDE.md`'s hard rule and ADR 08-20 forbid the core or relay knowing which game it is
carrying, so `if game == "emerald"` is not available and never will be. That constraint is the
whole design problem here, not an obstacle to route around.

**Which leaves the adapter as the only honest place for the knowledge**, since it is the one
component that is allowed to know the game. Two shapes worth weighing, both of which keep the core
game-blind:

- The adapter DECLARES a preferred delay over the bridge, the way it already declares `features`
  and its `game_id` in its Hello, and the core treats it as an opaque number it was handed rather
  than one it reasoned about.
- Or the delay stays a deployment setting and each game's `dev-scripts` launcher simply passes a
  different `-interp`, which needs no protocol change at all and is the cheaper first step.

**The precedence rule, the user's, 2026-08-28 — and it is the part that makes this safe to build.**
Unset means **the adapter's own default** for whichever game is attached; an explicit `-interp`
means **that value, for every adapter, no exceptions**. So the flag is not a per-game override and
never grows into a table of them: it is a global "stop deciding for me".

Two things follow, and both are why this shape is worth preferring:

- **The core still knows nothing about any game.** It holds either a number an adapter handed it or
  a number the operator typed, and cannot tell which game either came from. The game-specific
  knowledge stays entirely inside the adapter that is allowed to have it. No `if game ==` anywhere,
  which is the constraint that kills the obvious designs.
- **It matches the precedent this repo already set** for `MESHGHOST_BRIDGE_PORT`: *"an explicit port
  is honoured and then not walked -- someone who names a port means that port, and silently landing
  elsewhere would be worse than failing"* (`emerald/FLAGS.md`). Same principle, different knob:
  an explicit value is a statement of intent and must not be quietly improved upon. A per-game
  default that overrode a typed `-interp` would be exactly that mistake.

**A measurement is still the first step, not the mechanism.** Whether the difference is
real and worth a mechanism is unknown. Nobody has compared a tile game and a continuous game at the same delay
and judged them side by side, so "Pokemon needs more" is a well-motivated hypothesis and not yet a
measurement. The cheap experiment is the second shape above -- vary `-interp` per game from the
launcher, judge on screen, and only then decide whether it deserves to be in the protocol.

**Related:** the receive-rate cap and `clock.v1` skew handling are the two other knobs that change
how a remote looks, and neither has been judged against a tile game either. `architecture.md`.

**A DIFFERENT AXIS OF THE SAME KNOB, found 2026-09-03 and filed as a defect rather than an idea:**
the delay is not only one number per GAME, it is one number per PEER, and a ghost this core
INVENTED (a replay, a chaser) does not want the network's number at all. Local samples never
crossed a network, so the 450ms that covers jitter and loss buys nothing and simply draws a 3s
chaser 3.45s behind. That is per-peer-CLASS, not per-game, and it is being built now --
`phases/phase11.md`, 2026-09-03 (late). Worth noting for THIS entry: the per-peer plumbing it puts
in is the natural place a per-adapter value would later land, so this idea gets cheaper, not
harder, and it still needs its measurement before it needs a mechanism.

## Two Go file splits, scoped and deliberately not done (2026-08-27)

`netx/udpconn/udpconn.go` was split the same day — 964 lines into `cookies.go`, `conn.go`,
`listener.go` and `dial.go`, along the banner comments that file had already drawn around its own
four concerns. **These two were looked at in the same pass and left alone, because neither is the
pure move that one was.**

- **`protocol/online.go`, 861 lines over six concerns** (`ValidOpaqueString`, the capability/feature
  system, Hello/resume validation, lease, escrow, world custody). The obvious cut is `features.go` /
  `lease.go` / `escrow.go` / `world.go`, following `limits.go` and `ghostcollision.go`. What stops it
  being mechanical is the single const block headed *"Limits for everything in this file"*, which
  deliberately co-locates the event, lease-key, escrow and resume-token bounds. Splitting the file
  either scatters that block or makes its own heading false, and the honest answer is probably that
  those constants belong in `limits.go` — which is a **design decision about where limits live**,
  not a file move, and wants its own pass.
- **`relay/relay.go`, 1,517 lines, with `handleConn` alone 539 of them.** The natural extraction is
  the Hello handshake into `relay/hello.go` and the post-join dispatch switch into
  `relay/dispatch.go`. That is splitting a **function**, not moving code between files, on the path
  every connection takes — so it is a change whose regression would be attributable only to itself,
  and bundling it behind six other commits is what makes that impossible.

Also worth doing and not done: `cmd/meshghost`'s 286-line `main()` wants the `flags()` extraction
that `cmd/meshghost-relay/main.go` set the precedent for on 2026-08-25 ("so the rule can be
tested" — it turned one rule into nine test cases), and `core/core_test.go` is 2,231 lines.

## Four refactors still deferred from the 2026-08-18 audit-and-refactor pass

Moved out of `status.md` 2026-08-25 — it is an index of what is open, not a backlog with
rationale. The pass itself fixed two real relay bugs, four adapter defects and ~60 stale doc
claims; five were identified, scoped and deliberately NOT done, because each needs a live game to
judge or is large enough that bundling it would make one confirmation pass unable to isolate a
regression. **Four are left: `internal/cfg` shipped, and this heading said "Five" until
2026-08-27** while `status.md` had already said four.

- **`Plugin.cpp`'s `game_thread_tick()` is ~4,000 lines in a 10,347-line file.** Per-remote blocks
  are the next extraction; on the adapter's hot path, so it needs a live session.
- **The two BizHawk Lua adapters do NOT duplicate ~400-500 lines each any more — they have
  DIVERGED, which is a different and harder problem.** Measured 2026-08-27, comments and whitespace
  excluded, on the three blocks this entry named:

  | Block | Crystal | Emerald | Code similarity |
  |---|---|---|---|
  | `scriptDir` | 24 code lines | 21 | **49%** |
  | `loadSocketCore` | 23 code lines | 20 | **33%** |
  | JSON codec | 97 lines, 3 functions | 294 lines, 7 functions | different algorithm |

  The JSON codecs are not two copies of one thing: Emerald's decoder is recursive-descent
  (`decodeString`/`decodeNumber`/`decodeObject`/`decodeArray`, nine call sites) and Crystal's is
  not. `scriptDir` differs in its match pattern and its environment-variable names; `loadSocketCore`
  differs in structure. **So a shared `adapters/emulator/lib/` is not a code MOVE.** It means
  choosing one implementation per helper and changing the other game's behaviour to match — on the
  socket-loading and script-directory path, whose failure mode is *the adapter is silently absent*,
  on both shipped games at once.

  **That is still worth doing**, and the reason is not tidiness: it is the only real answer to the
  200-local ceiling (Crystal 197, Emerald 198 — `emulator/CLAUDE.md`), where grouping constants onto
  tables is explicitly a bandage. But it is a session of its own, with a live confirmation per game,
  and it needs `release.yml`'s staging changed to match.

  **Two traps already paid for, to design around before writing a line.** A shared module loaded
  with `dofile` sees `debug.getinfo(1,"S").source` as a RELATIVE path, so a module that resolves its
  own directory gets `"."` — which passes the absolute-path guard's sibling branch and then fails
  where it matters, because `package.loadlib` resolves a relative DLL path against BizHawk's process
  directory. **The host adapter resolves `SCRIPT_DIR` and passes it in.** And the env-var names are
  game-specific on purpose: BizHawk runs every script in one process, so a shared name leaks one
  adapter's folder into the next one loaded.
- **Probe boilerplate: a near-identical block across the Crystal probes**, including the ROM
  guard. **Twelve** probes carry the `PM_CRYSTAL` header check — the ten `spawn_test`,
  `spawn_test2`-`7`, `struct_diff_probe`, `walk_test` and `grant_test_kit`, plus `grant_items` and
  `set_level`. Recorded as eight, then nine, then ten, then twelve: **count it, do not quote it** —
  `grep -lc PM_CRYSTAL adapters/emulator/pokemon/crystal/probes/*.lua | wc -l`. Divergence between
  the copies is the risk, not the line count.
- ~~**`cmd/meshghost` and `cmd/meshghost-relay` duplicate ~120 lines of config/log plumbing**~~ —
  **DONE.** `internal/cfg` shipped; `StripBOM`, `ApplyDespiteBadValue`, `Override` and
  `OpenLogFile` live there and `grep -rn stripBOM --include=*.go` returns nothing.
- **TEVI: the `bridge_ready` send gate, and the port walk.** The message is RECOGNISED as of
  2026-08-18 but not yet waited on before sending. Entry 5 in `adapters/tevi/BANDAGES.md`.

## Doc restructuring: what was done — moved to `doc-history.md` (2026-08-25)

The record of the doc-restructuring passes — what changed, what was left alone and why, and the
measurements not to re-derive — now lives in [doc-history.md](doc-history.md). It was 282 lines
of dated history inside a backlog, and it quotes canonical rules verbatim, which forced
`preflight.ps1` to exempt this entire file from the canonical-source drift check. The exemption
moved with it; this file is now checked like every other.


## Fuzz the SCHEDULE, not just the bytes — randomized ordering and timing (2026-08-28)

**The user's question, and it is the right one:** *"do we have random start/stop timings for things
as well in the tests? we have had a lot of 'ohh this only happens after 8-15sec' or ohh this only
happens early/late?"* and *"basically fuzz everything?, even how long/short times are between
things?"*

**The gap, and a correction to how it was first stated (2026-08-29).** The original claim here was
"not one fuzzer targets ORDER or TIMING". That was wrong, and wrong in the way worth recording:
`core/schedule_convergence_fuzz_test.go`'s `FuzzSchedule` has fuzzed SCHEDULES all along — attach,
frame and drop events in a generated order, asserting convergence. The claim came from listing
target names and reading their categories rather than reading what they do.

What IS true is narrower: no target fuzzes DURATIONS, the reconnect tests each run one fixed
sequence, and `FuzzSchedule` cannot reach outage-length behaviour because the cadence it would have
to wait out was a constant until 2026-08-29.

**2026-08-28 is the case in point, twice in one evening.** A nametag failed depending purely on
WHICH SIDE CONNECTED FIRST — a peer already in the room took a different code path from one that
joined while you watched, and no test varied that. And the underlying adapter bug was a readiness
flag sampled one call too early, which only bites on the single tick where acceptance arrives.

**Why this is affordable, which is the part that decides whether it ever gets built.** All four
timing constants that matter are already PER-CORE FIELDS, not hardcoded: `InterpolationDelay`,
`MinSendInterval`, `IdleKeepalive`, `RemoteStaleAfter`. So the clock compresses — set
`RemoteStaleAfter` to 30ms instead of 3s and "peer silent for ten times the stale window" costs
300ms. "Only happens after 8-15 seconds" becomes a 40ms test, same code paths.

**Two tiers, and only one of them gets fuzzed:**

- **Fast tier, in-process, fuzzed.** The seed picks both the delays and the ORDER of events: relay
  up, client connects, adapter attaches, peer joins, peer goes silent, relay restarts, peer leaves.
  A compressed cycle is ~50ms, so a few hundred schedules is under a minute — CI-affordable under
  `-fuzztime`.
- **Slow tier, real binaries, NOT fuzzed.** `internal/e2e` is dominated by process startup, which
  cannot be compressed. Keep it to a handful of fixed shapes chosen for cases known to matter.

**Assert INVARIANTS, never a script** — a script is what makes these brittle. Things that must hold
under every ordering: every peer that set a name eventually has it delivered to every other
adapter; no ghost outlives its peer's leave; the core's roster never disagrees with the relay's; a
reconnect never leaves a peer permanently invisible.

**First piece of work, and it is small:** make `MaxReconnectBackoff` (15s), `DefaultHeartbeatInterval`
(20s) and `DefaultHelloTimeout` (10s) configurable the way the other four already are. Until then a
long-outage test costs real seconds, because the backoff cap cannot be shrunk.

### BUILT, 2026-08-29 -- and it found three bugs on its first campaign

`Core.ReconnectInitialBackoff`/`ReconnectMaxBackoff` shipped (`core/backoff_test.go`;
`HeartbeatInterval` and the relay's `HelloTimeout` were already fields), and the fast tier exists as
`core.FuzzSchedule` in `core/schedule_convergence_fuzz_test.go` -- two cores, two adapters, one
relay, a seed-chosen order of attach/detach/relay-drop/send with seed-chosen delays, and the
invariant "once both are attached and sending, each renders exactly the other, under the other's
name". A second, narrower target on the same idea (`FuzzNameDeliverySurvivesAnyConnectOrdering`)
covers the connect-ordering half.

**Five bugs, all the predicted family** (three found locally, then two more by CI's Windows
runner against the target's own seed corpus -- reproducible here only at `GOMAXPROCS=2`, which is
itself a lesson: a concurrency test's parallelism setting is part of what it can see) -- a game left permanently invisible by a drop landing on
the wrong tick. The evidence and the regression tests are in `verified.md` (2026-08-29): a drop
inside the join handshake, the same hole in the ownership-transfer path added the day before, and a
mid-handshake hangup that nothing was watching for. Every one of them had an attached adapter, a
`bridge_ready` already sent, no error in the log, and nothing retrying -- which is why no amount of
staring at a live session would have produced them.

**Two lessons about the method itself, both paid for:**

- **A compressed clock is only honest while it stays longer than the machine's scheduling noise.**
  At 50x (a 60ms stale window) twelve fuzz workers on one desktop starved each other into failing
  two perfectly healthy cores. 15x is the setting that stopped lying.
- **A test knob that is too tight HIDES bugs as well as inventing them.** The 2s dial timeout the
  other tests use was concealing the third finding completely; raising it to a realistic ten
  seconds made that bug reproduce on every single run.

**Still open here:** the target is not in CI, because the rig leaks a `Core` per iteration (there is
no `Core.Close`) and a long single-process campaign exhausts Windows' ephemeral ports and kills the
worker. Giving `Core` a real shutdown is the prerequisite, and it is worth having for its own sake.
The slow tier (`internal/e2e`, fixed shapes, not fuzzed) is unchanged.

**What does NOT compress at any price**, so the e2e tier keeps a floor: quic-go's own ~17s idle
timeout, OS socket behaviour, and process startup.

**And the class this never reaches**, worth knowing so it is not oversold: bugs needing ABSOLUTE
elapsed time or accumulation — a sequence number wrapping, a token expiring, a slow leak. Those are
tested by seeding the counter near its limit, not by waiting.

**Honest limit on the whole idea:** it would have caught the ordering half of 2026-08-28 and NONE
of the other half. `RegisterComponent` not being a reflected UFunction is a fact about a shipped
game's reflection data; no amount of Go fuzzing can see it. The live failures split into those two
families and this addresses one.

### Follow-up (2026-08-29): the first schedule fuzzer exists, and it is SOCKET-bound

`core/schedule_fuzz_test.go` implements the fast tier for one invariant — a peer's name reaches
another adapter however the session was assembled. Its seeds are the two orderings that mattered
live, and they run green in every `go test` in about a second.

**What building it taught, which changes the plan above.** Compressing the CLOCK was the easy half
and it worked. The binding constraint is sockets: every input stands up two cores and a bridge, so
`-fuzz` at full tilt (550 execs/sec, 12 workers) exhausts Windows' ephemeral ports in seconds.

**Four harness limits were hit before that was clear, and every single "failing input" was one of
them rather than a product bug:** ephemeral-port exhaustion, leftover peers from previous inputs
sharing a relay, relay capacity (`server full`) because cores never hung up, and TIME_WAIT
accumulation that persists even at `-parallel 2`.

**So the tier split in the entry above needs a third line.** A schedule fuzzer over REAL sockets is
not a continuous CI fuzzer; it is a table of orderings that happens to be fuzzable in short,
deliberate, low-parallelism bursts. To explore deeply it would have to drive the core over an
in-memory transport — a bigger change than it sounds, because part of what is being varied IS the
ordering of real dials.

**Unchanged and still worth doing:** the invariant framing, and making the remaining constants
configurable. `MaxReconnectBackoff` and `InitialReconnectBackoff` are Core fields as of 2026-08-29
(commit f25b38c); `DefaultHeartbeatInterval` and relay's `DefaultHelloTimeout` are not yet.

## Pseudoregalia: mirror a peer's REAL light state onto their ghost (filed 2026-08-30)

The shipped policy is that a ghost NEVER glows — vertex light killed, blade aura hidden, the same
call as the blue outline (user, 2026-08-29/30: *"keep it fully disabled similar to how we did with
the blue outlines"*). Cost of that policy: a peer who legitimately owns the ascendant light (the
`havelight?` save flag), or is carrying the temporary post-pickup light, shows none of it to
others — the user watched exactly that go missing on 2026-08-29.

If ghost light parity is ever wanted, the shape is the observation mirror the recall glow uses:
put the peer's actual light state on the wire (the save flag plus the temp-light window), and on
the ghost re-enable its `LightMesh`/vertex light only while the peer's state says lit. The scene
latch is no obstacle any more — post-spawn `FixAllLights` ships — but a ghost's vertex light
painting rooms bright around it is why "too bright near other players" was the original complaint;
any implementation should cap or skip the room-painting half and keep only the character-visible
part. Filed on the user's ask: *"log it somewhere if we ever do want to give ghosts real
synced/mimiced light in the future"*.

## Ghost RECORDING and racing a replay — the wire format is already a replay format (filed 2026-08-30)

**PICKED UP 2026-09-03 as Phase 11** — ADR 0047 decides the model (a replay is a local fake peer),
ADR 0048 the hotkeys, `plans.md` the stages, `phases/phase11.md` the log. The prerequisite below
("debugging tool or shipped feature?") was answered: shipped, player-facing, sharable files. The
chaser ("Badeline") and the chaser pack came from the same conversation. Kept as the research trail.

**Quoted observation, relayed by the user 2026-08-30 and recorded verbatim** — secondhand, about
Trackmania specifically, and **not verified against that game by anyone here**:

> *"depending on the game it either saves inputs (if the game is fully deterministic) or enough
> state to recreate it (basically what is being send by MeshGhost anyway) so I would have just
> replaced the client and instead of sending to the server for syncing, saved it to a file.
> Trackmania can reduce a lot of complexity by just not having to many states iirc. it's just
> position + rotation, steering value, break, accelerate and which special effects are active and
> you can fully recreate it. Then add limited polling + interpolation and things are good enough"*

**Filed for two purposes the user named: a time-trial/race-against-a-ghost feature, and as a lens on
making ghosts cheaper.** Prior art for PRESENTATION rather than the wire is already noted in
`scaling.md`'s culling entry; this is the other half of that same conversation.

**WHY THIS IS CHEAPER HERE THAN IT LOOKS: the replay format already exists.** A recording is this
project's own state stream written to a file instead of a socket — same `protocol.State`, same
timestamps, same `extras`. Playback is a fake peer: read the file, feed it into the interpolation
buffer, and every renderer, every adapter and every knob works unchanged, because nothing
downstream can tell where a snapshot came from. **No new format, no new render path, no adapter
work.** That is a genuinely small feature hiding behind a big-sounding name, and it is the strongest
argument for building it if anyone wants it.

**THE INPUTS-VS-STATE FORK, and this project has already answered it by construction.** Recording
INPUTS is smaller and needs the game to be fully deterministic; recording STATE is bigger and needs
nothing. **We cannot assume determinism and should not try**: an adapter has no way to prove its
game is deterministic, a patched ROM or a different build breaks it silently, and the failure mode
is a replay that diverges halfway through with nothing to detect it. State is what we already send,
and it is the robust half of the fork — the quote's own "or enough state to recreate it".

**THE PERFORMANCE LESSON, which applies whether or not the feature is ever built: minimise the
number of distinct STATES a ghost must express, not the bytes.** The Trackmania reading is that a
whole vehicle is position, rotation, three scalars and a small set of active effects. This project
already does the same thing in one place and should keep doing it — Pseudoregalia sends effect KEYS
from a fixed table rather than asset paths, so a peer's VFX is one short string and the receiving
game supplies the rest. **The generalisation is the existing let-the-game-do-the-work rule**: send
the QUESTION, not the answer, and a small closed vocabulary beats a rich open one for cost AND for
safety (an unbounded peer-controlled name lookup is its own risk — see "The ACE audit").

**Not scheduled, and it has one real prerequisite:** deciding whether a recording is a debugging
tool (agent-side, dev only) or a shipped feature players see. Those want different things — the
first wants completeness, the second wants a file small enough to share and a UI to race against.
**Nothing about Trackmania here has been checked**; if this is ever picked up, that starts with
`licensing.md`, not with a download.

### What people actually want from it: controls, scrubbing and SLOW MOTION (added 2026-08-30)

**A friend of the user, quoted:**

> *"I'd very much use it if we could press a button to start/stop recording and another to replay
> the last recording (maybe add a console command to the UE4SS console to save/load from file?) If
> we then could scrub the replay or slow it down, that'd be insane to use especially considering it
> could be reasonably well added to any game as long one puts in the work to get an adapter for it.
> Doubt it would be much use in like GBA pokemon, but for any 3d platforming game it'd be really
> nice to see things from other angles when trying stuff"*

**And the user, on speed:** *"being able to replay something like this at a faster/slower speed
could be cool, like playing against a ghost that does things at half the speed so you can
see/watch what it does"* — with the caveat that it *"would probly also require some menu/in game
things to actually feel nice to use"*, which is the honest half.

**SPEED CONTROL IS NEARLY FREE, and that is the surprising part.** Playback is a fake peer feeding
the interpolation buffer, and the interpolator already renders at an ARBITRARY time between two
samples — that is its whole job. So "half speed" is advancing the replay clock at half rate and
nothing else. **The one rule: the render clock must scale with playback, not stay wall-clock**, or
position and the interpolation delay end up on different clocks — the same lockstep failure the
rotation work turned on (ADR 0043).

**Fast and slow are NOT symmetric, and the asymmetry is useful:**

- **Slow motion IMPROVES**, because the same samples are spread over more frames — more
  interpolation between each pair, nothing invented.
- **Fast forward DEGRADES**, and predictably: 2x playback of a 20Hz recording shows the visual
  information of 10Hz, because you cannot invent detail nobody sampled. Expect a fast replay to
  look like a low-rate one, and do not read that as a bug.

**SLOW MOTION IS ALSO A DIAGNOSTIC INSTRUMENT, which may be its strongest argument.** It is a
magnifying glass on interpolation quality: at 0.25x, a facing that steps, a ghost that snaps at a
bracket boundary, or a prediction being taken back all become obvious where they are invisible at
1x. That is precisely the class of defect this project keeps chasing through expensive live cycles
(the 2026-08-30 facing step took a three-launch A/B), and a scrubbable slow replay would turn some
of them into something an agent can inspect alone. **Worth weighing when the render sweep in
`plans.md` needs finer evidence than "looks choppy".**

**SCRUBBING NEEDS THE FILE AS THE SOURCE OF TRUTH, not the buffer.** `remoteBuffer` deliberately
holds only a short window (derived, ~600ms floor — see `hz-ceiling.md`), so a seek cannot come from
it. Playback reads the file, so seeking means re-filling the buffer around the new time. Cheap, but
it is a real design point rather than a free consequence.

**THE LAYERING, so nobody builds this game-aware:** the CORE owns record and playback, because a
state stream is game-agnostic and that is the entire reason this is small. The ADAPTER owns the
TRIGGER and the UI — a hotkey, a UE4SS console command, an in-game menu — because a keybind and a
console are per-host concerns and the core may not know what a keyboard is. Same split as every
other capability here.

**The friend's read on which games benefit is right, and it generalises: VALUE SCALES WITH CAMERA
FREEDOM.** A fixed-camera 2D game gains little for a player, because a replay shows the same
pixels from the same angle; a 3D game with a movable camera gains a lot, because the replay is the
only way to watch your own run from somewhere else. **The exception is US:** even in GBA Pokemon a
deterministic replay of a bug would be worth having as a dev tool, which is the same
debugging-tool-vs-player-feature fork the entry above already names.

**Still unscheduled, and the UI is the real cost.** The recording and the speed control are small;
"feels nice to use" is a menu, a scrub bar and per-adapter input handling, and that is where the
work actually is.

## Go side: carry the previous state in every unreliable packet, quic datagrams and udp alike (loss redundancy, 2026-09-02)

**Where it came from.** Watched on Crystal on 2026-09-02 (`crystal/UNVERIFIED.md`, the interp ladder
entry): on a 100–200ms link with 2% loss and the shipped 250ms interp, the ghost snapped on quic and
snapped, glided and teleported on udp. **Same mechanism on both**: the state plane is unreliable on
each (a QUIC datagram is fire-and-forget like a udp packet; only hello/control ride the stream), and
the client suppresses unchanged states, so the one packet carrying "I stopped here" has no successor
until the 250ms keepalive, and losing it leaves the ghost walking on and then jumping. How the user
views the three transports, in their own words the same day, *"at least how i view the 3 protocols
personally"*: quic is the default, tcp is there *"to bypass things"*, and udp is *"just fun/optional
... similar to how we allow people to easily change the hz"* — kept because removing an opt-in feels
bad, not something to invest in on its own. So this is worth doing ONLY because it fixes the default
quic path in the same change.

**The idea.** Every unreliable state frame — quic datagram or udp packet, they share the shape — also
carries the previous state (or the last N). A single lost packet then costs nothing — the next one re-delivers what was missed — and only a
run of losses shows. It is the standard trick for unreliable game transports and costs roughly one
extra state per packet (~2x state-plane bytes on both transports). Alternatives: lower the
keepalive on udp only (cheaper, weaker), or send the terminal "stopped" sample twice.

**BUILT the same day — ADR 0045**, as a rate-gated delta (`protocol/prev.go`); this entry stays as the record of why. What it needed, and got: a contract note (the `prev` field), a change at `core/sending.go` and its receiver (not in either netx package — the redundancy is above the transport), and the
loss-injection e2e in `internal/e2e` to show the teleport before and its absence after. Judged on
screen the same way, on the same rig.

## Go side: quic datagrams are congestion-controlled, so a loss paces the samples after it — measure, then decide (2026-09-02)

**Seen, not measured** (`crystal/UNVERIFIED.md`, the bike rows of the loss-cover entry): at 300ms interp
on a 75ms ±25ms loopback link with 2% loss, the bike glided a little on quic and looked fine on udp, and
was clean on quic with loss off. The loss cover (ADR 0045) covers a LOST sample on both transports
equally, so the difference is what happens after a loss: quic-go sends DATAGRAM frames inside ordinary
packets, which are subject to the connection's congestion controller, so a loss shrinks the window and
the next few samples are paced out late. udp has no controller and sends the moment the core asks.

**Measure first.** A receiver-side instrument: per state, `arrival - timestamp` (the core already has
the clock offset), logged around each recovered sample, quic against udp on one netsim seed. If quic
shows a late cluster after every loss and udp does not, the theory holds. Only then decide between:
sending datagrams outside the controller (quic-go has no public switch for that; check its
`Config` before assuming), a larger initial window, or accepting it and saying so in `docs/`. Not a
reason to change the default transport: quic is the default for encryption and spoof resistance, and a
hint of glide after a lost packet on a bike at 15Hz is the price so far.

## Adapter-specific settings in the per-game config.json, read by the mod itself, instead of in-game menus — filed 2026-09-03

**The user's thought, the night `"autostart"` moved from an environment variable into the config:**
*"this is maybe how we can add more 'adapter specific' settings later as well? like enabling the
clients own config to change game related things? so we can avoid making in game menu's to apply
changes."*

**What already works this way.** Every game's `config.json` is one file two readers share: the
client (`meshghost.exe`) reads the keys it knows and ignores the rest, and the mod or script reads
the keys IT knows before the client exists -- `autostart` in all four (2026-09-03), and
`local_game_bridge` in Pseudoregalia (2026-08-28). Both are hand-parsed with a regex or a string
scan, so no JSON library entered any adapter, and a key the client does not know costs nothing.

**What it would mean.** A game-specific knob -- a ghost tint, a nametag font size, the drawn tier
on Emerald, whether a TEVI ghost's effects play -- becomes a line in the file a player already
edits, applied at load, no in-game menu built and no UI toolkit pulled into a mod. The cost is
the one every extra key has carried so far: a name to keep spelled the same across the file, the
README and the mod, and a restart to apply it.

**The user's examples, same morning:** *"could have things like 'online enemies', 'online items'
true/false etc. just probly a good/simple way to handle it if we ever do make bigger changes to a game,
to easily swap/change things by the user afterwards."* That is the opt-in switch for the deeper planes
(`beyond-cosmetic.md`: events, leases, world custody) expressed per game in the player's own file --
`"online_enemies": false` shipped, flipped by the player who wants it, no menu -- and it is the shape
the `features` key already has at the protocol level.

**The rule if it happens:** game-specific keys live in that game's file only, never in the root
`config.json` (which every game is cut from), documented in that game's `README.txt` under the
same ADVANCED heading; a mod that reads a key logs the value it read once, the way the launcher
logs its port and its autostart decision, so a typo shows up as a wrong value rather than silence.


## Fuzz the REPLAY schedule under the race job: attach, first frame, files, seeks, gaps, detach (filed 2026-09-03, DONE 2026-09-03)

**The user's question, on the day CI's race job caught a test-ordering race the local runs missed:**
*"don't we fuzz things in random order as well? ... can we actually just randomize EVERYTHING possible for
fuzzers?"* The schedule fuzzers (`core/schedule_fuzz_test.go`, `schedule_convergence_fuzz_test.go`)
randomize the order of REAL events and the loader fuzz throws random headers at playback — but nothing
randomizes the replay feature's own lifecycle: files appearing in `replay/active/` before or after the
adapter attaches, the first in-game frame landing before or after `StartReplays`, seeks arriving during a
seam or the end-of-clip hold, a live gap during a chaser's spawn window, detach mid-lap, a relay session
reset mid-replay (the `nowMs` back-step). Each of those is a hand-written test today. **A
`FuzzReplaySchedule` in the shape of the existing schedule targets** — a byte string decoded into an
ordered list of those events with random gaps, driven against a real clip through the fake adapter, run
under CI's race job — is the "randomize everything" that applies here. Not started; the race that
prompted the question was in a test helper, which no fuzzer over shipped behaviour would reach.

### Planned out (2026-09-03): `FuzzEverything` already covers most of this, and the gap is the SEAM

Re-reading `core/everything_fuzz_test.go` against the six lifecycle events named above changes the
plan from "write a new target" to "finish the one that landed the same day". `FuzzEverything`'s
32-op alphabet (`fuzzEverythingOps`) already contains `attach`, `detach`, `file.valid`,
`file.garbage`, `file.otherGame`, `file.huge`, `startReplays`, `stopReplays`, `ctl.restart`,
`ctl.rewind`, `ctl.ff`, `ctl.replayLast`, `ctl.recordToggle`, `ctl.saveLast`, `ctl.nonsense`,
`chasersStart`, `chasersStop`, `gap`, and the relay ops. Because the seed picks the ORDER, a file
already lands before or after an attach, a `startReplays` already lands before or after the first
frame, a seek already arrives during a chaser's spawn window, and a detach already happens mid-lap.
Five of the six are reachable today; a separate `FuzzReplaySchedule` would be `FuzzEverything`
minus the relay ops, so **fold the remainder in rather than building a second target.**

**CORRECTED 2026-09-03, while building it — the paragraph below was wrong twice over.** The claim
was that no seed can reach a seam because `replayGapSeamMs = 1500` (`core/replay.go:56`) is a
package constant the compressed clock cannot shrink, and a fuzz step's largest gap is 350ms. Both
halves need splitting apart, because the two seams are not measured the same way:

- **The REPLAY seam is measured on the clip's RECORDED timestamps** (`replay.go:471`), not on wall
  time, so a clip carrying a 2s gap between two samples crosses the threshold instantly and the
  compressed clock has nothing to do with it. `fuzzEverythingClip` has always written exactly such
  a gap. **It was unreachable for a completely different reason: every clip that function produced
  was REFUSED by the loader**, because `speed` was read from bits the op index pins and always came
  out as the string `"fast"`. Playback-from-a-file had never run in this target at all. Fixed in
  `b7205acb`, with the eight shapes now deliberate and `TestFuzzEverythingClipShapesAreWhatTheyClaim`
  pinning them. The cheap route to the seam is `skip_gaps`, which collapses a 2s recorded gap to one
  millisecond while still marking a forced seam — the path runs for ~1ms rather than two seconds.
- **The CHASER seam is measured on the LIVE stream** (`chaser.go:89`, the same 1500ms constant
  against `s.Timestamp - prevTs` on nowMs-stamped frames). That one really is gated by wall time,
  a step's gap really does cap at 350ms, and a frame is sent after every step — so it stays
  unreachable, and it is the virtual clock that fixes it, not a field promotion.

**The lesson worth keeping, because it is the general one:** a fuzz target that silently exercises
nothing passes exactly like one that exercises everything. Nothing failed here for as long as the
bug existed; it was found by reading a `-v` log. Assert the SHAPE of what a generator produces, not
just the absence of a crash.


**Three steps — all DONE 2026-09-03 in `b7205acb`, kept here with what each turned out to be.**

1. ~~**Make the seam reachable** by promoting `replayGapSeamMs` to a per-`Core` field.~~ **Not
   needed, and it would not have worked.** The replay seam was blocked by the refused-clip bug
   above, not by the constant; fixing the clip shapes reached it. The chaser seam is genuinely
   wall-time gated and wants the virtual clock, which no field promotion substitutes for.
2. **The missing ops — one, not two.** `clock.backStep` is built, riding the parameter bits the
   `relay.forget` slot does not use. The second proposed op, a `relay.reset` under an active
   replay, is **redundant**: `forgetRelaySessionLocked` already drops the session, and it can
   already land while replays run. What it does NOT do is test the clamp — it clears `c.clock` and
   `c.lastNowMs`, so a forget RESETS `nowMsLocked`'s never-go-backwards guard rather than driving
   it. Only a back-step that keeps the session up does that. `nowMs` monotonicity is now an
   invariant checked after every step.
3. **Race coverage was already done, and the entry above was wrong to ask for it.** `go test`
   without `-fuzz` runs a target against its seed corpus, and the race job runs
   `go test -race -count=3 ./...` (`ci.yml:158`), so the replay lifecycle has run under the race
   detector three times per push since the target landed. What was worth doing instead — seeds for
   the seam shapes — is done: a cheap collapsed-gap seam and a clock back-step under a live replay.

**Sequencing across the three 2026-09-03 fuzzing entries:** the remaining overlap with the virtual
clock is the CHASER seam only, which needs wall time compressed and nothing else. The adapter
fuzzers are independent of both.

## Adapter-side fuzzers, one per adapter in its own language, in a CI job gated on that adapter's paths (filed 2026-09-03)

**TWO OF THREE BUILT, 2026-09-03. What the entry below assumed about the work was wrong in three
ways worth keeping, because each was wrong in the direction of "harder than it is".**

- **Lua — BUILT.** `adapters/emulator/tests/json_fuzz.lua`, second job in `lua.yml`. It needed no
  adapter edit and no shared module first: the prefix of each adapter up to the end of `jsonDecode`
  is pure declarations, so it loads under a stub `_ENV`, with the cut point found structurally so an
  edit to the decoder cannot silently point it at the wrong text. Each decode runs in a coroutine
  under an instruction-count hook, so a hang is a reported failure rather than a hung CI job —
  which is the point, since the 2026-08-25 incident was a hang and `pcall` cannot catch one.
  **It found one defect in each adapter, mirror images of each other**: Emerald followed nesting
  5000 levels deep where Crystal refused past 64, and Crystal turned every `\uXXXX` escape into a
  literal `?` where Emerald decoded it — which matters because Go's `encoding/json` HTML-escapes
  `&`, `<` and `>` by default, so an ordinary peer name would have arrived mangled. Both fixed
  (`78b69d9e`), both queued in their `UNVERIFIED.md`.
- **TEVI — BUILT, and it needed NO refactor.** `adapters/tevi/MeshGhostTevi.Tests/`, CI in
  `tevi.yml`. The entry assumed a BepInEx test build; `BridgeClient.cs` imports only `System.*` and
  `Newtonsoft.Json`, so the whole path from bytes to callback arguments runs on a Linux runner with
  no game and no engine. **It is therefore the strongest of the three — the only one that reaches
  the DISPATCH** rather than stopping at the decode, because the Pokemon adapters' dispatch sits
  past the point where the file starts calling BizHawk. No findings: 60 hostile lines survived,
  nesting is refused at 32 levels by Newtonsoft's own limit, and fourteen hostile peer ids reach the
  callback unchanged.
- **Pseudoregalia — NOT STARTED**, and cheaper than the entry implies. There is no recursive parser
  to fuzz: `json_string_field`, `json_vec3_field` and `json_number_field` (`Plugin.cpp`) are
  `std::string::find` and `sscanf` over `<string>` and `<cstdio>`, needing no UE4SS and no Unreal,
  so they compile standalone anywhere — **not a Windows runner, as this entry assumed.** The two
  things worth attacking are the reasoned-but-unmeasured assumptions in their comments: that JSON
  escaping makes a whole-string needle search safe against a hostile peer string, and that
  `clamp_to_uint8` catches every non-finite `sscanf` result before it reaches the game. The cost is
  lifting the three helpers into their own header, which edits `Mod/src/` — LF-pinned, hashed by
  the release gate, so it needs a DLL rebuild and deploy, and the new header must be added to
  `release.yml`'s `$files` map AND `build-pseudoregalia.bat`'s hash set in the same commit or every
  later edit ships a stale DLL with a green check.

**The general lesson, which cost nothing here and would have cost a lot later:** every one of these
harnesses needed a CONTROL asserting that valid input still produces the right answer. TEVI's first
run reported "0 renders" for every input and looked exactly like a broken decoder; it was a broken
test using the wrong message shape. Without the control it would have passed forever while
exercising nothing — the same failure found in `FuzzEverything` the same day.

**The original entry, kept because its reasoning about scope still stands:**

**The user's question:** *"do we have any fuzzing tests for adapters? should they live alongside the
server/client tests or have their own folders inside each adapter?"* — and the follow-up: *"we can also
make it the same way .Go actions happen, only run them if an adapter got any changes"*.

**Today only the Go side is fuzzed** (the targets CI runs, plus the opt-in schedule targets and
`FuzzEverything`). The adapters have none, and cannot borrow Go's: their bridge parsers are Lua, C#
and C++. What the Go fuzzers DO bound is what an adapter can ever receive — every value in a bridge
message has passed the wire limits and `ValidateState` — and `FuzzEverything` drives the bridge with
hostile adapter frames from the other direction.

**Where they belong:** inside each adapter's folder, next to its probes, in that adapter's language,
because the harness is the game host (BizHawk's Lua for the Pokemon adapters; a BepInEx test build
for TEVI; UE4SS for Pseudoregalia). **The first target is the same for all four** and is the one the
ACE audit names (`security-design.md`): feed the adapter's bridge line decoder random and hostile
`render_remote` / `remote_name` / `session_policy` lines and assert it never crashes the game and never
turns a peer string into a lookup it should not. **CI shape:** a job per adapter, path-filtered the
way the Lua workflow already is, so a Go-only push does not pay for it. Not started.

### Planned out (2026-09-03): the refactor is the work, the fuzzer is small — and Lua goes first

**The blocker in all three languages is the same shape.** Each adapter's decoder is welded to its
host, so nothing can call it without the host. Extracting the parse from the apply is most of the
effort; once a decoder is a pure function from a line to a table/object, the fuzzer around it is a
few dozen lines. So each stage below is "split it, then fuzz it", never "fuzz it".

**1. Lua first, because it needs no new toolchain and buys two adapters at once.** The decoder is
`decodeValue` / `decodeString` (`adapters/emulator/pokemon/emerald/meshghost_emerald.lua:823` and
`:830`), duplicated in the Crystal adapter. It is pure string handling and touches no BizHawk API,
but it lives inside a script that calls BizHawk at load, so it cannot be `require`d standalone.
**Step: lift the JSON decoder into a shared module both Pokemon adapters require.** That is worth
doing on its own merits (one copy of the parser instead of two, per the "rules that live in one
code path and are missing from their sibling" sweep entry above). Then the fuzzer is a plain
`lua5.4` script feeding random and hostile bytes at the module and asserting it returns or errors
but never loops or indexes nil. **CI is nearly free:** `lua.yml` already exists, already runs
`lua5.4`, and is already path-filtered on `**.lua` — this becomes a second job in it, not a new
workflow.

**2. TEVI next.** `BridgeClient.DrainInto` (`adapters/tevi/MeshGhostTevi/BridgeClient.cs:671`)
deserializes with `JsonConvert.DeserializeObject<JObject>` at `:690` and then switches on the
`type` field at `:702`-`:756` (`render_remote`, `despawn_remote`, `bridge_ready`, `reject`).
The parse half looks separable from the apply half — the switch builds a `RemoteState` and hands it
to callbacks, so no Unity type is needed to reach the end of parsing. **Step: confirm that, then
split the switch into a `TryParseBridgeLine` that returns a result object**, and put a `dotnet test`
project beside the adapter that references the same source file. No BepInEx, no game. CI needs a
new path-filtered workflow on `adapters/tevi/**`.

**3. Pseudoregalia last, because it is the most toolchain.** `BridgeClient.hpp`
(`adapters/pseudoregalia/MeshGhostPseudo/Mod/src/`) is header-only, which helps — a standalone test
binary can include it directly with no UE4SS. Do NOT reach for libFuzzer here; a seeded
pseudorandom loop under the compiler the adapter already builds with keeps this to one new binary
and no new toolchain in CI. Path-filtered on `adapters/pseudoregalia/**`, and note it needs a
Windows runner, which the Lua and C# jobs do not.

**The first target is the same for all three**, as the entry says and as the ACE audit in
`security-design.md` names: random and hostile `render_remote` / `remote_name` / `session_policy`
lines, asserting the game never crashes and a peer-controlled string never becomes a lookup it
should not be. **Two properties beyond "no crash" are worth asserting from the start**, because
they are the ones the Go side cannot bound for us: a peer id or name must never be used as a table
key, file path, or format string without passing the adapter's own allowlist, and a malformed line
must not advance the adapter's stream position past a subsequent valid one.

**What the Go fuzzers already bound, so the adapter targets do not need to re-prove it:** every
value in a bridge message has passed the wire limits and `ValidateState`, and `FuzzEverything`
drives the bridge from the adapter's side with hostile frames. The adapter targets exist for the
case those cannot reach — **a bridge that is not ours**, or a core that is compromised or buggy.
State that in each target's doc comment so the scope stays honest.

## A virtual clock for the core, so a fuzz step can say "eight hours pass" with no sleep (filed 2026-09-03)

**STARTED 2026-09-03. Stage 1 is in (`0e75ea99`): the interface, the accessor, and the recorder's
flush pair converted as its proof.** Two design corrections came out of building it, both of which
the entry below gets wrong:

- **The interface needs `Since`, not just `Now`.** Every duration here is a `time.Time` FIELD plus a
  reader somewhere else — `lastSendAt` written in one place and read by `time.Since` in two others,
  `lastFlush` likewise. Convert the writer and leave the reader and the code computes
  `wallNow - virtualStored`, which at any fake epoch is either an enormous positive or a negative:
  a rate limiter that never limits, or one that never sends, with nothing crashing.
  **So the unit of conversion is a field plus every reader of it, never a call site.** The stage-1
  test fails immediately if that rule is broken.
- **`awaitTick` needed a cancel escape FIRST, as its own change** — done, with a test that takes
  five seconds instead of milliseconds if it regresses. It had no stop channel and is called from
  inside the replay player's and the chasers' own goroutines, so `halt()` closed a channel nothing
  was listening to. At the wall clock that leaks a goroutine per abandoned replay; under a virtual
  clock a test that never advances time would park every one of them forever.

Also corrected: the site count is 32, not 24 — the five missed are all `time.Since` readers. And
`remotes.go:34` is a five-second LOG THROTTLE, not staleness; staleness comes from `nowMs()`, so
converting the root covers it and that file needs nothing of its own.

Still to convert: `nowMsLocked` (the root), `awaitTick`'s own polling, and the replay and chaser
due-waits. Then the preflight ratchet that stops a mixed clock coming back — which is a real commit
of its own, roughly nineteen `wall-clock:` markers across nine files, and must exclude `_test.go`
or it fires on hundreds of legitimate calls.

**The original entry:**

**The user, on FuzzEverything's early rate:** *"didn't we already do something where it simulates doing
things really long but still fast? so a multiple hour/day long test can be condensed into seconds?"*
Half yes. The compressed clock (`schedule_convergence_fuzz_test.go`'s argument) is every timing that is a
per-Core FIELD — stale window, interp, keepalive, backoff, chaser delay and spacing, replay start delay —
set to milliseconds, so "silent for twice the stale window" runs in tens of ms down the shipped path, and
`FuzzEverything` draws all of them from the seed. **What it cannot compress:** anything that reads the wall
clock directly — `nowMs()` is `time.Now()` plus the relay offset; the replay player and the chasers SLEEP
until a sample's due time; the 1.5s seam threshold and the 3s default stale window are constants; and
the fuzzer's own `gap` op is a real sleep. So a schedule with a long pause costs real seconds.

**The full version: one injectable clock.** `Core` gets a `now func() time.Time` (default `time.Now`) that
`nowMsLocked`, the player's and chasers' sleeps, the recorder's flush clock, the seam and stale checks
and `awaitTick` all read; sleeps become waits on a clock-aware timer the test can advance. A fuzz step
then says "advance 8h" and every due sample, age-out, seam and hold fires at once, deterministically —
day-long sessions in milliseconds, and no scheduler noise in the results (the convergence fuzzer's own
complaint that a compressed clock stops testing the code once it is shorter than the machine's jitter).
A real change to the core's clock plumbing, its own stage, with the existing tests as the regression
suite. Not started; the pacing trim of 2026-09-03 (1ms per step, gaps capped at 350ms) got the target to
~28 inputs/s meanwhile.

**Scope, the user's follow-up ("always use this for all tests/fuzz things?"):** for every test of logic
and ordering, yes — core unit tests, the schedule fuzzers, `FuzzEverything`. NOT for what tests timing
against the outside world: `internal/e2e` (real binaries), `transport`/`netx` (socket deadlines), the
netsim rig, and anything spanning the relay process, which has its own clock. The one hazard is a MIXED
clock — one `time.Sleep`/`time.After`/`time.Now` left inside the core and a goroutine waits on virtual
time nothing advances while another waits on the wall: a deadlock. Hence its own stage, every clock read
in `core` audited, the whole suite as the net.

### Planned out (2026-09-03): the audit, the interface, the five stages

**Stage 0 — the audit, which is the part nobody had.** `core`'s non-test files read the wall clock
at 24 sites across 11 files. Listing them is most of the design, because the stage boundary is
exactly "which of these become virtual":

| File | Sites | Class |
|---|---|---|
| `online.go:107` (`nowMsLocked`) | 1 | **A — virtual.** The root: every timestamp and render time in the core comes from here. |
| `remotes.go:34` | 1 | **A** — staleness/age-out. |
| `replay.go:349` | 1 | **A** — the player's due-wait, capped at 50ms per iteration. |
| `chaser.go:127` | 1 | **A** — the chaser's due-wait, same 50ms shape. |
| `localpeer.go:130-135` (`awaitTick`) | 3 | **A** — the 2ms poll loop; deliberately polled, not signalled. |
| `bridgeserve.go:336` | 1 | **A** — the render tick ticker. |
| `sending.go:140`, `:241` | 2 | **A** — send cadence and `lastSendAt`. |
| `recorder.go:205`, `:219` | 2 | **A** — the once-a-second flush clock. |
| `transportpick.go:173` | 1 | **B — stays wall.** Transport discovery timeout. |
| `relaysession.go:295`, `:526`, `:666` | 3 | **B** — session timeout, dial backoff sleep. |
| `sending.go:238` (`probeGap`), `:273`, `online.go:434` (`recvAt`) | 3 | **B** — RTT/ping pairing: these MEASURE the network. |
| `chaser.go:240`, `replay.go:618` | 2 | **B** — the one-second goroutine-join safety nets. Virtualising a shutdown timeout turns a leak into a hang. |
| `core.go:898` (`startedAt`), `recorder.go:201`, `:290`, `:291`, `:377`, `:383`, `:386` | 7 | **C — cosmetic.** Human-facing timestamps and replay file names. Virtualising them is optional; the payoff is deterministic fuzz output, not speed. |

**The B/A boundary rule, stated once so later sites classify themselves: anything whose other end
is a socket, a process, or a human stays on the wall clock.** Everything whose other end is our own
logic goes virtual. Note the one subtlety this creates — `nowMsLocked` is `time.Now()` plus
`clockAdjustLocked()`, and that offset is estimated from wall-clock RTT samples (class B). After the
split it is a virtual `Now()` plus an offset derived from wall measurements. That is fine, because
the offset is just a scalar the tests can set, but it must be written down or someone will later
"fix" the inconsistency and reintroduce the mixed clock.

**Stage 1 — the interface, and why `now func() time.Time` is not enough.** The entry above proposed
a bare function. That is half the problem: the sleeps must be virtual too, or a test advances time
while a goroutine sits in `time.After` and nothing wakes it. So `Core` takes a small interface —
`Now()`, `After(d)`, `NewTicker(d)`, `Sleep(d)` — with a wall implementation as the default and a
fake carrying `Advance(d)`. Nothing outside `core` changes; the field is unexported with a
test-only setter, so `cmd/` and `bridge` are untouched.

**Stage 2 — convert class A, one file per commit**, existing tests as the net after each. Start
with `online.go` and `remotes.go` (the root and the simplest consumer), then the two due-waits,
then `awaitTick`, then the tickers. `awaitTick` is the interesting one: it polls at 2ms *and* is
what several tests wait on, so it is where a missed conversion will show first — a good early
canary rather than a late surprise.

**Stage 3 — the deadlock guard, which is the whole risk.** A fake clock that blocks forever when
nothing advances turns every missed site into a hang instead of a wrong answer, and the entry's own
hazard note is exactly this. Two mitigations, both cheap:

- **The fake counts its blocked waiters** and exposes "advance until quiescent", so a test never
  has to guess how far to move time. A goroutine still waiting on the wall clock simply never
  registers, which makes the miss visible as a stuck test with a clean stack rather than a flake.
- **A grep gate in `dev-scripts/preflight.ps1`** failing on a bare `time.Now|time.Sleep|time.After|
  time.NewTicker` anywhere in `core/*.go` outside the clock file and an explicit allowlist of the
  class-B sites. **This is the thing that keeps the mixed clock from coming back**, and without it
  the next feature reintroduces one.

**Stage 4 — adopt in the tests.** `-count=10` and `-race` per the hard rules, then convert
`FuzzEverything`'s `gap` op from a sleep to an advance and the schedule fuzzers after it.

**Stage 5 — the payoff, and what to measure.** About 120ms of every `FuzzEverything` input is pure
sleeping: ~98ms of expected `gap` time (24 steps, one op in 32, a 10/40/120/350ms alphabet) plus the
24ms of 1ms per-step pauses. Removing it is the point, but **measure the before and after rather
than predicting** — at ~28 inputs/s across 12 workers the sleeps are not the only cost, and the
honest claim is "sleeps go to zero", not a multiplier. The other two payoffs are worth more than
the rate: **the seam becomes reachable** (see the replay-schedule entry above — a 2s gap costs
nothing once time is virtual, which subsumes promoting `replayGapSeamMs` to a field), and
**day-long shapes become testable at all**. The chaser queue sized to 336 hours that commit
`6ca1c992` fixed is precisely the class of bug an "advance 8 hours" step finds and no 350ms gap ever
will.

## Recording file size: gzip now, per-KEY delta encoding later (measured 2026-09-03)

**The user's question, reading a 15 MB file from a 3-minute run:** *"if a value haven't changed
from the last line, why do we need to repeat that ... or do we need to do it this way to actually
play things back properly?"*

**The answer to the second half is no.** `parseReplay` builds `clip.samples` fully in memory
before playback starts and every seek, rewind and loop indexes into that array, so a carry-forward
reconstruction at LOAD time produces identical samples and no playback path changes at all. The
verbatim repetition exists only because the recorder writes the same `protocol.State` it would
have sent on the wire.

**The measurements, and the surprise in them, are in `scaling.md`** ("What a recording costs on
disk"). Two things decided from them:

- **gzip SHIPPED 2026-09-03**, together with rounding the float64 tails json.Marshal prints
  ("550.0000000000016"): 33.5x together, so ~310 MB/hour became **~9 MB/hour**, which is enough
  that nothing else is urgent. No format change — both loaders already read `.ndjson.gz`.
- **Per-KEY `extras` delta encoding is filed here rather than built**: 4.4x before gzip, and most
  of that overlaps with what gzip already gets — a rounded-and-gzipped 3-minute clip is already
  452 KB — against a real cost — a header flag, loader
  carry-forward, the `parseReplay` validator, the fuzz corpus, and files shared between versions.
  Pick it up if recordings ever need to be small enough to send someone, where CPU-free decoding
  and a small transfer both matter.

**The trap to carry, because it is the intuitive design and it does not work:** skipping a LINE
that did not change saves ~2%, because only 274 of 15,761 lines have an `extras` block identical
to the one before it. Three jittering floats -- `h_speed`, `v_speed`, `slide_t` -- change on
nearly every line while every other one of the 40 keys changes on 117 lines or fewer. Delta by
KEY, never by line.
