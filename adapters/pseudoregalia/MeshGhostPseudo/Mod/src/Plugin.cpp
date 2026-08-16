#include <Plugin.hpp>

#include <algorithm>
#include <array>
#include <bit>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <map>
#include <cwctype>
#include <format>
#include <utility>

#include <BridgeClient.hpp>
#include <CoreLauncher.hpp>

#include <DynamicOutput/DynamicOutput.hpp>
#include <Unreal/AActor.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/CoreUObject/UObject/UnrealType.hpp>
#include <Unreal/FFrame.hpp>
#include <Unreal/FHitResult.hpp>
#include <Unreal/Hooks.hpp>
#include <Unreal/UFunctionStructs.hpp>
#include <Unreal/UnrealVersion.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/World.hpp>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

namespace MeshGhostPseudo
{
    using namespace RC;
    using namespace RC::Unreal;

    // Log bridge stats every ~2s -- same cadence as 7.1/step-1's position log, chosen for
    // readability, not tied to a real need. local_state itself is sent every tick per
    // PROTOCOL.md's tick loop ("send local_state every frame, state may be nil"), not throttled.
    constexpr uint64_t LOG_INTERVAL_TICKS = 120;

    // Slide mesh-offset probe -- the "START HERE" step of ideas.md's plan to replace the slide
    // render-Z compensation (the +43 in slide_z_comp) with whatever the game's own crouch logic
    // actually does. Question it answers: the ghost's VisualMesh sits at a FIXED -65 set at
    // construction, so what does the REAL player's mesh read mid-slide?
    //
    // Why it does not reuse LOG_INTERVAL_TICKS: a plain slide is exactly 87 ticks (measured, four
    // runs, verified.md), which is SHORTER than the 120-tick cadence -- a whole slide can fall
    // between two samples and log nothing at all. At 10 ticks (~67ms on this build's ~150Hz) a
    // slide yields ~13 samples.
    //
    // Cost, per CLAUDE.md's "a diagnostic can break the thing it measures": two property lookups
    // on two already-known components. No enumeration, no name-to-string per object, no
    // ProcessEvent -- this is not the expensive shape. Flip OFF once the capture is read, and
    // record here what it produced (see OBJECT_REFLECTION_DUMP for the shape).
    constexpr bool SLIDE_MESH_PROBE = true;
    constexpr uint64_t SLIDE_MESH_PROBE_INTERVAL_TICKS = 10;

    // How often the montage divergence check asks the ghost what it's playing (see its call site in
    // tickRenders). Every tick would be a ProcessEvent getter call per ghost per frame for a
    // correction that only matters on the timescale an eye can see; 4 ticks is ~27ms on this
    // build's measured ~150Hz, well under a frame's worth of visible delay, at a quarter the cost.
    constexpr uint64_t MONTAGE_DIVERGENCE_CHECK_INTERVAL_TICKS = 4;

    constexpr auto GAME_ID = "pseudoregalia";
    // Sent as this adapter's bridge Hello alongside GAME_ID (internal/bridge.Hello's
    // game_version field, added for relay-safety hardening -- see the ADR in
    // agent_docs/architecture.md). This is this *mod's* own version, not Pseudoregalia's
    // game build -- no cited API exists to read that, and CLAUDE.md's "no addresses/APIs
    // from memory" rule means one isn't guessed at here. Opaque to the core/relay,
    // compared only by equality: it catches two peers running different revisions of this
    // mod, the most likely real source of a silent protocol mismatch.
    // Bumped 2026-08-15 (doc/dead-code cleanup pass touching this file's own comments and control
    // flow): a deliberate breaking change so the relay's hard-reject-on-mismatch behavior for
    // game_version actually catches it if a peer is still running the pre-cleanup build -- exactly
    // the failure mode this field exists to catch (two peers on genuinely different revisions both
    // reporting the old version, silently).
    constexpr auto ADAPTER_VERSION = "phase7.7";
    constexpr auto BRIDGE_HOST = "127.0.0.1";
    // The port is no longer a constant here: BridgeClient walks BRIDGE_BASE_PORT upward looking
    // for a core that will have this game (see BridgeClient.hpp), so which one we end up on is a
    // runtime answer. Two copies of Pseudoregalia, or Pseudoregalia alongside another game, each
    // get their own core this way with nothing to configure.

    // Live loopback ghost offset -- NOT a test-mode flag (despite the visual proximity to the
    // dead-code block this used to sit next to; that block, including the similarly-named
    // LOCAL_OFFSET_TEST_MODE/LOCAL_OFFSET_TEST_ID, was removed in a cleanup pass). This constant
    // is used in production, networked-path code: handle_bridge_line nudges a loopback-echoed
    // ghost ("<id>-ghost", from internal/relay's dev-only -loopback flag) sideways by this many
    // units so it doesn't render exactly on top of the real player, which would otherwise make it
    // impossible to visually judge ghost rendering/animation quality side by side with the real
    // character. See handle_bridge_line's own comment on loopback_offset_x for the two valid
    // loopback use cases (this offset value vs. 0.0) and why this stays a plain constant rather
    // than a runtime flag.
    // **DO NOT set this to 0.0 while GHOST_COLLISION_ENABLED is true.** Tried 2026-08-15 to test
    // the pole-climb report and immediately reproduced the original drag/pull bug from the very
    // first spawn saga (Phase 7.4): an overlapping ghost physically shoves the real player around.
    // User: "its dragging/pulling me ... unsafe/should never be enabled." Reverted at once.
    //
    // **This is not just a test-mode caveat -- it is real evidence about the collision feature.**
    // The earlier "collision doesn't push me around" result was obtained WITH this 150-unit offset,
    // i.e. the ghost was never overlapping the player. Real remote peers get NO offset (see the
    // receive site), so two players occupying the same space WILL shove each other -- which in a
    // precision platformer can mean being pushed off a ledge. See agent_docs/ideas.md's
    // ghost-collision entry; this is the "untested with a real peer" risk, now partly answered.
    constexpr double LOOPBACK_GHOST_OFFSET_X = 150.0;
    // Vertical loopback offset, added 2026-08-15 for the pole-rotation question, which the sideways
    // offset structurally cannot answer.
    //
    // **Why a Z offset is the right tool here.** Orbiting a pole moves you around the POLE'S AXIS. A
    // ghost pushed 150 units sideways orbits a phantom axis 150 units away -- it performs the same
    // motion faithfully while visibly not going around the pole, which reads as "the rotation isn't
    // syncing" even when the transform is provably exact (2469 samples, actualYaw == wantYaw to the
    // decimal across the full +/-180 range -- see verified.md). Offsetting UP instead puts the ghost
    // on the SAME axis, directly above the player, where an orbit is compared like with like.
    //
    // Also the safe way to get a zero horizontal offset: CLAUDE.md forbids
    // `LOOPBACK_GHOST_OFFSET_X = 0` while ghost collision is on, because an exact overlap reproduces
    // the 7.4 drag bug by construction. A vertical separation keeps the two bodies apart, so
    // collision stays on and this stays a one-variable change.
    //
    // **Tried 2026-08-15 at 220.0, and it was a BAD tool for this after all -- back to 0.0.** A pole
    // is a vertical structure, so offsetting along the pole's own axis put the ghost far up the same
    // pole: the user reported "i couldn't see the ghost at all while on the pole" (out of frame, and
    // plausibly inside ceiling geometry) and that it made everything else harder to judge. The
    // geometry reasoning above is still right -- it just fails on the one structure it was built
    // for. Kept as a named constant because it is the correct tool for a HORIZONTAL orbit, and
    // because rediscovering the idea is worth more than the two lines it costs.
    constexpr double LOOPBACK_GHOST_OFFSET_Z = 0.0;

    // Phase 7.6: one-constant control between the two ghost designs. true = spawn a clone of the
    // player's own pawn class (real player model, can animate -- what Phase 7.6 is actually for),
    // ported from the Lua adapter's already-proven trySpawnRemoteGhost, but now with every
    // spawn/reposition call made from game_thread_tick (the real game thread) instead of the
    // pre-fix on_update() the original C++ spawn attempt used -- see RemoteGhost's comment in
    // Plugin.hpp for why that distinction is the whole point of this retest. false = the older
    // hijack-an-existing-StaticMeshActor design, kept as an instant revert if the world-leak crash
    // reproduces even on the game thread.
    constexpr bool SPAWN_BASED_GHOSTS = true;

    // Ported from main.lua's MIN_PLAUSIBLE_DISTANCE (probe_ghost/Scripts/main.lua): refuse to
    // spawn against a transform still sitting near the origin -- a real placed pawn transform is
    // never this close to (0,0,0), so this is "the engine hasn't placed this pawn yet", not a
    // real location.
    constexpr double MIN_PLAUSIBLE_DISTANCE = 100.0;

    // Used by release_ghost to park a despawned ghost far out of the playable area, added in a
    // review pass. NEVER destroy the actor -- K2_DestroyActor is confirmed to silently no-op on
    // this build (see the "no working destroy mechanism" comment on ensure_ghost_hijacked), and
    // earlier attempts to work around that caused the "Fatal world leaks detected" crashes this
    // design deliberately avoids. Before this, a peer leaving mid-area left its ghost frozen in
    // place, visible, until the next area transition's own teardown finally reclaimed it; moving
    // it via the already-proven call_set_actor_location_and_rotation path (the same one the
    // redraw loop already calls every tick) fixes the visible-freeze without touching actor
    // lifetime at all -- the level's own teardown on area change is completely unaffected and
    // still does the real cleanup, exactly as before this change. Symmetric with
    // MIN_PLAUSIBLE_DISTANCE's own reasoning: a real placed level position is never this far
    // below the playable area either.
    constexpr double DESPAWN_PARK_Z = -500000.0;

    // User-requested 2026-08-13, re-added: mirrors Lua's original SPAWN_DELAY_TICKS
    // (probe_ghost/Scripts/main.lua, ~5s at that build's tick rate) -- holds off spawning any
    // ghost until this many real game-thread ticks after the local pawn first becomes valid, so
    // the player's own camera settles on a real target first. This is what let the original
    // investigation catch the camera re-pick as a clean, isolated, ~2.6ms-after-spawn event
    // (agent_docs/phases/phase7.md's Phase 7.4 saga) instead of it being tangled up with level-
    // entry camera setup. ~300 ticks at a typical 60fps game thread ~= 5s.
    // Logs which branch the camera fight-back hook takes on EVERY SetViewTargetWithBlend call,
    // not just the one where it rewrites. Off by default; flip, rebuild, deploy, reproduce, read,
    // flip back -- the same pattern as the other *_TRACE flags in this file.
    //
    // What it is for (2026-08-16): the camera goes wrong after an in-game cutscene or a "reset to
    // last save", and today's logging cannot say why, because it prints only when the hook
    // rewrites. That leaves three explanations indistinguishable -- the game asks for a camera
    // change and we clobber it, the game asks and we accept it but something else is wrong, or the
    // game does not use this function for cutscenes at all. Silence currently means all three.
    //
    // Cost is one line per view-target change, and this game changes rigs a handful of times per
    // area -- not per tick. That distinction matters: per-tick logging with a name lookup per
    // object is what caused this project's worst regression (pitfalls.md, 2026-08-16), and
    // GetFullName() here is the same expensive call, just called a few times a minute instead of
    // thousands. Do not move it into a tick loop.
    // One-shot dump of the render flags that decide whether a character is drawn THROUGH walls,
    // for the local player and for each ghost, so the two can be compared.
    //
    // The question (user, 2026-08-16): Pseudoregalia outlines the player when they stand behind
    // geometry, the ghost inherits it because it is a clone of the player pawn, and seeing a peer
    // through walls is an information advantage a visual-only mod should not hand out.
    //
    // In Unreal that outline is almost always custom depth -- bRenderCustomDepth on the mesh
    // component plus a CustomDepthStencilValue, with a post-process material drawing the
    // silhouette where those pixels sit behind scene depth. Almost always is not confirmed, which
    // is what this prints. If the player's mesh shows bRenderCustomDepth=true then that is the
    // mechanism and disabling it on the ghost is a one-line fix; if it shows false, the outline is
    // something else (a separate outline mesh, or a material with depth testing off) and the fix
    // has to be aimed at whatever that turns out to be.
    //
    // Read-only, per adapters/_template's "observe before you override" rule -- this deliberately
    // changes nothing on the first run.
    //
    // One line per actor per session (see outline_traced_*), not per tick: the same
    // per-tick-with-a-name-lookup shape that caused this project's worst regression is exactly what
    // to avoid here.
    // Logs who the local controller is actually possessing, for several ticks after a ghost
    // spawns, plus why a spawn was allowed at all.
    //
    // The question (user, 2026-08-16): after loading a different save, the camera stayed on the
    // player but the player could not be moved. That is not a camera fault -- it is the controller
    // driving something else. BP_PlayerGoatMain_C auto-possesses on spawn (pitfalls.md), which is
    // why ensure_ghost_spawned re-possesses the local pawn immediately afterwards; if the
    // auto-possess is deferred to BeginPlay it would land AFTER that hand-back and quietly keep
    // control.
    //
    // The same session logged TWO ghosts spawned for one peer 23ms apart in one world, so the
    // second half of this prints what the spawn guard saw -- a duplicate leaves an orphaned pawn
    // nobody tracks, and an orphan that auto-possessed is exactly the shape of "cannot move".
    //
    // Read-back, not an echo: it asks the CONTROLLER which pawn it holds rather than reporting
    // what we asked for, which would prove nothing (CLAUDE.md).
    constexpr bool POSSESS_TRACE = false;

    // How many redraw ticks after a spawn to keep checking who holds the controller. Long enough
    // to catch a possess that lands a frame or two later, short enough not to become per-tick
    // logging.
    constexpr uint32_t POSSESS_TRACE_TICKS = 20;

    // How long after OUR ghost spawn a camera switch is treated as the ghost's own rig taking
    // over. Measured at 3-4ms (2-3 ticks) every time; a handful of ticks covers it with margin
    // while staying far away from "block everything forever", which is what the removed
    // fight-back did.
    constexpr uint64_t GHOST_SPAWN_CAMERA_GUARD_TICKS = 10;

    constexpr bool OUTLINE_TRACE = false;

    constexpr bool CAMERA_TRACE = false;

    constexpr uint64_t SPAWN_DELAY_TICKS = 300;

    // User-requested toggle, 2026-08-13: try re-enabling ghost collision as a real fix for the
    // stuck-falling-pose and can't-grab-ledges bugs (both plausibly need a real physics trace to
    // detect ground/ledge contact, which an ActorEnableCollision(false) ghost can never provide),
    // rather than continuing to guess at state-mirroring workarounds. Re-reading phase7.md's own
    // history first: collision-disable was never actually proven necessary -- it was added
    // defensively during the Phase 7.4 drag-bug investigation, but the real causes found later (a
    // live-reference position-mutation bug, then a separate auto-possess bug) were both unrelated
    // to collision; the disable call was "left in place as a reasonable safety measure even though
    // they turned out not to be the actual fix" (phase7.md). Lower risk than it first looked, but
    // still a real behavior change (the ghost can now physically push the real player, get stuck
    // in world geometry on a teleport that lands inside a wall, etc.) -- a named toggle here rather
    // than a silent hardcode, per the user's own "maybe a feature/toggle later" framing.
    // Reverted 2026-08-13 -- tried twice now, both real risk with no solidity gained:
    // (1) blanket SetActorEnableCollision(true) alone: did NOT make the ghost solid (real player
    // walked straight through it), but let melee attack and kill it, which killed the REAL
    // player's own character too. (2) Added SetCollisionResponseToChannel(Pawn, Block) on the
    // ghost's own capsule on top (call_set_collision_response_to_channel): confirmed via log that
    // the function was genuinely found and called (no reflection failure) -- still no solidity.
    // Leading theory: UE's dynamic-vs-dynamic actor blocking needs BOTH sides' collision response
    // to agree on Block, and only the ghost's side was ever changed; the real player's own
    // capsule was very likely never configured to Block the Pawn channel at all, since two-pawn
    // contact was never a real case in this single-player game. Fixing that would mean touching
    // the REAL PLAYER's own live collision component, not just the ghost's -- a materially bigger
    // risk than anything tried so far, on top of an already-demonstrated melee-death danger that
    // is STILL UNRESOLVED. Do not re-enable without explicit go-ahead, and treat any attempt to
    // modify the real player's own collision setup as its own separate, carefully-scoped decision.
    // **Re-enabled 2026-08-15 and KEPT ON as a deliberate feature decision by the user**, after a
    // live test found it well-behaved: the ghost does not push or pull the real player around.
    // Rationale (user's): it adds real physical presence and "a bit more unintentional depth to the
    // online/coop experience" at no observed cost to normal play.
    //
    // Note the two 2026-08-13 attempts that led to this being off never asked this question -- both
    // measured PLAYER-vs-GHOST solidity ("can I walk through it", "can I hit it"), not
    // GHOST-vs-WORLD collision. Ghosts are also moved by teleport (bTeleport), and teleport moves
    // ignore collision blocking, so this makes the ghost PRESENT in the physics world rather than
    // physically blocked by walls -- consistent with the observed no-push behaviour.
    //
    // **KNOWN RESIDUAL RISK, accepted knowingly, NOT fixed**: the 2026-08-13 melee-death bug is
    // unchanged -- damage that kills the ghost also killed the REAL player's character. The user's
    // judgement is that co-op players won't swing at each other by accident, which is reasonable
    // for deliberate player melee. **What is still untested is non-player damage**: an enemy
    // attack, AoE, or environmental hazard striking the ghost is a different vector entirely and
    // nobody has tried it. If a player ever dies for no visible reason near a ghost, look here
    // first. See agent_docs/ideas.md's ghost-collision entry.
    // Briefly false on 2026-08-15 for run 2 of GHOST_SELF_MONTAGE_PROBE's design, then restored:
    // that run showed the ledge-grab self-start happens with collision OFF too (the ghost visibly
    // could not hang on the ledge and still ended up in the hang pose), so collision does not cause
    // it and there is no reason to keep the feature disabled. See verified.md.
    constexpr bool GHOST_COLLISION_ENABLED = true;

    // Redone landed?/jumped? pulse mirror, 2026-08-13 (follow-up session) -- see
    // RemoteGhost::target_land_count's comment in Plugin.hpp for the full root-cause story (the
    // first attempt read/wrote the wrong object, animBPref->landed?/jumped? rather than the pawn,
    // and was a silent no-op on both ends). Ticks to hold landed?/jumped? true on the ghost's own
    // AnimBP once a rising edge is observed on the wire, since the AnimBP's own update graph may
    // re-evaluate and stomp a single-tick write before its state machine transition sees it.
    constexpr uint32_t PULSE_HOLD_TICKS = 3;

    // Trail-colour sync diagnostic, 2026-08-15. Same problem the weapon/outfit sync hit and the
    // same shape of answer as WEAPON_SYNC_INVERT below: on a same-machine loopback both characters
    // naturally have the SAME trail colour, so "synced correctly" and "never written at all" look
    // identical on screen -- user raised this directly ("unless you can manually change what color
    // it is during the test to something else so i can visually tell it apart from the player").
    // When true, the ghost's trail colour is forced to a deliberately unmistakable value instead
    // of the peer's real one, so the write path is proven or disproven at a glance. THIS
    // DELIBERATELY MAKES THE GHOST WRONG -- diagnostic only, flip back off once the plumbing is
    // confirmed and the real synced colour takes over.
    // **Ran 2026-08-15, write path CONFIRMED**: the ghost's trail rendered magenta while the real
    // player's stayed yellow (see verified.md's "trail (afterimage) COLOUR write" entry), proving
    // the property write lands and is consumed by the spawn. Flipped back off -- the ghost now
    // shows the peer's real colour. Keep this flag: it is the cheapest way to re-prove this write
    // path if the colour ever appears not to sync, and it's also effectively a working prototype
    // of the per-peer distinct-colour feature idea in ideas.md.
    constexpr bool AFTERIMAGE_COLOR_TEST_OVERRIDE = false;
    // Bright magenta: maximally distinct from BOTH real trail colours this effect uses (the normal
    // yellow and the perfect-timing-ultra blue), so it can't be confused with a real one.
    constexpr float AFTERIMAGE_COLOR_TEST_RGB[3] = {1.0f, 0.0f, 1.0f};

    // Trail-VFX heuristic-trigger attempts, 2026-08-15 -- ABANDONED, not dead code kept for
    // reference. Five real live-test rounds tried to infer "the real game just spawned an
    // afterimage" from polled actionState/hSpeed (see verified.md's "Pseudoregalia ghost trail"
    // entry and PLAYER_FIELDS.md's trail-VFX section for the full account): every repeat-interval
    // variant either fired once instead of repeating, mis-fired on a quick 180-degree turn-around
    // (which shares actionState 18 with a real slide), or missed Solar Wind's ultra hop entirely.
    // Replaced with a real UFunction::RegisterPostHookForInstance hook directly on the local
    // pawn's own 'Spawn After Image' call (see spawn_after_image_function in Plugin.hpp and its
    // registration in game_thread_tick) -- driven by the actual event, not an approximation of
    // when one probably happened. The AFTERIMAGE_MIN_SLIDE_SPEED/AFTERIMAGE_SPAWN_INTERVAL_TICKS
    // constants this comment used to sit above are gone; nothing in this file references them now.

    // Read-only diagnostic, 2026-08-13: an every-tick trace (gated on "state looks interesting",
    // not the usual ~2s LOG_INTERVAL_TICKS cadence, since a one-frame AnimBP pulse can't be seen
    // at 2s resolution) of every field plausibly gating the stuck-falling/stuck-ledge-hang
    // transitions, both local and on the ghost, plus a readback of the ghost's own animBPref-
    // >landed?/jumped? right after we write it -- per CLAUDE.md, a write that "ran without errors"
    // is not evidence it actually stuck. Confirmed live 2026-08-13 (both the falling-pose fix and,
    // after adding Montage_Stop, the ledge-hang-stuck-forever fix) -- flipped back to false, same
    // as the other now-removed investigation-only diagnostics (see git history for their
    // now-deleted local-only test-mode counterparts).
    constexpr bool ANIM_PULSE_TRACE = false;

    // Trail-VFX trigger investigation, 2026-08-15 continued: the actionState==18/8 hypothesis
    // (correlated from only 2-3 LOG_INTERVAL_TICKS-sampled snapshots earlier this session) shipped
    // as the real trigger and the user's live test came back wrong on all three counts -- fires
    // once instead of repeating through a slide, unreliable on a real slide/Solar Wind hop, fires
    // spuriously while walking. Per CLAUDE.md's "two guessed fixes failing is a signal" -- this is
    // the first guess at the TRIGGER CONDITION specifically (the call itself was already
    // separately confirmed working), so the right move is real per-tick evidence, not a second
    // blind guess. Unconditional every-tick trace (not gated, unlike ANIM_PULSE_TRACE above) --
    // deliberately floods the log; meant for one short, clean manual test (walk a bit, one full
    // slide, one ultra-hop, stop), not a long session.
    // Flipped back on 2026-08-15 for a second capture: the ghost-side coalescing fix (call the
    // delta count of times instead of once) was live-tested and showed the exact same "fires
    // once" symptom -- ruling that theory out. Now also traces the ghost-apply side (see the
    // afterimage-fire block's own Output::send), not just local, since the pivot to
    // spawnNumAfterimages means the open question is now "does the ghost-side call even resolve
    // and fire," not "how many times does the local side detect an edge."
    // Cling-gem (wall-ride) investigation, 2026-08-15. Ghost collision was enabled and confirmed
    // NOT to produce the cling-gem VFX on its own -- expected, since the ghost's wall-run logic
    // never runs without input. Before calling doWallRun on the ghost, this establishes what the
    // real player's wall-ride state actually looks like: which flags mark it, whether wallRideVFX
    // goes non-null (i.e. whether the VFX component is spawned on demand or pre-existing), and how
    // long a real cling lasts. Edge-logged, same reasoning as every other trace in this file -- a
    // periodic sample can miss a short window entirely.
    // Flipped back off 2026-08-15: it did its job -- established moveState==4 as the cling marker,
    // that actionState is NOT involved, that canWallRun is a misleading name (false even mid-cling),
    // and that wallRideVFX is spawned once then reused. See verified.md's wall-ride entry.
    constexpr bool WALLRIDE_TRACE = false;

    // Cling-gem VFX, 2026-08-15 -- **CONFIRMED WORKING, now real production code, not a test**
    // (see verified.md's cling-gem entry). Calls doWallRun on the ghost when its mirrored moveState
    // enters 4 (the confirmed cling marker), deactivates wallRideVFX on the falling edge, and
    // suppresses the paired SFX entirely per the silence clause (ghosts are visual-only).
    // Originally gated because wall-run logic applies velocity and the ghost's position is
    // network-authoritative, so a self-propelled ghost fighting its own position writes was the
    // real risk -- that did NOT materialise across three live test rounds (no jitter, drift, or
    // wall-sticking reported). Kept as a named flag anyway: it's the cleanest off-switch if that
    // interaction ever does surface, e.g. with a real remote peer rather than a loopback ghost.
    constexpr bool WALLRUN_TRIGGER_TEST = true;

    // Re-enabled, then off again 2026-08-15, for the afterImagesToSpawn-mirroring rewrite. Result:
    // the pipeline is exact -- 6 real bursts detected locally, 6 applied to the ghost, no drops on
    // either side -- and it revealed the true burst size is 5 (the previous hardcoded 6 was wrong).
    // It also showed actionState reading 0 on five of the six real bursts, which retrospectively
    // explains why every actionState-based heuristic failed. Remaining gap is NOT this pipeline:
    // some afterimages come from a path that never sets afterImagesToSpawn (see verified.md).
    // Flipped back off 2026-08-15 after the trail work settled: it answered the repeat-cadence
    // question, then the colour question (afterimageColor never changes -> not the blue's source),
    // then the ultra-state question (ultraCap/fullUltraModifier/cappedUltraModifier/animJumpType
    // all ruled out). See verified.md. Kept in the tree for the still-open turn-around
    // false-positive question, same flip/rebuild/deploy/watch/flip-back convention as every other
    // toggle in this file.
    // **On again 2026-08-15** to verify trigger C (the bubble boost-available trail) actually fires,
    // and how many times per bubble -- it logs only when a trigger fires, so it is cheap next to the
    // coverage trace, and the new bubble_edge/bubble_refire columns say which one did it. Flip off
    // once the trail is confirmed on screen. **Off again 2026-08-15**: it confirmed trigger C fires
    // (bubble_enter then a run of bubble_refire, moveState=7 throughout), which is how the trigger
    // was shown to be attached to the IN-BUBBLE state rather than the post-jump window.
    constexpr bool TRAIL_TRIGGER_TRACE = false;

    // Enemy-damage-vs-ghost safety test, 2026-08-15. Ghost collision is now on as a deliberate
    // feature, and the melee-death bug (damaging the ghost damaged/killed the REAL player) is
    // unresolved -- bCanBeDamaged=false was tried and provably did not stop it. Deliberate
    // player-on-ghost melee is an accepted footgun; ENEMY and environmental damage is the vector
    // nobody has tested, and the ghost stands in the world where enemies fight.
    //
    // Logs local and ghost health independently, only on change, because the naive live test is
    // ambiguous: if enemies are hitting the player too, "I died" doesn't say whether the ghost
    // caused it. The property NAME is not known yet, so the first resolution attempt logs which of
    // several candidates actually exists on this build rather than assuming one -- per this file's
    // standing rule against addresses/names from memory.
    // Flipped off 2026-08-15: it never resolved a health property at all -- none of the eight
    // candidate names exist on this build, so it produced a single warning and nothing else. The
    // enemy-damage result was established by what the user saw on screen, not by this. Left in the
    // tree, off, because a future attempt only needs a real property NAME (find one via
    // OBJECT_REFLECTION_DUMP first, rather than guessing a name list again as this did).
    constexpr bool HEALTH_TRACE = false;

    // Trail COVERAGE investigation, 2026-08-15. The afterImagesToSpawn mirror is provably exact
    // (6 detected / 6 applied) yet some real afterimages still never reach the ghost, so those come
    // from a path that never touches that field. Rather than theorise about it, this captures dense
    // per-tick state during real play so a move that SHOULD trail but doesn't can be diffed against
    // a move that does -- the same compare-working-vs-broken technique that settled the
    // ghost-vs-player question. Gated on "actually doing something" (not idle+grounded) so a normal
    // play session doesn't flood the log with standing-still ticks, but it is still verbose: meant
    // for one short, targeted capture of specific named moves, not a long session.
    // Flipped back off 2026-08-15. Its plain-slide-only capture answered both open questions at
    // once and is the reason both fixes landed: a plain slide is actionState==1 with the capsule
    // SHRUNK 65 -> 22 (four runs of exactly 87 ticks), and the origin drops 567.2 -> 524.2 with it,
    // which is precisely the 43-unit floor-sinking offset. Carrying CapsuleHalfHeight ungated in
    // every line -- rather than gated behind the trigger being debugged, as an earlier version
    // wrongly did -- is what made that visible.
    // Flipped back off 2026-08-15 after the pole-climb capture. Result: CapsuleHalfHeight reads 65
    // for all 10,930 in-game ticks including throughout a climb, so the slide floor fix's render-Z
    // compensation (which only fires below 65) provably never runs during a climb and is NOT the
    // cause of the ghost vanishing there. Cause still unknown -- see status.md.
    //
    // **On again 2026-08-15 for the BUBBLE capture** (user-reported: the ghost animates correctly
    // inside the bubble/ball that suspends you in the air, but gets no afterimages, and the real
    // player's trail persists after leaving it until the forward launch). This is a concrete,
    // repeatable instance of the "REMAINING GAP" recorded in verified.md's afterImagesToSpawn entry
    // -- a spawn path that never touches that field -- and a repeatable trigger is exactly what
    // that investigation never had.
    //
    // **This does NOT reopen the general property hunt that entry closes.** That ceiling is real:
    // no single property tells you when the game trails, and intercepting `Spawn After Image`
    // itself needs the Blueprint UFunction hook that CRASHED the game. What this capture is for is
    // the narrower, already-proven move: the plain-slide trail was fixed not by finding a "trailing
    // now" property but by keying on a PHYSICAL FACT of that one move (capsule 65 -> 22), which is
    // trigger B in tickLocal today. If the bubble has an equally clean signature, it earns a trigger
    // C the same way. If it doesn't, the answer is that it stays uncovered -- do not substitute a
    // guess for a signature.
    // Per the slide lesson, capture ONE move and nothing else: the deliberately minimal
    // plain-slide-only capture answered two questions after several broad ones had produced wrong
    // answers. Flip off after.
    // **Flipped back off 2026-08-15, job done.** The bubble-only capture was decisive: `moveState==7`
    // (always with `movementMode==5`, `actionState==0`, `animJumpType==0`, capsule 65) is the
    // post-jump boost-available state, and `afterImagesToSpawn` reads 0 across all 2002 ticks of it.
    // That produced trigger C in tickLocal. The boost itself (`animJumpType==2`) sets it to 4 and
    // was already covered by trigger A.
    constexpr bool TRAIL_COVERAGE_TRACE = false;

    // **The bubble effect is probably NOT an afterimage at all**, 2026-08-15, from the user's own
    // close look: leaving the bubble the real player has "no trail behind you" -- the MODEL ITSELF
    // is "pulsating yellow", which at a glance resembles a trail. And inside the bubble the real
    // player is "kinda flashing" while the ghost, fed real spawned afterimages by trigger C, "looks
    // like its a constant yellow colour in comparison". User's own conclusion, and it is the right
    // one: "we might have tried to applied the after image, where something else was supposed to
    // be/play". Triggers C and D reproduce a real effect that the game is not using here.
    //
    // A pulsation is by definition a value that oscillates, so this samples the local pawn's
    // simple-typed properties while the effect is on screen and logs only what CHANGED between
    // samples (snapshot_object_values + log_value_snapshot_diff). A dump gives 389 lines to eyeball;
    // a diff gives the handful that moved. Same technique that found the outfit field by diffing two
    // dumps rather than reading one.
    //
    // **A quiet log is a real answer here, not a failure**: it means the effect is not a
    // simple-typed property on the pawn, and the search moves to the mesh/material (a dynamic
    // material instance's scalar parameter would be invisible to this) instead of continuing to
    // stare at the pawn. Deliberately samples during BOTH the in-bubble state and the window after
    // leaving it, since the user reports the effect spans both.
    // **Ran 2026-08-15, and it FOUND IT -- flipped back off.** The diff was not quiet: the pawn
    // carries `Blink_NewTrack_0_<GUID>`, a Blueprint Timeline track cycling 0 -> 1 -> 2 -> 0 (65
    // changes in-bubble, 1 post-jump), alongside `Timeline_5_NewTrack_0_<GUID>` ramping smoothly
    // 0 -> 1. A track literally named "Blink" whose cycle matches the user's "kinda flashing" is
    // the pulsation, and it is a READABLE PROPERTY on the pawn -- so the trigger information this
    // effect needs is available after all, unlike the afterimage second-spawn-path ceiling.
    // Measured span: 9406 ticks in a single bubble visit (~52s at ~180Hz), which is why the
    // 900-tick guess dropped the ghost's effect so early. See verified.md; next step recorded in
    // status.md.
    constexpr bool BUBBLE_FX_DIFF = false;
    // Every 4 ticks (~22ms at this build's measured ~180Hz). A visible flash cycles far slower than
    // that, so this cannot alias past it, and the diff keeps the volume down by itself.
    constexpr uint64_t BUBBLE_FX_DIFF_INTERVAL_TICKS = 4;

    // Pole ROTATION sync, 2026-08-15 (user: climbing up/down now syncs, "but it does not sync
    // rotating on it -- not going up, just spinning around the pole by going left/right").
    //
    // Reading the code first narrowed this before any capture: pitch/yaw/roll ARE sent
    // (`orientation`) and ARE applied to the ghost via call_set_actor_location_and_rotation, so
    // this is not a missing field on the wire. That leaves exactly two candidates, which this
    // separates in one run:
    //  (a) the spin is not expressed as ACTOR rotation at all -- this game is already known to
    //      drive facing through `VisualMesh`'s own RelativeRotation (see the facing-direction
    //      trace below, which found yaw=-90 on the mesh), so a pole spin may move the mesh, or
    //      orbit the actor's position, while actor yaw sits still. Then there is nothing wrong
    //      with the apply and the fix is to sync the thing that actually moves.
    //  (b) actor yaw does change locally and the ghost's readback does not follow -- the apply is
    //      being overridden by the ghost's own climb state, the same shape as the montage
    //      self-start proved this session.
    // Logs local yaw, VisualMesh relative yaw, and X/Y **on change**, plus each ghost's applied
    // target yaw and an INDEPENDENT readback of its actual yaw -- never the value just written,
    // per CLAUDE.md. Gated to movementMode==5 (the flying mode poles and bubbles both use) so a
    // normal session doesn't flood.
    // **Off again 2026-08-15, question ANSWERED**: local actorYaw moves smoothly through a spin while
    // visualMeshYaw stays pinned at -90, and across 2469 ghost samples actualYaw matched wantYaw to
    // the decimal over the full +/-180 range -- zero mismatches. The rotation pipeline is provably
    // correct, so what the user saw is not a sync bug. See verified.md.
    constexpr bool POLE_ROTATION_TRACE = false;

    // One-shot, 2026-08-15: the follow-up BUBBLE_FX_DIFF earned. It found the pulsation's driver
    // (`Blink_NewTrack_0_<GUID>`, a Blueprint Timeline track), but knowing WHEN the effect runs
    // isn't enough to reproduce it -- something has to be callable on the ghost. This dumps the
    // pawn's function names filtered to timeline/blink/flash/colour/material needles, which is the
    // same "what is this class's API actually called" step that found `Montage_Play` and made the
    // whole montage mirror possible. A Timeline is driven by UTimelineComponent, so a component or
    // a Play/SetPlaybackPosition entry point appearing here is the lead; nothing appearing means
    // the effect is driven from inside the Blueprint graph and needs a different angle.
    // Deliberately paired with POLE_ROTATION_TRACE in one build: they are independent read-only
    // captures in different subsystems, distinguishable by log prefix, and the scarce resource is
    // the user's testing time, not log volume. Not a violation of "one diagnostic at a time" --
    // that rule is about stacking probes on the SAME question.
    // **Off again 2026-08-15, job done and it was the turning point**: the dump named
    // `StartBubbleJumpFlash(Condition)` and `changeBubbleChargedJump(hasBubbleChargedJump)`, which
    // is the entire bubble fix. Kept because "ask the class what its API is actually called" has now
    // paid off twice (Montage_Play, then this) and the needle list is one line to change.
    constexpr bool BLINK_FX_SEARCH = false;

    // Discovery tooling, restored 2026-08-16. A near-identical dumper (log_pawn_reflection_once)
    // existed during the falling-pose/ledge-hang investigation and was deleted in commit c3eb489
    // as dead diagnostics -- generalized back for a new discovery pass (Dream Breaker
    // holding-state, ability VFX fields; agent_docs/ideas.md's Pseudoregalia section) rather than
    // re-adding the old single-purpose version verbatim. Off by default, same convention as
    // ANIM_PULSE_TRACE/GHOST_COLLISION_ENABLED: flip, rebuild, deploy, watch the log, flip back --
    // this project's established discovery-toggle workflow, not a runtime keybind.
    // Flipped back off 2026-08-15 after one real capture session (see verified.md's "Pseudoregalia
    // ability field schema" entry and adapters/pseudoregalia/PLAYER_FIELDS.md) -- its job (finding
    // real field names) is done; ABILITY_FIELD_TRACE below is the next real step, not this.
    // Flipped ON then back off 2026-08-15 for the "trigger the pawn's own system" pass (ideas.md's
    // Pseudoregalia item 3). Job done: it produced the FX/ability entry-point list and, crucially,
    // manageRecallIdleFX's real internals (SpawnSystemAttached + SpawnSoundAttached behind IsValid
    // guards -- see call_manage_recall_idle_fx's own comment), which is what that call is built on.
    // Also captured for later, not yet used: doWallRun/wallRunTick/doWallRunJump (cling-gem) and
    // slideTick/slideOverheadCheck.
    constexpr bool OBJECT_REFLECTION_DUMP = false;

    // ~5s at a typical 60fps game thread (observed ~1.5s in practice on this build -- see
    // verified.md). Deliberately slower than LOG_INTERVAL_TICKS (~2s): each firing dumps every
    // property AND every function on a class, which is long enough that a 2s cadence would make
    // consecutive dumps hard to tell apart in the log. The point of this cadence is letting a live
    // capture protocol work -- hold the sword, wait, let go, wait, cling to a wall, wait -- and
    // compare dumps taken at each distinct moment, not a single one-shot dump.
    constexpr uint64_t OBJECT_REFLECTION_DUMP_INTERVAL_TICKS = 300;

    // Live-*value* trace for the ability field schema OBJECT_REFLECTION_DUMP found (see
    // verified.md's "Pseudoregalia ability field schema" entry and PLAYER_FIELDS.md) -- that dump
    // only confirmed these fields EXIST and are spelled this way; it never read a single value.
    // This traces the actual live values of the highest-priority subset (weapon-held state,
    // charge-attack, power meter, a few wall-kick/wall-ride/plunge flags) at the existing
    // LOG_INTERVAL_TICKS (~2s) cadence, the same one the local moveState/actionState TRACE line
    // already uses, so this session's output lines up with that one. Object-reference fields
    // (WeaponMesh, weaponRef, chargingVFX, wallRideVFX) are logged as null/non-null only -- real
    // signal (e.g. does WeaponMesh become non-null only once equipped?), just not a full value
    // print, which this file has no generic case for yet.
    // Flipped back off 2026-08-15 after the second real capture session (see verified.md's
    // "Pseudoregalia ability field live-value trace" entry) -- weaponEquipped?/animEquippedWeapon
    // are now real production sync code (RemoteGhost::target_weapon_equipped), not diagnostics.
    // Flipped back on 2026-08-15 for a third session, with 'spawnTrackingParticles?' added to the
    // trace line below: OBJECT_REFLECTION_DUMP found this bool by name only, this checks whether
    // it actually flips true during a real slide/ultra-hop (the yellow/blue trail VFX).
    // Flipped back off same day: the edge trace ruled the bool out (fires once at spawn, never
    // again) -- OBJECT_REFLECTION_DUMP is doing the next real step (recursing into
    // AnimGraphNode_Trail's own fields), not this.
    constexpr bool ABILITY_FIELD_TRACE = false;

    // Trail-VFX prototype test, 2026-08-15 (see PLAYER_FIELDS.md's trail-VFX section and
    // call_spawn_after_image's own comment): calls 'Spawn After Image' on every remote ghost at a
    // slow, easy-to-eyeball cadence (~3s), independent of any real trigger condition on the real
    // player -- deliberately decoupled, same phased approach already used for weaponEquipped?
    // (confirm the call itself produces a visible effect before wiring it to the real condition
    // that should fire it). **CONFIRMED LIVE 2026-08-15** (verified.md's "Spawn After Image call
    // confirmed" entry) -- the call does produce a visible afterimage on the ghost. Flipped back
    // off now that the real actionState-edge-fired trigger (afterimage_count, this same session)
    // is in place as production code; kept in the tree for future re-diagnosis, same convention as
    // every other named test flag in this file.
    constexpr bool AFTERIMAGE_CALL_TEST = false;

    // Debugging the "ghost still holds the Dream Breaker after the real player throws it away"
    // bug found live 2026-08-15 (screenshot evidence: real player empty-handed with the thrown
    // weapon visible on the ground, ghost still visibly holding one). Traces two independent
    // things at the LOG_INTERVAL_TICKS cadence: (1) the real player's own raw weaponEquipped?
    // value -- does it actually go false on a throw, or does it stay true and weaponRef (which
    // the earlier live-value trace showed genuinely toggles) is the field that actually tracks
    // "in hand" -- and (2) an independent READBACK of the ghost's own weaponEquipped? value right
    // after this file writes it, per CLAUDE.md's "never log the value you just wrote as proof it
    // worked" rule -- confirms the write actually stuck, not just that the write call ran.
    // Flipped back off 2026-08-15, investigation paused (see verified.md's "Dream Breaker
    // weapon-visibility sync" entry): root cause reframed around a shared-local-save-data theory
    // rather than a property/function to find on WeaponMesh, and the fix approach was deliberately
    // deferred rather than decided this session. Kept in the tree, off by default, same convention
    // as OBJECT_REFLECTION_DUMP/ABILITY_FIELD_TRACE.
    // Flipped back off 2026-08-15 after the reorder-fix live test confirmed working (see
    // verified.md's "Dream Breaker weapon-visibility: animBPref cross-save diff" entry) -- the
    // trace lines did their job; the reordered calls in tickRenders' Dream Breaker block are now
    // real production code, not diagnostics.
    constexpr bool WEAPON_SYNC_TRACE = false;

    // Dream Breaker THROW animation, still open after the 2026-08-15 call-order fix (verified.md's
    // "animBPref cross-save diff" entry): that reorder fixed weapon VISIBILITY in both directions
    // and the PICKUP animation, but the user confirmed live that the throw MOTION specifically
    // still doesn't play on the ghost. The asymmetry is the whole clue -- the same edge, the same
    // two calls, the same synced flag, one direction animates and the other doesn't -- so
    // `changeEquippedWeapon(true)` plausibly IS the game's own pickup path (draw montage included)
    // while the throw motion is played by something else entirely that only real player input
    // reaches. That fits the ghost-vs-player property diff (verified.md): the ghost has no
    // Controller/InputComponent, so nothing input-driven ever runs on it.
    //
    // This flag is the read-only ground-truth pass BEFORE any fix attempt, per this project's
    // "what state does that function read, and can I write it?" triage question: watch what the
    // LOCAL player's own pawn and anim instance actually do across a real throw. It logs one line
    // per real CHANGE (not per tick) in moveState/actionState/animJumpType/weaponEquipped?/
    // weaponRef plus the currently-playing montage, which answers three things in one capture:
    // (a) is the throw a montage (needs Montage_Play with a named asset, the mechanism
    // call_montage_stop already proves works here) or a state-machine pose (needs a property we
    // aren't syncing); (b) how many ticks the throw state actually lasts -- if it's a handful, the
    // send cadence drops it and it needs the landed?/jumped? monotonic-counter pulse treatment
    // (PLAYER_FIELDS.md's bucket 2 predicted exactly this for a "weapon thrown" moment); and
    // (c) the real name of the throw entry point, via the one-shot filtered function dump, since
    // the log that originally held it has since been overwritten by later sessions.
    // Flip back to false once the capture is done, same convention as every flag above.
    // **Flipped back off 2026-08-15, job done and the fix CONFIRMED LIVE.** The three captures this
    // flag paid for, in order: (1) the throw is invisible to every value this adapter mirrors --
    // moveState/actionState/animJumpType are bit-identical through a real throw -- and is an Anim
    // Montage, 'dreamLady_WeaponThrow_Montage'; (2) the game's own CustomPlayMontage wrapper is a
    // clean NEGATIVE on a ghost (returns normally, montage never starts, twelve-tick readback says
    // 'none'); (3) stock Montage_Play on the ghost's animBPref works, returning length=1.000 with
    // the readback showing the right montage playing. The montage mirror it produced is real
    // production code now (RemoteGhost::target_montage); what stays behind this flag is only its
    // logging plus the post-call readback, kept for the next montage question rather than deleted.
    // **Flipped back ON 2026-08-15, one session**, for the follow-up the fix opened up: the mirror
    // is general, so attack/hurt/ledge-hang montages may already play on the ghost with no new
    // code, and nobody has watched. This run logs every montage the local player starts and every
    // one the ghost plays, so the session produces real names even for animations too quick or too
    // subtle to judge by eye -- plus a one-shot dump of every loaded AnimMontage asset, which
    // answers "what else is there" directly instead of one trigger at a time. Flip off after.
    //
    // **Renamed from THROW_ANIM_TRACE 2026-08-15**: it outgrew the throw. That session confirmed
    // the montage mirror carries attacks, flinch, knockback, ledge grab, pole-to-perch and sitting,
    // and the same log-on-change shape is now answering two follow-ups it inherited:
    //  (a) **Ledge-grab pose lingers on the ghost after release** -- and NOT because of montages:
    //      LedgeGrab_Montage is 0.567s and the log shows it running to completion, with its mirrored
    //      stop landing 15-20ms after the local one. So the hang itself is a state-machine pose and
    //      the release is a state transition. This trace now logs the LOCAL state timeline and the
    //      GHOST's applied state side by side so the actual lag can be measured rather than guessed
    //      at -- this adapter's own pulse-hold logic being the first suspect.
    //  (b) **The ghost trails afterimages while CROUCHING** (user-observed live). Cause is visible
    //      in the code: the trail's real-slide trigger keys on the capsule shrinking below 50
    //      (65 standing, 22 sliding) and crouching shrinks it too. The fix depends on a number
    //      nobody has measured -- the capsule half-height while crouched -- so the local line below
    //      now carries capsule + bIsCrouched. If crouch sits well above 22, tightening the
    //      threshold is the whole fix; if not, bIsCrouched has to gate it, but ONLY if that flag
    //      isn't also set during a real slide, which the same capture settles.
    //
    // **Flipped back off 2026-08-15, both answered and both fixes confirmed live.** (a) The ledge
    // lingering was the ghost RE-STARTING the montage itself (our stop provably worked -- an
    // immediate same-tick readback read 'none' -- and the montage was back ~0.4s later with no
    // Montage_Play from this adapter); fixed by the peer-authoritative divergence correction in
    // tickRenders, user-confirmed "not stuck anymore and does the proper animation as well".
    // (b) Crouch and slide are identical on capsule (22.0) and bIsCrouched (true) and differ only
    // on moveState -- fix shipped, user-confirmed crouch clean and slide still trailing. Two wrong
    // guesses died on the way (a blend-time change; a "the stop call fails" theory), both killed by
    // measurement rather than argument -- see verified.md.
    // **On again 2026-08-15 for run 3** of GHOST_SELF_MONTAGE_PROBE, then back off, job done. Runs
    // 1 and 2 had proved the ghost self-starts LedgeGrab_Montage and that collision isn't why; this
    // flag's log-on-change of the GHOST's applied state timeline supplied the answer, by lining that
    // timeline up against the probe's self-start line. Result: the ghost held the synced hang state
    // for 5s playing nothing and started the montage 0.42s AFTER being told the hang ended, so the
    // trigger is this adapter's own state sync driving ABP_PlayerGoat_C, not the ledge. Full
    // timeline in verified.md; the conclusion is written up at the divergence correction itself.
    constexpr bool ANIM_TRACE = false;

    // Proof-by-subtraction for the one unproven claim left over from the montage work: **does the
    // ghost's OWN logic start montages?** verified.md's ledge-climb-up entry established that the
    // ghost was playing `LedgeGrab_Montage` ~0.4s after a readback-confirmed effective stop, with
    // no `Montage_Play` from this adapter in between -- but "no play in between" was read off a
    // log while the adapter was still making montage calls constantly, so it argues rather than
    // proves. The divergence correction that shipped was deliberately written not to depend on it.
    //
    // This flag removes the adapter from the montage business entirely: no start mirror, no stop
    // mirror, no divergence stop, no land/jump pulse stop. **Every montage call this file makes on
    // a ghost is suppressed** -- that is the single variable, and it has to be all of them, because
    // any surviving call leaves "we didn't see one" ambiguous. What remains is a read-only poll of
    // the ghost's own anim instance, logged on CHANGE. Then the reading is unambiguous:
    //   * ghost plays a montage at any point -> something other than this adapter started it, which
    //     is the claim, proven directly rather than inferred from an absence in a busy log.
    //   * ghost stays on 'none' for a whole session including ledge grabs and poles -> the claim is
    //     FALSE and the lingering had another cause, which reopens the ledge/pole questions.
    // The name it logs matters as much as the fact: `LedgeGrab` vs a pole/climb montage is the
    // direct link to the "ghost vanishes on a pole, returns stuck in a climb pose" item.
    //
    // **Deliberately makes the ghost wrong while on** -- no montage animation mirrors at all, and
    // the ledge-hang lingering comes back. Diagnostic only; flip, rebuild, deploy, watch, flip back,
    // same convention as ANIM_TRACE. Turns ANIM_TRACE's logging on for itself implicitly by having
    // its own unconditional output, so it does not need ANIM_TRACE set as well.
    //
    // **Second run, one variable later:** if run 1 shows self-starts, rebuild with
    // GHOST_COLLISION_ENABLED = false and repeat. Self-starts disappearing pins it on
    // collision-driven ledge detection (the leading explanation); self-starts surviving means the
    // ghost's anim graph does it without world contact and collision is exonerated.
    // **Run 2026-08-15, three runs, question ANSWERED -- see the divergence correction in tickRenders
    // for the conclusion and verified.md for the evidence.** Kept rather than deleted: it is the
    // only tool that can tell "the ghost did this" from "we did this", and the pole bug may yet need
    // exactly that answer again.
    constexpr bool GHOST_SELF_MONTAGE_PROBE = false;

    // The other half of the montage follow-up: the mirror is general, so the montages nobody has
    // ever triggered on camera -- `Guard_Main`, `Getup`, `SummonWeapon`, `Channel` (verified.md's
    // 33-montage vocabulary dump) -- should already play on a ghost for free. Nobody has watched,
    // and the ordinary way to find out is blocked: they need whatever local player input fires
    // them, which for at least some of them may be unreachable in normal play.
    //
    // So this asks the question from the other end: play each named montage on the ghost DIRECTLY,
    // one every CATALOG_PROBE_INTERVAL_TICKS, logging the asset it resolved to as it starts. The
    // user watches the ghost and reports which ones visibly animate; the log lines timestamp what
    // was on screen. This needs no knowledge of the local trigger at all, and it answers the
    // actual question ("does this montage work on a ghost") rather than a proxy for it.
    //
    // The list carries a known-good control (the throw, confirmed live) so a session where nothing
    // animates is distinguishable from a session where the probe itself is broken. Names are
    // matched as case-insensitive SUBSTRINGS of loaded AnimMontage assets, because verified.md
    // records these as short labels and the real asset names carry prefixes/suffixes
    // (`dreamLady_WeaponThrow_Montage` for what that entry calls `WeaponThrow`) -- the resolved
    // full name is logged so an ambiguous match is visible rather than silent. **Loaded assets
    // only**, same caveat as the vocabulary dump: an unresolved name means "not streamed in here",
    // not "doesn't exist", and it logs as such.
    // **Run 2026-08-15 in two rounds, question ANSWERED: 8 of 8 montages play on a ghost** (see
    // verified.md). Kept rather than deleted -- it is the general answer to "does X work on a ghost
    // when I can't trigger X locally", and the list is one line to change.
    constexpr bool MONTAGE_CATALOG_PROBE = false;
    // ~4s at this build's measured ~150Hz -- long enough to see a full montage play and end before
    // the next one starts, short enough that the whole list fits in one calm stretch of play.
    constexpr uint64_t CATALOG_PROBE_INTERVAL_TICKS = 600;
    // Cycled in order by the catalog probe. The first entry is the control: `WeaponThrow` is the
    // montage confirmed live on a ghost (verified.md), so if it doesn't animate here the probe is
    // broken and the other four results mean nothing. The rest are exactly the player montages
    // verified.md's vocabulary dump found loaded but never observed being triggered.
    // **Round 1 (2026-08-15) is DONE and all four passed** -- Guard_Main, Getup, SummonWeapon and
    // Channel all resolved unambiguously, all returned a real length, and the user watched all four
    // animate on the ghost. Round 2 below finishes the set: the remaining player montages from
    // verified.md's vocabulary dump that nobody has watched. `Sit` is deliberately absent -- it is
    // already confirmed live (user screenshot of the real player and ghost in the same sit pose).
    // `Idle_ThinkMap` is the one the user asked about directly ("looking at map").
    constexpr std::array<const char*, 5> CATALOG_PROBE_MONTAGES = {
        "WeaponThrow", "Idle_ThinkMap", "Guard_BlockedHit", "Guard_CounterF", "SitLowHP",
    };

    // Either probe needs this file to stop calling Montage_Stop on ghosts, for opposite reasons:
    // GHOST_SELF_MONTAGE_PROBE must not touch the ghost at all, and MONTAGE_CATALOG_PROBE plays
    // montages the peer isn't playing, which the divergence correction would otherwise cancel within
    // ~27ms -- the probe would look like it had failed when it had actually worked. Named once here
    // so a future third probe can't half-suppress them and quietly get an ambiguous result.
    constexpr bool MONTAGE_PROBES_SUPPRESS_ADAPTER_STOPS = GHOST_SELF_MONTAGE_PROBE || MONTAGE_CATALOG_PROBE;

    // The inversion test designed in verified.md's "Dream Breaker weapon-visibility sync" entry:
    // five straight fix attempts on the weapon-visibility sync all failed identically (data
    // pipeline confirmed correct on every sample, two function calls confirmed firing, four
    // WeaponMesh properties confirmed never changing), and the user then reported the ghost has
    // matched sword/costume state since spawning was first built -- BEFORE any weapon sync code
    // existed. This flag deliberately sends the ghost the OPPOSITE of the real player's
    // weaponEquipped? state (applied once, at the receive-parse site, so every downstream consumer
    // -- both ghost property writes, both function calls, edge detection -- sees the inverted
    // value together). THIS DELIBERATELY MAKES THE GHOST WRONG -- diagnostic only, not a fix.
    // **Run 2026-08-15, confound CONFIRMED**: the ghost kept visibly matching the real player
    // (sword and outfit both) despite the inverted target, and an independent readback proved the
    // inverted value genuinely landed and stuck on the ghost's own weaponEquipped?/
    // animEquippedWeapon properties -- so the property demonstrably has no causal influence on the
    // visual at all. See verified.md's "inversion test run" entry for the full evidence. Flipped
    // back to false; do not re-run without new grounding data (a real two-machine test with
    // different save files is the next genuinely independent confirmation angle, not another
    // loopback run of this same flag).
    constexpr bool WEAPON_SYNC_INVERT = false;

    // Next step after the inversion test confirmed the confound (see WEAPON_SYNC_INVERT's own
    // comment) and the sweater-costume follow-up sharpened it to "one-time snapshot at spawn":
    // find WHAT the spawn actually reads, by dumping every simple-typed property's real VALUE on
    // the ghost the moment it's spawned (dump_object_property_values -- see its own comment for
    // why this is a value dump, not the earlier name-only OBJECT_REFLECTION_DUMP), then comparing
    // two captures taken on two different saves (armed-everything vs. no-items) by eye/diff. Also
    // dumps the local player's own pawn at that same moment as a same-log reference point. One-shot
    // per ghost spawn (not gated behind a tick interval like OBJECT_REFLECTION_DUMP -- a spawn is
    // already a rare, easy-to-trigger event, no need to wait). Off by default, same
    // flip/rebuild/deploy/watch/flip-back convention as every other toggle in this file.
    // Flipped back off 2026-08-15: its job (finding animEquippedWeapon as the one differing field,
    // clearing WeaponMesh entirely -- see verified.md's two "cross-save" entries) is done; the
    // reorder-fix live test below doesn't need it and its output would just add noise.
    // Flipped ON then back off 2026-08-15, for a genuinely different question than the one it was
    // built for: "is there a master gate that disables ALL VFX on the ghost?" ANSWERED, NO --
    // see verified.md's "ghost vs. local player, full property diff" entry. The ghost is identical
    // to the real player on 381 of 389 properties; 'spawnTrackingParticles?' (the prime suspect)
    // is already true on the ghost, as is every ability-unlock flag. The only real differences are
    // Controller/InputComponent/Owner/PlayerState/PreviousController, all null -- i.e. the ghost is
    // fully capable but unpossessed, so its input-driven ability logic never runs, which is why no
    // VFX ever fire on it. Don't re-run this to re-ask that question; the answer is recorded.
    constexpr bool DUMP_GHOST_SPAWN_VALUES = false;

    // Outfit/costume sync investigation, started 2026-08-15 after the Dream Breaker fix. No field
    // for "currently equipped outfit" has ever turned up anywhere -- the only "outfit"-named
    // property found so far (outfitDataTable) is a static options-table asset reference, identical
    // on every save, not a per-player selection. Unlike the weapon investigation, the 0%/100%-save
    // diff can't be relied on here (both saves may share the same default outfit) -- the reliable
    // signal is a LIVE costume change within one session, which is known to visibly change
    // something. This periodically dumps the local pawn's VisualMesh (the main body mesh, distinct
    // from WeaponMesh) at the same ~2s cadence as the existing weapon/ability traces, so two
    // samples straddling a live costume swap can be diffed the same way the weapon fields were.
    // Off by default, same flip/rebuild/deploy/watch/flip-back convention as every other toggle.
    // Flipped back off 2026-08-15: its job (finding VisualMesh.SkeletalMesh/SkinnedAsset as the
    // real outfit lever -- see verified.md's outfit-trace entry) is done; real sync code now
    // exists (RemoteGhost::target_outfit_mesh) and doesn't need this diagnostic running.
    constexpr bool OUTFIT_TRACE = false;

    // First live outfit-sync test found a real negative: the raw SkeletalMesh/SkinnedAsset
    // property write (see the outfit ghost-write block in tickRenders) sticks the mesh reference
    // but the ghost renders in a T-pose -- the engine never re-binds/re-inits the anim instance
    // against the new mesh. One-shot function-name dump of VisualMesh (via dump_object_reflection,
    // schema-only, not a value dump) to find the real available setter before guessing a name.
    // Off by default, same flip/rebuild/deploy/watch/flip-back convention as every other toggle.
    // Flipped back off 2026-08-15: found SetSkeletalMeshAsset as the one real candidate this
    // build's reflection exposes (no SetSkeletalMesh/InitAnim/MarkRenderStateDirty/
    // RecreateRenderState) -- see call_set_skeletal_mesh_asset's own comment for the fix built
    // from this finding.
    constexpr bool DUMP_VISUALMESH_FUNCTIONS = false;

    // Thrown-Dream-Breaker tracking, started 2026-08-15 (`ideas.md`'s Pseudoregalia idea 0:
    // "fully visually track the thrown Dream Breaker, hand -> flight -> ground -> pickup").
    // Everything shipped so far syncs the sword only as a state OF THE CHARACTER -- in hand or
    // not (`weaponEquipped?`) plus the throw/catch montages. The thrown weapon is a real, separate
    // world object: it flies, bounces off walls, can be caught mid-air, otherwise lands and sits
    // there until walked into. None of that is visible on a ghost today, because none of it lives
    // on the pawn.
    //
    // This capture answers the ONE question the whole feature is blocked on, and it is a genuine
    // contradiction in the existing record rather than an unexplored gap: `ideas.md` says
    // `weaponRef` goes non-null specifically while the weapon is thrown/in-flight (from
    // WEAPON_SYNC_TRACE), but `verified.md`'s throw-animation entry records the opposite from a
    // later capture -- non-null for most of a session INCLUDING while the sword was in hand, and
    // null once while equipped. Both were incidental observations at a ~2s sampling cadence in
    // traces built to answer something else, so neither is trustworthy for this. Per CLAUDE.md's
    // "two guessed fixes failing identically is a signal", the fix is to stop sampling and
    // measure the field directly, on its own edges:
    //
    //   1. **Identity edges, not a cadence.** Logs whenever the OBJECT `weaponRef` points at
    //      changes (including to/from null), with its class and full name, alongside the current
    //      `weaponEquipped?`. If a throw allocates a fresh actor, that shows up as a new object
    //      identity at the exact tick the flag drops -- which a value sampler at 2s intervals
    //      cannot distinguish from "same object the whole time".
    //   2. **Is it an actor at all, and does it move?** An object with a reflected `RootComponent`
    //      is an actor (the reflection-only test this file uses everywhere instead of a raw cast
    //      on an unknown type). While non-null, its world transform is logged on real MOVEMENT
    //      (>WEAPON_ACTOR_MOVE_EPSILON units since the last logged sample) plus a slow heartbeat --
    //      so a flight arc prints as a dense run of samples, a sword resting on the ground prints
    //      as silence plus its resting position, and "never an actor / never moves" prints as
    //      neither. That distinction is exactly the MVP-vs-full-version cut point in `ideas.md`.
    //   3. **A fallback if `weaponRef` is the wrong lever.** On the `weaponEquipped?` true->false
    //      edge (a real throw), one deferred one-shot sweep of every live actor whose class or
    //      name looks weapon-ish, so the flying object can be found by world search even if the
    //      pawn never references it. Deferred by WEAPON_ACTOR_SWEEP_DELAY_TICKS so the sweep runs
    //      while the sword is actually in the air, not on the frame the throw starts.
    //   4. **What can we even sync?** One-shot full value dump of the first non-null `weaponRef`,
    //      the same dump_object_property_values that found `animEquippedWeapon` -- this is what
    //      says whether the object carries physics/velocity/resting-state fields worth sending, or
    //      whether position+rotation is the whole story.
    //
    // Read-only: this flag spawns nothing, writes nothing, and calls no game function.
    // Its job is DONE -- the capture ran 2026-08-15 and answered all four questions (see
    // verified.md's thrown-Dream-Breaker entry); real sync code now exists for what it found.
    // Left in place rather than deleted: it is the tool for the next question about this actor.
    constexpr bool WEAPON_ACTOR_TRACE = false;

    // Movement threshold for (2) above, in Unreal units. The point is to separate "in flight"
    // from "resting on the ground" without drowning the log at this build's ~150Hz tick rate, so
    // this only has to be above the noise floor of a stationary object, not precise.
    constexpr double WEAPON_ACTOR_MOVE_EPSILON = 1.0;

    // Ticks after a real throw before the one-shot world sweep in (3) runs -- long enough that the
    // sword is genuinely airborne rather than still in the throw animation's first frames. ~0.2s
    // at this build's measured ~150Hz.
    constexpr uint64_t WEAPON_ACTOR_SWEEP_DELAY_TICKS = 30;

    // First live test of the thrown-sword sync, 2026-08-15: the prop spawns and plays its own spin
    // animation, but then hangs motionless in mid-air (user screenshot: sword planted vertically,
    // exactly as it looks when embedded in a wall). It never follows the arc, never parks when the
    // peer picks their sword back up, and a second throw re-triggers its animation without moving
    // it. Notably the ghost's *held* sword still shows and hides correctly, so the peer's
    // weapon-equipped state is arriving fine -- it is specifically the prop that is stuck.
    //
    // Three causes would produce that identical symptom, and they need completely different fixes,
    // so this separates them instead of guessing (CLAUDE.md: isolate by subtraction, one variable
    // at a time). Each line prints four things side by side:
    //
    //   * TARGET    -- what the peer says. If this stops changing, the bug is on the send/parse
    //                  side and nothing about the prop is at fault.
    //   * RENDER    -- what the smoother decided to write. If TARGET moves but RENDER doesn't, the
    //                  smoothing/snap logic is wrong.
    //   * READBACK  -- the actor's OWN world location, read via K2_GetActorLocation *after* the
    //                  write. Per CLAUDE.md this is the independent read that actually proves
    //                  anything: if RENDER moves but READBACK doesn't, our move call is being
    //                  silently rejected on this actor, and no amount of send-side work fixes it.
    //   * thrown/isEmbedded?/weaponState -- whether a park was even requested, and whether the
    //                  prop's own Blueprint logic has decided it embedded itself in the geometry,
    //                  which is the leading suspect for a write being rejected.
    //
    // Read-only apart from the writes tick_remote_weapon already performs.
    // Flipped back off 2026-08-15, its job done: it found the resting pose (weaponState 0 -> 3),
    // proved the state setter does NOT spawn the glow, and -- once its own blind spot was fixed by
    // reading the position BEFORE each write instead of after -- measured the sinking as gravity.
    constexpr bool WEAPON_PROP_TRACE = false;

    // Why a landed ghost sword floats, 2026-08-15. The sync itself is PROVEN correct for this:
    // WEAPON_PROP_TRACE showed TARGET/RENDER/READBACK agreeing to a decimal through a whole arc,
    // and the prop comes to rest at exactly the peer's own resting coordinates and rotation. Yet
    // the peer's real sword lies on the floor while our copy hovers at that same position.
    //
    // Same coordinates + different appearance means the difference is INSIDE the actor, not in the
    // transform we're syncing -- structurally the same bug as the slide floor-sinking fix
    // (PLAYER_FIELDS.md): a mesh hangs off its parent at an offset fixed at construction, and it's
    // the object's own logic -- which a teleported copy never runs, since our prop has collision
    // off and never actually lands on anything -- that adjusts it. Do NOT "fix" this by nudging
    // render Z by a guessed constant; the slide fix earned its constant from a measurement, and
    // the same is required here.
    //
    // Three candidate mechanisms, all read off the LOCAL player's own thrown weapon, all logged on
    // CHANGE so a landing prints a couple of lines rather than a flood:
    //   * weaponState -- a real ByteProperty on the actor, which reads 0 on our prop the whole
    //     time. If the real one steps to another value on landing, that's the resting state and
    //     the fix is to mirror it.
    //   * isEmbedded? -- a real bool on the actor. Same question; the name suggests it's set when
    //     the sword plants into geometry.
    //   * the SkeletalMesh component's own RelativeLocation -- the direct analogue of the slide
    //     bug. If this shifts on landing, the fix is to mirror the offset itself rather than any
    //     state flag.
    // Whichever one moves names the fix; if none move, the cause is somewhere else again and no
    // guess gets to be spent on it.
    // Flipped back off 2026-08-15: it answered all three candidates at once -- weaponState carries
    // the resting pose, isEmbedded? and the mesh offset provably never move, and the glow is a
    // NiagaraComponent whose asset path is now read live rather than guessed. Kept, not deleted:
    // it is the tool for the next question about this actor.
    constexpr bool WEAPON_LANDING_TRACE = false;

    // ~10 lines/sec at this build's measured ~150Hz -- dense enough to see a 2s arc as motion,
    // sparse enough that the four columns stay readable side by side.
    constexpr uint64_t WEAPON_PROP_TRACE_INTERVAL_TICKS = 15;

    // Finds the player's own VFX by watching for them instead of guessing at their triggers.
    //
    // Motivated by two effects the user can see but can't reliably trigger on demand: a white glow
    // when empty-handed, and a yellow glow outlining where the sword used to be held. Every VFX
    // hunt in this file so far has worked the other way round -- guess a function or property name,
    // call it, watch nothing happen -- and that approach produced a long trail of negative results
    // (`afterimageColor` for the ultra trail, `manageRecallIdleFX`, four hand-picked WeaponMesh
    // properties). The thrown sword's glow changed what's possible here: effects in this game are
    // Niagara components with real, readable asset paths, and the sword's glow was reproduced on a
    // ghost purely by spawning the peer's own asset, with no in-game trigger involved at all.
    //
    // So this inverts the search. Every few ticks it enumerates the live NiagaraComponents owned by
    // the LOCAL player and logs the difference against the previous sample, giving two things per
    // effect that no name-guess ever did: **what asset it is** (which is all that's needed to
    // reproduce it, per the sword glow) and **exactly when it appeared**, which is the trigger
    // question answered by observation rather than by knowing the answer in advance.
    //
    // Deliberately not filtered to the two effects above -- anything the player spawns shows up,
    // including during an ultra hop, which is the one remaining lead on the parked blue-trail
    // problem (`verified.md` says that one is not derivable from any polled property, and this
    // isn't a polled property).
    //
    // Read-only: enumerates and logs, spawns and calls nothing.
    // Off 2026-08-16 after the throw/save-crystal capture answered both open questions: the recall
    // glow attaches to WeaponMesh (fixing its placement) and its trigger is now mirrored by
    // observing the real effect rather than inferred. Left in place -- it is the tool for the next
    // effect, and NS_WeaponPickup is already a known, un-reproduced candidate it found.
    constexpr bool VFX_WATCH = false;

    // ~15 samples/sec at this build's measured ~150Hz. Tightened from 30 for the throw capture:
    // the throw itself is a ~1s montage and effects around it can be brief, and since this logs
    // only the DIFFERENCE between samples, a faster cadence costs resolution, not log volume.
    constexpr uint64_t VFX_WATCH_INTERVAL_TICKS = 10;

    // The VFX equivalent of the montage catalog probe (README build-log step 31), and it exists for
    // the same reason that one did: the effects nobody has reproduced are mostly effects nobody
    // knows how to *trigger* on demand, and a probe sidesteps the trigger question entirely by
    // playing each candidate directly onto the ghost, one after another on a fixed cadence, naming
    // each in the log as it goes. That turned 8 untested montages into 8 confirmed ones in a single
    // session without ever learning their in-game triggers.
    //
    // What makes it possible here is the thrown sword's glow: it proved a Niagara system can be
    // spawned on a ghost from nothing but its asset path, with no game function involved. So the
    // catalog is every Niagara system this build has loaded, enumerated live rather than typed out
    // -- unlike the montage probe's hand-written name list, which could only ever contain names
    // somebody already knew.
    //
    // Deliberately paired with VFX_WATCH rather than replacing it. They answer different halves:
    // the watcher says which effects the real player spawns and *when* (the trigger), while this
    // says what each one actually looks like (the identity). The white empty-hand glow and the
    // yellow held-sword outline need the second; the parked blue ultra trail needs both.
    // Off again 2026-08-15: the shortlisted pass did its job -- the user identified
    // NS_WeaponCallReady on screen as the empty-hand glow, which is now real sync code
    // (tick_remote_recall_glow). Flip on, optionally widening VFX_PROBE_NAME_FILTERS, to identify
    // the next effect the same way. It spawns effects onto a ghost, so VFX_WATCH's results are only
    // clean while this is off; run the two in sequence.
    constexpr bool VFX_CATALOG_PROBE = false;

    // ~3s per effect at this build's measured ~150Hz -- long enough to see a looping idle effect
    // establish itself and be recognised, matching the montage probe's own ~4s cadence.
    constexpr uint64_t VFX_PROBE_INTERVAL_TICKS = 450;

    // Engine and plugin content is skipped: this is a hunt for *this game's* effects, and the
    // engine's default systems would pad the cycle with things the player can never produce.
    constexpr const char* VFX_PROBE_PATH_FILTER = "/Game/";

    // Name shortlist, added 2026-08-15 after the first full run. The `/Game/` filter alone left 58
    // systems, most of them level dressing -- item glows, breaking walls, crystals -- and the user
    // reported that as the actual problem: they can tell a player effect from a non-player one on
    // sight, but not while tracking 58 of them over three minutes. That is a signal-to-noise
    // problem, not a "watch harder" problem.
    //
    // So the cycle is narrowed to the two families that could plausibly be the effects being
    // hunted -- a white empty-hand glow and a yellow glow outlining where the sword was held --
    // which takes it to roughly ten and a full loop to well under a minute. Substring match, case
    // sensitive, matched against the asset path.
    //
    // Deliberately kept as a widenable list rather than a hardcoded set of asset names: the whole
    // point of enumerating the catalog live was to find effects nobody had named, and pinning it
    // to names we already picked would throw that away. Clear the array to go back to all 58.
    constexpr const char* VFX_PROBE_NAME_FILTERS[] = {"Weapon", "Aura"};

    // Smoothing for a remote's thrown sword -- see RemoteGhost::render_weapon_x for why any is
    // needed (extras cross the wire at 20Hz and the core never interpolates them, while this
    // redraw loop runs at ~150Hz). Fraction of the remaining gap closed per redraw tick: covers
    // most of a 20Hz step within that step's own interval, without the prop visibly trailing the
    // arc behind where the peer actually threw it.
    constexpr double WEAPON_SMOOTHING_ALPHA = 0.25;

    // Above this gap, snap instead of smoothing. A throw starts at the peer's hand and a peer can
    // also cross an area, and easing across either would draw the sword gliding through the level.
    // Comfortably above a real 20Hz step of the measured arc (~300 units/sec, so ~15 units per
    // update) and well below a room-scale jump.
    constexpr double WEAPON_SNAP_DISTANCE = 400.0;

    // The weaponState value a thrown sword takes once it has landed and planted itself. Measured,
    // not assumed: an edge trace of the real sword showed 0 -> 3 on touchdown, identically across
    // five consecutive throws, with 0 covering flight. Named rather than left as a bare 3 because
    // it is now load-bearing in two places (the resting pose and the glow spawn).
    constexpr int LANDED_WEAPON_STATE = 3;

    namespace
    {
        // StringType is std::wstring on this build (confirmed: RE-UE4SS/deps/first/String/
        // include/String/StringType.hpp, CharType = wchar_t unless FORCE_U16 is defined, which
        // it isn't here). The bridge is a plain byte socket expecting UTF-8 JSON text, so every
        // string field needs this conversion before going on the wire.
        auto to_utf8(const StringType& wide) -> std::string
        {
            if (wide.empty())
            {
                return {};
            }
            int needed = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), nullptr, 0, nullptr, nullptr);
            std::string result(static_cast<size_t>(needed), '\0');
            WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), result.data(), needed, nullptr, nullptr);
            return result;
        }

        // Minimal JSON string escaping -- only quote and backslash are realistically possible in
        // an Unreal object path (e.g. "/Game/Maps/ZONE_LowerCastle.ZONE_LowerCastle:PersistentLevel"),
        // but escaped defensively to match the Lua adapter's jsonString() safety.
        auto json_escape(const std::string& s) -> std::string
        {
            std::string out;
            out.reserve(s.size() + 2);
            for (char c : s)
            {
                if (c == '"' || c == '\\')
                {
                    out.push_back('\\');
                }
                out.push_back(c);
            }
            return out;
        }

        // Finds the real local PlayerController + its Pawn, or nullptr/nullptr if neither
        // currently exists. See the two bugs already fixed and recorded in
        // agent_docs/pitfalls.md's "Engine reflection / API availability" section:
        // FindFirstOf returns the CDO (need FindAllOf + RF_ClassDefaultObject filter), and Pawn
        // is an inherited property (need GetValuePtrByPropertyNameInChain, not the plain version).
        auto find_local_controller_and_pawn() -> std::pair<UObject*, UObject*>
        {
            std::vector<UObject*> controllers;
            UObjectGlobals::FindAllOf(STR("PlayerController"), controllers);
            for (UObject* candidate : controllers)
            {
                if (!candidate || candidate->HasAnyFlags(RF_ClassDefaultObject))
                {
                    continue;
                }
                UObject** pawn_ptr = candidate->GetValuePtrByPropertyNameInChain<UObject*>(STR("Pawn"));
                if (pawn_ptr && *pawn_ptr)
                {
                    return {candidate, *pawn_ptr};
                }
            }
            return {nullptr, nullptr};
        }

        // Minimal, non-general JSON field extraction -- deliberately not a full parser, matching
        // the Lua adapter's own minimalism (its jsonString()/hand-built envelopes, not a generic
        // decoder). This data is NOT trusted input, despite the fixed envelope shape: it arrives
        // over the bridge socket as a render_remote line originated by a remote peer, forwarded
        // by the Go core, which only bounds it by total serialized byte size
        // (protocol.MaxExtrasBytes) -- not by per-field type, range, or finiteness. See
        // adapters/_template/PROTOCOL.md's own "peer-controlled" warning on render_remote data,
        // and clamp_to_uint8's comment below for the specific narrowing hazard this file already
        // guards against. What actually makes this minimal string-search parser safe to use on
        // untrusted bytes is narrower than "the format is fixed-shape": see json_number_field's
        // comment just below for the real reason a whole-string search doesn't misparse.
        auto json_string_field(const std::string& s, const std::string& key) -> std::string
        {
            std::string needle = "\"" + key + "\":\"";
            size_t pos = s.find(needle);
            if (pos == std::string::npos)
            {
                return {};
            }
            pos += needle.size();
            size_t end = s.find('"', pos);
            if (end == std::string::npos)
            {
                return {};
            }
            return s.substr(pos, end - pos);
        }

        auto json_vec3_field(const std::string& s, const std::string& key, double& a, double& b, double& c) -> bool
        {
            std::string needle = "\"" + key + "\":[";
            size_t pos = s.find(needle);
            if (pos == std::string::npos)
            {
                return false;
            }
            pos += needle.size();
            return std::sscanf(s.c_str() + pos, "%lf,%lf,%lf", &a, &b, &c) == 3;
        }

        // Same minimal-parser philosophy as json_string_field/json_vec3_field above. Used for the
        // animation-state fields nested under "extras" -- key names (move_state, h_speed, etc.)
        // are distinct enough that a whole-string search is safe without properly scoping to the
        // "extras" object, same tradeoff already made for every other field here. This holds even
        // against a hostile peer, not just a well-behaved one: JSON string values are escaped when
        // serialized, so a peer-controlled string field (e.g. anim, area_id, player_id) can never
        // contain a literal, unescaped `"h_speed":` substring that this search could mistake for
        // the real key -- any such content would itself be escaped (e.g. `\"h_speed\":`) in the
        // serialized bytes, which does not match the bare needle searched for here. The numeric
        // *value* found this way is still fully attacker-controlled, though -- that's what
        // clamp_to_uint8 below exists to bound before use.
        auto json_number_field(const std::string& s, const std::string& key, double& out) -> bool
        {
            std::string needle = "\"" + key + "\":";
            size_t pos = s.find(needle);
            if (pos == std::string::npos)
            {
                return false;
            }
            pos += needle.size();
            return std::sscanf(s.c_str() + pos, "%lf", &out) == 1;
        }

        // JSON player_id values in this wire format are always plain ASCII ids (e.g. "p1-ghost",
        // stamped by the core, never user-typed free text) -- a byte-widen is safe and avoids
        // pulling in a full UTF-8 decoder just for log lines.
        auto to_wide_ascii(const std::string& s) -> StringType
        {
            return StringType(s.begin(), s.end());
        }

        // Best-effort extra safety margin for the hijack design (user-requested 2026-08-13):
        // interactive/quest-relevant objects (chairs you can sit on, notes you can read) almost
        // certainly aren't plain StaticMeshActor instances -- that base engine class has no
        // built-in interaction support, so anything with attached behavior would need a custom
        // Blueprint subclass instead, which wouldn't even match this FindAllOf("StaticMeshActor")
        // search. This keyword skip is a belt-and-suspenders check on top of that, not the primary
        // safeguard -- it can't catch an interactive object that happens to still be named
        // generically, only ones whose name gives it away.
        constexpr std::wstring_view HIJACK_EXCLUDE_KEYWORDS[] = {
            L"Chair", L"Note", L"Item", L"Quest", L"NPC", L"Pickup", L"Key", L"Book", L"Letter", L"Interact"};

        auto name_has_excluded_keyword(const StringType& full_name) -> bool
        {
            for (std::wstring_view keyword : HIJACK_EXCLUDE_KEYWORDS)
            {
                auto it = std::search(full_name.begin(), full_name.end(), keyword.begin(), keyword.end(), [](wchar_t a, wchar_t b) {
                    return towlower(a) == towlower(b);
                });
                if (it != full_name.end())
                {
                    return true;
                }
            }
            return false;
        }

        // Phase 7.6: C++ equivalent of Lua's `ghost:IsValid()`, read from UE4SS's own binding
        // (RE-UE4SS/UE4SS/include/LuaType/LuaUObject.hpp:721-733) rather than guessed. Lua's real
        // check also confirms the object is still present in Lua's own wrapper-lifetime cache
        // (`is_object_in_global_unreal_object_map`), which has no equivalent for a raw C++
        // pointer -- but `IsUnreachable()` is the actual engine-level "the garbage collector has
        // condemned this object" signal Lua's check is built on
        // (deps/first/Unreal/include/Unreal/UObject.hpp:285-287), and is a plain public member
        // function, not Lua-specific.
        auto actor_is_alive(AActor* actor) -> bool
        {
            return actor != nullptr && !actor->IsUnreachable();
        }

        // Clamps a remote-controlled double to a valid uint8_t range before narrowing. Added in
        // a review pass: static_cast<uint8_t>(double) is undefined behavior -- not just "wraps",
        // the way an integer-to-integer narrowing would -- if the value is NaN or outside
        // [0, 255]. move_state/action_state/anim_jump_type/movement_mode all come from a remote
        // peer's extras map, which the Go core only bounds by serialized byte size
        // (protocol.MaxExtrasBytes), not by per-field numeric range or finiteness -- unlike
        // Position, which the core's own storeRemoteState now rejects outright if non-finite
        // (see the ADR in agent_docs/architecture.md), extras values reach here unchecked.
        auto clamp_to_uint8(double value) -> uint8_t
        {
            if (std::isnan(value) || value < 0.0)
            {
                return 0;
            }
            if (value > 255.0)
            {
                return 255;
            }
            return static_cast<uint8_t>(value);
        }

        // 'landed?'/'jumped?' (and every other per-frame anim local: 'Move State', 'landed?', etc.)
        // live on animBPref -- the AnimBP instance -- not on the pawn itself, confirmed via the
        // real reflection dump (see PULSE_HOLD_TICKS's comment above). One hop through
        // GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref")) reaches it, same pattern
        // already used elsewhere in this file for CharacterMovement/CapsuleComponent/VisualMesh.
        // Returns false (not found treated the same as "not currently true") if animBPref, or the
        // named bool on it, doesn't resolve -- e.g. a hijacked StaticMeshActor ghost has neither.
        auto read_animbp_bool(UObject* actor, const wchar_t* name) -> bool
        {
            if (!actor)
            {
                return false;
            }
            UObject** abp = actor->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref"));
            if (!abp || !*abp)
            {
                return false;
            }
            bool* value = (*abp)->GetValuePtrByPropertyNameInChain<bool>(name);
            return value && *value;
        }

        // Write counterpart of read_animbp_bool -- used to drive the ghost's own AnimBP directly,
        // since (unlike moveState/actionState/etc.) landed?/jumped? are set by the AnimBP's own
        // event graph in response to a delegate (LandedDelegate/playerLanded?) the ghost's
        // collision-disabled CharacterMovementComponent can never fire, so mirroring the pawn side
        // alone (the pattern used for every other animation field in this file) cannot work here.
        // No-op, safely, if animBPref or the named bool doesn't resolve (e.g. hijack-mode ghost).
        auto write_animbp_bool(UObject* actor, const wchar_t* name, bool value) -> void
        {
            if (!actor)
            {
                return;
            }
            UObject** abp = actor->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref"));
            if (!abp || !*abp)
            {
                return;
            }
            if (bool* ptr = (*abp)->GetValuePtrByPropertyNameInChain<bool>(name))
            {
                *ptr = value;
            }
        }

        // Prints the render flags that control drawing-through-walls for one actor's mesh
        // components. Read-only. See OUTLINE_TRACE for what question this answers.
        //
        // Checks VisualMesh and WeaponMesh separately because they are separate components and an
        // outline could be on either -- a fix that only covered the body would leave a sword
        // hovering through a wall, which is the same information leak in a smaller shape.
        auto log_outline_flags(UObject* actor, const wchar_t* label) -> void
        {
            if (!actor)
            {
                return;
            }
            for (const wchar_t* mesh_name : {STR("VisualMesh"), STR("WeaponMesh")})
            {
                UObject** mesh = actor->GetValuePtrByPropertyNameInChain<UObject*>(mesh_name);
                if (!mesh || !*mesh)
                {
                    Output::send(STR("[MeshGhostPseudo] OUTLINE_TRACE {} {}=<not found>\n"), label, mesh_name);
                    continue;
                }

                bool* custom_depth = (*mesh)->GetValuePtrByPropertyNameInChain<bool>(STR("bRenderCustomDepth"));
                bool* main_pass = (*mesh)->GetValuePtrByPropertyNameInChain<bool>(STR("bRenderInMainPass"));
                int32_t* stencil = (*mesh)->GetValuePtrByPropertyNameInChain<int32_t>(STR("CustomDepthStencilValue"));

                Output::send(STR("[MeshGhostPseudo] OUTLINE_TRACE {} {} obj={} bRenderCustomDepth={} CustomDepthStencilValue={} bRenderInMainPass={}\n"),
                             label,
                             mesh_name,
                             (*mesh)->GetFullName(),
                             custom_depth ? (*custom_depth ? STR("true") : STR("false")) : STR("<absent>"),
                             stencil ? std::to_wstring(*stencil) : STR("<absent>"),
                             main_pass ? (*main_pass ? STR("true") : STR("false")) : STR("<absent>"));
            }
        }

        // Read-only reflection dumper, gated by OBJECT_REFLECTION_DUMP (see its own comment).
        // Uses the real native reflection API (TFieldRange<FProperty>/TFieldRange<UFunction>,
        // RE-UE4SS/deps/first/Unreal/include/.../UnrealType.hpp:3117 defines the template; usage
        // grounded against RE-UE4SS/UE4SS/src/GUI/Dumpers.cpp:412, which iterates a live UObject's
        // class the same way for its own property-value dumper), not the Lua-exposed
        // UStruct:ForEachProperty binding -- that binding was confirmed missing on this exact
        // installed build during the original falling-pose/ledge-hang investigation (phase7.md's
        // BP_PlayerCam_C entry, "attempt to call a nil value" on every call). Dumps both
        // properties and functions in one pass: a weapon-held flag is plausibly a property, a
        // VFX toggle is plausibly reached via a function (e.g. "Play"/"Activate" on a Niagara
        // component reference), and neither is known yet -- that's the whole point of this pass.
        auto dump_object_reflection(UObject* obj, const wchar_t* label) -> void
        {
            if (!obj)
            {
                Output::send(STR("[MeshGhostPseudo] DIAG: {} is null, cannot reflect.\n"), label);
                return;
            }
            UClass* obj_class = obj->GetClassPrivate();
            if (!obj_class)
            {
                Output::send(STR("[MeshGhostPseudo] DIAG: {} has no class, cannot reflect.\n"), label);
                return;
            }
            Output::send(STR("[MeshGhostPseudo] DIAG: reflecting {} = instance '{}' of class {}\n"),
                         label, obj->GetFullName(), obj_class->GetFullName());
            for (FProperty* property : TFieldRange<FProperty>(obj_class, EFieldIterationFlags::Default))
            {
                if (!property)
                {
                    continue;
                }
                Output::send(STR("[MeshGhostPseudo] DIAG: {} property '{}' ({})\n"),
                             label, property->GetName(), property->GetClass().GetName());

                // Trail-VFX investigation, 2026-08-15: TFieldRange above only lists this object's
                // OWN class properties -- a StructProperty's inner fields (e.g. whatever gates the
                // native FAnimNode_Trail struct on/off) are invisible unless recursed into
                // explicitly, same GetStruct() cast this file already uses for NewLocation/
                // NewRotation at K2_SetActorLocationAndRotation's call site. Scoped to
                // AnimGraphNode_Trail* by name so this doesn't recurse into every struct on the
                // class (Vector/Rotator/etc.) and flood the log.
                if (property->GetClass().GetName() == STR("StructProperty") &&
                    StringType(property->GetName()).find(STR("AnimGraphNode_Trail")) != StringType::npos)
                {
                    if (UScriptStruct* trail_struct = static_cast<FStructProperty*>(property)->GetStruct())
                    {
                        for (FProperty* inner : TFieldRange<FProperty>(trail_struct, EFieldIterationFlags::Default))
                        {
                            if (!inner)
                            {
                                continue;
                            }
                            Output::send(STR("[MeshGhostPseudo] DIAG: {} {}.{} inner property '{}' ({})\n"),
                                         label, property->GetName(), trail_struct->GetName(),
                                         inner->GetName(), inner->GetClass().GetName());
                        }
                    }
                    else
                    {
                        Output::send(STR("[MeshGhostPseudo] DIAG: {} {} has no reflected UScriptStruct.\n"),
                                     label, property->GetName());
                    }
                }
            }
            for (UFunction* function : TFieldRange<UFunction>(obj_class, EFieldIterationFlags::Default))
            {
                if (!function)
                {
                    continue;
                }
                Output::send(STR("[MeshGhostPseudo] DIAG: {} function '{}' PropertiesSize={}\n"),
                             label, function->GetName(), function->GetPropertiesSize());

                // Trail-VFX investigation, 2026-08-15 continued: 'Spawn After Image' and
                // 'spawnNumAfterimages' turned up on the local pawn -- "afterimage" is the real
                // in-game term for this effect. UFunction IS-A UStruct (Class.hpp:349), so its own
                // parameters reflect the same way changeEquippedWeapon's 'weaponEquipped?' param
                // was found by name earlier in this file, just enumerated here instead of a single
                // named lookup, since these two functions' real parameter names aren't known yet.
                // Broadened 2026-08-15 for the "trigger the pawn's own system" pass (ideas.md's
                // Pseudoregalia item 3): the afterimage trail proved that calling the pawn's own
                // function reproduces the real effect on the ghost, and the ghost-vs-player diff
                // (verified.md) showed the ghost is fully capable but simply never driven. This
                // widens the param dump to every plausible FX/ability entry point so ONE capture
                // covers the remaining effects (empty-hand recall glow, cling-gem sparkle) instead
                // of a rebuild+relaunch cycle per function.
                StringType function_name(function->GetName());
                auto name_has = [&function_name](const wchar_t* needle) {
                    return function_name.find(needle) != StringType::npos;
                };
                if (name_has(STR("After Image")) || name_has(STR("fterimages")) ||
                    name_has(STR("FX")) || name_has(STR("VFX")) ||
                    name_has(STR("allRide")) || name_has(STR("allRun")) ||
                    name_has(STR("ecall")) || name_has(STR("lide")))
                {
                    for (FProperty* param : TFieldRange<FProperty>(function, EFieldIterationFlags::Default))
                    {
                        if (!param)
                        {
                            continue;
                        }
                        Output::send(STR("[MeshGhostPseudo] DIAG: {} {}(...) param '{}' ({})\n"),
                                     label, function->GetName(), param->GetName(), param->GetClass().GetName());
                    }
                }
            }
            Output::send(STR("[MeshGhostPseudo] DIAG: end of {} reflection dump.\n"), label);
        }

        // Value dumper, new 2026-08-15 for the Dream Breaker spawn-snapshot investigation.
        // dump_object_reflection above only ever printed property NAMES and types -- useful for
        // finding candidate fields by name, useless for "what's actually different between an
        // armed-save spawn and an unarmed-save spawn" (verified.md's "second follow-up" entry:
        // the ghost's weapon/outfit is a one-time spawn-time snapshot, not driven by any of the
        // five candidate fields/functions already tried). This prints real values for the common
        // property kinds, by name, reusing the exact same GetValuePtrByPropertyNameInChain<T>
        // pattern already used everywhere else in this file for each type -- not a new access
        // mechanism, just applied generically across every property the class has instead of a
        // hand-picked list. Deliberately does not attempt struct/array/map properties (FVector,
        // TArray, etc.) -- those need their own per-type marshaling (see the FRotator marshaling
        // bug elsewhere in this file for why guessing a struct layout is dangerous) and aren't
        // needed to find a simple "which flag/reference differs" answer first.
        auto dump_object_property_values(UObject* obj, const wchar_t* label) -> void
        {
            if (!obj)
            {
                Output::send(STR("[MeshGhostPseudo] DIAG: {} is null, cannot dump values.\n"), label);
                return;
            }
            UClass* obj_class = obj->GetClassPrivate();
            if (!obj_class)
            {
                Output::send(STR("[MeshGhostPseudo] DIAG: {} has no class, cannot dump values.\n"), label);
                return;
            }
            Output::send(STR("[MeshGhostPseudo] DIAG: value-dumping {} = instance '{}' of class {}\n"),
                         label, obj->GetFullName(), obj_class->GetFullName());
            for (FProperty* property : TFieldRange<FProperty>(obj_class, EFieldIterationFlags::Default))
            {
                if (!property)
                {
                    continue;
                }
                StringType prop_name = property->GetName();
                StringType prop_type = property->GetClass().GetName();
                if (prop_type == STR("BoolProperty"))
                {
                    bool* ptr = obj->GetValuePtrByPropertyNameInChain<bool>(prop_name.c_str());
                    Output::send(STR("[MeshGhostPseudo] DIAG: {} {} (bool) = {}\n"), label, prop_name, ptr ? *ptr : false);
                }
                else if (prop_type == STR("IntProperty"))
                {
                    int32_t* ptr = obj->GetValuePtrByPropertyNameInChain<int32_t>(prop_name.c_str());
                    Output::send(STR("[MeshGhostPseudo] DIAG: {} {} (int32) = {}\n"), label, prop_name, ptr ? *ptr : -1);
                }
                else if (prop_type == STR("FloatProperty"))
                {
                    float* ptr = obj->GetValuePtrByPropertyNameInChain<float>(prop_name.c_str());
                    Output::send(STR("[MeshGhostPseudo] DIAG: {} {} (float) = {}\n"), label, prop_name, ptr ? *ptr : -1.0f);
                }
                else if (prop_type == STR("DoubleProperty"))
                {
                    double* ptr = obj->GetValuePtrByPropertyNameInChain<double>(prop_name.c_str());
                    Output::send(STR("[MeshGhostPseudo] DIAG: {} {} (double) = {}\n"), label, prop_name, ptr ? *ptr : -1.0);
                }
                else if (prop_type == STR("NameProperty"))
                {
                    FName* ptr = obj->GetValuePtrByPropertyNameInChain<FName>(prop_name.c_str());
                    Output::send(STR("[MeshGhostPseudo] DIAG: {} {} (FName) = '{}'\n"), label, prop_name, ptr ? ptr->ToString() : STR("<unreadable>"));
                }
                else if (prop_type == STR("EnumProperty") || prop_type == STR("ByteProperty"))
                {
                    // New 2026-08-15: previously skipped entirely as "unsupported type" -- the
                    // Dream Breaker spawn-snapshot investigation needs enum-backed fields checked
                    // too (e.g. a possible weapon-state selector), and every enum-backed field
                    // already read elsewhere in this file (moveState, actionState, movementMode,
                    // animJumpType) is read as a raw uint8_t, matching UE's standard
                    // UENUM(uint8)/plain-byte convention -- not a new access mechanism.
                    uint8_t* ptr = obj->GetValuePtrByPropertyNameInChain<uint8_t>(prop_name.c_str());
                    Output::send(STR("[MeshGhostPseudo] DIAG: {} {} ({}) = {}\n"), label, prop_name, prop_type, ptr ? static_cast<int>(*ptr) : -1);
                }
                else if (prop_type == STR("ObjectProperty") || prop_type == STR("WeakObjectProperty") ||
                         prop_type == STR("SoftObjectProperty") || prop_type == STR("ClassProperty"))
                {
                    UObject** ptr = obj->GetValuePtrByPropertyNameInChain<UObject*>(prop_name.c_str());
                    if (ptr && *ptr)
                    {
                        Output::send(STR("[MeshGhostPseudo] DIAG: {} {} ({}) = {}\n"), label, prop_name, prop_type, (*ptr)->GetFullName());
                    }
                    else
                    {
                        Output::send(STR("[MeshGhostPseudo] DIAG: {} {} ({}) = null\n"), label, prop_name, prop_type);
                    }
                }
                else
                {
                    Output::send(STR("[MeshGhostPseudo] DIAG: {} {} ({}) = <unsupported type, skipped>\n"), label, prop_name, prop_type);
                }
            }
            Output::send(STR("[MeshGhostPseudo] DIAG: end of {} value dump.\n"), label);
        }

        // Same enumeration as dump_object_property_values, but returning the values instead of
        // printing them, so successive samples can be DIFFED. Built 2026-08-15 for the bubble
        // effect: the user reported that what the real player has in and after the bubble is not an
        // afterimage trail at all but the model itself **pulsating yellow** -- and a pulsation is,
        // by definition, a value that oscillates. A dump prints 389 lines you then have to eyeball;
        // a diff prints only what actually moved, which for a flashing effect is exactly the field
        // driving it. Same reason the outfit mirror was found by diffing two dumps rather than
        // reading one.
        //
        // Object-typed fields are recorded as null/non-null only, matching ABILITY_FIELD_TRACE's
        // convention: a component being swapped in is real signal, a full name is noise here.
        auto snapshot_object_values(UObject* obj) -> std::map<StringType, StringType>
        {
            std::map<StringType, StringType> out;
            if (!obj)
            {
                return out;
            }
            UClass* obj_class = obj->GetClassPrivate();
            if (!obj_class)
            {
                return out;
            }
            for (FProperty* property : TFieldRange<FProperty>(obj_class, EFieldIterationFlags::Default))
            {
                if (!property)
                {
                    continue;
                }
                StringType prop_name = property->GetName();
                StringType prop_type = property->GetClass().GetName();
                if (prop_type == STR("BoolProperty"))
                {
                    bool* ptr = obj->GetValuePtrByPropertyNameInChain<bool>(prop_name.c_str());
                    out[prop_name] = ptr ? (*ptr ? STR("true") : STR("false")) : STR("<unreadable>");
                }
                else if (prop_type == STR("IntProperty"))
                {
                    int32_t* ptr = obj->GetValuePtrByPropertyNameInChain<int32_t>(prop_name.c_str());
                    out[prop_name] = ptr ? std::format(STR("{}"), *ptr) : STR("<unreadable>");
                }
                else if (prop_type == STR("FloatProperty"))
                {
                    float* ptr = obj->GetValuePtrByPropertyNameInChain<float>(prop_name.c_str());
                    out[prop_name] = ptr ? std::format(STR("{:.4f}"), *ptr) : STR("<unreadable>");
                }
                else if (prop_type == STR("DoubleProperty"))
                {
                    double* ptr = obj->GetValuePtrByPropertyNameInChain<double>(prop_name.c_str());
                    out[prop_name] = ptr ? std::format(STR("{:.4f}"), *ptr) : STR("<unreadable>");
                }
                else if (prop_type == STR("EnumProperty") || prop_type == STR("ByteProperty"))
                {
                    uint8_t* ptr = obj->GetValuePtrByPropertyNameInChain<uint8_t>(prop_name.c_str());
                    out[prop_name] = ptr ? std::format(STR("{}"), static_cast<int>(*ptr)) : STR("<unreadable>");
                }
                else if (prop_type == STR("ObjectProperty") || prop_type == STR("WeakObjectProperty") ||
                         prop_type == STR("SoftObjectProperty") || prop_type == STR("ClassProperty"))
                {
                    UObject** ptr = obj->GetValuePtrByPropertyNameInChain<UObject*>(prop_name.c_str());
                    out[prop_name] = (ptr && *ptr) ? STR("<non-null>") : STR("<null>");
                }
            }
            return out;
        }

        // Log every field that changed between two snapshots. Prints nothing when nothing moved,
        // which is the point: a quiet log through the whole bubble means the effect is NOT a
        // simple-typed property on this object, and the search moves to the mesh/material rather
        // than continuing to stare at the pawn.
        auto log_value_snapshot_diff(const std::map<StringType, StringType>& before,
                                     const std::map<StringType, StringType>& after,
                                     const wchar_t* label,
                                     uint64_t tick) -> void
        {
            for (const auto& [name, new_value] : after)
            {
                auto it = before.find(name);
                if (it == before.end())
                {
                    continue;
                }
                if (it->second != new_value)
                {
                    Output::send(STR("[MeshGhostPseudo] DIFF {} tick={}: {} : {} -> {}\n"),
                                 label, tick, name, it->second, new_value);
                }
            }
        }

        // Phase 7.6 spawn-safety guard, new (not in the Lua adapter, which never spawned from the
        // title screen because it happened to only reach a real level by the time it first ran):
        // the original C++ spawn crash's ghost was a clone of the title screen's own transient
        // DefaultPawn. Never spawn against anything but the real player pawn class.
        auto class_looks_like_player(UObject* pawn) -> bool
        {
            if (!pawn)
            {
                return false;
            }
            UClass* pawn_class = pawn->GetClassPrivate();
            if (!pawn_class)
            {
                return false;
            }
            StringType class_name = pawn_class->GetFullName();
            constexpr std::wstring_view NEEDLE = L"PlayerGoat";
            auto it = std::search(class_name.begin(), class_name.end(), NEEDLE.begin(), NEEDLE.end(), [](wchar_t a, wchar_t b) {
                return towlower(a) == towlower(b);
            });
            return it != class_name.end();
        }

        // Phase 7.6 bugfix: calling ProcessEvent with a hand-rolled local struct sized by our own
        // guess at a UFunction's real parameter layout is unsafe -- if the function's actual
        // reflected parameter block (UFunction::GetPropertiesSize(), the real size UHT generated
        // for it) is larger than what we guessed, the engine writes past the end of our local
        // buffer into unrelated stack memory. This is the likely cause of a real regression: the
        // first version of the SetViewTargetWithBlend restore call (a 5-field guessed struct)
        // didn't just fail to fix the camera, it broke camera control entirely -- consistent with
        // stack corruption, not a logic bug. Fix: always size the Parms buffer from the function's
        // own GetPropertiesSize(), zero-initialized (matching every default argument value both
        // this call and the Possess call need: 0.0f, enum value 0, false are all all-zero-bits),
        // and only write the one pointer-typed argument every caller here needs, at offset 0 --
        // safe because it's always the first declared parameter (Possess(APawn* InPawn) and
        // SetViewTargetWithBlend(AActor* NewViewTarget, ...) both are). This mirrors what UE4SS's
        // own Lua binding does under the hood (allocates a real, correctly-sized Parms buffer per
        // function rather than a fixed guessed struct), just without Lua's marshalling layer.
        auto call_ufunction_with_leading_actor_arg(UObject* target, UFunction* function, AActor* actor_arg) -> void
        {
            if (!target || !function)
            {
                return;
            }
            int32_t parms_size = function->GetPropertiesSize();
            if (parms_size < static_cast<int32_t>(sizeof(AActor*)))
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: UFunction {} has an implausibly small PropertiesSize ({}) -- refusing to call it.\n"),
                             function->GetName(),
                             parms_size);
                return;
            }
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            *reinterpret_cast<AActor**>(params_buffer.data()) = actor_arg;
            target->ProcessEvent(function, params_buffer.data());
        }

        // User-requested, 2026-08-13: an attempt at real physical solidity, since the earlier
        // SetActorEnableCollision(true) test made the ghost killable but never blocking (see
        // agent_docs/risks.md's ghost-collision entry). This game was single-player -- pawn-vs-
        // pawn blocking is a case that plausibly never needed to exist, so the fix is likely a
        // per-channel *collision response* change (Block, not Overlap/Ignore), which is separate
        // from SetActorEnableCollision and not reachable via the plain property reflection used
        // everywhere else in this file (that data lives inside BodyInstance, a UE-internal struct
        // this SDK doesn't expose the layout of -- reading/writing it via a guessed offset would
        // be exactly the "address from memory" CLAUDE.md forbids). The safe path is the real
        // UFunction, UPrimitiveComponent::SetCollisionResponseToChannel(ECollisionChannel Channel,
        // ECollisionResponse NewResponse) -- unlike call_ufunction_with_leading_actor_arg's single
        // pointer argument at a known offset-0, this has two small (byte-sized) parameters whose
        // offsets aren't assumed here -- each parameter's own real FProperty::GetOffset_Internal()
        // is used, the same general technique UE4SS's own Lua ProcessEvent marshalling uses
        // (confirmed via dump_object.lua's Property:GetOffset_Internal() calls) and consistent
        // with this file's existing "don't guess a struct layout" standard.
        // Enemy-damage fix attempt, 2026-08-15. CONFIRMED live that an enemy hitting a ghost hurts
        // and can KILL the real player (verified.md) -- the vector that was flagged untested when
        // collision was kept on as a feature. bCanBeDamaged=false was already tried and provably
        // does not stop it, so instead of fighting the damage path this takes the ghost OUT of
        // enemy queries entirely: enemy targeting/hit-detection almost certainly looks for the Pawn
        // object type, so re-typing the ghost's capsule as WorldDynamic should make it invisible to
        // them while leaving it physically present (which is the whole point of the feature).
        //
        // ECollisionChannel::ECC_WorldDynamic = 1 -- a stable public UE engine constant
        // (Engine/EngineTypes.h), same sourcing as the ECC_PAWN/ECR_BLOCK constants already used at
        // the SetCollisionResponseToChannel call site, not this game's own data.
        auto call_set_collision_object_type(UObject* target, uint8_t object_type) -> void
        {
            if (!target)
            {
                return;
            }
            UFunction* function = target->GetFunctionByNameInChain(STR("SetCollisionObjectType"));
            if (!function)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: SetCollisionObjectType not reflected on the ghost capsule -- cannot hide the ghost from enemy targeting.\n"));
                return;
            }
            int32_t parms_size = function->GetPropertiesSize();
            if (parms_size < 1)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: SetCollisionObjectType has an implausibly small PropertiesSize ({}) -- refusing to call it.\n"),
                             parms_size);
                return;
            }
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            bool written = false;
            for (FProperty* property : TFieldRange<FProperty>(function, EFieldIterationFlags::None))
            {
                if (property && !written)
                {
                    params_buffer[static_cast<size_t>(property->GetOffset_Internal())] = object_type;
                    written = true;
                }
            }
            if (!written)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: SetCollisionObjectType reflected no parameters -- refusing to call it.\n"));
                return;
            }
            target->ProcessEvent(function, params_buffer.data());
        }

        // Turns off the through-walls silhouette for one mesh component.
        //
        // CONFIRMED the mechanism before writing this (OUTLINE_TRACE, verified.md): both the local
        // player's and the ghost's VisualMesh and WeaponMesh carry bRenderCustomDepth=true, which
        // is what a post-process outline pass keys off. The ghost inherits it by being a clone of
        // the player pawn.
        //
        // Calls the engine's own setter rather than writing bRenderCustomDepth directly, and that
        // distinction is the whole point: the raw bool is render-thread state, and assigning it on
        // the game thread can leave an already-created render state untouched -- the flag would
        // read false while the silhouette kept drawing. SetRenderCustomDepth marks the render
        // state dirty, which is the game doing the work rather than us imitating it.
        //
        // Same shape as call_set_collision_object_type above: size the buffer from the function's
        // own PropertiesSize and write at the reflected offset, never a hand-rolled struct.
        auto call_set_render_custom_depth(UObject* component, bool value) -> void
        {
            if (!component)
            {
                return;
            }
            UFunction* function = component->GetFunctionByNameInChain(STR("SetRenderCustomDepth"));
            if (!function)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: SetRenderCustomDepth not reflected on {} -- ghost may still be visible through walls.\n"),
                             component->GetFullName());
                return;
            }
            int32_t parms_size = function->GetPropertiesSize();
            if (parms_size < 1)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: SetRenderCustomDepth has an implausibly small PropertiesSize ({}) -- refusing to call it.\n"),
                             parms_size);
                return;
            }
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            bool written = false;
            for (FProperty* property : TFieldRange<FProperty>(function, EFieldIterationFlags::None))
            {
                if (property && !written)
                {
                    params_buffer[static_cast<size_t>(property->GetOffset_Internal())] = value ? 1 : 0;
                    written = true;
                }
            }
            if (!written)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: SetRenderCustomDepth reflected no parameters -- refusing to call it.\n"));
                return;
            }
            component->ProcessEvent(function, params_buffer.data());
        }

        auto call_set_collision_response_to_channel(UObject* target, UFunction* function, uint8_t channel, uint8_t response) -> void
        {
            if (!target || !function)
            {
                return;
            }
            int32_t parms_size = function->GetPropertiesSize();
            if (parms_size < 2)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: SetCollisionResponseToChannel has an implausibly small PropertiesSize ({}) -- refusing to call it.\n"),
                             parms_size);
                return;
            }
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            int params_written = 0;
            for (FProperty* property : TFieldRange<FProperty>(function, EFieldIterationFlags::None))
            {
                if (!property || params_written >= 2)
                {
                    continue;
                }
                params_buffer[static_cast<size_t>(property->GetOffset_Internal())] = (params_written == 0) ? channel : response;
                ++params_written;
            }
            if (params_written < 2)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: SetCollisionResponseToChannel reflected {} parameter(s), expected 2 -- refusing to call it.\n"),
                             params_written);
                return;
            }
            target->ProcessEvent(function, params_buffer.data());
        }

        // Ledge-hang-stuck-forever fix, 2026-08-13: the landed?/jumped? pulse mirror (see
        // PULSE_HOLD_TICKS's comment) provably resets the ghost's moveState/actionState/
        // movementMode correctly on every real landing, yet the user confirmed live the ghost
        // stays frozen in the ledge-hang POSE regardless of any later jump/slide/land -- a pose
        // that outlives every state-machine byte resetting is the signature of an Anim Montage
        // (started once via a "Play Anim Montage" node, independent of the state machine), not a
        // state-machine transition. Confirmed real, not guessed: log_pawn_reflection_once's
        // UFunction enumeration found 'Montage_Stop' on animBPref's class chain, and a follow-up
        // read-only FProperty dump of that exact function (not assumed from general Unreal Engine
        // knowledge, per CLAUDE.md) confirmed its real parameters: 'InBlendOutTime' (FloatProperty,
        // offset 0) and 'Montage' (ObjectProperty, offset 8, left null in the zeroed buffer below --
        // UAnimInstance::Montage_Stop's own documented behavior for a null Montage argument is to
        // stop whatever is currently playing, which is exactly what's wanted here since which
        // specific UAnimMontage asset played the hang pose was never determined and doesn't need to
        // be). Matched by property NAME here, not just assumed position, in case a future engine
        // update on this SDK ever reorders them.
        auto call_montage_stop(UObject* anim_instance, float blend_out_time) -> void
        {
            if (!anim_instance)
            {
                return;
            }
            UFunction* function = anim_instance->GetFunctionByNameInChain(STR("Montage_Stop"));
            if (!function)
            {
                return;
            }
            int32_t parms_size = function->GetPropertiesSize();
            if (parms_size < static_cast<int32_t>(sizeof(float)))
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: Montage_Stop has an implausibly small PropertiesSize ({}) -- refusing to call it.\n"),
                             parms_size);
                return;
            }
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            bool found_blend_out = false;
            for (FProperty* property : TFieldRange<FProperty>(function, EFieldIterationFlags::None))
            {
                if (property && property->GetName() == STR("InBlendOutTime"))
                {
                    *std::bit_cast<float*>(params_buffer.data() + property->GetOffset_Internal()) = blend_out_time;
                    found_blend_out = true;
                }
                // 'Montage' (the UAnimMontage* to stop) is deliberately left null -- see this
                // function's own comment above for why that's the correct value here, not a
                // shortcut.
            }
            if (!found_blend_out)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: Montage_Stop's 'InBlendOutTime' parameter was not found by name -- refusing to call it.\n"));
                return;
            }
            anim_instance->ProcessEvent(function, params_buffer.data());
        }

        // Dream Breaker THROW-animation investigation, 2026-08-15 -- read-only probe, see
        // ANIM_TRACE's own comment. 'Montage_Stop' is already confirmed present on
        // animBPref's class chain (call_montage_stop above), so this chain does carry the stock
        // montage API -- but no *getter* for the currently-playing montage has ever been
        // enumerated on this build, so this resolves one by name and gives up quietly if it isn't
        // there rather than assuming the engine's API surface, per CLAUDE.md. The same capture
        // dumps every 'ontage'-named function on both objects (dump_functions_matching below), so
        // a name that doesn't resolve gets answered with evidence from that same session instead
        // of a second guess. Writes the montage's full name into `out_name` and returns false only
        // when the getter itself couldn't be used -- so the caller can stop asking after one miss.
        auto read_current_active_montage(UObject* anim_instance, std::string& out_name) -> bool
        {
            out_name.clear();
            if (!anim_instance)
            {
                return false;
            }
            UFunction* function = anim_instance->GetFunctionByNameInChain(STR("GetCurrentActiveMontage"));
            if (!function)
            {
                Output::send(STR("[MeshGhostPseudo] TRACE throwAnim: no 'GetCurrentActiveMontage' on this anim instance's class chain -- see the filtered function dump for what montage API this build actually has.\n"));
                return false;
            }
            FProperty* return_property = nullptr;
            for (FProperty* property : TFieldRange<FProperty>(function, EFieldIterationFlags::None))
            {
                if (property && property->GetName() == STR("ReturnValue"))
                {
                    return_property = property;
                }
            }
            if (!return_property || return_property->GetClass().GetName() != STR("ObjectProperty"))
            {
                Output::send(STR("[MeshGhostPseudo] TRACE throwAnim: 'GetCurrentActiveMontage' has no ObjectProperty 'ReturnValue' -- refusing to call it.\n"));
                return false;
            }
            int32_t parms_size = function->GetPropertiesSize();
            int32_t return_end = static_cast<int32_t>(return_property->GetOffset_Internal()) + static_cast<int32_t>(sizeof(UObject*));
            if (parms_size < return_end)
            {
                Output::send(STR("[MeshGhostPseudo] TRACE throwAnim: 'GetCurrentActiveMontage' PropertiesSize={} is too small for its own ReturnValue (needs {}) -- refusing to call it.\n"),
                             parms_size, return_end);
                return false;
            }
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            anim_instance->ProcessEvent(function, params_buffer.data());
            UObject* montage = *std::bit_cast<UObject**>(params_buffer.data() + return_property->GetOffset_Internal());
            out_name = montage ? to_utf8(montage->GetFullName()) : std::string("none");
            return true;
        }

        // Montage mirror, 2026-08-15 -- the Dream Breaker THROW-animation fix (see
        // RemoteGhost::target_montage). 'CustomPlayMontage' is the game's OWN wrapper on
        // BP_PlayerGoatMain_C, confirmed by live reflection dump this same session alongside the
        // stock engine alternatives (Montage_Play on animBPref, PlayAnimMontage on the pawn):
        // exactly one parameter, 'MontageToPlay' (ObjectProperty), PropertiesSize=8. Chosen over
        // the stock calls deliberately, per ideas.md's "let the game do the work" -- the game's own
        // wrapper is what the real player's throw goes through, so whatever slot/blend handling it
        // does is the handling the animation was authored against. Matched by parameter NAME, same
        // discipline as call_montage_stop and call_change_equipped_weapon above.
        auto call_custom_play_montage(UObject* pawn, UObject* montage) -> bool
        {
            if (!pawn || !montage)
            {
                return false;
            }
            UFunction* function = pawn->GetFunctionByNameInChain(STR("CustomPlayMontage"));
            if (!function)
            {
                return false;
            }
            int32_t parms_size = function->GetPropertiesSize();
            if (parms_size < static_cast<int32_t>(sizeof(UObject*)))
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: CustomPlayMontage has an implausibly small PropertiesSize ({}) -- refusing to call it.\n"),
                             parms_size);
                return false;
            }
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            bool found_param = false;
            for (FProperty* property : TFieldRange<FProperty>(function, EFieldIterationFlags::None))
            {
                if (property && property->GetName() == STR("MontageToPlay"))
                {
                    *std::bit_cast<UObject**>(params_buffer.data() + property->GetOffset_Internal()) = montage;
                    found_param = true;
                }
            }
            if (!found_param)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: CustomPlayMontage's 'MontageToPlay' parameter was not found by name -- refusing to call it.\n"));
                return false;
            }
            pawn->ProcessEvent(function, params_buffer.data());
            return true;
        }

        // Second mechanism for the montage mirror, 2026-08-15, after CustomPlayMontage came back a
        // clean NEGATIVE: it returned normally on the ghost ten times with no warning, and an
        // independent readback of the ghost's own anim instance showed 'none' playing on every one
        // of the twelve ticks after each call (verified.md). The game's own wrapper bails somewhere
        // inside, most plausibly on the possession state the ghost structurally lacks (no
        // Controller/InputComponent/PlayerState -- the ghost-vs-player diff), which is the same
        // precondition clause manageRecallIdleFX ran into.
        //
        // 'Montage_Play' is the stock UAnimInstance entry point, confirmed present on the ghost's
        // animBPref class chain by this session's own dump (alongside Montage_Stop, which this file
        // already calls successfully on that same object -- so montage calls on a ghost's anim
        // instance do reach it). Every parameter is matched by NAME and only the ones understood
        // are written; the rest stay zeroed. Its float ReturnValue is a real built-in success
        // signal -- UAnimInstance::Montage_Play returns the montage length it started, or 0 when it
        // refuses to play -- so this reports what the engine itself thought, not just that the call
        // ran.
        auto call_montage_play(UObject* anim_instance, UObject* montage) -> float
        {
            if (!anim_instance || !montage)
            {
                return -1.0f;
            }
            UFunction* function = anim_instance->GetFunctionByNameInChain(STR("Montage_Play"));
            if (!function)
            {
                return -1.0f;
            }
            int32_t parms_size = function->GetPropertiesSize();
            if (parms_size < static_cast<int32_t>(sizeof(UObject*)))
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: Montage_Play has an implausibly small PropertiesSize ({}) -- refusing to call it.\n"),
                             parms_size);
                return -1.0f;
            }
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            bool found_montage_param = false;
            FProperty* return_property = nullptr;
            // One-shot parameter dump, first call only: this function's real signature on THIS
            // build has never been recorded, and CLAUDE.md's rule is that a call's parameters come
            // from a dump rather than from general engine knowledge. Logging them at the first real
            // call means the same session that tests the fix also carries the evidence for it.
            static bool signature_dumped = false;
            for (FProperty* property : TFieldRange<FProperty>(function, EFieldIterationFlags::None))
            {
                if (!property)
                {
                    continue;
                }
                if (!signature_dumped)
                {
                    Output::send(STR("[MeshGhostPseudo] DIAG: Montage_Play param '{}' ({}) offset={}\n"),
                                 property->GetName(), property->GetClass().GetName(), property->GetOffset_Internal());
                }
                if (property->GetName() == STR("MontageToPlay"))
                {
                    *std::bit_cast<UObject**>(params_buffer.data() + property->GetOffset_Internal()) = montage;
                    found_montage_param = true;
                }
                else if (property->GetName() == STR("InPlayRate"))
                {
                    *std::bit_cast<float*>(params_buffer.data() + property->GetOffset_Internal()) = 1.0f;
                }
                else if (property->GetName() == STR("ReturnValue"))
                {
                    return_property = property;
                }
            }
            signature_dumped = true;
            if (!found_montage_param)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: Montage_Play's 'MontageToPlay' parameter was not found by name -- refusing to call it.\n"));
                return -1.0f;
            }
            anim_instance->ProcessEvent(function, params_buffer.data());
            if (return_property && return_property->GetClass().GetName() == STR("FloatProperty") &&
                parms_size >= static_cast<int32_t>(return_property->GetOffset_Internal()) + static_cast<int32_t>(sizeof(float)))
            {
                return *std::bit_cast<float*>(params_buffer.data() + return_property->GetOffset_Internal());
            }
            return 0.0f;
        }

        // Resolve one of MONTAGE_CATALOG_PROBE's short labels to a real loaded AnimMontage.
        // Substring, case-insensitive, for the reason given at CATALOG_PROBE_MONTAGES: verified.md
        // records the vocabulary as short labels while the assets carry prefixes and suffixes, and
        // the exact asset names for the never-triggered four were never captured -- guessing a full
        // path here would be inventing an address, which this project does not do. StaticFindObject
        // (used by the mirror, which receives a real full path from a peer) is therefore not usable
        // for these; enumerating what is actually loaded and matching is.
        //
        // Returns the FIRST match and reports how many matched, so an ambiguous label is visible in
        // the log rather than silently resolving to whichever asset came first.
        auto find_loaded_montage_by_label(const std::string& label) -> UObject*
        {
            std::vector<UObject*> loaded_montages;
            UObjectGlobals::FindAllOf(STR("AnimMontage"), loaded_montages);

            std::string needle = label;
            std::transform(needle.begin(), needle.end(), needle.begin(),
                           [](unsigned char c) { return static_cast<char>(std::tolower(c)); });

            UObject* first_match = nullptr;
            size_t match_count = 0;
            for (UObject* montage : loaded_montages)
            {
                if (!montage)
                {
                    continue;
                }
                std::string name = to_utf8(montage->GetName());
                std::transform(name.begin(), name.end(), name.begin(),
                               [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
                if (name.find(needle) == std::string::npos)
                {
                    continue;
                }
                ++match_count;
                if (!first_match)
                {
                    first_match = montage;
                }
            }

            if (!first_match)
            {
                Output::send(STR("[MeshGhostPseudo] DIAG: catalog probe -- '{}' matched none of the {} loaded AnimMontage asset(s) (not streamed in here; absence is not evidence it doesn't exist).\n"),
                             to_wide_ascii(label), loaded_montages.size());
            }
            else if (match_count > 1)
            {
                Output::send(STR("[MeshGhostPseudo] DIAG: catalog probe -- '{}' matched {} loaded assets, using '{}'.\n"),
                             to_wide_ascii(label), match_count, first_match->GetFullName());
            }
            return first_match;
        }

        // Name-filtered function dump -- dump_object_reflection's function half, minus the
        // property flood, so a targeted "what is this class's throw/montage API actually called"
        // question can be answered from one capture without 389 property lines per cycle drowning
        // it. Same TFieldRange<UFunction> enumeration and same param-by-param print as that
        // function's own FX/ability filter, just with the needle list passed in by the caller
        // instead of hardcoded.
        auto dump_functions_matching(UObject* obj, const wchar_t* label, const std::vector<StringType>& needles) -> void
        {
            if (!obj)
            {
                Output::send(STR("[MeshGhostPseudo] DIAG: {} is null, cannot reflect.\n"), label);
                return;
            }
            UClass* obj_class = obj->GetClassPrivate();
            if (!obj_class)
            {
                Output::send(STR("[MeshGhostPseudo] DIAG: {} has no class, cannot reflect.\n"), label);
                return;
            }
            Output::send(STR("[MeshGhostPseudo] DIAG: filtered function dump for {} = class {}\n"),
                         label, obj_class->GetFullName());
            for (UFunction* function : TFieldRange<UFunction>(obj_class, EFieldIterationFlags::Default))
            {
                if (!function)
                {
                    continue;
                }
                StringType function_name(function->GetName());
                bool matched = false;
                for (const StringType& needle : needles)
                {
                    if (function_name.find(needle) != StringType::npos)
                    {
                        matched = true;
                        break;
                    }
                }
                if (!matched)
                {
                    continue;
                }
                Output::send(STR("[MeshGhostPseudo] DIAG: {} function '{}' PropertiesSize={}\n"),
                             label, function->GetName(), function->GetPropertiesSize());
                for (FProperty* param : TFieldRange<FProperty>(function, EFieldIterationFlags::Default))
                {
                    if (!param)
                    {
                        continue;
                    }
                    Output::send(STR("[MeshGhostPseudo] DIAG: {} {}(...) param '{}' ({})\n"),
                                 label, function->GetName(), param->GetName(), param->GetClass().GetName());
                }
            }
            Output::send(STR("[MeshGhostPseudo] DIAG: end of {} filtered function dump.\n"), label);
        }

        // Dream Breaker throw/pickup animation, 2026-08-15: writing weaponEquipped?/
        // animEquippedWeapon directly (RemoteGhost::target_weapon_equipped) was confirmed correct
        // at the data level (a live readback matched the write on every sample -- verified.md) but
        // never made the ghost play the throw/pickup montage, which the real player visibly does.
        // Same category of problem as the ledge-hang fix: a montage is fired by an explicit call,
        // not read from a polled state. 'updateWeaponEquip' on animBPref (found in the original
        // schema dump) is the real candidate -- confirmed via a live signature dump (not assumed):
        // exactly one bool parameter, named 'animEquippedWeapon', offset 0. Hypothesis, not a
        // confirmed fix -- the ledge-hang fix needed more than just the right call (a specific
        // facing direction too), so this may not be sufficient alone either.
        auto call_update_weapon_equip(UObject* anim_instance, bool equipped) -> void
        {
            if (!anim_instance)
            {
                return;
            }
            UFunction* function = anim_instance->GetFunctionByNameInChain(STR("updateWeaponEquip"));
            if (!function)
            {
                return;
            }
            int32_t parms_size = function->GetPropertiesSize();
            if (parms_size < 1)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: updateWeaponEquip has an implausibly small PropertiesSize ({}) -- refusing to call it.\n"),
                             parms_size);
                return;
            }
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            bool found_param = false;
            for (FProperty* property : TFieldRange<FProperty>(function, EFieldIterationFlags::None))
            {
                if (property && property->GetName() == STR("animEquippedWeapon"))
                {
                    params_buffer[static_cast<size_t>(property->GetOffset_Internal())] = equipped ? 1 : 0;
                    found_param = true;
                }
            }
            if (!found_param)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: updateWeaponEquip's 'animEquippedWeapon' parameter was not found by name -- refusing to call it.\n"));
                return;
            }
            anim_instance->ProcessEvent(function, params_buffer.data());
        }

        // Follow-up, 2026-08-15: calling updateWeaponEquip above was confirmed firing correctly
        // (readback matched every call) with ZERO visible effect -- no animation, WeaponMesh still
        // visible after a throw. Real negative result. Next candidate: 'changeEquippedWeapon' on
        // the PAWN (not animBPref) -- found in the original schema dump alongside the real
        // input-action event handler for Throw, plausibly the actual orchestrating function
        // (visibility + montage) that only fires from real player input today. Signature confirmed
        // via a live dump, same discipline: one bool param, real name 'weaponEquipped?', offset 0
        // -- not assumed from updateWeaponEquip's param name despite the similar shape.
        // Puts a thrown-weapon prop into a given weaponState. Found by measurement, not by name
        // guessing: an edge trace of the LOCAL player's real thrown sword showed `weaponState`
        // stepping 0 -> 3 on landing, identically across five consecutive throws, while
        // `isEmbedded?` never changed and the mesh's relative offset stayed bit-identical -- so the
        // resting pose is driven by this state and nothing else this adapter can see. The live
        // function dump of the same actor then turned up exactly one plausible entry point,
        // 'Change Weapon State' with a one-byte parameter, which matches a uint8 state enum.
        //
        // The parameter is located by enumerating the function's own reflected properties rather
        // than by assuming a name (its name was never dumped, unlike changeEquippedWeapon's), and
        // the resolved name is logged once so it stays traceable to the game rather than to a
        // guess. PropertiesSize is verified as exactly the single byte expected before any call.
        // Destroys a thrown-weapon prop. Unlike the ghost pawn -- which this file deliberately
        // never destroys, only parks (see DESPAWN_PARK_Z), because under the hijack design it was
        // never ours and reflection for K2_DestroyActor wasn't available on it -- this prop IS ours,
        // spawned by us, and the live function dump of BP_looseWeapon_C lists K2_DestroyActor with
        // PropertiesSize=0. Returns false if the call isn't available so the caller can fall back
        // to parking rather than leaking a visible sword.
        // Stops a component's physics bodies simulating. Built for the "ghost sword sinks while
        // embedded" bug, whose measurement ruled out every transform explanation: with the sword at
        // rest the actor's world location and the mesh's RelativeLocation were both provably
        // constant while it visibly sank. A simulating component explains exactly that pairing --
        // its physics bodies are driven in world space and the engine stops maintaining the cached
        // relative transform, so the visual falls while every property we can read stays still. The
        // real sword is presumably put to rest by the landing it actually performs; ours has
        // collision off, never lands on anything, and so never stops falling.
        //
        // Resolved by name through reflection and logged, never assumed present: if this build
        // doesn't expose it, that prints once and the accompanying component dump (see
        // WEAPON_PROP_TRACE's spawn block) is what names the real lever, rather than a second guess.
        auto call_set_simulate_physics(UObject* component, bool simulate, const wchar_t* label) -> bool
        {
            if (!component)
            {
                return false;
            }
            UFunction* function = component->GetFunctionByNameInChain(STR("SetSimulatePhysics"));
            if (!function)
            {
                Output::send(STR("[MeshGhostPseudo] WEAPONPROP: no reflected 'SetSimulatePhysics' on {} -- see its component dump for what this build actually exposes.\n"), label);
                return false;
            }
            int32_t parms_size = function->GetPropertiesSize();
            if (parms_size < 1)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: 'SetSimulatePhysics' on {} has an implausibly small PropertiesSize ({}) -- refusing to call it.\n"), label, parms_size);
                return false;
            }
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            params_buffer[0] = simulate ? 1 : 0;
            component->ProcessEvent(function, params_buffer.data());
            Output::send(STR("[MeshGhostPseudo] WEAPONPROP: called SetSimulatePhysics({}) on {}\n"), simulate, label);
            return true;
        }

        // Stops a prop's ProjectileMovementComponent driving it. This is the measured cause of the
        // sinking, not another candidate: with the sword at rest, the actor's position read BEFORE
        // each frame's write sat further below the previous frame's written value every sample --
        // -7.5, -8.6, -9.2 ... -13.1 units, growing linearly, which is a constant downward
        // acceleration of roughly 850 units/s^2. That is gravity, and it is the component's own
        // velocity integration rather than physics bodies, which is why SetSimulatePhysics(false)
        // changed nothing. Our per-frame teleport reset the POSITION every frame but never the
        // accumulated VELOCITY, so each frame it fell further before the screen ever saw it.
        //
        // Deactivate stops the component ticking; the velocity and gravity-scale writes afterwards
        // make sure a component that somehow resumes has nothing left to integrate. Each piece is
        // resolved by reflection and reported, so a build where one is missing says so rather than
        // silently doing less than it claims.
        // Spawns a Niagara system attached to a component, for the landed sword's glow ring.
        //
        // Why spawning it ourselves rather than triggering the game's own path: the glow is
        // measured to be a NiagaraComponent running '/Game/VFX/Emitters/NS_WeaponIdle', created by
        // the real sword on landing. 'Change Weapon State' is PROVEN not to create it (our prop's
        // idleGlowVFX stayed null across every 0 -> 3 call), and the other candidate,
        // 'checkForValidLandingPoint', turned out to be flight-path prediction whose whole
        // parameter list is Blueprint compiler temporaries -- it line-traces against collision this
        // prop deliberately doesn't have, so it could never succeed here. There is no remaining
        // in-game trigger to borrow, which is what makes spawning it directly the right call rather
        // than the lazy one.
        //
        // Self-validating, in the same spirit as call_change_weapon_state: every parameter is
        // resolved by NAME off the function's own reflection, the complete list is logged once, and
        // if the essential parameters aren't found it refuses to call rather than firing a
        // half-filled buffer at a Blueprint-adjacent engine function. A wrong call here is exactly
        // the class of thing that has crashed this game before.
        auto spawn_niagara_attached(UObject* system_asset, UObject* attach_component) -> UObject*
        {
            if (!system_asset || !attach_component)
            {
                return nullptr;
            }
            static UFunction* function = UObjectGlobals::StaticFindObject<UFunction*>(
                nullptr, nullptr, STR("/Script/Niagara.NiagaraFunctionLibrary:SpawnSystemAttached"));
            static UObject* library_cdo = UObjectGlobals::StaticFindObject<UObject*>(
                nullptr, nullptr, STR("/Script/Niagara.Default__NiagaraFunctionLibrary"));
            if (!function || !library_cdo)
            {
                static bool warned = false;
                if (!warned)
                {
                    warned = true;
                    Output::send(STR("[MeshGhostPseudo] WARNING: SpawnSystemAttached={} NiagaraFunctionLibrary CDO={} -- cannot spawn the ghost sword's glow.\n"),
                                 function ? STR("found") : STR("MISSING"),
                                 library_cdo ? STR("found") : STR("MISSING"));
                }
                return nullptr;
            }

            const int32_t parms_size = function->GetPropertiesSize();
            if (parms_size < 1)
            {
                return nullptr;
            }
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            bool has_system = false;
            bool has_attach = false;
            UObject** return_slot = nullptr;

            static bool logged_params = false;
            for (FProperty* param : TFieldRange<FProperty>(function, EFieldIterationFlags::None))
            {
                if (!param)
                {
                    continue;
                }
                const StringType param_name = param->GetName();
                if (!logged_params)
                {
                    Output::send(STR("[MeshGhostPseudo] DIAG: SpawnSystemAttached param '{}' ({}) offset={} size={}\n"),
                                 param_name, param->GetClass().GetName(),
                                 param->GetOffset_Internal(), param->GetSize());
                }
                uint8_t* slot = params_buffer.data() + param->GetOffset_Internal();
                if (param_name == STR("SystemTemplate"))
                {
                    *std::bit_cast<UObject**>(slot) = system_asset;
                    has_system = true;
                }
                else if (param_name == STR("AttachToComponent"))
                {
                    *std::bit_cast<UObject**>(slot) = attach_component;
                    has_attach = true;
                }
                else if (param_name == STR("bAutoActivate"))
                {
                    // Must be explicit: a zeroed buffer would spawn the system and never play it,
                    // which would look exactly like this whole feature failing again.
                    *slot = 1;
                }
                else if (param_name == STR("bAutoDestroy"))
                {
                    // The component's lifetime is the prop's -- destroying the prop takes it with
                    // it -- so self-destruction on completion would only risk losing a looping
                    // idle effect early.
                    *slot = 0;
                }
                else if (param_name == STR("ReturnValue"))
                {
                    return_slot = std::bit_cast<UObject**>(slot);
                }
                // Every other parameter is deliberately left zeroed: Location/Rotation zero means
                // "at the attach point", LocationType 0 is KeepRelativeOffset, PoolingMethod 0 is
                // None, and bPreCullCheck false only means the effect is never culled early.
            }
            logged_params = true;

            if (!has_system || !has_attach)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: SpawnSystemAttached is missing SystemTemplate/AttachToComponent by name -- refusing to call it. See the DIAG param list above for this build's real signature.\n"));
                return nullptr;
            }

            library_cdo->ProcessEvent(function, params_buffer.data());
            return return_slot ? *return_slot : nullptr;
        }

        // Whether a component is currently ACTIVE, as opposed to merely existing.
        //
        // Built for the "ghost keeps the recall glow forever after walking away from the save
        // crystal" bug. The local side detected the glow by asking whether the component existed,
        // which silently assumed the game destroys it when it stops. A Niagara component spawned
        // with bAutoDestroy off is normally deactivated and kept, so it stays in the enumeration
        // permanently and the existence test can never go false again -- which is exactly the
        // symptom. Note this is strictly more precise rather than a coin-flip between two theories:
        // a destroyed component fails the lookup and is reported inactive anyway, so this is
        // correct whichever the game actually does.
        //
        // Uses the reflected IsActive() function rather than reading a `bIsActive` property, and
        // that choice matters here: UE packs component bools into a bitfield, and this file has
        // already been bitten by exactly that -- `bHidden`/`bActorIsBeingDestroyed` read `true` on
        // a live, working actor (`verified.md`). A byte-wide read of a bitfield flag is not
        // trustworthy; a function return value is.
        auto component_is_active(UObject* component) -> bool
        {
            if (!component)
            {
                return false;
            }
            UFunction* function = component->GetFunctionByNameInChain(STR("IsActive"));
            if (!function)
            {
                static bool warned = false;
                if (!warned)
                {
                    warned = true;
                    Output::send(STR("[MeshGhostPseudo] WARNING: no reflected 'IsActive' on a Niagara component -- falling back to existence, which cannot detect a deactivated effect.\n"));
                }
                return true;
            }
            const int32_t parms_size = function->GetPropertiesSize();
            if (parms_size < 1)
            {
                return true;
            }
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            component->ProcessEvent(function, params_buffer.data());
            for (FProperty* param : TFieldRange<FProperty>(function, EFieldIterationFlags::None))
            {
                if (param && param->GetName() == STR("ReturnValue"))
                {
                    return *std::bit_cast<bool*>(params_buffer.data() + param->GetOffset_Internal());
                }
            }
            return true;
        }

        auto stop_projectile_movement(UObject* prop) -> void
        {
            if (!prop)
            {
                return;
            }
            UObject** pm_ptr = prop->GetValuePtrByPropertyNameInChain<UObject*>(STR("ProjectileMovement"));
            if (!pm_ptr || !*pm_ptr)
            {
                Output::send(STR("[MeshGhostPseudo] WEAPONPROP: prop has no reflected 'ProjectileMovement' -- cannot stop its gravity.\n"));
                return;
            }
            UObject* projectile_movement = *pm_ptr;

            if (UFunction* deactivate = projectile_movement->GetFunctionByNameInChain(STR("Deactivate")))
            {
                projectile_movement->ProcessEvent(deactivate, nullptr);
                Output::send(STR("[MeshGhostPseudo] WEAPONPROP: called Deactivate on prop ProjectileMovement.\n"));
            }
            else
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: no reflected 'Deactivate' on prop ProjectileMovement -- the prop may still fall.\n"));
            }

            if (FVector* velocity = projectile_movement->GetValuePtrByPropertyNameInChain<FVector>(STR("Velocity")))
            {
                *velocity = FVector(0.0, 0.0, 0.0);
            }
            if (float* gravity_scale = projectile_movement->GetValuePtrByPropertyNameInChain<float>(STR("ProjectileGravityScale")))
            {
                *gravity_scale = 0.0f;
            }
        }

        auto call_destroy_actor(AActor* actor) -> bool
        {
            if (!actor)
            {
                return false;
            }
            UFunction* function = actor->GetFunctionByNameInChain(STR("K2_DestroyActor"));
            if (!function)
            {
                static bool warned = false;
                if (!warned)
                {
                    warned = true;
                    Output::send(STR("[MeshGhostPseudo] WARNING: no reflected 'K2_DestroyActor' -- thrown-weapon props will be parked instead of destroyed.\n"));
                }
                return false;
            }
            actor->ProcessEvent(function, nullptr);
            return true;
        }

        auto call_change_weapon_state(UObject* weapon_actor, uint8_t new_state) -> void
        {
            if (!weapon_actor)
            {
                return;
            }
            UFunction* function = weapon_actor->GetFunctionByNameInChain(STR("Change Weapon State"));
            if (!function)
            {
                static bool warned = false;
                if (!warned)
                {
                    warned = true;
                    Output::send(STR("[MeshGhostPseudo] WARNING: no 'Change Weapon State' on this weapon's class chain -- ghost sword's resting pose will not update.\n"));
                }
                return;
            }
            int32_t parms_size = function->GetPropertiesSize();
            if (parms_size < 1)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: 'Change Weapon State' has an implausibly small PropertiesSize ({}) -- refusing to call it.\n"),
                             parms_size);
                return;
            }
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            bool found_param = false;
            for (FProperty* property : TFieldRange<FProperty>(function, EFieldIterationFlags::None))
            {
                if (!property)
                {
                    continue;
                }
                // The one byte-sized parameter. Guarded on size so a future build that adds a
                // second parameter can't silently get this byte written into the wrong slot.
                if (property->GetSize() == 1)
                {
                    params_buffer[static_cast<size_t>(property->GetOffset_Internal())] = new_state;
                    found_param = true;
                    static bool logged_name = false;
                    if (!logged_name)
                    {
                        logged_name = true;
                        Output::send(STR("[MeshGhostPseudo] 'Change Weapon State' parameter resolved as '{}' (offset {}, size {})\n"),
                                     property->GetName(), property->GetOffset_Internal(), property->GetSize());
                    }
                    break;
                }
            }
            if (!found_param)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: 'Change Weapon State' has no single-byte parameter -- refusing to call it.\n"));
                return;
            }
            weapon_actor->ProcessEvent(function, params_buffer.data());
        }

        auto call_change_equipped_weapon(UObject* pawn, bool equipped) -> void
        {
            if (!pawn)
            {
                return;
            }
            UFunction* function = pawn->GetFunctionByNameInChain(STR("changeEquippedWeapon"));
            if (!function)
            {
                return;
            }
            int32_t parms_size = function->GetPropertiesSize();
            if (parms_size < 1)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: changeEquippedWeapon has an implausibly small PropertiesSize ({}) -- refusing to call it.\n"),
                             parms_size);
                return;
            }
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            bool found_param = false;
            for (FProperty* property : TFieldRange<FProperty>(function, EFieldIterationFlags::None))
            {
                if (property && property->GetName() == STR("weaponEquipped?"))
                {
                    params_buffer[static_cast<size_t>(property->GetOffset_Internal())] = equipped ? 1 : 0;
                    found_param = true;
                }
            }
            if (!found_param)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: changeEquippedWeapon's 'weaponEquipped?' parameter was not found by name -- refusing to call it.\n"));
                return;
            }
            pawn->ProcessEvent(function, params_buffer.data());
        }

        // Generic single-bool-param Blueprint call, 2026-08-15. Same
        // GetFunctionByNameInChain/params_buffer/ProcessEvent shape as call_change_equipped_weapon
        // above, parameterised only because the bubble work needs two of them
        // (`StartBubbleJumpFlash(Condition)` and `changeBubbleChargedJump(hasBubbleChargedJump)`)
        // and copying that body twice more would be worse than naming it once.
        //
        // Returns whether the call was actually made, so a caller can tell "fired" from "this build
        // doesn't have it" without inferring it from silence. Still says nothing about whether
        // anything VISIBLE happened -- per CLAUDE.md, only the user watching establishes that, and
        // this project already has a recorded case (`CustomPlayMontage`) of a Blueprint wrapper
        // returning cleanly on a ghost while doing nothing at all.
        auto call_bool_ufunction(UObject* target, const wchar_t* function_name, const wchar_t* param_name, bool value) -> bool
        {
            if (!target)
            {
                return false;
            }
            UFunction* function = target->GetFunctionByNameInChain(function_name);
            if (!function)
            {
                return false;
            }
            int32_t parms_size = function->GetPropertiesSize();
            if (parms_size < 1)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: {} has an implausibly small PropertiesSize ({}) -- refusing to call it.\n"),
                             function_name, parms_size);
                return false;
            }
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            bool found_param = false;
            for (FProperty* property : TFieldRange<FProperty>(function, EFieldIterationFlags::None))
            {
                if (property && property->GetName() == StringType(param_name))
                {
                    params_buffer[static_cast<size_t>(property->GetOffset_Internal())] = value ? 1 : 0;
                    found_param = true;
                }
            }
            if (!found_param)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: {}'s '{}' parameter was not found by name -- refusing to call it.\n"),
                             function_name, param_name);
                return false;
            }
            target->ProcessEvent(function, params_buffer.data());
            return true;
        }

        // Trail-VFX prototype, 2026-08-15 (see PLAYER_FIELDS.md's trail-VFX section): 'Spawn After
        // Image' is the real lead OBJECT_REFLECTION_DUMP found for the yellow/blue slide/ultra-hop
        // trail -- a clean, single-float-param callable function, same shape as the calls above.
        // This is a prototype call only: confirmed to exist and take a plausible param, NOT yet
        // confirmed to produce a visible afterimage when called -- that's what AFTERIMAGE_CALL_TEST
        // below is for. Modeled directly on call_change_equipped_weapon above, same
        // GetFunctionByNameInChain/params_buffer/ProcessEvent shape.
        auto call_spawn_after_image(UObject* pawn, float duration) -> void
        {
            if (!pawn)
            {
                return;
            }
            UFunction* function = pawn->GetFunctionByNameInChain(STR("Spawn After Image"));
            if (!function)
            {
                return;
            }
            int32_t parms_size = function->GetPropertiesSize();
            if (parms_size < 4)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: Spawn After Image has an implausibly small PropertiesSize ({}) -- refusing to call it.\n"),
                             parms_size);
                return;
            }
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            bool found_param = false;
            for (FProperty* property : TFieldRange<FProperty>(function, EFieldIterationFlags::None))
            {
                if (property && property->GetName() == STR("Duration"))
                {
                    *std::bit_cast<float*>(params_buffer.data() + property->GetOffset_Internal()) = duration;
                    found_param = true;
                }
            }
            if (!found_param)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: Spawn After Image's 'Duration' parameter was not found by name -- refusing to call it.\n"));
                return;
            }
            pawn->ProcessEvent(function, params_buffer.data());
        }

        // Trail (afterimage) COLOR sync, 2026-08-15. 'afterimageColor' is a real FLinearColor
        // property on the pawn, found via the attire-ui-overhaul mod's own dash-colour-picker
        // Blueprints (see licensing.md -- facts only) and independently confirmed present on this
        // build's pawn by reflection. Worth syncing for TWO reasons, not just the obvious one:
        // a third-party mod lets a player pick a custom colour, AND the base game itself changes
        // this dynamically -- a perfect-timing "ultra" hop trails BLUE instead of the normal
        // yellow (user-confirmed live), which the ghost currently never shows.
        //
        // The vendored SDK forward-declares FLinearColor but never defines it
        // (Core/Math/MathFwd.hpp), so its layout is resolved by REFLECTION rather than assumed --
        // deliberately, per agent_docs/pitfalls.md's FRotator entry, where assuming a struct's
        // layout against this same SDK was a real, hard-to-spot bug. Returns false (and writes
        // nothing) if any of R/G/B/A fails to resolve, same defensive posture as every other
        // reflection-driven call in this file.
        struct LinearColorRGBA
        {
            float r{}, g{}, b{}, a{};
        };

        auto resolve_linear_color_offsets(UObject* obj, const wchar_t* property_name,
                                          uint8_t** out_base, int32_t out_offsets[4]) -> bool
        {
            if (!obj)
            {
                return false;
            }
            UClass* obj_class = obj->GetClassPrivate();
            if (!obj_class)
            {
                return false;
            }
            FProperty* color_property = obj_class->FindProperty(FName(property_name, FNAME_Find));
            if (!color_property || color_property->GetClass().GetName() != STR("StructProperty"))
            {
                return false;
            }
            UScriptStruct* color_struct = static_cast<FStructProperty*>(color_property)->GetStruct();
            if (!color_struct)
            {
                return false;
            }
            const wchar_t* channels[4] = {STR("R"), STR("G"), STR("B"), STR("A")};
            for (int i = 0; i < 4; ++i)
            {
                FProperty* channel = color_struct->FindProperty(FName(channels[i], FNAME_Find));
                if (!channel)
                {
                    return false;
                }
                out_offsets[i] = channel->GetOffset_Internal();
            }
            *out_base = std::bit_cast<uint8_t*>(obj) + color_property->GetOffset_Internal();
            return true;
        }

        auto read_linear_color(UObject* obj, const wchar_t* property_name, LinearColorRGBA& out) -> bool
        {
            uint8_t* base = nullptr;
            int32_t offsets[4]{};
            if (!resolve_linear_color_offsets(obj, property_name, &base, offsets))
            {
                return false;
            }
            out.r = *std::bit_cast<float*>(base + offsets[0]);
            out.g = *std::bit_cast<float*>(base + offsets[1]);
            out.b = *std::bit_cast<float*>(base + offsets[2]);
            out.a = *std::bit_cast<float*>(base + offsets[3]);
            return true;
        }

        // Writes R/G/B only, deliberately leaving A untouched: alpha plausibly controls the trail's
        // own fade/transparency and is not something this sync has any evidence about, so the
        // ghost keeps whatever its own construction gave it rather than having it overwritten by a
        // value we never verified the meaning of. Colour is also sent over the wire as 3 numbers
        // for the same reason (see the local_state format string).
        auto write_linear_color_rgb(UObject* obj, const wchar_t* property_name, float r, float g, float b) -> bool
        {
            uint8_t* base = nullptr;
            int32_t offsets[4]{};
            if (!resolve_linear_color_offsets(obj, property_name, &base, offsets))
            {
                return false;
            }
            *std::bit_cast<float*>(base + offsets[0]) = r;
            *std::bit_cast<float*>(base + offsets[1]) = g;
            *std::bit_cast<float*>(base + offsets[2]) = b;
            return true;
        }

        // **Reject a pool retirement being mistaken for a spawn -- see the birth-position note in
        // observe_local_afterimage_colors below.** Its own flag because it is the one rule here that
        // can SUPPRESS images: if the assumption were wrong it would thin the ghost's trail, which is
        // the symptom this area has already regressed on, so it needs a real off-switch rather than
        // being baked into the detector.
        constexpr bool AFTERIMAGE_REQUIRE_SPAWN_PROXIMITY = true;

        // How far from the player an image may appear and still count as freshly spawned.
        //
        // Derived rather than guessed: an afterimage is placed at the player, so the only thing that
        // can separate the two by the time a scan sees it is how far the player moved in between.
        // That is bounded by the scan gap -- at most 10 ticks (AFTERIMAGE_IDLE_SCAN_INTERVAL_TICKS)
        // on this build's ~150Hz, i.e. ~67ms, so even at a brisk 1500 units/s that is ~100 units.
        // 400 leaves roughly a 4x margin over the fastest case; for scale, the player capsule's own
        // half-height is 65.
        //
        // The log reports `farNew=` (the furthest mover seen) and `rejFar=` (how many were rejected),
        // so a mis-sized threshold shows up in the capture instead of quietly changing the effect.
        constexpr double AFTERIMAGE_SPAWN_PROXIMITY_UNITS = 400.0;

        // Result of one colour-only afterimage observation -- see AFTERIMAGE_OBSERVE_COLOR.
        struct AfterimageColorObservation
        {
            LinearColorRGBA color{};
            int images_found{0};   // every BP_AfterImage_C in the world, ours or a ghost's
            int images_ours{0};    // those whose cachedMesh belongs to the local pawn
            int images_new{0};     // of ours, those the pool handed out since the last scan
            bool have_color{false};
            bool have_special{false}; // at least one new image differed from the pawn's baseline
            // The actual actor the special colour was read from. Logged, never dereferenced after
            // the scan -- it exists to answer whether two detections are two distinct spawns or the
            // pool handing the SAME actor back, which the counts alone cannot distinguish.
            UObject* special_image{nullptr};
            int images_rejected_far{0};      // moved, but nowhere near the player -- a pool retirement
            double farthest_new_dist_sq{0.0}; // how far the furthest mover was, for tuning the threshold
        };

        // **The ultra hop's blue: observe it off the AFTERIMAGE, not off the pawn.** The pawn's
        // `afterimageColor` provably never changes during a real ultra (verified.md) -- the ultra
        // path colours each BP_AfterImage_C actor's own `Color` and bypasses the pawn field. Normal
        // images measure (1.000, 0.888, 0.260), ultra images (0.000, 0.787, 1.000).
        //
        // This mirrors whatever colour the game actually used rather than trying to detect an ultra.
        // That distinction is the whole reason it works: every earlier attempt tried to identify the
        // ultra STATE and failed, and this needs no such test -- ultra, a future variant or a mod all
        // come out right. Same principle as the recall-glow presence mirror.
        //
        // **Cost is the point of this function's shape**, because a per-object scan on the game
        // thread is what caused this project's worst regression (pitfalls.md, "The diagnostics were
        // the bug"): a `GetFullName()` + UTF-8 conversion + substring search PER OBJECT PER SCAN,
        // against a pool that grows past 80, at ~50Hz. So ownership is a single pointer compare here
        // -- `cachedMesh` is a component of the character it was snapshotted from, and a component's
        // Outer is its owning actor, which is exactly what the old name-substring test was
        // approximating. No strings are built, and the position map is keyed by pointer rather than
        // by name. The caller runs this ONCE PER BURST rather than on a fixed cadence, so it costs
        // nothing at all while the player is not trailing.
        auto observe_local_afterimage_colors(UObject* pawn,
                                             const LinearColorRGBA& baseline,
                                             std::map<UObject*, std::tuple<double, double, double>>& last_pos)
            -> AfterimageColorObservation
        {
            AfterimageColorObservation obs{};
            if (!pawn)
            {
                return obs;
            }
            // **An afterimage is a snapshot of the player, so it is BORN WHERE THE PLAYER IS.** That
            // fact is what separates a spawn from a pool retirement, and without it the detector
            // counts one blue image twice -- proven live 2026-08-16, where every ultra logged two
            // detections carrying the IDENTICAL actor pointer about 60 ticks (~400ms, roughly one
            // fade lifetime) apart. The pool moves an actor when it reclaims it, and "did it
            // teleport?" cannot tell that from a fresh placement.
            //
            // Note this is the exact inverse of the pooling entry in pitfalls.md: there, re-use made
            // objects look OLD and undercounted; here, retirement makes them look NEW and
            // overcounts. Same pooling, opposite error, so a detector needs guarding at both ends.
            const FVector pawn_loc = static_cast<AActor*>(pawn)->K2_GetActorLocation();

            std::vector<UObject*> afterimages;
            UObjectGlobals::FindAllOf(STR("BP_AfterImage_C"), afterimages);
            obs.images_found = static_cast<int>(afterimages.size());

            for (UObject* image : afterimages)
            {
                if (!image)
                {
                    continue;
                }
                // Must be OUR afterimage: a ghost's images are in this same list, and letting one
                // through would feed the ghost's own colour back into itself.
                UObject** cached_ptr = image->GetValuePtrByPropertyNameInChain<UObject*>(STR("cachedMesh"));
                if (!cached_ptr || !*cached_ptr || (*cached_ptr)->GetOuterPrivate() != pawn)
                {
                    continue;
                }
                ++obs.images_ours;

                // **A reused image betrays itself by TELEPORTING.** These actors are pooled and never
                // destroyed (measured: across 122 tracked images, not one ever disappeared), so "a
                // pointer I have not seen" goes quiet once the pool stops growing. An afterimage is a
                // frozen snapshot that never moves after placement, so any position change means the
                // pool handed it back out at the player's current spot. This matters for COLOUR even
                // though the trail trigger does not use it: after an ultra, blue images sit in the
                // pool indefinitely, and a later gold slide burst would otherwise keep seeing them
                // and latch blue forever.
                //
                // The threshold only needs to clear read noise: the alternative to a jump is exactly
                // zero movement, not a small one. (Declared here rather than shared with the trail
                // trigger's own copy of this value -- that one lives further down the file, outside
                // this namespace, and the two are independent knobs.)
                constexpr double REUSE_MOVE_THRESHOLD = 5.0;
                const FVector image_loc = static_cast<AActor*>(image)->K2_GetActorLocation();
                auto known = last_pos.find(image);
                bool is_new = true;
                if (known != last_pos.end())
                {
                    const double dx = image_loc.X() - std::get<0>(known->second);
                    const double dy = image_loc.Y() - std::get<1>(known->second);
                    const double dz = image_loc.Z() - std::get<2>(known->second);
                    is_new = (dx * dx + dy * dy + dz * dz) > (REUSE_MOVE_THRESHOLD * REUSE_MOVE_THRESHOLD);
                }
                last_pos[image] = {image_loc.X(), image_loc.Y(), image_loc.Z()};
                if (!is_new)
                {
                    continue;
                }

                // Reject the retirement move: a real spawn is at the player, a reclaimed actor is
                // wherever the pool put it. The distance is recorded either way so the threshold can
                // be judged from measurement rather than defended as a guess.
                const double pdx = image_loc.X() - pawn_loc.X();
                const double pdy = image_loc.Y() - pawn_loc.Y();
                const double pdz = image_loc.Z() - pawn_loc.Z();
                const double dist_sq = pdx * pdx + pdy * pdy + pdz * pdz;
                if (dist_sq > obs.farthest_new_dist_sq)
                {
                    obs.farthest_new_dist_sq = dist_sq;
                }
                if (AFTERIMAGE_REQUIRE_SPAWN_PROXIMITY &&
                    dist_sq > (AFTERIMAGE_SPAWN_PROXIMITY_UNITS * AFTERIMAGE_SPAWN_PROXIMITY_UNITS))
                {
                    ++obs.images_rejected_far;
                    continue;
                }
                ++obs.images_new;

                LinearColorRGBA image_color{};
                if (!read_linear_color(image, STR("Color"), image_color))
                {
                    continue;
                }

                // **Tie-break within a burst, and it is load-bearing.** A burst can hold one blue
                // ultra image and several gold ones, and simply taking the last meant whichever the
                // enumeration returned last won -- a coin flip, which is the whole of the original
                // "blue sometimes, yellow other times" report. An image whose colour differs from the
                // pawn's own afterimageColor wins, because that field is by definition the baseline
                // an ordinary trail uses, so a divergence from it is the game deliberately colouring
                // one image differently. Losing a gold image among blues is invisible; losing the
                // blue is exactly what was reported. This compares two OBSERVED values -- it never
                // asks whether an ultra is happening.
                constexpr float COLOR_MATCH_EPSILON = 0.01f;
                const bool differs_from_baseline =
                    std::fabs(image_color.r - baseline.r) > COLOR_MATCH_EPSILON ||
                    std::fabs(image_color.g - baseline.g) > COLOR_MATCH_EPSILON ||
                    std::fabs(image_color.b - baseline.b) > COLOR_MATCH_EPSILON;

                if (!obs.have_color || (differs_from_baseline && !obs.have_special))
                {
                    obs.color = image_color;
                    obs.have_color = true;
                    if (differs_from_baseline)
                    {
                        obs.special_image = image;
                    }
                }
                obs.have_special = obs.have_special || differs_from_baseline;
            }
            return obs;
        }

        // Cling-gem (wall-ride) VFX attempt, 2026-08-15 -- third application of the "trigger the
        // pawn's own system" pattern. Same zero-filled-buffer shape as call_spawn_num_afterimages:
        // 'doWallRun' reports PropertiesSize=768, but that size is Blueprint-internal temporaries
        // (the same thing every other function inspected this session turned out to be), not real
        // caller-facing parameters. NOT param-dumped by name first, unlike manageRecallIdleFX --
        // an honest gap, accepted because the trigger question was the expensive unknown here and
        // a wrong-shaped call on a zero buffer is the same risk profile as the two that worked.
        auto call_do_wall_run(UObject* pawn) -> void
        {
            if (!pawn)
            {
                return;
            }
            UFunction* function = pawn->GetFunctionByNameInChain(STR("doWallRun"));
            if (!function)
            {
                return;
            }
            int32_t parms_size = function->GetPropertiesSize();
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size > 0 ? parms_size : 0), 0);
            pawn->ProcessEvent(function, params_buffer.data());
        }

        // Cling-gem VFX stop, 2026-08-15. Calling doWallRun on the ghost successfully STARTS the
        // cling-gem effect (confirmed live) but nothing ever ends it -- the effect persisted after
        // the peer left the wall and while walking around. On the real player the same component
        // also stays non-null for the whole session (WALLRIDE_TRACE), so the game deactivates it
        // rather than destroying it; this does the same on the ghost.
        //
        // 'Deactivate' is a stock UActorComponent UFunction (every Niagara/particle component
        // inherits it), not this game's own API -- same reasoning as bCanBeDamaged being an engine
        // property, though note THAT one turned out not to be the lever the game actually used, so
        // this is verified by watching the effect stop, not by the call succeeding.
        auto call_component_deactivate(UObject* component) -> void
        {
            if (!component)
            {
                return;
            }
            UFunction* function = component->GetFunctionByNameInChain(STR("Deactivate"));
            if (!function)
            {
                return;
            }
            int32_t parms_size = function->GetPropertiesSize();
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size > 0 ? parms_size : 0), 0);
            component->ProcessEvent(function, params_buffer.data());
        }

        // Audio sibling of the above, 2026-08-15: deactivating the cling-gem VFX fixed the visual
        // but its paired SFX kept looping forever after the peer left the wall (confirmed live).
        // Tries 'Stop' first -- the audio-specific call on UAudioComponent, which is what actually
        // ends a looping sound -- and falls back to the generic UActorComponent 'Deactivate' if
        // this build's component doesn't expose it. Returns which one ran so the caller can log it
        // rather than assume, per this file's standing "a call succeeding is not evidence" posture.
        auto call_audio_component_stop(UObject* component) -> const wchar_t*
        {
            if (!component)
            {
                return STR("<null component>");
            }
            if (UFunction* stop_fn = component->GetFunctionByNameInChain(STR("Stop")))
            {
                int32_t parms_size = stop_fn->GetPropertiesSize();
                std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size > 0 ? parms_size : 0), 0);
                component->ProcessEvent(stop_fn, params_buffer.data());
                return STR("Stop");
            }
            if (UFunction* deactivate_fn = component->GetFunctionByNameInChain(STR("Deactivate")))
            {
                int32_t parms_size = deactivate_fn->GetPropertiesSize();
                std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size > 0 ? parms_size : 0), 0);
                component->ProcessEvent(deactivate_fn, params_buffer.data());
                return STR("Deactivate");
            }
            return STR("<no Stop or Deactivate found>");
        }

        // The confirmed-working ghost-side apply path, 2026-08-15: writing 'afterImagesToSpawn'
        // (IntProperty) and then calling 'spawnNumAfterimages' produced a real repeating trail on
        // the ghost, user-confirmed live -- unlike call_spawn_after_image above, which only ever
        // showed a single afterimage per action no matter how it was re-called. This function's own
        // reflected internals (Subtract_IntInt, Temp_int_Variable, Greater_IntInt -- a
        // decrement/compare pattern, plus a SetTimerDelegate call) are consistent with "spawn N via
        // a repeating timer, counting an externally-set N down," which is why the count must be
        // written first: an earlier attempt that called this WITHOUT setting it produced nothing.
        // None of this function's own reflected properties are real named parameters (all internal
        // Blueprint temporaries -- see PLAYER_FIELDS.md), so it's called with a zero-filled buffer
        // sized to its own PropertiesSize, matching how a Blueprint VM stack frame is normally
        // allocated regardless of real inputs.
        auto call_spawn_num_afterimages(UObject* pawn) -> void
        {
            if (!pawn)
            {
                return;
            }
            UFunction* function = pawn->GetFunctionByNameInChain(STR("spawnNumAfterimages"));
            if (!function)
            {
                return;
            }
            int32_t parms_size = function->GetPropertiesSize();
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size > 0 ? parms_size : 0), 0);
            pawn->ProcessEvent(function, params_buffer.data());
        }

        // Empty-hand recall glow, 2026-08-15 -- the second application of the "trigger the pawn's
        // own system rather than reimplementing it" pattern that produced the afterimage trail
        // (ideas.md's Pseudoregalia item 3, backed by verified.md's ghost-vs-player diff: the ghost
        // is a fully-capable player pawn that simply never gets driven). Chosen over the cling-gem
        // sparkle as the next target because it depends only on weapon state -- which this adapter
        // already syncs correctly -- with no wall-geometry or collision dependency, and the ghost's
        // collision is deliberately disabled.
        //
        // Signature confirmed by a live param dump, not assumed: every reflected property is an
        // internal Blueprint temporary (CallFunc_IsValid_ReturnValue x3, CallFunc_BooleanAND_...,
        // CallFunc_Not_PreBool_..., CallFunc_SpawnSystemAttached_ReturnValue,
        // CallFunc_SpawnSoundAttached_ReturnValue) -- no real caller-facing parameters, so a
        // zero-filled buffer sized to its own PropertiesSize is correct, same as
        // call_spawn_num_afterimages. Those internals also confirm what it does: spawns a Niagara
        // system plus a sound, guarded by its own IsValid checks -- so it's idempotent by design
        // and safe to call without tracking whether the glow already exists.
        auto call_manage_recall_idle_fx(UObject* pawn) -> void
        {
            if (!pawn)
            {
                return;
            }
            UFunction* function = pawn->GetFunctionByNameInChain(STR("manageRecallIdleFX"));
            if (!function)
            {
                return;
            }
            int32_t parms_size = function->GetPropertiesSize();
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size > 0 ? parms_size : 0), 0);
            pawn->ProcessEvent(function, params_buffer.data());
        }

        // Outfit T-pose fix, 2026-08-15: a raw direct write to VisualMesh's SkeletalMesh/
        // SkinnedAsset properties sticks (readback confirmed) but leaves the ghost in a T-pose --
        // the mesh reference changes without the engine re-binding/re-initializing the anim
        // instance against it. 'SetSkeletalMeshAsset' is the one real candidate this build's
        // reflection actually exposes on SkeletalMeshComponent (confirmed via a live function-name
        // dump, DUMP_VISUALMESH_FUNCTIONS -- no SetSkeletalMesh/InitAnim/MarkRenderStateDirty/
        // RecreateRenderState exist on this build), PropertiesSize=8 matching exactly one pointer
        // parameter. Its real parameter name was never confirmed by name (unlike
        // updateWeaponEquip/changeEquippedWeapon above) -- a PropertiesSize of exactly 8 with a
        // single property found via TFieldRange is itself the grounding: there is nowhere else for
        // an 8-byte pointer to go, so writing to "the one property this function has" is not a
        // guess about which of several params to use, just that pointer's real reflected offset.
        auto call_set_skeletal_mesh_asset(UObject* mesh_component, UObject* new_mesh) -> void
        {
            if (!mesh_component || !new_mesh)
            {
                return;
            }
            UFunction* function = mesh_component->GetFunctionByNameInChain(STR("SetSkeletalMeshAsset"));
            if (!function)
            {
                return;
            }
            int32_t parms_size = function->GetPropertiesSize();
            if (parms_size < 8)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: SetSkeletalMeshAsset has an implausibly small PropertiesSize ({}) -- refusing to call it.\n"),
                             parms_size);
                return;
            }
            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            bool found_param = false;
            for (FProperty* property : TFieldRange<FProperty>(function, EFieldIterationFlags::None))
            {
                if (property)
                {
                    *std::bit_cast<UObject**>(params_buffer.data() + property->GetOffset_Internal()) = new_mesh;
                    found_param = true;
                    break; // exactly one property expected -- see this function's own comment
                }
            }
            if (!found_param)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: SetSkeletalMeshAsset has no reflected parameter -- refusing to call it.\n"));
                return;
            }
            mesh_component->ProcessEvent(function, params_buffer.data());
        }

        // Facing-direction root cause, found 2026-08-13: the vendored RE-UE4SS SDK's own
        // K2_SetActorLocationAndRotation/K2_SetActorRotation (RE-UE4SS/deps/first/Unreal/src/
        // AActor.cpp) marshal FRotator's Pitch/Yaw/Roll as hardcoded `float` into the reflected
        // parameter buffer, unlike FVector's X/Y/Z, which correctly branch on engine version via
        // UE_COPY_VECTOR (BPMacros.hpp). Pseudoregalia is UE 5.1, where the real FRotator fields
        // are `double` -- so every rotation write above put 4 bytes of float into an 8-byte slot
        // of a zeroed buffer, leaving the upper 4 bytes zero. The engine then read back a denormal
        // near zero (confirmed: 90.0f's bit pattern in a zeroed double slot is exactly
        // 5.529052754e-315, matching the ~5.5e-315 "garbage" logged during the investigation) --
        // this is why position (written in the very same call) always stuck while rotation never
        // did, and why a forced 0/90/180/270 yaw cycle produced no visible change: every value
        // became ~0.
        //
        // Fix: a local, version-aware replacement for just this one function, following the same
        // "don't guess a struct layout, read real FProperty offsets" pattern as
        // call_set_collision_response_to_channel above. This can't be fixed by patching the SDK
        // itself -- RE-UE4SS is a git submodule, so this repo tracks only its pinned commit, never
        // its file contents; an edit to BPMacros.hpp would be invisible to anyone cloning this
        // repo and wiped by any `git submodule update`. See agent_docs/pitfalls.md.
        //
        // NOTE: this only covers K2_SetActorLocationAndRotation, the one rotation-writing function
        // this file actually calls. The same float/double bug affects K2_SetActorRotation and
        // presumably every other native FRotator-taking function in this SDK -- do not assume any
        // of those are safe to call directly; route any future rotation write through a helper
        // like this one instead.
        auto call_set_actor_location_and_rotation(AActor* actor, const FVector& new_location, const FRotator& new_rotation) -> void
        {
            if (!actor)
            {
                return;
            }

            static UFunction* function = UObjectGlobals::StaticFindObject<UFunction*>(
                nullptr, nullptr, STR("/Script/Engine.Actor:K2_SetActorLocationAndRotation"));
            if (!function)
            {
                // Cached null is permanent for the process lifetime by
                // design (a core Engine UFunction either exists once the
                // game is running or it never will, so retrying every call
                // buys nothing but cost) -- but the warning itself was not
                // throttled the same way, so every single caller (once per
                // ghost per tick) printed it forever. Found in a review
                // pass; gated the same way the layout-diagnostic message
                // below already is.
                static bool logged_warning_once = false;
                if (!logged_warning_once)
                {
                    Output::send(STR("[MeshGhostPseudo] WARNING: could not find K2_SetActorLocationAndRotation -- ghost rotation will not be set.\n"));
                    logged_warning_once = true;
                }
                return;
            }

            FProperty* location_property = function->FindProperty(FName(STR("NewLocation"), FNAME_Find));
            FProperty* rotation_property = function->FindProperty(FName(STR("NewRotation"), FNAME_Find));
            FProperty* sweep_property = function->FindProperty(FName(STR("bSweep"), FNAME_Find));
            FProperty* teleport_property = function->FindProperty(FName(STR("bTeleport"), FNAME_Find));
            if (!location_property || !rotation_property || !sweep_property || !teleport_property)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: K2_SetActorLocationAndRotation is missing an expected top-level parameter -- refusing to call it.\n"));
                return;
            }

            UScriptStruct* location_struct = static_cast<FStructProperty*>(location_property)->GetStruct();
            UScriptStruct* rotation_struct = static_cast<FStructProperty*>(rotation_property)->GetStruct();
            FProperty* x_property = location_struct ? location_struct->FindProperty(FName(STR("X"), FNAME_Find)) : nullptr;
            FProperty* y_property = location_struct ? location_struct->FindProperty(FName(STR("Y"), FNAME_Find)) : nullptr;
            FProperty* z_property = location_struct ? location_struct->FindProperty(FName(STR("Z"), FNAME_Find)) : nullptr;
            FProperty* pitch_property = rotation_struct ? rotation_struct->FindProperty(FName(STR("Pitch"), FNAME_Find)) : nullptr;
            FProperty* yaw_property = rotation_struct ? rotation_struct->FindProperty(FName(STR("Yaw"), FNAME_Find)) : nullptr;
            FProperty* roll_property = rotation_struct ? rotation_struct->FindProperty(FName(STR("Roll"), FNAME_Find)) : nullptr;
            if (!x_property || !y_property || !z_property || !pitch_property || !yaw_property || !roll_property)
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: K2_SetActorLocationAndRotation's NewLocation/NewRotation struct is missing an expected inner field -- refusing to call it.\n"));
                return;
            }

            int32_t parms_size = function->GetPropertiesSize();
            if (parms_size < static_cast<int32_t>(location_property->GetOffset_Internal() + location_property->GetSize())
                || parms_size < static_cast<int32_t>(rotation_property->GetOffset_Internal() + rotation_property->GetSize()))
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: K2_SetActorLocationAndRotation has an implausibly small PropertiesSize ({}) -- refusing to call it.\n"), parms_size);
                return;
            }

            std::vector<uint8_t> params_buffer(static_cast<size_t>(parms_size), 0);
            uint8_t* base = params_buffer.data();
            int32_t loc_base = location_property->GetOffset_Internal();
            int32_t rot_base = rotation_property->GetOffset_Internal();

            // Mirrors UE_COPY_VECTOR (BPMacros.hpp): double on UE 5.0+, float below -- this is the
            // branch the rotation path was missing.
            static const bool use_float = Version::IsBelow(5, 0);
            static bool logged_once = false;
            if (!logged_once)
            {
                Output::send(STR("[MeshGhostPseudo] call_set_actor_location_and_rotation: NewLocation@{} NewRotation@{} inner_type={} parms_size={}\n"),
                             loc_base, rot_base, use_float ? STR("float") : STR("double"), parms_size);
                logged_once = true;
            }

            if (use_float)
            {
                *std::bit_cast<float*>(base + loc_base + x_property->GetOffset_Internal()) = static_cast<float>(new_location.X());
                *std::bit_cast<float*>(base + loc_base + y_property->GetOffset_Internal()) = static_cast<float>(new_location.Y());
                *std::bit_cast<float*>(base + loc_base + z_property->GetOffset_Internal()) = static_cast<float>(new_location.Z());
                *std::bit_cast<float*>(base + rot_base + pitch_property->GetOffset_Internal()) = static_cast<float>(new_rotation.GetPitch());
                *std::bit_cast<float*>(base + rot_base + yaw_property->GetOffset_Internal()) = static_cast<float>(new_rotation.GetYaw());
                *std::bit_cast<float*>(base + rot_base + roll_property->GetOffset_Internal()) = static_cast<float>(new_rotation.GetRoll());
            }
            else
            {
                *std::bit_cast<double*>(base + loc_base + x_property->GetOffset_Internal()) = new_location.X();
                *std::bit_cast<double*>(base + loc_base + y_property->GetOffset_Internal()) = new_location.Y();
                *std::bit_cast<double*>(base + loc_base + z_property->GetOffset_Internal()) = new_location.Z();
                *std::bit_cast<double*>(base + rot_base + pitch_property->GetOffset_Internal()) = new_rotation.GetPitch();
                *std::bit_cast<double*>(base + rot_base + yaw_property->GetOffset_Internal()) = new_rotation.GetYaw();
                *std::bit_cast<double*>(base + rot_base + roll_property->GetOffset_Internal()) = new_rotation.GetRoll();
            }

            *std::bit_cast<bool*>(base + sweep_property->GetOffset_Internal()) = false;
            *std::bit_cast<bool*>(base + teleport_property->GetOffset_Internal()) = true;

            actor->ProcessEvent(function, params_buffer.data());
        }
    } // namespace

    Plugin::Plugin() : CppUserModBase()
    {
        ModName = STR("MeshGhostPseudo");
        ModVersion = STR("0.5.0");
        ModDescription = STR("MeshGhost adapter for Pseudoregalia (Phase 7.6, spawn-based ghosts on the game thread)");
        ModAuthors = STR("MeshGhost");
    }

    // Unregisters every detour this mod installed, found missing in a review pass: the
    // GlobalCallbackId/CallbackId each Register*/RegisterPreHook call below returns was
    // previously discarded, so on mod unload/reload every one of these detours stayed active,
    // pointing at this (about-to-be-freed) Plugin instance -- a real dangling-callback hazard,
    // even though normal single-session play never unloads the mod and so never exercised it.
    // Hook::ERROR_ID (0) / -1 mean "never actually registered" (e.g. svtwb_function was never
    // found), guarded the same way the registration sites themselves guard a failed lookup.
    Plugin::~Plugin()
    {
        if (load_map_pre_callback_id != Hook::ERROR_ID)
        {
            Hook::UnregisterCallback(load_map_pre_callback_id);
        }
        if (engine_tick_post_callback_id != Hook::ERROR_ID)
        {
            Hook::UnregisterCallback(engine_tick_post_callback_id);
        }
        if (svtwb_function && svtwb_hook_id != -1)
        {
            svtwb_function->UnregisterHook(svtwb_hook_id);
        }
    }

    // Kept from the "Fatal world leaks detected" investigation: dumps every remote's ghost
    // pointer/world whenever called, useful for the LoadMap hook below and for any future
    // diagnostics. See agent_docs/phases/phase7.md's 7.5-in-C++ entries and the plan at
    // lowlevelfatalerror-file-d-build-ue5-sync-zazzy-star.md for the full investigation history.
    auto Plugin::log_remote_state(const wchar_t* context) -> void
    {
        Output::send(STR("[MeshGhostPseudo] remote state dump ({}): {} remote(s)\n"), context, remotes.size());
        for (auto& [id, remote] : remotes)
        {
            Output::send(STR("[MeshGhostPseudo]   remote {}: ghost={} owning_world={}\n"),
                         to_wide_ascii(id),
                         static_cast<void*>(remote.ghost),
                         static_cast<void*>(remote.owning_world));
        }
    }

    // Renders one remote peer's thrown Dream Breaker. See RemoteGhost::weapon_actor for the
    // measured lifecycle behind the three states this switches between, and verified.md's
    // thrown-Dream-Breaker entry for the capture that established them.
    //
    // Reuses, rather than reinvents, every mechanism the ghost pawn already proved on this game:
    // SpawnActor into the local player's own world, call_set_actor_location_and_rotation to move
    // it (which is where the FRotator float/double marshaling fix lives -- a hand-rolled move call
    // here would silently reintroduce that bug), actor_is_alive for staleness, and parking at
    // DESPAWN_PARK_Z instead of destroying.
    auto Plugin::tick_remote_weapon(const std::string& player_id, RemoteGhost& remote, UWorld* current_world) -> void
    {
        // Staleness, both checks the ghost pawn gets and for the same reasons: a level transition
        // destroys spawned actors out from under us, and a peer/local area change leaves this
        // pointing into a torn-down world. Cleared rather than reused -- the next thrown sample
        // spawns a fresh prop in whatever world is current.
        if (remote.weapon_actor)
        {
            const bool dead = !actor_is_alive(remote.weapon_actor);
            const bool wrong_world = current_world && remote.weapon_actor_world && remote.weapon_actor_world != current_world;
            if (dead || wrong_world)
            {
                // The glow component is attached to the prop and dies with it -- only the reference

                // needs clearing, so the next throw's fresh prop spawns its own.

                remote.weapon_glow_component = nullptr;
                remote.weapon_actor = nullptr;
                remote.weapon_actor_world = nullptr;
                remote.weapon_render_primed = false;
                // A replacement prop is a fresh actor in its own default state, so the peer's
                // current weaponState has to be applied to it again from scratch.
                remote.last_synced_weapon_state = -1.0;
            }
        }

        // Sword back in the peer's hand. The held sword is already handled by the existing
        // weaponEquipped?/animEquippedWeapon mirror on the ghost's own body, so all this has to do
        // is get rid of the loose prop.
        //
        // DESTROYED rather than parked and reused, changed 2026-08-15 after the first live test of
        // the resting pose: the prop landed upright correctly, but sank visibly further into the
        // floor on each successive throw. One prop was being reused for every throw while
        // `Change Weapon State` was called on it again each time, so whatever the embed step
        // adjusts accumulated instead of starting clean. The game itself spawns a fresh
        // BP_looseWeapon_C per throw (three throws produced three distinct instances in the
        // WEAPONACTOR capture) -- matching that is both the fix and the more faithful mirror, and
        // it avoids having to find and reset every piece of state the embed touches.
        if (!remote.target_weapon_thrown)
        {
            if (remote.weapon_actor)
            {
                if (!call_destroy_actor(remote.weapon_actor))
                {
                    // Fallback only: park it out of the playable area so a failed destroy can never
                    // leave a sword hanging in the level.
                    FVector park_loc(remote.target_weapon_x, remote.target_weapon_y, DESPAWN_PARK_Z);
                    call_set_actor_location_and_rotation(remote.weapon_actor, park_loc, FRotator(0.0, 0.0, 0.0));
                }
                if constexpr (WEAPON_PROP_TRACE)
                {
                    Output::send(STR("[MeshGhostPseudo] WEAPONPROP {}: sword back in hand -- prop released (actor={})\n"),
                                 to_wide_ascii(player_id), static_cast<void*>(remote.weapon_actor));
                }
                // The glow component is attached to the prop and dies with it -- only the reference

                // needs clearing, so the next throw's fresh prop spawns its own.

                remote.weapon_glow_component = nullptr;
                remote.weapon_actor = nullptr;
                remote.weapon_actor_world = nullptr;
                remote.weapon_render_primed = false;
                remote.last_synced_weapon_state = -1.0;
            }
            return;
        }

        if (!remote.weapon_actor)
        {
            if (remote.target_weapon_class.empty() || !current_world)
            {
                return;
            }
            // Retry throttle, same shape and reason as the outfit mirror's: a peer whose weapon
            // class doesn't resolve on this machine must not re-attempt and re-log every tick. A
            // genuinely different class still gets tried immediately.
            if (remote.target_weapon_class == remote.last_failed_weapon_class &&
                tick_count - remote.last_weapon_spawn_attempt_tick < LOG_INTERVAL_TICKS)
            {
                return;
            }
            remote.last_weapon_spawn_attempt_tick = tick_count;

            UClass* weapon_class = UObjectGlobals::StaticFindObject<UClass*>(
                nullptr, nullptr, to_wide_ascii(remote.target_weapon_class).c_str());
            if (!weapon_class)
            {
                remote.last_failed_weapon_class = remote.target_weapon_class;
                Output::send(STR("[MeshGhostPseudo] WARNING: weapon class '{}' not found via StaticFindObject -- remote {}'s thrown sword not rendered (will retry periodically).\n"),
                             to_wide_ascii(remote.target_weapon_class), to_wide_ascii(player_id));
                return;
            }
            remote.last_failed_weapon_class.clear();

            FVector spawn_loc(remote.target_weapon_x, remote.target_weapon_y, remote.target_weapon_z);
            FRotator spawn_rot(remote.target_weapon_pitch, remote.target_weapon_yaw, remote.target_weapon_roll);
            AActor* prop = current_world->SpawnActor(weapon_class, &spawn_loc, &spawn_rot);
            if (!prop)
            {
                Output::send(STR("[MeshGhostPseudo] SpawnActor returned nullptr for remote {}'s thrown weapon.\n"),
                             to_wide_ascii(player_id));
                return;
            }

            // **Required, not a precaution.** The real BP_looseWeapon_C carries a `PlayerPickup`
            // BoxComponent (confirmed in its own property dump, verified.md) -- a collidable copy
            // would let the local player walk into a peer's phantom sword and actually pick it up,
            // which is a game-state effect and outside this project's visual-only posture. Unlike
            // the ghost pawn, whose collision is deliberately ON as a feature
            // (GHOST_COLLISION_ENABLED), there is no version of this prop that should ever be
            // touchable.
            prop->SetActorEnableCollision(false);

            // Stop the prop simulating. We drive this actor's transform entirely from the peer's
            // samples, so any physics it runs of its own is only ever something to fight -- and the
            // sinking-while-embedded bug is what that fight looks like on screen. Applied to both
            // the root Box and the SkeletalMesh, because the measurement could not say which of
            // them carries the simulating bodies and each is cheap to call.
            // The measured cause of the sinking -- see stop_projectile_movement's own comment for
            // the numbers. Kept ahead of the physics calls below because it is the one with
            // evidence behind it; those two remain because a prop we drive entirely by teleport
            // should not be simulating either way, not because they ever fixed anything.
            stop_projectile_movement(prop);

            if (UObject** root_ptr = prop->GetValuePtrByPropertyNameInChain<UObject*>(STR("RootComponent")); root_ptr && *root_ptr)
            {
                call_set_simulate_physics(*root_ptr, false, STR("prop RootComponent"));
            }
            if (UObject** mesh_ptr = prop->GetValuePtrByPropertyNameInChain<UObject*>(STR("SkeletalMesh")); mesh_ptr && *mesh_ptr)
            {
                call_set_simulate_physics(*mesh_ptr, false, STR("prop SkeletalMesh"));
                if constexpr (WEAPON_PROP_TRACE)
                {
                    // One-shot, first prop only: names the real physics/visibility API this build's
                    // SkeletalMeshComponent exposes. Cited evidence for whichever call ends up
                    // fixing this, and the fallback if SetSimulatePhysics above turns out not to
                    // exist or not to be the lever -- so a failed attempt still leaves us with the
                    // answer instead of another guess.
                    static bool dumped = false;
                    if (!dumped)
                    {
                        dumped = true;
                        dump_object_reflection(*mesh_ptr, STR("prop SkeletalMesh component"));
                    }
                }
            }

            remote.weapon_actor = prop;
            remote.weapon_actor_world = current_world;
            remote.weapon_render_primed = false;
            Output::send(STR("[MeshGhostPseudo] spawned thrown-weapon prop for remote {}: class='{}' actor={}\n"),
                         to_wide_ascii(player_id), to_wide_ascii(remote.target_weapon_class),
                         static_cast<void*>(prop));

            if constexpr (WEAPON_PROP_TRACE)
            {
                // One-shot, because Mobility doesn't change after construction. This is the single
                // specific reason a UE actor silently refuses every SetActorLocation call while
                // reporting no error: a root component whose Mobility is Static (0) rather than
                // Movable (2). The ghost PAWN's root is a CapsuleComponent and is Movable, which is
                // why the identical move call has always worked there -- so this prop's root being
                // a BoxComponent is a real difference between the two cases, not a stretch.
                // Logged rather than "fixed" on the spot: writing Mobility blind would be guessing
                // at the cause, and if it reads Movable here the fix lies somewhere else entirely.
                if (UObject** root_ptr = prop->GetValuePtrByPropertyNameInChain<UObject*>(STR("RootComponent")); root_ptr && *root_ptr)
                {
                    uint8_t* mobility_ptr = (*root_ptr)->GetValuePtrByPropertyNameInChain<uint8_t>(STR("Mobility"));
                    Output::send(STR("[MeshGhostPseudo] WEAPONPROP {}: root='{}' Mobility={} (0=Static, 1=Stationary, 2=Movable)\n"),
                                 to_wide_ascii(player_id),
                                 (*root_ptr)->GetFullName(),
                                 mobility_ptr ? static_cast<int>(*mobility_ptr) : -1);
                }
            }
        }

        // Smoothing. Position only -- rotation is written straight through deliberately: the
        // measured throw tumbles in discrete 30-degree steps rather than sweeping continuously, so
        // there is no smooth curve to reconstruct, and easing an angle invites wrap-around
        // artifacts at the +/-180 boundary for no visual gain.
        const double dx = remote.target_weapon_x - remote.render_weapon_x;
        const double dy = remote.target_weapon_y - remote.render_weapon_y;
        const double dz = remote.target_weapon_z - remote.render_weapon_z;
        const bool snap = !remote.weapon_render_primed ||
                          std::sqrt(dx * dx + dy * dy + dz * dz) > WEAPON_SNAP_DISTANCE;
        if (snap)
        {
            remote.render_weapon_x = remote.target_weapon_x;
            remote.render_weapon_y = remote.target_weapon_y;
            remote.render_weapon_z = remote.target_weapon_z;
            remote.weapon_render_primed = true;
        }
        else
        {
            remote.render_weapon_x += dx * WEAPON_SMOOTHING_ALPHA;
            remote.render_weapon_y += dy * WEAPON_SMOOTHING_ALPHA;
            remote.render_weapon_z += dz * WEAPON_SMOOTHING_ALPHA;
        }

        // Resting pose. The prop never lands on anything -- collision is off and it is teleported,
        // not simulated -- so the 0 -> 3 transition the real sword performs on impact has to be
        // driven from here instead.
        //
        // Function call FIRST, raw property write second, and that order is load-bearing: the
        // Dream Breaker visibility bug was exactly this code shape with the two reversed, where
        // writing the property up front meant the game's own transition function saw no change
        // left to act on and did nothing (PLAYER_FIELDS.md's worked example). The write is kept
        // afterwards only as a safety net for the case where the call is a no-op.
        if (remote.target_weapon_state != remote.last_synced_weapon_state)
        {
            remote.last_synced_weapon_state = remote.target_weapon_state;
            const auto new_state = static_cast<uint8_t>(remote.target_weapon_state);
            call_change_weapon_state(remote.weapon_actor, new_state);
            if (uint8_t* state_ptr = remote.weapon_actor->GetValuePtrByPropertyNameInChain<uint8_t>(STR("weaponState")))
            {
                *state_ptr = new_state;
            }
            if constexpr (WEAPON_PROP_TRACE)
            {
                // Independent readback, per CLAUDE.md: report what the actor says its state is
                // now, not the value just written into it.
                uint8_t* readback_ptr = remote.weapon_actor->GetValuePtrByPropertyNameInChain<uint8_t>(STR("weaponState"));
                // The glow half, measured on the real sword: idleGlowVFX goes null -> non-null on
                // exactly this 0 -> 3 edge, every throw. So the question here is narrow and this
                // readback answers it outright -- if our prop's idleGlowVFX is non-null too, the
                // state call already spawns the component and the glow is failing for some later
                // reason; if it stays null, the spawn lives in the landing path the real sword runs
                // on impact and calling the state setter alone was never going to reach it.
                UObject** glow_ptr = remote.weapon_actor->GetValuePtrByPropertyNameInChain<UObject*>(STR("idleGlowVFX"));
                Output::send(STR("[MeshGhostPseudo] WEAPONPROP {}: weaponState -> {} (readback={}) idleGlowVFX={}\n"),
                             to_wide_ascii(player_id), static_cast<int>(new_state),
                             readback_ptr ? static_cast<int>(*readback_ptr) : -1,
                             (glow_ptr && *glow_ptr) ? STR("non-null") : STR("null"));
            }

            // The landed sword's glow ring. Spawned on the landing edge only, and only once per
            // prop -- the prop is destroyed and rebuilt per throw, so there is no stale component
            // to clean up here and no way for these to accumulate across throws.
            if (new_state == LANDED_WEAPON_STATE && !remote.weapon_glow_component && !remote.target_weapon_glow.empty())
            {
                UObject* glow_asset = UObjectGlobals::StaticFindObject<UObject*>(
                    nullptr, nullptr, to_wide_ascii(remote.target_weapon_glow).c_str());
                if (!glow_asset)
                {
                    Output::send(STR("[MeshGhostPseudo] WARNING: glow system '{}' not found via StaticFindObject -- ghost {}'s landed sword will have no glow.\n"),
                                 to_wide_ascii(remote.target_weapon_glow), to_wide_ascii(player_id));
                }
                else if (UObject** root_ptr = remote.weapon_actor->GetValuePtrByPropertyNameInChain<UObject*>(STR("RootComponent")); root_ptr && *root_ptr)
                {
                    remote.weapon_glow_component = spawn_niagara_attached(glow_asset, *root_ptr);
                    Output::send(STR("[MeshGhostPseudo] WEAPONPROP {}: glow spawn '{}' -> {}\n"),
                                 to_wide_ascii(player_id), to_wide_ascii(remote.target_weapon_glow),
                                 remote.weapon_glow_component ? STR("component returned") : STR("NULL"));
                }
            }
        }

        // Drift detection -- the isolation step for "still sinking after two fixes". Read BEFORE
        // this frame's write and compared against what we wrote last frame, which is the one
        // question the previous diagnostic structurally could not answer (see
        // RemoteGhost::last_written_weapon_x). Exactly two outcomes, and they point opposite ways:
        //
        //   * PRE differs from what we wrote -> something moves the actor between our writes, and
        //     our own write papers over it every frame while the render still catches the drift.
        //     The delta's size and sign then say what: a steady small drop is gravity.
        //   * PRE matches what we wrote -> the actor transform genuinely never moves, and the
        //     sinking is purely visual -- bone/animation driven, below the level of any transform
        //     property, which means no amount of position syncing will ever address it.
        if constexpr (WEAPON_PROP_TRACE)
        {
            if (remote.weapon_write_recorded && tick_count % WEAPON_PROP_TRACE_INTERVAL_TICKS == 0)
            {
                FVector pre = remote.weapon_actor->K2_GetActorLocation();
                const double drift_x = pre.X() - remote.last_written_weapon_x;
                const double drift_y = pre.Y() - remote.last_written_weapon_y;
                const double drift_z = pre.Z() - remote.last_written_weapon_z;
                Output::send(STR("[MeshGhostPseudo] WEAPONPROP {}: PRE=({:.2f}, {:.2f}, {:.2f}) lastWrote=({:.2f}, {:.2f}, {:.2f}) drift=({:.3f}, {:.3f}, {:.3f})\n"),
                             to_wide_ascii(player_id),
                             pre.X(), pre.Y(), pre.Z(),
                             remote.last_written_weapon_x, remote.last_written_weapon_y, remote.last_written_weapon_z,
                             drift_x, drift_y, drift_z);
            }
        }

        FVector render_loc(remote.render_weapon_x, remote.render_weapon_y, remote.render_weapon_z);
        FRotator render_rot(remote.target_weapon_pitch, remote.target_weapon_yaw, remote.target_weapon_roll);
        call_set_actor_location_and_rotation(remote.weapon_actor, render_loc, render_rot);
        remote.last_written_weapon_x = remote.render_weapon_x;
        remote.last_written_weapon_y = remote.render_weapon_y;
        remote.last_written_weapon_z = remote.render_weapon_z;
        remote.weapon_write_recorded = true;

        if constexpr (WEAPON_PROP_TRACE)
        {
            // Sampled rather than per-tick: at ~150Hz a per-tick line would bury the very
            // comparison it exists to make. The four columns are read AFTER the write above, so
            // READBACK reflects whatever the engine actually let happen to the actor.
            if (tick_count % WEAPON_PROP_TRACE_INTERVAL_TICKS == 0)
            {
                FVector readback = remote.weapon_actor->K2_GetActorLocation();
                bool* embedded_ptr = remote.weapon_actor->GetValuePtrByPropertyNameInChain<bool>(STR("isEmbedded?"));
                uint8_t* weapon_state_ptr = remote.weapon_actor->GetValuePtrByPropertyNameInChain<uint8_t>(STR("weaponState"));

                // The prop's own mesh offset, added 2026-08-15 for the "sinks downwards while
                // embedded" report. That symptom splits cleanly in two and these two columns
                // decide it outright, with no third possibility:
                //   * READBACK z falling  -> the ACTOR is being driven down. Our own position write
                //     runs every frame and would normally win, so that would mean something moves
                //     it after us -- most likely its still-live ProjectileMovementComponent
                //     continuing to fall, since collision is off and it can never land on anything.
                //   * READBACK z steady but MESH z falling -> the drift is INSIDE the actor and our
                //     actor-level writes can never correct it, because they don't touch it. The
                //     likely driver then is the embed/landing logic (the class has a real
                //     `checkForValidLandingPoint`) tracing for ground it can never find, again
                //     because collision is off.
                // Both roads lead back to collision being disabled -- which is non-negotiable for
                // the PlayerPickup reason -- so the fix differs per branch and neither is worth
                // guessing at.
                double mesh_x = -99999.0, mesh_y = -99999.0, mesh_z = -99999.0;
                if (UObject** mesh_ptr = remote.weapon_actor->GetValuePtrByPropertyNameInChain<UObject*>(STR("SkeletalMesh")); mesh_ptr && *mesh_ptr)
                {
                    if (FVector* rel_loc = (*mesh_ptr)->GetValuePtrByPropertyNameInChain<FVector>(STR("RelativeLocation")))
                    {
                        mesh_x = rel_loc->X();
                        mesh_y = rel_loc->Y();
                        mesh_z = rel_loc->Z();
                    }
                }

                Output::send(STR("[MeshGhostPseudo] WEAPONPROP {}: TARGET=({:.1f}, {:.1f}, {:.1f}) RENDER=({:.1f}, {:.1f}, {:.1f}) READBACK=({:.1f}, {:.1f}, {:.1f}) MESH=({:.2f}, {:.2f}, {:.2f}) isEmbedded={} weaponState={}\n"),
                             to_wide_ascii(player_id),
                             remote.target_weapon_x, remote.target_weapon_y, remote.target_weapon_z,
                             remote.render_weapon_x, remote.render_weapon_y, remote.render_weapon_z,
                             readback.X(), readback.Y(), readback.Z(),
                             mesh_x, mesh_y, mesh_z,
                             embedded_ptr ? *embedded_ptr : false,
                             weapon_state_ptr ? static_cast<int>(*weapon_state_ptr) : -1);
            }
        }
    }

    // Shows a ghost's empty-hand recall glow. See RemoteGhost::recall_glow_component for why this
    // spawns the effect directly instead of calling the game's own `manageRecallIdleFX`.
    //
    // The asset is a constant here, unlike the landed sword's ring which reads its path off the
    // peer. That is not a shortcut around the "nothing from memory" rule -- the path came from a
    // live catalog enumeration recorded in `UE4SS.log`, and the user identified this specific
    // entry on screen as the empty-hand glow. It is a constant because there is nothing to read it
    // from: the real player's copy is spawned into the world rather than parented to the pawn, so
    // the pawn exposes no property pointing at it (the first VFX_WATCH run found exactly one
    // component on the pawn across a whole session, which is what established that).
    constexpr const wchar_t* RECALL_GLOW_ASSET = STR("/Game/VFX/Emitters/NS_WeaponCallReady.NS_WeaponCallReady");

    // Capture for "throwing the sword BEFORE the ghost spawns leaves things weird", reported
    // 2026-08-16. Every weapon test so far has thrown with a ghost already standing there, so the
    // spawn-mid-throw ordering has genuinely never been exercised.
    //
    // Leading suspect, and it is not a guess -- it is the same mechanism proven hours earlier by
    // the self-constructed recall glow: a ghost is a clone of the player's class reading the
    // player's save, so it builds itself with whatever save-dependent state that implies. If the
    // save says the sword is thrown, the ghost's construction may spawn its OWN loose-weapon actor,
    // which this adapter neither tracks nor destroys. That would leave an extra sword in the world
    // belonging to nobody, on top of the one we spawn deliberately.
    //
    // So the capture is aimed at exactly that: at ghost spawn, and again shortly after (once the
    // construction has had time to run and the first real state has arrived), it logs
    //   * what this adapter believes about the peer's weapon (thrown / state / equipped / class),
    //   * the ghost's own weapon fields, which say what its construction decided independently,
    //   * and EVERY live BP_looseWeapon_C in the world with its location and Instigator.
    // The last one is the decisive column: if the count is higher than the number of swords this
    // adapter spawned, the extra one was constructed by the ghost and the fix is a sweep, exactly
    // like the glow's. If the count is right, the bug is in our own spawn/state handling instead
    // and the first two columns say which field disagrees.
    // Off 2026-08-16, investigation CLOSED with a negative result -- worth stating plainly, since a
    // negative is easy to mistake for "nobody checked". Throwing before a ghost spawns behaves
    // correctly: the census showed exactly two loose weapons (the real one and ours, no third), the
    // prop tracked the arc and landed at the peer's own Y/Z, and the equip state settled by the
    // follow-up sample. The apparent weirdness was the ghost mirroring the LOCAL player's state at
    // construction, which is expected in loopback where the peer is the local player.
    //
    // Reading this path for the capture did surface a real defect independently: the "already
    // synced" latches were never re-armed when a ghost was replaced, so a fresh ghost could keep
    // its construction state forever. Fixed -- see release_all_ghosts. That one is invisible in
    // loopback and only misbehaves against a real peer, which is why it needed finding by reading
    // rather than by watching.
    constexpr bool GHOST_SPAWN_WEAPON_TRACE = false;

    // Ticks after a ghost spawns before the follow-up sample. ~1s at this build's measured ~150Hz:
    // long enough for construction and a first state packet, short enough to still be "at spawn".
    constexpr uint64_t GHOST_SPAWN_WEAPON_TRACE_DELAY_TICKS = 150;

    // The ultra hop's BLUE trail, resumed 2026-08-16 -- but NOT by guessing more property names,
    // which `status.md` explicitly parks this on. The record there is a list of negatives:
    // `afterimageColor` provably never changes during a real ultra, and `ultraCap`,
    // `fullUltraModifier`, `cappedUltraModifier` and `animJumpType` were all cleared too. The note
    // ends "not derivable from polled state", and that conclusion still stands -- so this does not
    // poll anything.
    //
    // What changed is that two things are now known that were not when it was parked:
    //   1. Effects in this game can be identified by enumeration rather than inference (the whole
    //      VFX catalog/watcher approach that found NS_WeaponCallReady).
    //   2. The trail is almost certainly NOT a particle system. The catalog holds 58 game Niagara
    //      systems and not one is an afterimage -- so a colour property on a particle effect was
    //      never going to be the answer, which retrospectively explains why every colour guess
    //      failed.
    //
    // The remaining leverage is that this adapter can already SPAWN an afterimage on demand, via
    // the pawn's own `Spawn After Image` (confirmed live -- the trail appears on a ghost). So the
    // mechanism can be studied without landing a perfect ultra: snapshot the world's mesh
    // components and actors, fire one afterimage on the ghost, snapshot again, and print what is
    // new. That names what an afterimage physically IS -- a pooled actor, a mesh component, a
    // material instance -- which is the prerequisite for asking where its colour comes from.
    //
    // Deliberately scoped to identification only. No attempt to explain the blue yet: the blue is a
    // property of a thing nobody has identified, and this file's own history says the guesses go
    // wrong precisely when the underlying object is still unknown.
    // Off 2026-08-16, job done: it identified an afterimage as a BP_AfterImage_C actor carrying a
    // PoseableMeshComponent, which is what made both the observed-spawn trigger and the real colour
    // source possible. **Must stay off while judging the trail**: it fires an afterimage on the
    // ghost every ~3s on its own, which would look exactly like a trail bug.
    constexpr bool AFTERIMAGE_DISCOVERY = false;

    // ~3s between probes at this build's measured ~150Hz, and the "after" snapshot 3 ticks past the
    // call -- long enough for the spawn to exist, short enough that a short-lived afterimage has
    // not faded and been reclaimed before it is seen.
    constexpr uint64_t AFTERIMAGE_DISCOVERY_INTERVAL_TICKS = 450;

    // **Was 3, and 3 was wrong** (2026-08-16). At that delay the probe reported "0 new objects"
    // every time and concluded afterimages were pooled -- the exact opposite of the truth. The
    // give-away was in its own output: the total object count rose by exactly 2 between one probe
    // and the next (1460 -> 1462 -> 1464 ...), so each call was demonstrably creating two objects
    // that simply had not appeared yet 3 ticks in, and then persisted. A negative result from a
    // sampling window that is too narrow looks identical to a real negative, which is worth
    // remembering: the counts, not the diff, are what caught it.
    constexpr uint64_t AFTERIMAGE_DISCOVERY_SAMPLE_DELAY_TICKS = 30;

    // How often the local side reads the colour off its own live afterimages (production, not a
    // diagnostic -- see the block in tickLocal). ~15Hz at this build's measured ~150Hz: below the
    // 20Hz send rate, and an afterimage lives about a second, so a burst cannot be missed. Scoped
    // to the exact class so the enumeration stays small.
    // Tightened 10 -> 3 (2026-08-16, ~50Hz) alongside the batch tie-break below. Both attack the
    // same measured failure from different sides: a scan that catches several new afterimages at
    // once has to choose one colour for them, and the fewer images share a batch, the less often
    // that choice has to be made at all. Still class-scoped, so each scan enumerates only
    // afterimages rather than every actor.
    // **Back to 15 from 3.** A bisect against real commits (not a flag flip) pinned the trail
    // regression to the commit that introduced this scan, and the cost is the mechanism: a
    // FindAllOf over every afterimage, with a GetFullName + UTF-8 conversion and several
    // name-keyed property lookups PER IMAGE, against a pool that grows past 80 -- executed on the
    // game thread. At every 3 ticks (~50Hz) that is a large amount of string work per second.
    //
    // The game spawns its afterimages as a countdown ACROSS ticks, so stalling the game thread
    // truncates bursts still in flight. That produces exactly the reported symptom: intermittently
    // missing images, with every image that does appear perfectly correct in count, colour,
    // position and opacity -- which is why four count-based instruments all reported parity while
    // the trail was visibly wrong. A diagnostic heavy enough to disturb the thing it measures.
    constexpr uint64_t AFTERIMAGE_COLOR_SCAN_INTERVAL_TICKS = 15;

    // How long a non-baseline afterimage colour is held so it cannot be overwritten before the
    // ~20Hz send samples it. At this build's ~150Hz that send interval is ~7-8 ticks, so 15 covers
    // it with margin -- sized against the send rate rather than against how long the effect looks
    // right for, because the whole failure was a sampling race, not a visual duration. Same
    // reasoning as PULSE_HOLD_TICKS for the landed?/jumped? one-shots.
    constexpr uint64_t AFTERIMAGE_COLOR_HOLD_TICKS = 15;

    // How far a pooled afterimage must move to count as re-used rather than still sitting where it
    // was placed. An afterimage is a frozen snapshot and does not move at all once spawned, so this
    // separates "zero" from "somewhere else entirely" and only needs to clear read noise.
    constexpr double AFTERIMAGE_REUSE_MOVE_THRESHOLD = 5.0;

    // **OFF: counting pool re-use as a spawn made the ghost over-fire, and it was never the cause.**
    // It was added on the theory that the ghost's thinner trail came from missed spawns. A world
    // census then measured the opposite: the ghost has produced roughly TWICE as many afterimages
    // as the real player (27 vs 54 attributed at one sample), while still looking thinner. So the
    // shortfall was never about how many are created, and this only added spurious ones.
    //
    // Kept rather than deleted because the underlying finding is real and still useful: these
    // actors ARE pooled and re-used, which is why nothing ever disappears. If a future effect needs
    // re-use counted, this is the mechanism -- it just is not what the trail needed.
    constexpr bool AFTERIMAGE_COUNT_REUSE = false;

    // Drive the ghost's trail from afterimages the game REALLY created, instead of reconstructing
    // when it probably created them. The old trigger keyed on a measured capsule shrink -- the best
    // available at the time, after three wrong actionState guesses -- but it was still our
    // re-derivation of the game's rule, so it could lead or lag the real burst, and it only ever
    // knew about slides. That last part is why an ultra hop produced NO ghost trail at all: an
    // ultra is not a slide, so nothing fired, and the blue had nothing to colour.
    //
    // Possible only now that an afterimage is known to be a BP_AfterImage_C actor, which makes
    // "count the ones the game made" a cheap, exact question. Same principle as the recall glow's
    // presence mirror: copy the decision, never re-implement the rule.
    // **Temporarily FALSE for an A/B test, 2026-08-16** -- user's recollection is that the trail
    // stopped looking right when this trigger was revamped, and that is worth testing directly
    // rather than reasoning about, because the mechanical difference is real: the old path asked
    // the ghost for a BURST of 5-6 images per detection, while this one asks for 1 per detected
    // image. Aggregate counts come out equal either way (measured, 7 vs 7), but the same total
    // delivered one-at-a-time instead of in clumps looks completely different on screen -- and no
    // counter built so far could have shown that, which is exactly why four instruments all
    // reported parity while the user kept seeing a thinner trail.
    //
    // **A/B RESULT (2026-08-16): the trigger revamp is NOT the cause.** Reverting to the old
    // capsule-shrink path did not restore the trail, so it is back on -- it covers ultras, which
    // the old rule never did, and its timing is the game's own.
    //
    // What the A/B did find, which no previous instrument had: the ghost's spawn call
    // UNDER-DELIVERS. The old path requested 25 bursts of 5 (125 images) and produced 49 bodies,
    // about two per burst. Leading explanation, consistent with this file's own note that the
    // game's loop counts `afterImagesToSpawn` DOWN as it spawns: the spawn happens over several
    // ticks, and a re-fire 12 ticks later overwrites the counter mid-countdown, truncating the
    // burst still in progress. The repeats fight each other, which is why more requests did not
    // mean more images -- and why reverting the trigger changed nothing.
    //
    // That makes the next step concrete and NOT another counter: measure how many images one
    // single request actually yields, with no second request anywhere near it, before changing any
    // trigger. See `status.md`.
    // **FALSE — and this time it is a real revert.** The earlier A/B with this flag was worthless:
    // the expensive scan it was supposed to disable ran regardless, because only the counter
    // increment inside it was gated. Now that the scan is gated too, false restores the old
    // capsule-shrink trigger AND removes the per-tick enumeration, which together are everything
    // commit 861e6cd changed about the trail.
    //
    // Keeping it here rather than reverting the commit, because 861e6cd also carries the ultra
    // BLUE work, which is independently confirmed and worth keeping. The intended end state is the
    // old burst-shaped triggering plus the measured colour -- not one or the other.
    constexpr bool AFTERIMAGE_TRIGGER_OBSERVED = false;

    // **Re-enable the ultra hop's BLUE trail, colour only -- deliberately NOT the trigger revamp.**
    // 2026-08-16. The blue was solved and seen working on a ghost, then switched off as collateral:
    // the code that read it rode inside the AFTERIMAGE_TRIGGER_OBSERVED scan above, and that scan is
    // what broke the trail. Both halves went off together even though only one was at fault.
    //
    // This separates them. The trigger stays exactly as it was before the revamp (burst_edge /
    // slide edges, above), and only the COLOUR is observed off the game's real afterimages. That is
    // the end state the flag above already describes as intended: "the old burst-shaped triggering
    // plus the measured colour -- not one or the other."
    //
    // Three things make this cheap enough to leave on, against the version that regressed:
    //   1. It runs ONCE PER BURST, not on a fixed cadence -- zero cost when not trailing, where the
    //      old scan ran every few ticks forever.
    //   2. No strings. Ownership is one pointer compare (see observe_local_afterimage_colors); the
    //      old test built a full object name and UTF-8 string per object per scan.
    //   3. Heavy per-object tracing (TRAIL_COLOR_TRACE) stays off and is not needed by this path.
    // If the trail ever looks sparse again, this flag is a REAL off-switch -- it gates the
    // enumeration itself, not just the decision it feeds. That distinction is the one the earlier
    // A/B got wrong, and it is why a flag flip proved nothing then.
    constexpr bool AFTERIMAGE_OBSERVE_COLOR = true;

    // When to start looking at what the game actually spawned. Not zero: the game counts
    // `afterImagesToSpawn` DOWN over several ticks, so on the tick the burst is DETECTED its images
    // do not exist yet.
    constexpr uint64_t AFTERIMAGE_COLOR_OBSERVE_DELAY_TICKS = 4;

    // **A burst must be observed ACROSS its spawn, not at one instant -- confirmed live 2026-08-16.**
    //
    // The first version scanned once, 4 ticks after the trigger. The user saw the blue appear on the
    // first afterimage of the NEXT slide instead of on the ultra hop itself: exactly one burst late.
    // The mechanism is plain once stated. A burst spawns over many ticks, so a single scan sees only
    // the images that exist at that moment (the log showed new=1 against n=5). Every image that
    // appears AFTER that scan is still unknown when the next burst scans, and a first sighting is
    // indistinguishable from a fresh spawn -- so the ultra's late blue images were counted as new by
    // the following slide's scan and won its tie-break. Nothing was wrong with the detection or the
    // colour; the images were simply attributed to the wrong burst.
    //
    // So the window covers the whole spawn, and the wire event is emitted at its end (or as soon as
    // the burst's full count has been seen, whichever comes first). Sized generously on purpose --
    // the log's `off=`/`new=` pair reports the real drain profile, so this can be tightened from
    // measurement rather than from another guess.
    constexpr uint64_t AFTERIMAGE_COLOR_OBSERVE_WINDOW_TICKS = 20;

    // **The ultra hop fires NO local trigger -- proven live 2026-08-16, and this is why the blue kept
    // landing on the following slide.**
    //
    // The log settled it. Both ultras produced the identical pattern: the blue was found at off=4 --
    // the FIRST scan of a burst -- with FOUR images appearing at once, against new=1 for a genuinely
    // fresh burst. Four-at-once on a first scan is a backlog being discovered, not a burst spawning.
    // The bursts around it were 12 ticks apart, i.e. slide re-fires. So the ultra's afterimages had
    // already been spawned, unseen, and were only picked up by the next slide's first scan, which is
    // precisely when the ghost turned blue.
    //
    // The cause is the gap verified.md already records: some afterimages come from a path that never
    // touches `afterImagesToSpawn`, and the ultra is that path. `burst_edge` therefore never fires,
    // no window opens, and nothing scans during the ultra at all. No window size can fix that.
    // Identifying the ultra by STATE is a closed dead end -- ultraCap, fullUltraModifier,
    // cappedUltraModifier and animJumpType were each ruled out with live captures.
    //
    // So the trigger comes from the same place the colour does: observing what the game really
    // spawned. This scans at a coarse cadence while no burst is pending, and emits a burst only when
    // it finds new images the game coloured DIFFERENTLY from its own baseline. Restricting it to a
    // divergent colour is what keeps it from double-trailing: an ordinary gold straggler is absorbed
    // silently, and the only thing that can fire this is the game deliberately colouring something
    // -- which is the event being mirrored. Same principle as the recall-glow presence mirror, and
    // the reason neither needs to know the game's rule.
    //
    // NOT the old AFTERIMAGE_TRIGGER_OBSERVED, which replaced the slide trigger wholesale and ran an
    // expensive scan unconditionally. This is additive and only fires where the existing trigger
    // found nothing.
    constexpr bool AFTERIMAGE_OBSERVE_SPECIAL_TRIGGER = true;

    // (AFTERIMAGE_REQUIRE_SPAWN_PROXIMITY and AFTERIMAGE_SPAWN_PROXIMITY_UNITS are declared up in
    // the anonymous namespace beside observe_local_afterimage_colors, the only code that uses them.)

    // **Trail the ghost from what the game REALLY spawned, not from our reconstruction of when it
    // probably would have. 2026-08-16.**
    //
    // The user reported the ghost trailing where the real player shows nothing at all -- a slide
    // into a backflip with bad timing is meant to be neutral, and the ghost trailed yellow anyway.
    // The capture had already hinted at why without it being read: EVERY burst logged `n=5`, which
    // is the hardcoded fallback rather than a real `afterImagesToSpawn` value. So `burst_edge` --
    // the one trigger that reads the game's own decision and cannot false-positive -- was never
    // firing for slides at all. Every slide trail came from the capsule-shrink heuristic, which
    // detects "a slide is happening", not "the game decided to trail". Those differ exactly when a
    // move is performed badly, which is precisely the case reported.
    //
    // No fourth heuristic is worth writing. This is the pattern CLAUDE.md and this file's own
    // "the game already knows" entry keep landing on, and every prior attempt here failed the same
    // way: three actionState guesses, then the capsule shrink, each a re-derivation of a rule that
    // was never ours to own. The observation path is now cheap enough to be the trigger itself, and
    // it already carries the two guards this took to get right -- the pool-retirement rejection and
    // the birth-position test.
    //
    // With this on, the reconstructed triggers (burst_edge / slide_edge / slide_refire) are switched
    // off entirely rather than kept alongside, because BOTH firing would double-count the same
    // burst. `false` restores the previous behaviour exactly, and is a real revert: it re-enables
    // the old trigger block and puts the scan back to special-colours-only.
    constexpr bool AFTERIMAGE_TRIGGER_FROM_OBSERVATION = true;

    // Scan cadence when observation IS the trigger, and the main cost knob for this feature.
    //
    // Chosen between two cadences already proven live not to regress the trail: the in-burst stride
    // of 5 and the idle interval of 10, both of which have been running in confirmed-good builds.
    // It also bounds how late the ghost's trail can be, since a burst is not seen until the next
    // scan -- 6 ticks is ~40ms on this build's ~150Hz, under one send interval. Finer tracks the
    // real burst shape more faithfully; coarser is cheaper. **If the trail ever looks sparse again,
    // raise this before anything else** -- a per-tick enumeration on the game thread is what caused
    // this project's worst regression (pitfalls.md, "The diagnostics were the bug").
    constexpr uint64_t AFTERIMAGE_OBSERVE_SCAN_INTERVAL_TICKS = 6;

    // Cadence of that idle scan, and **the cost knob to reach for first if the trail ever looks
    // sparse again** -- this is the only part of the feature that runs when the player is not
    // trailing. At 10 ticks (~15Hz on this build's ~150Hz) it is well under a third of the ~50Hz
    // enumeration that caused the regression, and each scan here does no per-object name building,
    // UTF-8 conversion or substring search, which was the bulk of that cost.
    constexpr uint64_t AFTERIMAGE_IDLE_SCAN_INTERVAL_TICKS = 10;

    // Gap between scans inside that window. **This is the cost knob, and it is the one to reach for
    // if the trail ever looks sparse again**, because a per-tick enumeration on the game thread is
    // precisely what caused this project's worst regression (pitfalls.md, "The diagnostics were the
    // bug"). At 5 ticks a burst costs about 4 scans, and because slide re-fires arrive every 12
    // ticks the sustained rate during a slide is roughly one scan per 6 ticks -- half the 3-tick
    // cadence that contributed to the regression, and each scan here is far cheaper than that one
    // was (no per-object name building, no UTF-8 conversion, no substring search, no tracing).
    // Still zero while the player is not trailing.
    constexpr uint64_t AFTERIMAGE_COLOR_OBSERVE_STRIDE_TICKS = 5;

    // **Per-SCAN logging, and it must stay small.** Five lines was the original budget and it was
    // useless: the first seconds of ordinary sliding spent all five (log timestamps 03:02:00, ticks
    // 1752-1775), so the ultra hop the run existed to capture was never recorded at all and the
    // session could not be diagnosed. Raised, but only enough to cover the opening of a focused
    // test -- per-scan lines are the ones that could get noisy, so the real coverage comes from the
    // per-burst summary and the unconditional special line below, not from this.
    constexpr int AFTERIMAGE_COLOR_OBSERVE_LOG_COUNT = 40;

    // One line per BURST at the moment it is emitted, which is the granularity a session actually
    // needs to be readable: how long the burst was observed for, how many images it saw, what colour
    // it settled on, and whether that colour diverged from the baseline. Bursts only happen while
    // the player is trailing, so this is bounded by real activity rather than by tick rate, and one
    // Output::send per burst is nothing next to the per-object-per-tick logging that caused the
    // regression. The cap is a runaway backstop, not an expected limit.
    constexpr int AFTERIMAGE_COLOR_BURST_LOG_COUNT = 400;

    // **The blue moment itself, logged whenever it happens regardless of the budgets above.** This
    // is the single observation the whole feature turns on, and the last run proved that a shared
    // budget spent by routine sliding will hide it. A divergence from the baseline is rare by
    // construction -- it only occurs when the game deliberately colours an image differently -- so
    // this cannot become chatty without that itself being the finding.
    constexpr int AFTERIMAGE_COLOR_SPECIAL_LOG_COUNT = 200;

    // The ghost trails on a slide now (trigger confirmed live) but still never blue on an ultra.
    // Colour crosses three hands, and this logs all three so the one that drops it is named rather
    // than guessed -- there are exactly three places it can be lost and they need different fixes:
    //   1. LOCAL   -- is a blue afterimage even observed and captured? If the local scan only ever
    //                 reports gold, the ultra's images are being missed (a sampling problem), and
    //                 nothing downstream matters.
    //   2. WRITE   -- what colour does the ghost's burst actually write, and did the write report
    //                 success? This is the value after the wire, so a mismatch with (1) means the
    //                 send/parse path or the timing between burst and colour update.
    //   3. RESULT  -- what Color do the GHOST's own afterimages come out with? If (2) writes blue
    //                 and (3) is still gold, then the pawn's afterimageColor does NOT seed the
    //                 spawned actor's Color, and the fix is to write Color on the ghost's
    //                 afterimage actors directly -- which is now possible, since they are findable.
    // Every new afterimage is logged with the character it came from, so local and ghost images can
    // be told apart in one stream.
    // OFF: this was the single most expensive thing in the scan -- a second FindAllOf, a lifetime
    // map, per-image GetFullName conversions and a log line per image, all on the game thread. It
    // did its job (it produced the observed/chosen/written/resulting split that located the colour
    // loss), but leaving a diagnostic of this weight enabled is what made the trail intermittent.
    constexpr bool TRAIL_COLOR_TRACE = false;

    // How often the local side checks whether the real recall glow is currently showing. This is a
    // full Niagara-component enumeration, so it is deliberately not per-tick: at ~10Hz it is well
    // under the 20Hz rate the state is sent at anyway, so a tighter cadence would buy nothing
    // visible. The last result is held between scans.
    constexpr uint64_t RECALL_GLOW_SCAN_INTERVAL_TICKS = 15;

    // Superseded note kept for the reasoning, 2026-08-16 -- the flag below is now ON again.
    //
    // 1. **The gate is known wrong.** This shows the glow whenever a peer is empty-handed, but the
    //    user reports the real one only appears when near a save crystal, because that is the only
    //    place the sword can be summoned. So a ghost currently glows in situations the real player
    //    never would. Rather than reimplement "am I near a crystal" -- reproducing a game rule we
    //    would get subtly wrong, and which would silently drift if the game's own rule changed --
    //    the fix is to mirror the game's own DECISION: sync whether the real effect is actually
    //    present on the peer, which covers the crystal rule and any other condition nobody has
    //    noticed, for free. That is the same "let the game do the work" principle the montage
    //    mirror already runs on.
    // 2. **It would contaminate the very capture that fixes it.** VFX_WATCH enumerates every live
    //    Niagara component; a copy we spawn ourselves on a ghost would appear in those results as
    //    an appearing NS_WeaponCallReady, which is precisely the thing the capture is trying to
    //    observe on the real player. Leaving it on risks reading our own output back as evidence.
    //
    // **Both are now resolved and it is back on.** The capture (`UE4SS.log`, 2026-08-16) answered
    // the trigger and the placement together:
    //   * The real effect attaches to the pawn's **WeaponMesh** at a zero offset -- i.e. exactly
    //     where the sword is held -- not to the actor root, which is where this originally put it
    //     and why the user reported it sitting visibly wrong.
    //   * The gate is no longer inferred at all. Instead of trying to reproduce "empty-handed AND
    //     near a save crystal", the local side simply observes whether the real effect is currently
    //     present and sends that. Whatever rule the game applies -- crystal proximity or anything
    //     else nobody has noticed -- is mirrored for free, and cannot drift out of sync with the
    //     game's own logic the way a reimplemented rule would.
    constexpr bool RECALL_GLOW_ENABLED = true;

    auto Plugin::tick_remote_recall_glow(const std::string& player_id, RemoteGhost& remote) -> void
    {
        if (!remote.ghost)
        {
            return;
        }
        // See RECALL_GLOW_ENABLED: the gate below is known to be wrong (empty-handed is necessary
        // but not sufficient -- the real glow also needs the sword to be summonable, which means
        // being near a save crystal), so this is held off rather than shipped visibly wrong.
        if constexpr (!RECALL_GLOW_ENABLED)
        {
            return;
        }
        // Clear any recall glow the ghost constructed for itself, once per ghost. See
        // RemoteGhost::recall_glow_swept for why this is a real bug rather than tidiness: in
        // loopback it merely happens to agree with the peer's state, because the peer is the local
        // player; against a real peer it would display the LOCAL player's summon availability on
        // someone else's ghost, permanently, since nothing else would ever take it down.
        if (!remote.recall_glow_swept)
        {
            remote.recall_glow_swept = true;
            std::vector<UObject*> niagara_components;
            UObjectGlobals::FindAllOf(STR("NiagaraComponent"), niagara_components);
            const std::string ghost_name = to_utf8(remote.ghost->GetName());
            for (UObject* component : niagara_components)
            {
                if (!component || component == remote.recall_glow_component)
                {
                    continue;
                }
                if (to_utf8(component->GetFullName()).find(ghost_name) == std::string::npos)
                {
                    continue;
                }
                UObject** asset_ptr = component->GetValuePtrByPropertyNameInChain<UObject*>(STR("Asset"));
                if (!asset_ptr || !*asset_ptr)
                {
                    continue;
                }
                if (to_utf8((*asset_ptr)->GetFullName()).find(to_utf8(RECALL_GLOW_ASSET)) == std::string::npos)
                {
                    continue;
                }
                if (UFunction* deactivate_fn = component->GetFunctionByNameInChain(STR("Deactivate")))
                {
                    component->ProcessEvent(deactivate_fn, nullptr);
                }
                if (UFunction* destroy_fn = component->GetFunctionByNameInChain(STR("DestroyComponent")))
                {
                    component->ProcessEvent(destroy_fn, nullptr);
                }
                Output::send(STR("[MeshGhostPseudo] RECALLGLOW {}: cleared a self-constructed glow (not ours) at spawn.\n"),
                             to_wide_ascii(player_id));
            }
        }

        const bool want_glow = remote.target_recall_glow;
        if (want_glow == remote.recall_glow_shown)
        {
            return;
        }
        remote.recall_glow_shown = want_glow;

        if (!want_glow)
        {
            if (remote.recall_glow_component)
            {
                // Deactivate first, then destroy. Destroy alone should be enough, but the local
                // half of this same bug was the game keeping a deactivated component alive, so a
                // component that outlives our DestroyComponent call would leave a ghost glowing
                // permanently -- the exact symptom being fixed. Deactivating first makes that
                // failure mode invisible rather than permanent.
                if (UFunction* deactivate_fn = remote.recall_glow_component->GetFunctionByNameInChain(STR("Deactivate")))
                {
                    remote.recall_glow_component->ProcessEvent(deactivate_fn, nullptr);
                }
                if (UFunction* destroy_fn = remote.recall_glow_component->GetFunctionByNameInChain(STR("DestroyComponent")))
                {
                    remote.recall_glow_component->ProcessEvent(destroy_fn, nullptr);
                }
                Output::send(STR("[MeshGhostPseudo] RECALLGLOW {}: hidden\n"), to_wide_ascii(player_id));
                remote.recall_glow_component = nullptr;
            }
            return;
        }

        UObject* glow_asset = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, RECALL_GLOW_ASSET);
        if (!glow_asset)
        {
            static bool warned = false;
            if (!warned)
            {
                warned = true;
                Output::send(STR("[MeshGhostPseudo] WARNING: recall-glow system '{}' not found -- ghosts will show no empty-hand glow.\n"),
                             RECALL_GLOW_ASSET);
            }
            return;
        }
        // Attached to WeaponMesh, not the actor root. Measured, not chosen: the capture showed the
        // real effect hanging off the pawn's own WeaponMesh at a zero offset -- i.e. right where
        // the sword is held, which is why the user described it as an outline of the sword. The
        // root-attached first attempt is what made it sit visibly wrong.
        UObject** attach_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("WeaponMesh"));
        if (!attach_ptr || !*attach_ptr)
        {
            // Falling back to the root would silently reintroduce the exact misplacement this fix
            // exists to correct, so it is better to show nothing and say why.
            Output::send(STR("[MeshGhostPseudo] RECALLGLOW {}: ghost has no WeaponMesh -- glow not shown.\n"),
                         to_wide_ascii(player_id));
            return;
        }
        remote.recall_glow_component = spawn_niagara_attached(glow_asset, *attach_ptr);
        Output::send(STR("[MeshGhostPseudo] RECALLGLOW {}: spawn on WeaponMesh -> {}\n"),
                     to_wide_ascii(player_id),
                     remote.recall_glow_component ? STR("component returned") : STR("NULL"));
    }

    // See AFTERIMAGE_DISCOVERY for why this exists and why it identifies rather than explains.
    auto Plugin::tick_afterimage_discovery(AActor* ghost) -> void
    {
        if (!ghost)
        {
            return;
        }

        // Enumerated together and treated as one set. MeshComponent covers static/skeletal/poseable
        // in one go (an afterimage is most plausibly a mesh snapshot), and Actor covers the case
        // where each one is its own pooled actor instead.
        auto snapshot = [](std::set<std::string>& out) {
            out.clear();
            std::vector<UObject*> objects;
            UObjectGlobals::FindAllOf(STR("MeshComponent"), objects);
            {
                std::vector<UObject*> actors;
                UObjectGlobals::FindAllOf(STR("Actor"), actors);
                objects.insert(objects.end(), actors.begin(), actors.end());
            }
            for (UObject* object : objects)
            {
                if (object)
                {
                    out.insert(to_utf8(object->GetFullName()));
                }
            }
        };

        if (!afterimage_probe_pending)
        {
            if (afterimage_probe_tick != 0 && tick_count - afterimage_probe_tick < AFTERIMAGE_DISCOVERY_INTERVAL_TICKS)
            {
                return;
            }
            snapshot(afterimage_before);
            // Catch anything that appeared since the last probe's post-call sample -- i.e. later
            // than the sample delay. This is the half that was missing when the probe wrongly
            // reported afterimages as pooled.
            if (!afterimage_prev_after.empty())
            {
                for (const std::string& entry : afterimage_before)
                {
                    if (afterimage_prev_after.find(entry) == afterimage_prev_after.end())
                    {
                        Output::send(STR("[MeshGhostPseudo] AFTERIMAGE: + LATE (appeared between probes) {}\n"),
                                     to_wide_ascii(entry));
                    }
                }
            }
            call_spawn_after_image(ghost, 1.0f);
            afterimage_probe_tick = tick_count;
            afterimage_probe_pending = true;
            return;
        }

        if (tick_count - afterimage_probe_tick < AFTERIMAGE_DISCOVERY_SAMPLE_DELAY_TICKS)
        {
            return;
        }
        afterimage_probe_pending = false;

        std::set<std::string> after;
        snapshot(after);

        size_t new_count = 0;
        for (const std::string& entry : after)
        {
            if (afterimage_before.find(entry) != afterimage_before.end())
            {
                continue;
            }
            ++new_count;
            Output::send(STR("[MeshGhostPseudo] AFTERIMAGE: + NEW {}\n"), to_wide_ascii(entry));
        }
        Output::send(STR("[MeshGhostPseudo] AFTERIMAGE: {} new object(s) {} ticks after one Spawn After Image on the ghost (before={}, after={}).\n"),
                     new_count, AFTERIMAGE_DISCOVERY_SAMPLE_DELAY_TICKS,
                     afterimage_before.size(), after.size());
        if (new_count == 0)
        {
            // Do NOT read this as "pooled" any more -- the first run did exactly that and was
            // wrong. If the totals are still climbing between probes, the objects are being
            // created and this window is simply still too narrow; the LATE lines above are then
            // where the answer is. Only a flat total across several probes would actually argue
            // for pooling.
            Output::send(STR("[MeshGhostPseudo] AFTERIMAGE: nothing new within the sample window -- check whether the totals above are still climbing before concluding anything.\n"));
        }
        afterimage_prev_after = std::move(after);

        // **The lead, found in the schema dump**: BP_AfterImage_C carries its own `Color`
        // (StructProperty). The property-value dumper skips structs, which is why it never showed
        // up before -- and it explains the whole dead end in `status.md`. Every colour attempt so
        // far targeted `afterimageColor` on the PAWN, and that field provably never changes during
        // an ultra. It was simply the wrong object: the pawn's value seeds a normal trail, while
        // the colour that actually renders lives on each afterimage actor.
        //
        // So this logs the Color of every afterimage belonging to the LOCAL player as it appears.
        // Do a few normal hops and one ultra in the same session and the answer is a diff, not a
        // guess: if ultra afterimages carry a different Color, that is the blue, and reproducing it
        // means writing Color on the ghost's own afterimage actors rather than anything on its pawn.
        {
            std::vector<UObject*> actors;
            UObjectGlobals::FindAllOf(STR("Actor"), actors);
            for (UObject* candidate : actors)
            {
                if (!candidate)
                {
                    continue;
                }
                UClass* candidate_class = candidate->GetClassPrivate();
                if (!candidate_class || to_utf8(candidate_class->GetName()).find("AfterImage") == std::string::npos)
                {
                    continue;
                }
                const std::string full_name = to_utf8(candidate->GetFullName());
                if (afterimage_colors_logged.find(full_name) != afterimage_colors_logged.end())
                {
                    continue;
                }
                afterimage_colors_logged.insert(full_name);

                // Whose afterimage is this? `cachedMesh` points at the VisualMesh of the character
                // it was snapshotted from, which separates the local player's trail from the
                // ghost's own -- otherwise the ghost's probe-spawned images would drown the real
                // ones being measured.
                std::string source = "<unknown>";
                if (UObject** cached_ptr = candidate->GetValuePtrByPropertyNameInChain<UObject*>(STR("cachedMesh")); cached_ptr && *cached_ptr)
                {
                    source = to_utf8((*cached_ptr)->GetFullName());
                }
                LinearColorRGBA color{};
                const bool ok = read_linear_color(candidate, STR("Color"), color);
                bool* grow_ptr = candidate->GetValuePtrByPropertyNameInChain<bool>(STR("Grow?"));
                Output::send(STR("[MeshGhostPseudo] AFTERIMAGECOLOR: {} rgba=({:.3f}, {:.3f}, {:.3f}, {:.3f}) read_ok={} grow={} from='{}'\n"),
                             candidate->GetName(), color.r, color.g, color.b, color.a, ok,
                             grow_ptr ? *grow_ptr : false,
                             to_wide_ascii(source));
            }
        }

        // Identification is done: an afterimage is a BP_AfterImage_C actor carrying a
        // PoseableMeshComponent -- a posed mesh snapshot, NOT a particle system. That single fact
        // retroactively explains the whole trail of failed colour guesses in `status.md`: they were
        // all aimed at particle/pawn properties, and the thing that is actually coloured here is a
        // mesh's material.
        //
        // So this dumps one real instance, once: the actor's own property values (where a colour or
        // material reference would live if the Blueprint holds one) and its function list (where a
        // setter would be), plus the same for its PoseableMeshComponent, which is what actually
        // renders. This is schema discovery only -- no claim yet about which field carries the
        // blue, because the next step is comparing a normal hop against an ultra and diffing, and
        // that comparison needs to know what fields exist before it can mean anything.
        if (!afterimage_dumped)
        {
            std::vector<UObject*> actors;
            UObjectGlobals::FindAllOf(STR("Actor"), actors);
            for (UObject* candidate : actors)
            {
                if (!candidate)
                {
                    continue;
                }
                UClass* candidate_class = candidate->GetClassPrivate();
                if (!candidate_class || to_utf8(candidate_class->GetName()).find("AfterImage") == std::string::npos)
                {
                    continue;
                }
                afterimage_dumped = true;
                dump_object_property_values(candidate, STR("BP_AfterImage_C"));
                dump_object_reflection(candidate, STR("BP_AfterImage_C"));
                if (UObject** mesh_ptr = candidate->GetValuePtrByPropertyNameInChain<UObject*>(STR("PoseableMesh")); mesh_ptr && *mesh_ptr)
                {
                    dump_object_property_values(*mesh_ptr, STR("afterimage PoseableMesh"));
                }
                break;
            }
        }
    }

    // See GHOST_SPAWN_WEAPON_TRACE for what this is answering and why the loose-weapon census is
    // the column that decides it.
    auto Plugin::tick_ghost_spawn_weapon_trace(const std::string& player_id, RemoteGhost& remote) -> void
    {
        if (!remote.ghost)
        {
            return;
        }
        if (remote.spawn_weapon_trace_tick == 0)
        {
            remote.spawn_weapon_trace_tick = tick_count;
        }
        const bool at_spawn = !remote.spawn_weapon_traced_at_spawn;
        const bool after = !remote.spawn_weapon_traced_after &&
                           tick_count - remote.spawn_weapon_trace_tick >= GHOST_SPAWN_WEAPON_TRACE_DELAY_TICKS;
        if (!at_spawn && !after)
        {
            return;
        }
        const wchar_t* label = at_spawn ? STR("AT-SPAWN") : STR("AFTER");
        if (at_spawn)
        {
            remote.spawn_weapon_traced_at_spawn = true;
        }
        else
        {
            remote.spawn_weapon_traced_after = true;
        }

        // What we believe about the peer, i.e. what the ghost is being told to show.
        Output::send(STR("[MeshGhostPseudo] SPAWNWEAPON {} {}: peer thrown={} state={} equipped={} ourProp={} class='{}'\n"),
                     label, to_wide_ascii(player_id),
                     remote.target_weapon_thrown,
                     static_cast<int>(remote.target_weapon_state),
                     remote.target_weapon_equipped,
                     static_cast<void*>(remote.weapon_actor),
                     to_wide_ascii(remote.target_weapon_class));

        // What the ghost's OWN construction decided, independently of anything we sent it.
        bool* ghost_equipped = remote.ghost->GetValuePtrByPropertyNameInChain<bool>(STR("weaponEquipped?"));
        UObject** ghost_weapon_ref = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("weaponRef"));
        Output::send(STR("[MeshGhostPseudo] SPAWNWEAPON {} {}: ghost weaponEquipped={} weaponRef={}\n"),
                     label, to_wide_ascii(player_id),
                     ghost_equipped ? *ghost_equipped : false,
                     (ghost_weapon_ref && *ghost_weapon_ref) ? (*ghost_weapon_ref)->GetFullName() : STR("null"));

        // The census. Every loose weapon in the world, with where it is and who threw it --
        // Instigator is what distinguishes "the real player's sword" from "a sword some clone
        // created". More of these than this adapter spawned means the ghost built its own.
        std::vector<UObject*> loose_weapons;
        UObjectGlobals::FindAllOf(STR("Actor"), loose_weapons);
        size_t count = 0;
        for (UObject* candidate : loose_weapons)
        {
            if (!candidate)
            {
                continue;
            }
            UClass* candidate_class = candidate->GetClassPrivate();
            if (!candidate_class || to_utf8(candidate_class->GetName()).find("looseWeapon") == std::string::npos)
            {
                continue;
            }
            ++count;
            auto* weapon_actor = static_cast<AActor*>(candidate);
            FVector loc = weapon_actor->K2_GetActorLocation();
            std::string instigator = "<none>";
            if (UObject** inst_ptr = candidate->GetValuePtrByPropertyNameInChain<UObject*>(STR("Instigator")); inst_ptr && *inst_ptr)
            {
                instigator = to_utf8((*inst_ptr)->GetName());
            }
            Output::send(STR("[MeshGhostPseudo] SPAWNWEAPON {} {}:   loose weapon '{}' at ({:.1f}, {:.1f}, {:.1f}) instigator='{}' isOurs={}\n"),
                         label, to_wide_ascii(player_id),
                         candidate->GetName(), loc.X(), loc.Y(), loc.Z(),
                         to_wide_ascii(instigator),
                         candidate == remote.weapon_actor);
        }
        Output::send(STR("[MeshGhostPseudo] SPAWNWEAPON {} {}: {} loose weapon(s) alive in the world.\n"),
                     label, to_wide_ascii(player_id), count);
    }

    // See VFX_CATALOG_PROBE for what this is for and why it exists in this shape.
    auto Plugin::tick_vfx_catalog_probe(AActor* ghost) -> void
    {
        if (!ghost)
        {
            return;
        }

        if (!vfx_probe_catalog_built)
        {
            vfx_probe_catalog_built = true;
            std::vector<UObject*> systems;
            UObjectGlobals::FindAllOf(STR("NiagaraSystem"), systems);
            for (UObject* system : systems)
            {
                if (!system)
                {
                    continue;
                }
                std::string full_name = to_utf8(system->GetFullName());
                size_t space_pos = full_name.find(' ');
                std::string path = (space_pos != std::string::npos) ? full_name.substr(space_pos + 1) : full_name;
                if (path.find(VFX_PROBE_PATH_FILTER) == std::string::npos)
                {
                    continue;
                }
                // See VFX_PROBE_NAME_FILTERS: an empty list means "everything", which is what the
                // first run did.
                if (std::size(VFX_PROBE_NAME_FILTERS) > 0)
                {
                    bool matched = false;
                    for (const char* needle : VFX_PROBE_NAME_FILTERS)
                    {
                        if (path.find(needle) != std::string::npos)
                        {
                            matched = true;
                            break;
                        }
                    }
                    if (!matched)
                    {
                        continue;
                    }
                }
                vfx_probe_catalog.push_back(path);
            }
            // Sorted so a second session walks the catalog in the same order -- otherwise "the
            // seventh one was the yellow glow" wouldn't survive a relaunch, which is exactly the
            // note a person watching this is going to take.
            std::sort(vfx_probe_catalog.begin(), vfx_probe_catalog.end());
            Output::send(STR("[MeshGhostPseudo] VFXPROBE: catalog built -- {} game Niagara system(s) to cycle, ~{} seconds each.\n"),
                         vfx_probe_catalog.size(), VFX_PROBE_INTERVAL_TICKS / 150);
            for (size_t i = 0; i < vfx_probe_catalog.size(); ++i)
            {
                Output::send(STR("[MeshGhostPseudo] VFXPROBE: catalog[{}] = {}\n"), i, to_wide_ascii(vfx_probe_catalog[i]));
            }
        }

        if (vfx_probe_catalog.empty())
        {
            return;
        }
        if (vfx_probe_last_switch_tick != 0 && tick_count - vfx_probe_last_switch_tick < VFX_PROBE_INTERVAL_TICKS)
        {
            return;
        }
        vfx_probe_last_switch_tick = tick_count;

        // Retire the previous effect first, so exactly one is ever on screen -- the whole point is
        // being able to attribute a look to a name, which overlapping effects would ruin.
        if (vfx_probe_component)
        {
            if (UFunction* destroy_fn = vfx_probe_component->GetFunctionByNameInChain(STR("DestroyComponent")))
            {
                vfx_probe_component->ProcessEvent(destroy_fn, nullptr);
            }
            else if (UFunction* deactivate_fn = vfx_probe_component->GetFunctionByNameInChain(STR("Deactivate")))
            {
                vfx_probe_component->ProcessEvent(deactivate_fn, nullptr);
            }
            vfx_probe_component = nullptr;
        }

        const std::string& path = vfx_probe_catalog[vfx_probe_index];
        Output::send(STR("[MeshGhostPseudo] VFXPROBE: [{}/{}] now showing '{}'\n"),
                     vfx_probe_index + 1, vfx_probe_catalog.size(), to_wide_ascii(path));
        vfx_probe_index = (vfx_probe_index + 1) % vfx_probe_catalog.size();

        UObject* system = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, to_wide_ascii(path).c_str());
        if (!system)
        {
            Output::send(STR("[MeshGhostPseudo] VFXPROBE: '{}' no longer resolves -- skipped.\n"), to_wide_ascii(path));
            return;
        }
        if (UObject** root_ptr = ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("RootComponent")); root_ptr && *root_ptr)
        {
            vfx_probe_component = spawn_niagara_attached(system, *root_ptr);
            if (!vfx_probe_component)
            {
                Output::send(STR("[MeshGhostPseudo] VFXPROBE: spawn returned null for '{}'.\n"), to_wide_ascii(path));
            }
        }
    }

    // Stops tracking one remote's ghost. Never destroys the underlying actor -- see
    // DESPAWN_PARK_Z's own comment for why that's a hard rule here, not a missed optimization.
    // Under the hijack design the actor was never ours to destroy anyway; under the spawn design
    // (Phase 7.6), a level transition destroys it out from under us on its own (confirmed live
    // throughout the Lua saga) and game_thread_tick's own staleness check (actor_is_alive) is
    // what actually notices and clears a dead ghost after that happens.
    //
    // Found in a review pass: before parking the ghost below, a peer despawning mid-area (not via
    // an area transition) left its ghost standing frozen in place, visible, until the *next* area
    // transition's teardown finally reclaimed it -- cosmetic, but real. Parking moves it far out
    // of the playable area via the same proven move call the redraw loop already uses every tick,
    // with no change to actor lifetime at all; the level's own eventual teardown on area change is
    // completely unaffected and still does the real cleanup, exactly as before this change.
    //
    // Keeps the map entry so the next ensure_ghost_spawned/ensure_ghost_hijacked call can produce
    // a fresh ghost once render_remote resumes in whatever world comes next.
    auto Plugin::release_ghost(const std::string& player_id) -> void
    {
        auto it = remotes.find(player_id);
        if (it == remotes.end())
        {
            return;
        }

        // Bookkeeping that owns no actor of its own is cleared unconditionally. Previously this sat
        // inside the `if (weapon_actor)` block below, so a remote with no prop kept stale recall-glow
        // and trace state -- harmless today only by luck.
        it->second.weapon_glow_component = nullptr;  // attached to the prop; dies with it
        it->second.recall_glow_component = nullptr;  // attached to the ghost; dies with it
        it->second.recall_glow_shown = false;
        it->second.recall_glow_swept = false;
        it->second.spawn_weapon_trace_tick = 0;
        it->second.spawn_weapon_traced_at_spawn = false;
        it->second.spawn_weapon_traced_after = false;
        // See release_all_ghosts for why these latches must be re-armed when a ghost goes away:
        // they describe an actor that is about to stop existing, and a replacement ghost builds
        // itself from the local save rather than from the peer's state.
        it->second.weapon_equip_call_armed = false;
        it->second.last_synced_weapon_equipped = false;
        it->second.last_synced_outfit_mesh.clear();
        it->second.last_failed_outfit_mesh.clear();

        // The peer's thrown sword is a separate actor with its own lifetime, so a peer despawning
        // mid-throw must not leave a sword hanging in the level. Handled BEFORE the ghost check on
        // purpose: a remote can legitimately have a live prop and no ghost.
        //
        // **DESTROYED, not parked** -- fixing a real crash (EXCEPTION_ACCESS_VIOLATION, 2026-08-16,
        // reported going back to the main menu; stack: handle_bridge_line -> release_ghost ->
        // call_set_actor_location_and_rotation). Two mistakes met here. The park call was left over
        // from before props became per-throw destroyed, so it moved an actor this code no longer
        // keeps alive. And nothing cleared this pointer when a LEVEL tore the prop down, so a
        // `despawn_remote` arriving after a transition moved freed memory. Note a liveness check
        // would NOT have saved it: as the redraw loop's own comment records, IsUnreachable() is only
        // safe on an object that is still allocated. The real fix is the proactive clear in
        // release_all_ghosts (which runs in the LoadMap PRE hook, before teardown) -- exactly the
        // mechanism that has always kept the ghost pointer safe here, now extended to the prop.
        if (it->second.weapon_actor)
        {
            call_destroy_actor(it->second.weapon_actor);
            it->second.weapon_actor = nullptr;
            it->second.weapon_actor_world = nullptr;
            it->second.weapon_render_primed = false;
            it->second.last_synced_weapon_state = -1.0;
        }

        if (!it->second.ghost)
        {
            return;
        }
        Output::send(STR("[MeshGhostPseudo] releasing remote {}: ghost={} owning_world={}\n"),
                     to_wide_ascii(player_id),
                     static_cast<void*>(it->second.ghost),
                     static_cast<void*>(it->second.owning_world));

        FVector park_loc(it->second.target_x, it->second.target_y, DESPAWN_PARK_Z);
        FRotator park_rot(it->second.target_pitch, it->second.target_yaw, it->second.target_roll);
        call_set_actor_location_and_rotation(it->second.ghost, park_loc, park_rot);

        hijacked_actors.erase(it->second.ghost);
        it->second.ghost = nullptr;
        it->second.owning_world = nullptr;
    }

    auto Plugin::release_all_ghosts(const wchar_t* reason) -> void
    {
        for (auto& [id, remote] : remotes)
        {
            // **Cleared for EVERY remote, before the no-ghost skip below** -- this is the fix for a
            // real crash (see release_ghost's comment). This function runs in the LoadMap PRE hook,
            // i.e. the one moment we are guaranteed to be before the level destroys its actors, so
            // it is the only place a pointer can be dropped while it is still definitely valid.
            // Nulling the ghost here is what has always made the ghost safe; the thrown-weapon prop
            // was added later and never got the same treatment, which left it dangling across a
            // transition for a later despawn to trip over. Anything actor-shaped added to
            // RemoteGhost in future belongs in these lines too.
            //
            // Deliberately just drops references and destroys nothing: the level's own teardown is
            // already about to reclaim all of it, and calling into an actor during a LoadMap PRE
            // hook is exactly the kind of thing this file has crashed on before.
            remote.weapon_actor = nullptr;
            remote.weapon_actor_world = nullptr;
            remote.weapon_render_primed = false;
            remote.weapon_glow_component = nullptr;
            remote.last_synced_weapon_state = -1.0;
            remote.recall_glow_component = nullptr;
            remote.recall_glow_shown = false;
            remote.recall_glow_swept = false;
            remote.spawn_weapon_trace_tick = 0;
            remote.spawn_weapon_traced_at_spawn = false;
            remote.spawn_weapon_traced_after = false;
            // **Re-arm every "already synced" latch, because the NEXT ghost is a different actor.**
            // Found 2026-08-16 while reading this path for the spawn-mid-throw capture. These
            // latches exist to avoid re-calling transition functions every tick, but they describe
            // a ghost that is about to stop existing. A replacement ghost constructs itself from
            // the LOCAL player's save, so if the peer's value happens to equal what was last synced
            // to the old ghost, there is no edge, the transition function is never called, and the
            // new ghost keeps its construction state forever -- wearing the local player's outfit,
            // or holding a sword the peer has thrown. Same bug family as the dangling prop pointer:
            // per-ghost state that outlived its ghost.
            remote.weapon_equip_call_armed = false;
            remote.last_synced_weapon_equipped = false;
            remote.last_synced_outfit_mesh.clear();
            remote.last_failed_outfit_mesh.clear();

            if (!remote.ghost)
            {
                continue;
            }
            Output::send(STR("[MeshGhostPseudo] releasing ghost for remote {} ({}): ghost={} owning_world={}\n"),
                         to_wide_ascii(id),
                         reason,
                         static_cast<void*>(remote.ghost),
                         static_cast<void*>(remote.owning_world));
            hijacked_actors.erase(remote.ghost);
            remote.ghost = nullptr;
            remote.owning_world = nullptr;
        }

        // Afterimage pool bookkeeping is per-level: the level's teardown destroys these actors, and
        // the next level's allocator can hand the same addresses back. Keys here are only ever
        // compared, never dereferenced, so a stale one is not a crash risk -- but a recycled address
        // sitting at a remembered position would make a genuinely fresh image look like an untouched
        // one and lose its colour. Clearing costs nothing and removes the case entirely.
        afterimage_pos_by_ptr.clear();
        afterimage_color_burst_pending = false;
        // Clearing the map makes every image in the next level unseen again, so the idle scan has to
        // re-prime or it would read the whole new pool as one enormous untriggered spawn.
        afterimage_pos_primed = false;
    }

    auto Plugin::release_all_ghosts_parked(const wchar_t* reason) -> void
    {
        Output::send(STR("[MeshGhostPseudo] parking all ghosts ({}): {} remote(s)\n"), reason, remotes.size());
        for (auto& [id, remote] : remotes)
        {
            if (!remote.ghost)
            {
                continue;
            }
            release_ghost(id);
        }
    }

    auto Plugin::on_unreal_init() -> void
    {
        Output::send(STR("[MeshGhostPseudo] on_unreal_init reached.\n"));
        unreal_ready = true;
        bridge = std::make_unique<BridgeClient>(BRIDGE_HOST);
        core_launcher = std::make_unique<CoreLauncher>();

        // Kept from the investigation: releases every remote's ghost reference synchronously
        // before a LoadMap-driven transition proceeds. This drops our own bookkeeping (a dangling-
        // pointer safety net, same as it always was) -- it does NOT destroy the actor itself, so
        // under the spawn design (Phase 7.6) it is deliberately NOT relied on as the fix for the
        // original "Fatal world leaks detected" crash. Whether that crash still happens now that
        // spawn/reposition calls run on the game thread (unlike the original spawn attempt) is
        // exactly what this retest is for -- see RemoteGhost's comment in Plugin.hpp. Call shape
        // (callback + FCallbackOptions, returning a GlobalCallbackId, no separate HookLoadMap()
        // call needed) confirmed from cppmods/EventViewerMod/src/Middleware.cpp, an
        // already-approved MIT reference this phase.
        load_map_pre_callback_id = Hook::RegisterLoadMapPreCallback(
            [this](Hook::TCallbackIterationData<bool>&, UEngine*, FWorldContext&, FURL, UPendingNetGame*, FString&) {
                Output::send(STR("[MeshGhostPseudo] HOOK: LoadMap PRE fired.\n"));
                log_remote_state(STR("LoadMap PRE, before release"));
                release_all_ghosts(STR("LoadMap PRE"));

                // Crash fix, found live 2026-08-13: entering a new area crashed with
                // EXCEPTION_ACCESS_VIOLATION inside the camera fight-back hook. last_known_good_
                // view_target is a raw AActor* cached across calls -- calling ->IsUnreachable() on
                // it (the existing staleness check) dereferences the object's own memory, which is
                // only safe if the object is merely GC-unreachable-but-still-allocated, not if a
                // level transition has actually freed it. Unlike Lua's IsValid() (which checks a
                // separate live-object registry before ever touching the object's own memory,
                // see actor_is_alive's comment), there is no safe way to test a raw AActor* for
                // "has this been fully freed" here -- so never let the pointer survive into a
                // transition in the first place. Same reasoning as release_all_ghosts above, just
                // for the camera's cached reference instead of the ghosts' own.
            },
            Hook::FCallbackOptions{.OwnerModName = STR("MeshGhostPseudo"), .HookName = STR("ReleaseGhostsBeforeLoadMap")});

        // THE render-freeze fix -- see game_thread_tick's own doc comment in Plugin.hpp. Runs
        // every real engine frame, on the actual game thread, unlike on_update() (UE4SS's own
        // ~5ms polling thread). All actor reads/writes now happen here instead.
        engine_tick_post_callback_id = Hook::RegisterEngineTickPostCallback(
            [this](Hook::TCallbackIterationData<void>&, UEngine*, float, bool) { game_thread_tick(); },
            Hook::FCallbackOptions{.OwnerModName = STR("MeshGhostPseudo"), .HookName = STR("GameThreadTick")});

        // Third attempt, using UFunction::RegisterPreHook instead of a ProcessEvent filter -- see
        // this function's own comment for why the first two never even fired.
        register_camera_fightback_hook();
    }

    // Phase 7.6, third attempt. Root cause of why the first two attempts never even fired: this
    // game calls SetViewTargetWithBlend as a *native* function (FUNC_Native), and confirmed by
    // reading UE4SS's own Lua RegisterHook implementation directly
    // (RE-UE4SS/UE4SS/src/Mod/LuaMod.cpp:3907-3921) -- for a native UFunction, Lua's RegisterHook
    // does NOT use a ProcessEvent hook at all; it calls UFunction::RegisterPreHook/RegisterPostHook
    // directly on the function object, which patches the function's own native entry point and
    // catches every call regardless of whether it's dispatched through ProcessEvent or called
    // directly by the engine's own native C++ code. RegisterProcessEventPostCallback (the previous
    // two attempts) only ever sees ProcessEvent-dispatched (Blueprint VM) calls -- a genuinely
    // different, narrower set of calls than what Lua's RegisterHook covers, which is why it never
    // fired even once (confirmed: zero DIAGNOSTIC log lines across a live run that visibly hit the
    // bug).
    //
    // This also enables a strictly safer design than "let the wrong call happen, then make a
    // second corrective call": RegisterPreHook fires BEFORE the engine's own native call runs, and
    // UnrealScriptFunctionCallableContext::GetParams<T>() gives direct access to the *engine's
    // own*, already-correctly-sized argument buffer (TheStack.Locals()) -- so the fix is to read
    // and, if needed, overwrite NewViewTarget (the first argument, offset 0) in place before the
    // real call proceeds. No second call, no guessed buffer size, no reentrancy, no defer-to-next-
    // tick needed -- the corrected value is simply what the engine's own call uses.
    auto Plugin::register_camera_fightback_hook() -> void
    {
        // Registered unconditionally: this hook no longer only observes. It refuses a camera
        // switch to a rig owned by one of our ghosts, which is the fix for the player losing
        // camera control after a ghost spawns -- so gating it on a trace flag would turn the probe
        // switch into a feature switch, and turning logging off would silently reinstate the bug.

        svtwb_function = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, STR("/Script/Engine.PlayerController:SetViewTargetWithBlend"));
        if (!svtwb_function)
        {
            Output::send(STR("[MeshGhostPseudo] WARNING: could not find SetViewTargetWithBlend UFunction -- camera trace unavailable this session.\n"));
            return;
        }

        struct SetViewTargetWithBlendLocals
        {
            AActor* NewViewTarget;
        };

        svtwb_hook_id = svtwb_function->RegisterPreHook(
            [this](UnrealScriptFunctionCallableContext& ctx, void*) {
                SetViewTargetWithBlendLocals& locals = ctx.GetParams<SetViewTargetWithBlendLocals>();
                AActor* target = locals.NewViewTarget;
                if (!target)
                {
                    return;
                }

                // Who does this rig belong to? Every load shows the camera switching to a
                // different BP_PlayerCam_C ~4ms after a ghost spawns, which is the 7.4 finding
                // again -- the ghost is a clone of the player pawn, so it brings its own camera
                // rig and the game targets it. If that rig's Owner is one of our ghosts, this can
                // be rejected precisely, instead of the old fight-back's "block every change
                // forever", which is what made it worse than the bug.
                // OwningActor, not Owner. The engine's Owner is (none) on every one of these rigs
                // -- measured -- but a property dump of a rig caught mid-steal showed
                // BP_PlayerCam_C carries its own Blueprint property pointing at the pawn it
                // serves: "OwningActor (ObjectProperty) = BP_PlayerGoatMain_C_...". That is the
                // exact test this needed, and it replaces the timing correlation that stood in for
                // it. Owner is still read as a fallback in case some rig uses it instead.
                UObject** owning_actor = target->GetValuePtrByPropertyNameInChain<UObject*>(STR("OwningActor"));
                UObject* owner_obj = (owning_actor && *owning_actor) ? *owning_actor : nullptr;
                if (!owner_obj)
                {
                    UObject** engine_owner = target->GetValuePtrByPropertyNameInChain<UObject*>(STR("Owner"));
                    owner_obj = (engine_owner && *engine_owner) ? *engine_owner : nullptr;
                }

                bool owned_by_ghost = false;
                if (owner_obj)
                {
                    std::lock_guard<std::mutex> lock(state_mutex);
                    for (const auto& [id, remote] : remotes)
                    {
                        if (remote.ghost && static_cast<UObject*>(remote.ghost) == owner_obj)
                        {
                            owned_by_ghost = true;
                            break;
                        }
                    }
                }

                Output::send(STR("[MeshGhostPseudo] CAMERA_TRACE tick={} target={} owner={} owned_by_ghost={}\n"),
                             tick_count,
                             target->GetFullName(),
                             owner_obj ? owner_obj->GetFullName() : STR("(none)"),
                             owned_by_ghost ? STR("YES") : STR("no"));

                // Owner is (none) on every one of these rigs -- measured, not assumed -- so
                // ownership cannot identify them. What CAN: we know exactly when we spawned a
                // ghost, and every observed steal happens within a few ticks of that, never at any
                // other time. So the window is the signal, and it is a window we create.
                //
                // Deliberately narrow: a handful of ticks after OUR OWN spawn, not a permanent
                // state. Outside it the game keeps every camera decision it makes, which is the
                // property the old fight-back lacked.
                bool inside_ghost_spawn_window = ghost_spawn_camera_guard_tick != 0 &&
                                                 tick_count >= ghost_spawn_camera_guard_tick &&
                                                 tick_count <= ghost_spawn_camera_guard_tick + GHOST_SPAWN_CAMERA_GUARD_TICKS;

                if (inside_ghost_spawn_window && !camera_rig_dumped)
                {
                    // One-shot: dump the rig that steals the camera, so the property that actually
                    // links it to its pawn can be found and this timing rule replaced with a
                    // precise test. Once per session -- a dump per switch would be its own
                    // problem.
                    camera_rig_dumped = true;
                    dump_object_property_values(target, STR("camera rig taken during a ghost spawn"));
                }

                // The window is now only a fallback for a rig that cannot be identified at all --
                // if OwningActor resolved, believe it rather than a correlation.
                bool reject = owned_by_ghost || (owner_obj == nullptr && inside_ghost_spawn_window);
                if (!reject)
                {
                    // Remember the last target the game chose for itself. Only ever used to undo a
                    // ghost's rig below -- unlike the old fight-back, which treated this as the one
                    // true camera forever and fought every legitimate switch with it.
                    last_non_ghost_view_target = target;
                    return;
                }

                // The one switch worth refusing: a camera taken during our own ghost spawn. Everything
                // else -- cutscenes, area rigs, the game's own routine switching -- passes through
                // untouched, which is exactly what the old mechanism got wrong.
                //
                // Self-validating: if a rig turns out NOT to be ghost-owned this never fires, and
                // the trace above says so, so nothing is blocked on a guess.
                //
                // Redirected to the last target the game itself picked rather than to nullptr: a
                // null view target is not "no change", it is "no camera".
                if (last_non_ghost_view_target && !last_non_ghost_view_target->IsUnreachable())
                {
                    Output::send(STR("[MeshGhostPseudo] refusing a camera switch to a GHOST's own rig -- keeping {}\n"),
                                 last_non_ghost_view_target->GetFullName());
                    locals.NewViewTarget = last_non_ghost_view_target;
                }
                else
                {
                    Output::send(STR("[MeshGhostPseudo] a GHOST's rig was chosen but no earlier camera is known -- letting it through rather than guessing.\n"));
                }
            },
            nullptr);
    }

    // Redesigned 2026-08-13 after the "Fatal world leaks detected" investigation found no working
    // actor-destroy mechanism on this build (K2_DestroyActor silently no-ops -- confirmed via a
    // GetWorld() readback showing the "destroyed" actor still fully alive seconds later; see
    // agent_docs/pitfalls.md and the plan at lowlevelfatalerror-file-d-build-ue5-sync-zazzy-star.md).
    // Never spawns anything: finds an already-existing, already-registered StaticMeshActor in the
    // local player's current world and hijacks it as the remote's ghost instead. Since nothing new
    // is ever created, there is never anything that needs destroying -- the level's own normal
    // teardown (which has always worked correctly for its own real props) handles cleanup
    // transparently. This also removes the whole auto-possess safety-fix machinery from the prior
    // spawn-based design: a StaticMeshActor can never auto-possess, so that bug class can't recur.
    auto Plugin::ensure_ghost_hijacked(const std::string& player_id, UObject* local_pawn) -> void
    {
        auto existing = remotes.find(player_id);
        if (existing != remotes.end() && existing->second.ghost)
        {
            return;
        }

        if (!local_pawn)
        {
            return;
        }

        auto* local_pawn_actor = static_cast<AActor*>(local_pawn);
        UWorld* world = static_cast<UWorld*>(local_pawn_actor->GetWorld());
        if (!world)
        {
            return;
        }

        // Simplified 2026-08-13 once the real render-freeze cause (on_update() running off the
        // game thread, see verified.md) was found and fixed -- the "prefer already-Movable"
        // heuristic tried here earlier was chasing a symptom of that bug, not a real requirement,
        // and it tended to grab gameplay-relevant Movable objects (walls, platforms) instead of
        // safe decoration -- exactly backwards from what a "safe to hijack" heuristic should
        // prefer. Back to simple first-eligible-candidate selection.
        std::vector<UObject*> candidates;
        UObjectGlobals::FindAllOf(STR("StaticMeshActor"), candidates);
        AActor* hijack_target = nullptr;
        for (UObject* candidate_obj : candidates)
        {
            if (!candidate_obj || candidate_obj->HasAnyFlags(RF_ClassDefaultObject))
            {
                continue;
            }
            auto* candidate = static_cast<AActor*>(candidate_obj);
            if (static_cast<UWorld*>(candidate->GetWorld()) != world)
            {
                continue; // not in the local player's current world
            }
            if (hijacked_actors.contains(candidate))
            {
                continue; // already in use by another remote
            }
            if (name_has_excluded_keyword(candidate->GetFullName()))
            {
                continue; // possibly interactive/quest-relevant -- see HIJACK_EXCLUDE_KEYWORDS
            }
            hijack_target = candidate;
            break;
        }

        if (!hijack_target)
        {
            Output::send(STR("[MeshGhostPseudo] no available StaticMeshActor to hijack for remote {} in this world yet.\n"), to_wide_ascii(player_id));
            return;
        }

        hijack_target->SetActorEnableCollision(false);

        // Ported from the Lua adapter's already-confirmed Mobility fix (Phase 7.4, this exact
        // build): a StaticMeshActor's root component defaults to Static mobility, which silently
        // ignores runtime position changes. Direct property write, not the setter UFunction, per
        // this whole phase's established working pattern for this build. Now that writes happen
        // on the real game thread (game_thread_tick), this should actually take visible effect.
        // EComponentMobility::Movable == 2, same value used successfully in the Lua fix.
        UObject** root_component_ptr = hijack_target->GetValuePtrByPropertyNameInChain<UObject*>(STR("RootComponent"));
        if (root_component_ptr && *root_component_ptr)
        {
            uint8_t* mobility_ptr = (*root_component_ptr)->GetValuePtrByPropertyNameInChain<uint8_t>(STR("Mobility"));
            if (mobility_ptr)
            {
                *mobility_ptr = 2;
                Output::send(STR("[MeshGhostPseudo] set hijacked actor's RootComponent Mobility to Movable (readback: {})\n"), *mobility_ptr);
            }
            else
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: could not find Mobility property on hijacked actor's RootComponent -- it may not move.\n"));
            }
        }
        else
        {
            Output::send(STR("[MeshGhostPseudo] WARNING: could not find RootComponent on hijacked actor -- it may not move.\n"));
        }

        hijacked_actors.insert(hijack_target);

        RemoteGhost& remote = remotes[player_id];
        remote.ghost = hijack_target;
        remote.owning_world = world;
        FVector current_loc = hijack_target->K2_GetActorLocation();
        remote.target_x = current_loc.X();
        remote.target_y = current_loc.Y();
        remote.target_z = current_loc.Z();
        Output::send(STR("[MeshGhostPseudo] hijacked existing actor for remote {} in world_ptr={} ({})\n"),
                     to_wide_ascii(player_id),
                     static_cast<void*>(world),
                     hijack_target->GetFullName());
    }

    // Phase 7.6: spawn-based ghost design, retested on the real game thread (this function is only
    // ever called from game_thread_tick's own call chain -- see handle_bridge_line below). Ported
    // field-for-field from the Lua adapter's trySpawnRemoteGhost
    // (probe_ghost/Scripts/main.lua:596-650), which spawned this exact way and survived real area
    // transitions -- the only C++ spawn attempt that ever crashed made every one of these calls
    // from on_update() (UE4SS's own polling thread) instead. See RemoteGhost's comment in
    // Plugin.hpp for the full reasoning.
    auto Plugin::ensure_ghost_spawned(const std::string& player_id, UObject* local_pawn, UObject* local_controller) -> void
    {
        auto existing = remotes.find(player_id);
        if (existing != remotes.end() && existing->second.ghost)
        {
            return;
        }
        if (!local_pawn || !local_controller)
        {
            return;
        }

        // Re-added 2026-08-13 (user-requested): hold off spawning until the player's own camera
        // has had time to settle on a real target -- see SPAWN_DELAY_TICKS's own comment for why.
        if (ticks_since_pawn_valid < SPAWN_DELAY_TICKS)
        {
            return;
        }

        // Refuse to spawn against the title-screen's transient DefaultPawn -- the original C++
        // spawn crash's ghost was exactly this. No ghost exists until the real player pawn exists.
        if (!class_looks_like_player(local_pawn))
        {
            return;
        }

        auto* local_pawn_actor = static_cast<AActor*>(local_pawn);
        UWorld* world = static_cast<UWorld*>(local_pawn_actor->GetWorld());
        if (!world)
        {
            return;
        }

        if (POSSESS_TRACE)
        {
            // Why was a spawn allowed at all? Two ghosts per level load have been observed, which
            // means this reported a null ghost pointer moments after a successful spawn -- so
            // something invalidates it in between, and the loser is left orphaned in the world.
            UObject** before = local_controller->GetValuePtrByPropertyNameInChain<UObject*>(STR("Pawn"));
            Output::send(STR("[MeshGhostPseudo] POSSESS_TRACE spawn-allowed remote={} entry={} tick={} controller_pawn_before={}\n"),
                         to_wide_ascii(player_id),
                         existing != remotes.end() ? STR("present") : STR("absent"),
                         tick_count,
                         (before && *before) ? (*before)->GetFullName() : STR("(none)"));
        }

        FVector spawn_loc = local_pawn_actor->K2_GetActorLocation();
        FRotator spawn_rot = local_pawn_actor->K2_GetActorRotation();

        // Lua's MIN_PLAUSIBLE_DISTANCE guard (main.lua): a pawn whose transform hasn't been
        // placed yet by the engine reads back near the origin -- wait for a real placement rather
        // than spawning the clone there.
        double distance_from_origin = std::sqrt(spawn_loc.X() * spawn_loc.X() + spawn_loc.Y() * spawn_loc.Y() + spawn_loc.Z() * spawn_loc.Z());
        if (distance_from_origin < MIN_PLAUSIBLE_DISTANCE)
        {
            return;
        }

        UClass* pawn_class = local_pawn->GetClassPrivate();
        if (!pawn_class)
        {
            return;
        }

        // Stop the clone taking the controller in the first place, rather than taking it back
        // afterwards.
        //
        // CONFIRMED the mechanism before writing this (POSSESS_TRACE, 2026-08-16): bracketing the
        // spawn showed the controller holding the LOCAL pawn before, the GHOST immediately after,
        // and the local pawn again after our hand-back. So the ghost really does auto-possess, and
        // every spawn puts the player through an unpossess/re-possess cycle -- twice per level
        // load, since a duplicate spawn is also happening. That cycle is the suspect for the
        // player being unable to move while the camera stays on them: re-possessing restores the
        // pawn, but need not restore whatever input the game bound to it.
        //
        // AutoPossessPlayer is a stock APawn UPROPERTY (EAutoReceiveInput), read during spawn, so
        // it has to be cleared on the class default object BEFORE SpawnActor -- setting it on the
        // instance afterwards is already too late. Restored immediately after so nothing else that
        // spawns this class is affected; the whole window is one synchronous call on the game
        // thread.
        //
        // Logged either way rather than assumed: if the property does not resolve on this build,
        // that is a finding, not something to quietly skip ("it ran without errors is not
        // evidence").
        uint8_t* auto_possess = nullptr;
        uint8_t saved_auto_possess = 0;
        if (UObject* cdo = pawn_class ? pawn_class->GetClassDefaultObject() : nullptr)
        {
            auto_possess = cdo->GetValuePtrByPropertyNameInChain<uint8_t>(STR("AutoPossessPlayer"));
            if (auto_possess)
            {
                saved_auto_possess = *auto_possess;
                *auto_possess = 0; // EAutoReceiveInput::Disabled
            }
        }
        if (POSSESS_TRACE)
        {
            Output::send(STR("[MeshGhostPseudo] POSSESS_TRACE AutoPossessPlayer on the ghost class = {}\n"),
                         auto_possess ? std::to_wstring(saved_auto_possess) : STR("<not reflected>"));
        }

        AActor* ghost = world->SpawnActor(pawn_class, &spawn_loc, &spawn_rot);

        if (auto_possess)
        {
            *auto_possess = saved_auto_possess;
        }
        if (!ghost)
        {
            Output::send(STR("[MeshGhostPseudo] SpawnActor returned nullptr for remote {}.\n"), to_wide_ascii(player_id));
            return;
        }

        // Facing-direction investigation, 2026-08-13: bisecting whether the ghost's
        // CapsuleComponent RelativeRotation is already garbage right at spawn (before Possess,
        // collision, or any redraw-loop write ever touches it) or develops later. Read-only,
        // fires once per spawn. Also checking the ghost's own bOrientRotationToMovement here since
        // it's nearly free once this block exists -- confirmed true on the real player already,
        // never checked on the ghost.
        {
            Output::send(STR("[MeshGhostPseudo] DIAG: spawn_rot passed to SpawnActor = (pitch={}, yaw={}, roll={})\n"),
                         spawn_rot.GetPitch(), spawn_rot.GetYaw(), spawn_rot.GetRoll());
            if (UObject** spawn_capsule_ptr = ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("CapsuleComponent")); spawn_capsule_ptr && *spawn_capsule_ptr)
            {
                if (FRotator* spawn_capsule_rot = (*spawn_capsule_ptr)->GetValuePtrByPropertyNameInChain<FRotator>(STR("RelativeRotation")))
                {
                    Output::send(STR("[MeshGhostPseudo] DIAG: ghost CapsuleComponent RelativeRotation immediately after SpawnActor = (pitch={}, yaw={}, roll={})\n"),
                                 spawn_capsule_rot->GetPitch(), spawn_capsule_rot->GetYaw(), spawn_capsule_rot->GetRoll());
                }
                else
                {
                    Output::send(STR("[MeshGhostPseudo] DIAG: ghost CapsuleComponent has no reflected RelativeRotation property.\n"));
                }
            }
            else
            {
                Output::send(STR("[MeshGhostPseudo] DIAG: ghost has no reflected CapsuleComponent immediately after SpawnActor.\n"));
            }
            if (UObject** spawn_movement_ptr = ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("CharacterMovement")); spawn_movement_ptr && *spawn_movement_ptr)
            {
                if (bool* spawn_orient_ptr = (*spawn_movement_ptr)->GetValuePtrByPropertyNameInChain<bool>(STR("bOrientRotationToMovement")))
                {
                    Output::send(STR("[MeshGhostPseudo] DIAG: ghost CharacterMovement bOrientRotationToMovement = {} -- forcing to false\n"), *spawn_orient_ptr);
                    // Facing-direction fix attempt, 2026-08-13: confirmed via the spawn-time DIAG
                    // above that CapsuleComponent RelativeRotation is CORRECT immediately after
                    // SpawnActor (matches spawn_rot exactly) and only goes garbage sometime after
                    // -- ruling out spawn-time corruption. bOrientRotationToMovement=true (real
                    // player has this too) is the leading remaining candidate: the ghost is
                    // teleported, not driven by real movement input, so its
                    // CharacterMovementComponent's own internal velocity tracking is presumably
                    // near-zero/bogus -- if the component re-derives rotation from that every
                    // tick, it would explain rotation starting correct then being overwritten with
                    // garbage shortly after, independent of our own explicit rotation writes.
                    // Forcing this false leaves K2_SetActorLocationAndRotation as the sole source
                    // of truth for the ghost's rotation.
                    *spawn_orient_ptr = false;
                }
            }
        }

        if (POSSESS_TRACE)
        {
            // The window nothing has ever looked at: between the ghost existing and us taking
            // control back. If the ghost auto-possessed, the controller is holding IT right here,
            // which also means the player's pawn was unpossessed -- and an unpossess/re-possess
            // cycle can restore the pawn without restoring whatever input the game bound to it.
            // That would look exactly like "camera is on me, I cannot move".
            UObject** mid = local_controller->GetValuePtrByPropertyNameInChain<UObject*>(STR("Pawn"));
            Output::send(STR("[MeshGhostPseudo] POSSESS_TRACE pre-handback tick={} controller_pawn={}\n"),
                         tick_count,
                         (mid && *mid) ? (*mid)->GetFullName() : STR("(none)"));
        }

        // Auto-possess safety fix (Phase 7.4, agent_docs/pitfalls.md's "Spawned actors
        // auto-possessing" -- BP_PlayerGoatMain_C auto-possesses on spawn and will otherwise steal
        // control from the real player). GetFunctionByNameInChain matches Lua's
        // controller:Possess(pawn) call and the pattern already confirmed live for this exact call
        // in the earlier (pre-thread-fix) spawn attempt, agent_docs/phases/phase7.md:1045-1046 --
        // reflection worked for Possess even when it didn't for K2_DestroyActor/SetVisibility/
        // DestroyComponent, so this is not a shot in the dark. call_ufunction_with_leading_actor_arg
        // sizes the Parms buffer from the function's own real GetPropertiesSize() rather than a
        // hand-guessed struct -- see that helper's comment for why that distinction matters.
        // Only take control back if something actually took it. Since AutoPossessPlayer is now
        // cleared around the spawn above, the usual case is that the controller never let go --
        // and re-possessing a pawn the controller already holds is not free in Unreal: it runs the
        // unpossess/possess path internally, which resets input state on a pawn that was working
        // fine. That is the current suspect for the player being unable to move while the camera
        // stays on them, now that the theft itself is fixed and the symptom survived.
        UObject** currently_held = local_controller->GetValuePtrByPropertyNameInChain<UObject*>(STR("Pawn"));
        bool controller_already_correct = currently_held && *currently_held == static_cast<UObject*>(local_pawn_actor);

        UFunction* possess_fn = local_controller->GetFunctionByNameInChain(STR("Possess"));
        if (controller_already_correct)
        {
            if (POSSESS_TRACE)
            {
                Output::send(STR("[MeshGhostPseudo] POSSESS_TRACE hand-back skipped -- controller already holds the local pawn.\n"));
            }
        }
        else if (possess_fn)
        {
            call_ufunction_with_leading_actor_arg(local_controller, possess_fn, local_pawn_actor);
        }
        else
        {
            Output::send(STR("[MeshGhostPseudo] WARNING: Controller has no reflected Possess function -- the real player may lose control.\n"));
        }

        // Arm the camera guard: the game re-picks a camera within a few ticks of this spawn.
        ghost_spawn_camera_guard_tick = tick_count;

        if (POSSESS_TRACE)
        {
            // Ask the controller what it actually holds now, rather than trusting the call above.
            // possess_watch_until_tick keeps this running for a few ticks, because an auto-possess
            // that fires on the ghost's BeginPlay would land AFTER this line and be invisible here.
            UObject** held = local_controller->GetValuePtrByPropertyNameInChain<UObject*>(STR("Pawn"));
            Output::send(STR("[MeshGhostPseudo] POSSESS_TRACE after-handback tick={} controller_pawn={} local_pawn={} ghost={}\n"),
                         tick_count,
                         (held && *held) ? (*held)->GetFullName() : STR("(none)"),
                         local_pawn_actor->GetFullName(),
                         ghost->GetFullName());
            possess_watch_until_tick = tick_count + POSSESS_TRACE_TICKS;
        }

        // Facing-direction bisection, 2026-08-13: rotation is confirmed correct immediately after
        // SpawnActor (the DIAG block above) but garbage by the time the redraw loop reads it.
        // bOrientRotationToMovement=false didn't change that. Next candidate: the ghost briefly
        // auto-possesses itself on spawn (this whole Possess() call above exists specifically to
        // hand control back), so this checks whether the corruption happens during/because of
        // that possess/un-possess cycle -- reading right after it, before anything else
        // (collision, animation writes) touches the ghost.
        if (UObject** post_possess_capsule_ptr = ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("CapsuleComponent")); post_possess_capsule_ptr && *post_possess_capsule_ptr)
        {
            if (FRotator* post_possess_rot = (*post_possess_capsule_ptr)->GetValuePtrByPropertyNameInChain<FRotator>(STR("RelativeRotation")))
            {
                Output::send(STR("[MeshGhostPseudo] DIAG: ghost CapsuleComponent RelativeRotation immediately after Possess() = (pitch={}, yaw={}, roll={})\n"),
                             post_possess_rot->GetPitch(), post_possess_rot->GetYaw(), post_possess_rot->GetRoll());
            }
        }

        ghost->SetActorEnableCollision(GHOST_COLLISION_ENABLED);

        // Ghost hurtbox disable, 2026-08-15 -- user's own proposal, and the right shape of fix for
        // the melee-death hazard that kept collision off until now: keep the ghost's physical
        // presence (which is what makes collision worth having, and what wall-ride detection may
        // need) while making it not a damageable target at all, rather than trying to identify and
        // Ignore whichever collision channel the damage trace happens to query.
        //
        // 'bCanBeDamaged' is a stock AActor UPROPERTY, not this game's own data, so this is not a
        // guess about Pseudoregalia's damage model -- it's the engine-level gate that standard
        // TakeDamage/ApplyDamage paths check. Written as a direct property rather than via a
        // SetCanBeDamaged() call, per agent_docs/pitfalls.md's "prefer a direct property write over
        // a setter UFunction on builds where reflection appears stripped down". Logged either way:
        // if the name doesn't resolve on this build, that's a real finding, not something to
        // silently assume worked -- CLAUDE.md's "it ran without errors is not evidence".
        //
        // NOT yet live-confirmed to stop the death propagation -- it targets the standard damage
        // path, and the original bug's exact mechanism (why damaging the ghost killed the REAL
        // player) was never root-caused. Verify by deliberately attacking a ghost before trusting.
        if constexpr (GHOST_COLLISION_ENABLED)
        {
            if (bool* can_be_damaged_ptr = ghost->GetValuePtrByPropertyNameInChain<bool>(STR("bCanBeDamaged")))
            {
                *can_be_damaged_ptr = false;
                Output::send(STR("[MeshGhostPseudo] ghost hurtbox disabled (bCanBeDamaged=false).\n"));
            }
            else
            {
                Output::send(STR("[MeshGhostPseudo] WARNING: could not resolve 'bCanBeDamaged' on the ghost -- hurtbox NOT disabled, attacking a ghost may still damage the real player.\n"));
            }
        }

        // Physical-solidity attempt -- see call_set_collision_response_to_channel's own comment.
        // STILL DOES NOT ADDRESS THE MELEE-DAMAGE RISK from the earlier collision test (see
        // agent_docs/risks.md) -- this only adds a Block response on the standard Pawn channel on
        // top of whatever collision was already enabled; it does not touch whatever channel the
        // real player's melee hit-detection actually queries, which is still unidentified. Only
        // meaningful while GHOST_COLLISION_ENABLED is true.
        if constexpr (GHOST_COLLISION_ENABLED)
        {
            // ECollisionChannel::ECC_Pawn = 2, ECollisionResponse::ECR_Block = 2 -- stable public
            // UE engine constants (Engine/EngineTypes.h), not this game's own data, unchanged
            // since UE4's initial public release.
            constexpr uint8_t ECC_PAWN = 2;
            constexpr uint8_t ECR_BLOCK = 2;
            if (UObject** ghost_capsule_ptr = ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("CapsuleComponent")); ghost_capsule_ptr && *ghost_capsule_ptr)
            {
                UObject* ghost_capsule = *ghost_capsule_ptr;
                UFunction* set_response_fn = ghost_capsule->GetFunctionByNameInChain(STR("SetCollisionResponseToChannel"));
                if (set_response_fn)
                {
                    call_set_collision_response_to_channel(ghost_capsule, set_response_fn, ECC_PAWN, ECR_BLOCK);
                    Output::send(STR("[MeshGhostPseudo] attempted SetCollisionResponseToChannel(Pawn, Block) on ghost capsule for remote {}.\n"), to_wide_ascii(player_id));

                    // Enemy-damage fix -- see call_set_collision_object_type's own comment. Applied
                    // AFTER the response call above deliberately: that one sets how the capsule
                    // RESPONDS to the Pawn channel, this changes what the capsule IS, and re-typing
                    // first would leave the response set against a channel it no longer belongs to.
                    constexpr uint8_t ECC_WORLD_DYNAMIC = 1;
                    call_set_collision_object_type(ghost_capsule, ECC_WORLD_DYNAMIC);
                    Output::send(STR("[MeshGhostPseudo] attempted SetCollisionObjectType(WorldDynamic) on ghost capsule for remote {} -- enemy-damage mitigation, NOT yet confirmed to work.\n"), to_wide_ascii(player_id));
                }
                else
                {
                    Output::send(STR("[MeshGhostPseudo] WARNING: ghost CapsuleComponent has no reflected SetCollisionResponseToChannel function.\n"));
                }
            }
        }


        RemoteGhost& remote = remotes[player_id];
        remote.ghost = ghost;
        remote.owning_world = world;
        remote.target_x = spawn_loc.X();
        remote.target_y = spawn_loc.Y();
        remote.target_z = spawn_loc.Z();
        Output::send(STR("[MeshGhostPseudo] spawned ghost for remote {} in world_ptr={} ({})\n"),
                     to_wide_ascii(player_id),
                     static_cast<void*>(world),
                     ghost->GetFullName());

        // Stop the ghost being drawn through walls. Knowing where another player is behind
        // geometry is information, and this project's line is visual-only with no gameplay effect
        // -- for a speedrunner especially, that is a real advantage and not a cosmetic one. The
        // local player keeps its own outline untouched; only the ghost loses it.
        for (const wchar_t* mesh_name : {STR("VisualMesh"), STR("WeaponMesh")})
        {
            if (UObject** mesh = ghost->GetValuePtrByPropertyNameInChain<UObject*>(mesh_name); mesh && *mesh)
            {
                call_set_render_custom_depth(*mesh, false);
            }
        }

        if (OUTLINE_TRACE)
        {
            // Runs AFTER the calls above on purpose, so it reads the component's own state back
            // rather than reporting what we intended -- an echo of our own write would prove
            // nothing (CLAUDE.md). Both sides, once, so they can be compared: the ghost should now
            // read false where the local player still reads true.
            log_outline_flags(ghost, STR("ghost"));
            if (auto [controller, local_pawn] = find_local_controller_and_pawn(); local_pawn)
            {
                log_outline_flags(local_pawn, STR("local"));
            }
        }

        // Dream Breaker spawn-snapshot investigation, see DUMP_GHOST_SPAWN_VALUES's own comment.
        // Dumps the ghost right after every field above has already been set up (mesh/rotation/
        // possession/collision), plus the local player's own pawn at this same moment as a
        // same-log reference -- comparing this dump across two different saves is the actual
        // next diagnostic step.
        if constexpr (DUMP_GHOST_SPAWN_VALUES)
        {
            dump_object_property_values(ghost, STR("spawned ghost"));
            dump_object_property_values(local_pawn, STR("local pawn at ghost-spawn"));

            // 2026-08-15 follow-up: the top-level pawn dump above only ever printed WeaponMesh as
            // an object REFERENCE (same component either way) -- it never recursed into that
            // component's OWN properties. The four WeaponMesh properties already cleared
            // (bHiddenInGame/bVisible/RelativeLocation/AttachSocketName) were only ever traced
            // mid-session on an already-armed save during a live throw, never on a genuinely fresh
            // unarmed spawn -- this closes that gap by dumping WeaponMesh's own full property set
            // (not just those four) at the moment of spawn, on both the ghost and the local pawn.
            if (UObject** ghost_weapon_mesh = ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("WeaponMesh")); ghost_weapon_mesh && *ghost_weapon_mesh)
            {
                dump_object_property_values(*ghost_weapon_mesh, STR("spawned ghost WeaponMesh"));
            }
            if (UObject** local_weapon_mesh = local_pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("WeaponMesh")); local_weapon_mesh && *local_weapon_mesh)
            {
                dump_object_property_values(*local_weapon_mesh, STR("local pawn WeaponMesh at ghost-spawn"));
            }

            // Second follow-up, same day: WeaponMesh's own properties came back completely
            // identical across the 0%/100% saves (see verified.md) -- ruling out the component
            // itself as the lever entirely, not just the four originally-checked properties. The
            // one remaining unexamined object in this class's own graph is animBPref, exactly
            // where landed?/jumped?/animEquippedWeapon already live -- the most likely home for
            // whatever actually selects a weapon-visible-or-not pose/state. dump_object_property_values
            // now also handles EnumProperty/ByteProperty (previously skipped outright), so this
            // pass can catch a state-selector field it would have missed before.
            if (UObject** ghost_abp = ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref")); ghost_abp && *ghost_abp)
            {
                dump_object_property_values(*ghost_abp, STR("spawned ghost animBPref"));
            }
            if (UObject** local_abp = local_pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref")); local_abp && *local_abp)
            {
                dump_object_property_values(*local_abp, STR("local pawn animBPref at ghost-spawn"));
            }
        }
    }

    // Parses one received NDJSON line per PROTOCOL.md's wire form and upserts/erases the
    // `remotes` map accordingly. Does not reposition anything itself -- redraw happens
    // unconditionally every tick in on_update, per PROTOCOL.md's "redraw every entry currently in
    // the remote-ghost map, unconditionally" rule (network updates arrive far slower than render).
    auto Plugin::handle_bridge_line(const std::string& line, UObject* local_pawn, UObject* local_controller) -> void
    {
        std::string type = json_string_field(line, "type");
        if (type == "render_remote")
        {
            std::string player_id = json_string_field(line, "player_id");
            if (player_id.empty())
            {
                return;
            }
            double x = 0, y = 0, z = 0;
            if (!json_vec3_field(line, "position", x, y, z))
            {
                return; // state was null or malformed -- nothing to render this frame
            }
            double pitch = 0, yaw = 0, roll = 0;
            json_vec3_field(line, "orientation", pitch, yaw, roll); // best-effort, defaults to 0

            // Animation-state mirror (see verified.md's "ghost animation" entry) -- best-effort,
            // each defaults to 0 if missing (e.g. an older peer build without this field yet).
            double move_state = 0, action_state = 0, h_speed = 0, v_speed = 0, anim_jump_type = 0, movement_mode = 0;
            json_number_field(line, "move_state", move_state);
            json_number_field(line, "action_state", action_state);
            json_number_field(line, "h_speed", h_speed);
            json_number_field(line, "v_speed", v_speed);
            json_number_field(line, "anim_jump_type", anim_jump_type);
            json_number_field(line, "movement_mode", movement_mode);
            double land_count = 0, jump_count = 0;
            json_number_field(line, "land_count", land_count);
            json_number_field(line, "jump_count", jump_count);
            double afterimage_count = 0;
            json_number_field(line, "afterimage_count", afterimage_count);
            double afterimage_n = 0;
            json_number_field(line, "afterimage_n", afterimage_n);
            double capsule_half = 0;
            json_number_field(line, "capsule_half", capsule_half);
            // Trail colour -- absent for a peer on an older build, in which case the ghost simply
            // keeps whatever colour its own construction gave it (see afterimage_color_valid).
            double afterimage_color_r = 0, afterimage_color_g = 0, afterimage_color_b = 0;
            bool has_afterimage_color = json_vec3_field(line, "afterimage_color",
                                                        afterimage_color_r, afterimage_color_g, afterimage_color_b);
            double weapon_equipped_num = 0;
            json_number_field(line, "weapon_equipped", weapon_equipped_num);
            bool weapon_equipped = weapon_equipped_num != 0;
            // Bubble charged-jump flag (see the local half). Best-effort like every other extra: a
            // peer on an older build simply never sends it, leaving this false, which falls the
            // ghost back to the peer's in-bubble state -- today's behaviour, not a regression.
            double bubble_charged_num = 0;
            json_number_field(line, "bubble_charged", bubble_charged_num);
            bool bubble_charged = bubble_charged_num != 0;
            std::string outfit_mesh = json_string_field(line, "outfit_mesh"); // best-effort, empty if missing
            // Montage mirror -- see RemoteGhost::target_montage. Both best-effort: a peer on an
            // older build simply sends neither, leaving montage_count at 0 forever, which never
            // fires anything.
            std::string montage = json_string_field(line, "montage");
            double montage_count_in = 0;
            json_number_field(line, "montage_count", montage_count_in);
            double montage_stop_count_in = 0;
            json_number_field(line, "montage_stop_count", montage_stop_count_in);
            // Thrown Dream Breaker -- see RemoteGhost::target_weapon_thrown. Best-effort like every
            // other extra: a peer on an older build sends none of these, leaving weapon_thrown
            // false forever, which is exactly today's behaviour (no thrown sword rendered at all),
            // not a regression.
            double weapon_thrown_num = 0;
            json_number_field(line, "weapon_thrown", weapon_thrown_num);
            bool weapon_thrown = weapon_thrown_num != 0;
            std::string weapon_class = json_string_field(line, "weapon_class");
            double weapon_state_in = 0;
            json_number_field(line, "weapon_state", weapon_state_in);
            std::string weapon_glow = json_string_field(line, "weapon_glow");
            double recall_glow_num = 0;
            json_number_field(line, "recall_glow", recall_glow_num);
            bool recall_glow = recall_glow_num != 0;
            double weapon_x = 0, weapon_y = 0, weapon_z = 0;
            bool has_weapon_pos = json_vec3_field(line, "weapon_pos", weapon_x, weapon_y, weapon_z);
            double weapon_pitch = 0, weapon_yaw = 0, weapon_roll = 0;
            bool has_weapon_rot = json_vec3_field(line, "weapon_rot", weapon_pitch, weapon_yaw, weapon_roll);

            // Checked before ensure_ghost_spawned/ensure_ghost_hijacked, both of which insert a
            // default-constructed RemoteGhost via remotes[player_id] on their very first call for
            // a given player_id regardless of whether the spawn/hijack itself succeeds -- so this
            // is true exactly once per remote, on the call that creates its entry.
            bool is_new_remote = remotes.find(player_id) == remotes.end();

            if constexpr (SPAWN_BASED_GHOSTS)
            {
                ensure_ghost_spawned(player_id, local_pawn, local_controller);
            }
            else
            {
                ensure_ghost_hijacked(player_id, local_pawn);
            }
            auto it = remotes.find(player_id);
            if (it != remotes.end())
            {
                // Loopback ghost offset, 2026-08-14 -- user-requested, generalized from the same
                // fix in adapters/pokemon/emerald/meshghost_emerald.lua's drawRemotes(). A
                // loopback-echoed ghost (internal/relay's dev-only -loopback flag, id =
                // "<id>-ghost") otherwise renders exactly on top of the real player -- it's an
                // echo of your own position by definition -- which made it hard to visually
                // judge ghost rendering quality against the real character side by side. Nudge
                // it sideways purely for local rendering; never changes what's actually
                // sent/received over the network (target_x/y/z here is only ever a local render
                // target). Uses LOOPBACK_GHOST_OFFSET_X's 150.0 unit magnitude -- a value already
                // found usable in this game for visibly separating a test ghost from the player.
                //
                // Two genuinely different, both-valid loopback use cases, per the user
                // (2026-08-14): offset (this default) for visually judging rendering/animation
                // quality side by side, since an exact overlap makes the two impossible to tell
                // apart; zero offset for verifying the ghost actually tracks the real position
                // exactly, which an offset would obscure. Toggle by changing
                // LOOPBACK_GHOST_OFFSET_X above to 0.0 -- deliberately a plain constant, not a
                // runtime flag, since -loopback itself is already a dev-only relay flag never
                // meant to run in a real session.
                static const std::string ghost_suffix = "-ghost";
                double loopback_offset_x = 0.0;
                double loopback_offset_z = 0.0;
                if (player_id.size() >= ghost_suffix.size() &&
                    player_id.compare(player_id.size() - ghost_suffix.size(), ghost_suffix.size(), ghost_suffix) == 0)
                {
                    loopback_offset_x = LOOPBACK_GHOST_OFFSET_X;
                    loopback_offset_z = LOOPBACK_GHOST_OFFSET_Z;
                }
                it->second.target_x = x + loopback_offset_x;
                it->second.target_y = y;
                // Slide floor-sinking fix, 2026-08-15 -- applied here as a pure render-target
                // adjustment, exactly like loopback_offset_x above (target_x/y/z are only ever a
                // local render target and never change what goes on the wire).
                //
                // Measured mechanism, after a first fix attempt failed: a real slide shrinks the
                // player's capsule 65 -> 22 and drops its origin 567.2 -> 524.2, keeping the feet
                // planted. Mirroring the ghost's CapsuleHalfHeight was tried and CONFIRMED to apply
                // (readback showed 22) but did NOT fix the visual -- because the skeletal mesh
                // hangs off the capsule at a FIXED relative offset set at construction (-65), and
                // it's the real player's own crouch logic, which an unpossessed ghost never runs,
                // that adjusts that offset. So the mesh stayed 65 below a centre now at 524.
                //
                // Compensating the render Z instead puts the ghost's fixed-offset mesh at the same
                // world height as the peer's feet: ghost_z = peer_z + (STANDING_HALF - peer_half),
                // i.e. +43 during a slide, 0 when standing.
                constexpr double GHOST_STANDING_CAPSULE_HALF = 65.0;
                double slide_z_comp = 0.0;
                if (capsule_half > 0.0 && capsule_half < GHOST_STANDING_CAPSULE_HALF)
                {
                    slide_z_comp = GHOST_STANDING_CAPSULE_HALF - capsule_half;
                }
                it->second.target_z = z + slide_z_comp + loopback_offset_z;
                it->second.target_pitch = pitch;
                it->second.target_yaw = yaw;
                it->second.target_roll = roll;
                it->second.target_move_state = move_state;
                it->second.target_action_state = action_state;
                it->second.target_h_speed = h_speed;
                it->second.target_v_speed = v_speed;
                it->second.target_anim_jump_type = anim_jump_type;
                it->second.target_movement_mode = movement_mode;
                it->second.target_land_count = land_count;
                it->second.target_jump_count = jump_count;
                it->second.target_afterimage_count = afterimage_count;
                it->second.target_afterimage_spawn_n = afterimage_n;
                it->second.target_capsule_half = capsule_half;
                if (has_afterimage_color)
                {
                    it->second.target_afterimage_color[0] = static_cast<float>(afterimage_color_r);
                    it->second.target_afterimage_color[1] = static_cast<float>(afterimage_color_g);
                    it->second.target_afterimage_color[2] = static_cast<float>(afterimage_color_b);
                    it->second.afterimage_color_valid = true;
                }
                // WEAPON_SYNC_INVERT (see its own comment): deliberately store the opposite of
                // the real player's weaponEquipped? for the inversion test. Applied here, once,
                // at parse time so every downstream consumer (ghost property writes, the
                // updateWeaponEquip/changeEquippedWeapon calls, edge detection) sees the inverted
                // value consistently, rather than patching each consumer separately.
                it->second.target_weapon_equipped = WEAPON_SYNC_INVERT ? !weapon_equipped : weapon_equipped;
                it->second.target_bubble_charged = bubble_charged;
                // Empty means "no data this sample" (e.g. an older peer build, or VisualMesh/
                // SkeletalMesh unresolved that tick) -- never overwrite a known-good target with
                // an empty string, matching the same "best-effort, missing means unchanged" spirit
                // as the other optional fields above.
                if (!outfit_mesh.empty())
                {
                    it->second.target_outfit_mesh = outfit_mesh;
                }
                // Montage mirror -- unlike outfit_mesh, an empty montage IS meaningful here (it's
                // simply "nothing playing right now"), but it's the counter that drives the ghost,
                // and the counter only ever advances on a start, where the path is non-empty by
                // construction. Storing the path unconditionally keeps the pair consistent.
                it->second.target_montage = montage;
                it->second.target_montage_count = montage_count_in;
                it->second.target_montage_stop_count = montage_stop_count_in;
                // Thrown Dream Breaker. The transform is only accepted when the peer actually says
                // "thrown" AND both vectors parsed -- a half-parsed sample must not drag the prop
                // to a partly-stale position, and the peer sends zeros in these fields whenever the
                // sword is in hand, which would otherwise yank it to world origin. The loopback
                // X offset is applied for the same reason it's applied to the ghost body: on a
                // same-machine loopback the peer IS you, so without it the ghost's sword renders
                // exactly inside your own and the two can't be told apart.
                it->second.target_weapon_thrown = weapon_thrown;
                if (weapon_thrown && has_weapon_pos && has_weapon_rot)
                {
                    it->second.target_weapon_x = weapon_x + loopback_offset_x;
                    it->second.target_weapon_y = weapon_y;
                    it->second.target_weapon_z = weapon_z + loopback_offset_z;
                    it->second.target_weapon_pitch = weapon_pitch;
                    it->second.target_weapon_yaw = weapon_yaw;
                    it->second.target_weapon_roll = weapon_roll;
                    it->second.target_weapon_state = weapon_state_in;
                }
                // Never overwrite a known-good class with an empty one, same rule as outfit_mesh:
                // the peer stops sending it the moment the sword is back in hand, and the prop is
                // reused across that peer's next throw rather than re-resolved.
                if (!weapon_class.empty())
                {
                    it->second.target_weapon_class = weapon_class;
                }
                // Same "never overwrite a known-good value with an empty one" rule: the peer only
                // reports this while its sword is actually landed.
                if (!weapon_glow.empty())
                {
                    it->second.target_weapon_glow = weapon_glow;
                }
                it->second.target_recall_glow = recall_glow;
                if (is_new_remote)
                {
                    // Baseline last_seen_* to this first sample -- found in a review pass.
                    // RemoteGhost's default member initializers leave last_seen_land_count/
                    // last_seen_jump_count at 0, so a peer that joins mid-session with an
                    // already-nonzero land/jump count (they landed or jumped several times
                    // before this ghost even existed) would otherwise have
                    // target_land_count > last_seen_land_count on the very next redraw tick,
                    // firing a spurious landing/jump pulse (and the Montage_Stop it drives) the
                    // instant the ghost spawns, before the peer has actually done anything new.
                    it->second.last_seen_land_count = land_count;
                    it->second.last_seen_jump_count = jump_count;
                    // Same reason for montages: a peer who has thrown the sword six times before
                    // this ghost existed must not have throw #6 replayed at spawn.
                    it->second.last_seen_montage_count = montage_count_in;
                    it->second.last_seen_montage_stop_count = montage_stop_count_in;
                }
            }
        }
        else if (type == "despawn_remote")
        {
            std::string player_id = json_string_field(line, "player_id");
            if (!player_id.empty())
            {
                release_ghost(player_id);
                remotes.erase(player_id);
                Output::send(STR("[MeshGhostPseudo] despawned remote {}\n"), to_wide_ascii(player_id));
            }
        }
    }

    // Runs on the real game thread (registered via RegisterEngineTickPostCallback in
    // on_unreal_init) -- see this method's declaration comment in Plugin.hpp for why this split
    // exists. All actor reads/writes for the real networked path happen here.
    auto Plugin::game_thread_tick() -> void
    {
        if (!unreal_ready)
        {
            return;
        }

        // Populated below whenever the local pawn/world resolve this tick; used as the cheaper of
        // the two staleness checks below (owning_world has since been torn down, e.g. the local
        // player transitioned areas) -- a dangling pointer into a torn-down world must not be
        // dereferenced.
        UWorld* current_world = nullptr;

        auto [controller, pawn_obj] = find_local_controller_and_pawn();
        if (controller && pawn_obj)
        {
            // Bug found live 2026-08-13: this must only count while possessing the REAL player
            // pawn. The title screen's own DefaultPawn is a valid controller+pawn pair too and
            // sits there for several real seconds before "Start" -- counting from any valid pawn
            // meant the delay had already elapsed by the time real gameplay began, confirmed by
            // the log ("local world changed: pawn=BP_PlayerGoatMain_C" and "spawned ghost" firing
            // at the same timestamp, not ~5s apart).
            if (class_looks_like_player(pawn_obj))
            {
                ++ticks_since_pawn_valid;
            }
            else
            {
                ticks_since_pawn_valid = 0;
            }
            auto* pawn = static_cast<AActor*>(pawn_obj);
            FVector location = pawn->K2_GetActorLocation();
            FRotator rotation = pawn->K2_GetActorRotation();
            current_world = static_cast<UWorld*>(pawn->GetWorld());
            if (current_world != last_logged_world)
            {
                Output::send(STR("[MeshGhostPseudo] local world changed: pawn={} world_ptr={}\n"),
                             pawn->GetFullName(),
                             static_cast<void*>(current_world));
                last_logged_world = current_world;
            }


            std::string area_id;
            if (current_world)
            {
                UObject** level_ptr = current_world->GetValuePtrByPropertyNameInChain<UObject*>(STR("PersistentLevel"));
                if (level_ptr && *level_ptr)
                {
                    area_id = to_utf8((*level_ptr)->GetFullName());
                }
            }

            // Real animation state (see verified.md's "ghost animation" entry): read straight off
            // the fields the pawn's own ABP_PlayerGoat_C anim instance mirrors every tick,
            // confirmed by name via the read-only reflection dump (log_pawn_reflection_once).
            // "anim" itself stays the 7.3 placeholder -- this data travels via "extras" instead
            // (Extras is the established opaque-structured-data field, e.g. Emerald's
            // extras.gender, so no core/protocol change is needed).
            uint8_t* move_state_ptr = pawn->GetValuePtrByPropertyNameInChain<uint8_t>(STR("moveState"));
            uint8_t* action_state_ptr = pawn->GetValuePtrByPropertyNameInChain<uint8_t>(STR("actionState"));
            double* h_speed_ptr = pawn->GetValuePtrByPropertyNameInChain<double>(STR("horizontalSpeed"));
            double* v_speed_ptr = pawn->GetValuePtrByPropertyNameInChain<double>(STR("verticalSpeed"));
            uint8_t* anim_jump_type_ptr = pawn->GetValuePtrByPropertyNameInChain<uint8_t>(STR("animJumpType"));

            // Dream Breaker visibility mirror -- see RemoteGhost::target_weapon_equipped's
            // comment. Continuous "do you have the weapon" flag, confirmed via live-value trace
            // (verified.md), same shape as moveState/actionState above -- not gated behind
            // ABILITY_FIELD_TRACE, since it's now real production sync code, not diagnostics.
            bool* weapon_equipped_ptr = pawn->GetValuePtrByPropertyNameInChain<bool>(STR("weaponEquipped?"));

            // Outfit/costume mirror, added 2026-08-15 -- see RemoteGhost::target_outfit_mesh's
            // comment. Unlike weapon, no boolean flag or animBPref indirection: VisualMesh's own
            // SkeletalMesh property directly swaps to a different mesh asset per outfit, confirmed
            // via a live value-diff straddling real costume swaps (OUTFIT_TRACE, verified.md).
            // Send the asset's real object PATH -- GetFullName() returns "ClassName /Path" (e.g.
            // "SkeletalMesh /Game/Meshes/Characters/sybil_outfit_sweater.sybil_outfit_sweater",
            // confirmed by this exact string in dump_object_property_values' own output), but
            // StaticFindObject's ObjectName parameter expects just the path with no class-name
            // prefix (the same form already used for the SetViewTargetWithBlend lookup elsewhere
            // in this file) -- strip everything up to and including the one space UE always puts
            // between the class name and the path. Not gated behind OUTFIT_TRACE, real production
            // sync code now.
            std::string outfit_mesh;
            if (UObject** visual_mesh_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("VisualMesh")); visual_mesh_ptr && *visual_mesh_ptr)
            {
                if (UObject** skel_mesh_ptr = (*visual_mesh_ptr)->GetValuePtrByPropertyNameInChain<UObject*>(STR("SkeletalMesh")); skel_mesh_ptr && *skel_mesh_ptr)
                {
                    std::string full_name = to_utf8((*skel_mesh_ptr)->GetFullName());
                    size_t space_pos = full_name.find(' ');
                    outfit_mesh = (space_pos != std::string::npos) ? full_name.substr(space_pos + 1) : full_name;
                }
            }

            // Thrown Dream Breaker, local half -- see RemoteGhost::target_weapon_thrown for the
            // measured lifecycle this reads out of, and WEAPON_ACTOR_TRACE for the capture that
            // established it. Read every tick, not at a trace cadence: this is production sync.
            //
            // "Thrown" is deliberately derived from three things rather than trusted to any single
            // flag, because the obvious single flag is wrong. `weaponRef` alone does NOT mean
            // thrown -- it stays pointing at the last thrown weapon after pickup, which is exactly
            // what made the two prior observations of this field contradict each other
            // (agent_docs/verified.md). The game parks a picked-up weapon at world origin instead
            // of destroying it, so origin is the real "it's in hand" sentinel, and the equipped
            // flag agrees with it.
            bool weapon_thrown = false;
            std::string weapon_class;
            double weapon_x = 0.0, weapon_y = 0.0, weapon_z = 0.0;
            double weapon_pitch = 0.0, weapon_yaw = 0.0, weapon_roll = 0.0;
            // See RemoteGhost::target_weapon_state -- 0 in flight, 3 once landed, measured.
            int weapon_state = 0;
            // See RemoteGhost::target_weapon_glow -- non-empty only while the sword is landed.
            std::string weapon_glow;
            {
                UObject** weapon_ref_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("weaponRef"));
                UObject* weapon_ref = weapon_ref_ptr ? *weapon_ref_ptr : nullptr;
                const bool weapon_in_hand = weapon_equipped_ptr && *weapon_equipped_ptr;
                // RootComponent is the reflection-only actor test used throughout this file, in
                // place of a raw cast on an object whose type isn't guaranteed.
                if (weapon_ref && !weapon_in_hand &&
                    weapon_ref->GetValuePtrByPropertyNameInChain<UObject*>(STR("RootComponent")))
                {
                    auto* weapon_actor = static_cast<AActor*>(weapon_ref);
                    FVector weapon_loc = weapon_actor->K2_GetActorLocation();
                    const double origin_distance = std::sqrt(weapon_loc.X() * weapon_loc.X() +
                                                             weapon_loc.Y() * weapon_loc.Y() +
                                                             weapon_loc.Z() * weapon_loc.Z());
                    // MIN_PLAUSIBLE_DISTANCE is reused rather than a new constant: it already means
                    // "this transform is a real placement in the world, not an unplaced/parked
                    // near-origin default" everywhere else in this file, which is precisely the
                    // question here.
                    if (origin_distance >= MIN_PLAUSIBLE_DISTANCE)
                    {
                        FRotator weapon_rot = weapon_actor->K2_GetActorRotation();
                        weapon_thrown = true;
                        weapon_x = weapon_loc.X();
                        weapon_y = weapon_loc.Y();
                        weapon_z = weapon_loc.Z();
                        weapon_pitch = weapon_rot.GetPitch();
                        weapon_yaw = weapon_rot.GetYaw();
                        weapon_roll = weapon_rot.GetRoll();
                        // Class path sent live rather than hardcoded, per CLAUDE.md's rule against
                        // baking in a value from memory -- and it costs nothing extra, since it's
                        // only on the wire during a throw. Same "strip the class-name prefix that
                        // GetFullName() puts before the path" step as outfit_mesh, for the same
                        // StaticFindObject reason.
                        if (UClass* weapon_class_obj = weapon_ref->GetClassPrivate())
                        {
                            std::string full_name = to_utf8(weapon_class_obj->GetFullName());
                            size_t space_pos = full_name.find(' ');
                            weapon_class = (space_pos != std::string::npos) ? full_name.substr(space_pos + 1) : full_name;
                        }

                        // Production read now, not a diagnostic -- the landing trace below proved
                        // this is the field that carries the resting pose.
                        if (uint8_t* state_ptr = weapon_ref->GetValuePtrByPropertyNameInChain<uint8_t>(STR("weaponState")))
                        {
                            weapon_state = static_cast<int>(*state_ptr);
                        }

                        // The glow ring's Niagara asset, read off the peer's own landed sword
                        // rather than hardcoded from the one path we happened to observe
                        // ('/Game/VFX/Emitters/NS_WeaponIdle') -- same reasoning as weapon_class
                        // above, and it costs nothing since idleGlowVFX is non-null exactly while
                        // landed, which is exactly when the ghost needs it. Same class-name-prefix
                        // strip as every other object path this adapter sends.
                        if (UObject** glow_ptr = weapon_ref->GetValuePtrByPropertyNameInChain<UObject*>(STR("idleGlowVFX")); glow_ptr && *glow_ptr)
                        {
                            if (UObject** asset_ptr = (*glow_ptr)->GetValuePtrByPropertyNameInChain<UObject*>(STR("Asset")); asset_ptr && *asset_ptr)
                            {
                                std::string full_name = to_utf8((*asset_ptr)->GetFullName());
                                size_t space_pos = full_name.find(' ');
                                weapon_glow = (space_pos != std::string::npos) ? full_name.substr(space_pos + 1) : full_name;
                            }
                        }

                        // See WEAPON_LANDING_TRACE for what each of these is testing and why a
                        // guessed Z nudge is not an acceptable substitute for this measurement.
                        if constexpr (WEAPON_LANDING_TRACE)
                        {
                            // One-shot schema dump of the real thrown weapon. The user's read is
                            // that the prop never performs the embed/place step at all, rather than
                            // performing it into a wrong-looking pose -- which makes this a "find
                            // and call the game's own function" problem, the same shape that
                            // actually worked for the trail VFX (Spawn After Image) and the outfit
                            // mesh (SetSkeletalMeshAsset), rather than a value to mirror. This
                            // lists every function the class exposes so the real entry point is
                            // read off the game instead of guessed at by name.
                            if (!weapon_landing_reflection_dumped)
                            {
                                weapon_landing_reflection_dumped = true;
                                dump_object_reflection(weapon_ref, STR("thrown weapon"));

                                // Parameter names for the landing entry point. The glow is now
                                // known to be a NiagaraComponent running
                                // '/Game/VFX/Emitters/NS_WeaponIdle', spawned by the real sword's
                                // landing and NOT by 'Change Weapon State' (our prop's idleGlowVFX
                                // stayed null through every state call). 'checkForValidLandingPoint'
                                // is the plausible entry point, but its PropertiesSize is 1330 --
                                // far too large to call with a blindly zeroed buffer, and calling a
                                // Blueprint function with wrong parameters is not a safe experiment
                                // on a game with this file's crash history. So this dumps its real
                                // parameter list first and calls nothing.
                                if (UFunction* landing_fn = weapon_ref->GetFunctionByNameInChain(STR("checkForValidLandingPoint")))
                                {
                                    for (FProperty* param : TFieldRange<FProperty>(landing_fn, EFieldIterationFlags::None))
                                    {
                                        if (!param)
                                        {
                                            continue;
                                        }
                                        Output::send(STR("[MeshGhostPseudo] DIAG: checkForValidLandingPoint param '{}' ({}) offset={} size={}\n"),
                                                     param->GetName(), param->GetClass().GetName(),
                                                     param->GetOffset_Internal(), param->GetSize());
                                    }
                                }
                            }

                            uint8_t* state_ptr = weapon_ref->GetValuePtrByPropertyNameInChain<uint8_t>(STR("weaponState"));
                            bool* embedded_ptr = weapon_ref->GetValuePtrByPropertyNameInChain<bool>(STR("isEmbedded?"));
                            const int32_t state_now = state_ptr ? static_cast<int32_t>(*state_ptr) : -2;
                            const int32_t embedded_now = embedded_ptr ? (*embedded_ptr ? 1 : 0) : -2;

                            // The mesh-offset candidate: the direct analogue of the slide bug. Read
                            // off the actor's own SkeletalMesh component, which the property dump
                            // confirmed exists on this class.
                            double mesh_x = -99999.0, mesh_y = -99999.0, mesh_z = -99999.0;
                            if (UObject** mesh_ptr = weapon_ref->GetValuePtrByPropertyNameInChain<UObject*>(STR("SkeletalMesh")); mesh_ptr && *mesh_ptr)
                            {
                                if (FVector* rel_loc = (*mesh_ptr)->GetValuePtrByPropertyNameInChain<FVector>(STR("RelativeLocation")))
                                {
                                    mesh_x = rel_loc->X();
                                    mesh_y = rel_loc->Y();
                                    mesh_z = rel_loc->Z();
                                }
                            }

                            const bool mesh_moved = std::fabs(mesh_x - prev_local_weapon_mesh_offset[0]) > 0.01 ||
                                                    std::fabs(mesh_y - prev_local_weapon_mesh_offset[1]) > 0.01 ||
                                                    std::fabs(mesh_z - prev_local_weapon_mesh_offset[2]) > 0.01;
                            // The landed sword's glow ring, missing on the ghost (user screenshot,
                            // 2026-08-15): the real one shows a coloured ring once planted, ours
                            // shows none. `idleGlowVFX` read null in the actor's property dump, but
                            // that dump was taken mid-throw -- if it becomes non-null on landing,
                            // the glow is a component the landing spawns, and the question becomes
                            // whether our own Change Weapon State call already spawns one (and it's
                            // failing for another reason) or never gets that far. `hasLight?` is
                            // read alongside it as the other plausible gate, at no extra cost.
                            UObject** glow_ptr = weapon_ref->GetValuePtrByPropertyNameInChain<UObject*>(STR("idleGlowVFX"));
                            bool* has_light_ptr = weapon_ref->GetValuePtrByPropertyNameInChain<bool>(STR("hasLight?"));

                            // Now that the state setter is PROVEN not to spawn the glow (our prop's
                            // idleGlowVFX stayed null through every 0 -> 3 call), the practical
                            // route is to spawn the effect ourselves rather than keep hunting for
                            // whichever internal landing branch does it. That needs the actual
                            // asset, so this dumps the REAL component the moment it exists: its
                            // class says what kind of system it is (Niagara vs Cascade, which
                            // decides the spawn call), and its properties carry the asset
                            // reference to spawn. One-shot, on the first landed sword of a session.
                            if (glow_ptr && *glow_ptr && !weapon_glow_dumped)
                            {
                                weapon_glow_dumped = true;
                                dump_object_property_values(*glow_ptr, STR("real sword idleGlowVFX"));
                            }

                            if (state_now != prev_local_weapon_state || embedded_now != prev_local_weapon_embedded || mesh_moved)
                            {
                                Output::send(STR("[MeshGhostPseudo] WEAPONLAND local: weaponState={} isEmbedded={} meshRelativeLocation=({:.2f}, {:.2f}, {:.2f}) actorZ={:.1f} idleGlowVFX={} hasLight={} tick={}\n"),
                                             state_now, embedded_now, mesh_x, mesh_y, mesh_z, weapon_z,
                                             (glow_ptr && *glow_ptr) ? STR("non-null") : STR("null"),
                                             has_light_ptr ? *has_light_ptr : false,
                                             tick_count);
                                prev_local_weapon_state = state_now;
                                prev_local_weapon_embedded = embedded_now;
                                prev_local_weapon_mesh_offset[0] = mesh_x;
                                prev_local_weapon_mesh_offset[1] = mesh_y;
                                prev_local_weapon_mesh_offset[2] = mesh_z;
                            }
                        }
                    }
                }
            }

            // Recall glow, local half -- see RECALL_GLOW_ENABLED. This mirrors the game's own
            // DECISION rather than its rule: it asks "is the real effect showing right now?"
            // instead of trying to recompute "empty-handed and near a save crystal". Scanned at a
            // bounded cadence and held between scans, since it enumerates components.
            if (tick_count % RECALL_GLOW_SCAN_INTERVAL_TICKS == 0)
            {
                std::vector<UObject*> niagara_components;
                UObjectGlobals::FindAllOf(STR("NiagaraComponent"), niagara_components);
                const std::string pawn_name = to_utf8(pawn->GetName());
                bool glow_now = false;
                for (UObject* component : niagara_components)
                {
                    if (!component)
                    {
                        continue;
                    }
                    // Owned by THIS pawn -- confirmed by the capture, where the real effect is a
                    // component of the player actor rather than a world-spawned one (unlike, say,
                    // footstep dust, which belongs to WorldSettings).
                    if (to_utf8(component->GetFullName()).find(pawn_name) == std::string::npos)
                    {
                        continue;
                    }
                    UObject** asset_ptr = component->GetValuePtrByPropertyNameInChain<UObject*>(STR("Asset"));
                    if (!asset_ptr || !*asset_ptr)
                    {
                        continue;
                    }
                    if (to_utf8((*asset_ptr)->GetFullName()).find(to_utf8(RECALL_GLOW_ASSET)) == std::string::npos)
                    {
                        continue;
                    }
                    // Active, not merely present -- see component_is_active for why existence alone
                    // left a ghost glowing forever once its peer walked away from the crystal.
                    if (component_is_active(component))
                    {
                        glow_now = true;
                        break;
                    }
                }
                if (glow_now != local_recall_glow)
                {
                    // Edge-logged so "is the LOCAL side even noticing the change?" is answerable
                    // from the log instead of by staring at a ghost. If this line prints false and
                    // the ghost still glows, the bug is in the ghost's teardown, not in detection
                    // -- the two have completely different fixes.
                    Output::send(STR("[MeshGhostPseudo] RECALLGLOW local: {} at tick {}\n"),
                                 glow_now ? STR("ON") : STR("OFF"), tick_count);
                }
                local_recall_glow = glow_now;
            }

            // See VFX_WATCH for why this searches by observation rather than by name.
            if constexpr (VFX_WATCH)
            {
                if (tick_count % VFX_WATCH_INTERVAL_TICKS == 0)
                {
                    std::vector<UObject*> niagara_components;
                    UObjectGlobals::FindAllOf(STR("NiagaraComponent"), niagara_components);
                    // Collected into its own vector and appended explicitly rather than reusing the
                    // one above: whether FindAllOf clears its out-parameter is not something to
                    // assume, and getting it wrong would silently drop every Niagara result.
                    {
                        std::vector<UObject*> cascade_components;
                        UObjectGlobals::FindAllOf(STR("ParticleSystemComponent"), cascade_components);
                        niagara_components.insert(niagara_components.end(),
                                                  cascade_components.begin(), cascade_components.end());
                    }

                    // **Widened 2026-08-15 after the first run caught almost nothing** -- one
                    // component across a whole session, while the player demonstrably produced
                    // footstep dust, an afterimage trail and more. The original filter kept only
                    // components whose outer chain contains the pawn's own instance name, i.e.
                    // components PARENTED to the player. But an effect spawned at a world position
                    // rather than attached to something is owned by the level, so every
                    // location-spawned effect the player causes was invisible to it -- which is
                    // most of them, and plausibly both of the glows this was built to find.
                    //
                    // Now every live Niagara component is tracked, with the ones owned by the local
                    // pawn marked. Volume stays manageable because this logs the DIFFERENCE between
                    // samples: a level's static effects appear once at load and then say nothing.
                    // **Cascade too, not just Niagara** (2026-08-16). The "sword outline" glow has
                    // not turned up anywhere yet, and every search so far has quietly assumed
                    // Niagara because that is what the landed sword's ring happened to be. This
                    // game is perfectly capable of using the older ParticleSystemComponent as well,
                    // and an effect in that system would have been invisible to every pass so far.
                    // Checking both is the difference between "we looked and it isn't there" and
                    // "we looked in one of the two places it could be".
                    UObjectGlobals::FindAllOf(STR("ParticleSystemComponent"), niagara_components);

                    const std::string pawn_name = to_utf8(pawn->GetName());
                    std::set<std::string> live_vfx;
                    std::map<std::string, UObject*> live_components;
                    for (UObject* component : niagara_components)
                    {
                        if (!component)
                        {
                            continue;
                        }
                        const std::string full_name = to_utf8(component->GetFullName());
                        const bool on_local_pawn = full_name.find(pawn_name) != std::string::npos;
                        // The asset is the payload: it is exactly what reproducing the effect on a
                        // ghost needs, as the landed sword's glow already demonstrated. Niagara
                        // calls it 'Asset', Cascade calls it 'Template' -- try both rather than
                        // silently reporting "<no asset>" for every Cascade effect found.
                        std::string asset_name = "<no asset>";
                        UObject** asset_ptr = component->GetValuePtrByPropertyNameInChain<UObject*>(STR("Asset"));
                        if (!asset_ptr || !*asset_ptr)
                        {
                            asset_ptr = component->GetValuePtrByPropertyNameInChain<UObject*>(STR("Template"));
                        }
                        if (asset_ptr && *asset_ptr)
                        {
                            std::string asset_full = to_utf8((*asset_ptr)->GetFullName());
                            size_t space_pos = asset_full.find(' ');
                            asset_name = (space_pos != std::string::npos) ? asset_full.substr(space_pos + 1) : asset_full;
                        }
                        const std::string entry = asset_name + (on_local_pawn ? "  [ON PLAYER]  " : "  |  ") + full_name;
                        live_vfx.insert(entry);
                        live_components[entry] = component;
                    }

                    for (const std::string& entry : live_vfx)
                    {
                        if (prev_player_vfx.find(entry) == prev_player_vfx.end())
                        {
                            Output::send(STR("[MeshGhostPseudo] VFXWATCH: + APPEARED tick={} {}\n"),
                                         tick_count, to_wide_ascii(entry));

                            // **Where it is attached**, logged only on appearance. This is the
                            // other half the ghost needs and the first watcher never captured: the
                            // recall glow shipped attached to the ghost's ROOT purely because
                            // nothing said otherwise, and the user reports it sitting visibly
                            // wrong. AttachParent plus AttachSocketName say what the real effect
                            // hangs off -- a named bone socket, most likely -- and RelativeLocation
                            // says how far off it sits from there. Together they are enough to
                            // place a copy exactly, instead of adjusting an offset by eye.
                            UObject* component = live_components[entry];
                            if (!component)
                            {
                                continue;
                            }
                            std::string attach_parent = "<none>";
                            if (UObject** parent_ptr = component->GetValuePtrByPropertyNameInChain<UObject*>(STR("AttachParent")); parent_ptr && *parent_ptr)
                            {
                                attach_parent = to_utf8((*parent_ptr)->GetFullName());
                            }
                            std::string socket = "<none>";
                            if (FName* socket_ptr = component->GetValuePtrByPropertyNameInChain<FName>(STR("AttachSocketName")))
                            {
                                socket = to_utf8(socket_ptr->ToString());
                            }
                            double rel_x = 0.0, rel_y = 0.0, rel_z = 0.0;
                            if (FVector* rel_ptr = component->GetValuePtrByPropertyNameInChain<FVector>(STR("RelativeLocation")))
                            {
                                rel_x = rel_ptr->X();
                                rel_y = rel_ptr->Y();
                                rel_z = rel_ptr->Z();
                            }
                            Output::send(STR("[MeshGhostPseudo] VFXWATCH:     attach='{}' socket='{}' relativeLocation=({:.2f}, {:.2f}, {:.2f})\n"),
                                         to_wide_ascii(attach_parent), to_wide_ascii(socket),
                                         rel_x, rel_y, rel_z);
                        }
                    }
                    for (const std::string& entry : prev_player_vfx)
                    {
                        if (live_vfx.find(entry) == live_vfx.end())
                        {
                            Output::send(STR("[MeshGhostPseudo] VFXWATCH: - gone     tick={} {}\n"),
                                         tick_count, to_wide_ascii(entry));
                        }
                    }
                    prev_player_vfx = std::move(live_vfx);
                }
            }

            // Bubble charged-jump flag, local half -- see the discovery block above for why this is
            // read rather than reconstructed from a duration. Empty name = this build has no such
            // property, in which case the ghost side falls back to the peer's in-bubble state.
            bool local_bubble_charged = false;
            if (!bubble_charge_prop_name.empty())
            {
                if (bool* bc_ptr = pawn->GetValuePtrByPropertyNameInChain<bool>(bubble_charge_prop_name.c_str()))
                {
                    local_bubble_charged = *bc_ptr;
                }
            }
            // Local edge log, 2026-08-15, so "does the ghost last exactly as long as the player"
            // stops being an eyeball judgement. The ghost side already logs its own on/off edges
            // (BUBBLE ghost), so printing the LOCAL edges too makes the comparison arithmetic:
            // subtract the two durations. They should differ only by the pipeline's ~100ms
            // interpolation delay, and any real mismatch shows up as a number rather than a
            // "looked fine". This is the same reason the pole trace logs local and ghost side by
            // side rather than trusting one of them.
            if (local_bubble_charged != prev_local_bubble_charged)
            {
                prev_local_bubble_charged = local_bubble_charged;
                Output::send(STR("[MeshGhostPseudo] BUBBLE local: hasBubbleChargedJump -> {}\n"),
                             local_bubble_charged);
            }

            // Montage mirror, local half -- see RemoteGhost::target_montage. Read every tick (not
            // at the trace cadence): the whole point of the monotonic counter below is that a
            // montage shorter than the send interval still gets delivered, which only works if the
            // start is actually noticed on the tick it happens. Same object-path form as
            // outfit_mesh above, for the same StaticFindObject reason.
            std::string montage_path;
            {
                std::string montage_full_name;
                if (UObject** abp_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref")); abp_ptr && *abp_ptr)
                {
                    read_current_active_montage(*abp_ptr, montage_full_name);
                }
                if (!montage_full_name.empty() && montage_full_name != "none")
                {
                    size_t space_pos = montage_full_name.find(' ');
                    montage_path = (space_pos != std::string::npos) ? montage_full_name.substr(space_pos + 1) : montage_full_name;
                }
                // A montage ENDING is its own event -- see montage_stop_count's comment. Counted
                // whether the game let it finish or cut it short, because the two are
                // indistinguishable from out here and stopping an already-finished montage on the
                // ghost is a no-op anyway. The cut-short case is the one that matters: it's what
                // left the ghost holding a ledge-grab pose after the real player let go.
                if (montage_path.empty() && !prev_local_montage.empty())
                {
                    ++montage_stop_count;
                    if constexpr (ANIM_TRACE)
                    {
                        Output::send(STR("[MeshGhostPseudo] TRACE montage local: STOP #{} (was '{}')\n"),
                                     montage_stop_count, to_wide_ascii(prev_local_montage));
                    }
                }
                if (!montage_path.empty() && montage_path != prev_local_montage)
                {
                    ++montage_count;
                    if constexpr (ANIM_TRACE)
                    {
                        Output::send(STR("[MeshGhostPseudo] TRACE montage local: START #{} '{}'\n"),
                                     montage_count, to_wide_ascii(montage_path));
                    }
                }
                prev_local_montage = montage_path;
            }

            // Thrown-Dream-Breaker capture -- see WEAPON_ACTOR_TRACE's own comment for the four
            // questions this answers and why the existing weaponRef record is contradictory.
            if constexpr (WEAPON_ACTOR_TRACE)
            {
                UObject** weapon_ref_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("weaponRef"));
                UObject* weapon_ref = weapon_ref_ptr ? *weapon_ref_ptr : nullptr;
                const bool equipped_now = weapon_equipped_ptr && *weapon_equipped_ptr;

                // (1) Identity edge. Logged on a real change of the referenced object, not on a
                // cadence -- a throw that swaps in a freshly spawned actor is invisible to any
                // sampler, and that is precisely the fact in dispute.
                if (weapon_ref != prev_weapon_ref)
                {
                    if (weapon_ref)
                    {
                        UClass* ref_class = weapon_ref->GetClassPrivate();
                        Output::send(STR("[MeshGhostPseudo] WEAPONACTOR: weaponRef -> NON-NULL at tick {} (weaponEquipped={}) instance='{}' class='{}'\n"),
                                     tick_count,
                                     equipped_now,
                                     weapon_ref->GetFullName(),
                                     ref_class ? ref_class->GetFullName() : STR("<no class>"));
                    }
                    else
                    {
                        Output::send(STR("[MeshGhostPseudo] WEAPONACTOR: weaponRef -> NULL at tick {} (weaponEquipped={})\n"),
                                     tick_count, equipped_now);
                    }
                    prev_weapon_ref = weapon_ref;
                    weapon_actor_transform_logged = false; // a new object gets its own first sample
                }

                if (weapon_ref)
                {
                    // (4) One-shot value dump, so the answer to "what is there to sync" comes from
                    // the object's own reflected fields rather than from guessing property names --
                    // the same dump that found animEquippedWeapon after four hand-picked guesses
                    // on WeaponMesh all came back negative (verified.md).
                    if (!weapon_ref_value_dumped)
                    {
                        weapon_ref_value_dumped = true;
                        dump_object_property_values(weapon_ref, STR("weaponRef"));
                    }

                    // (2) Actor test by reflection, not by casting an object of unknown type: only
                    // actors carry a RootComponent. If this never prints, weaponRef is a component
                    // or data object and the thrown sword has to be found some other way -- which
                    // is what the sweep below exists for.
                    UObject** root_component_ptr = weapon_ref->GetValuePtrByPropertyNameInChain<UObject*>(STR("RootComponent"));
                    if (root_component_ptr)
                    {
                        auto* weapon_actor = static_cast<AActor*>(weapon_ref);
                        FVector weapon_loc = weapon_actor->K2_GetActorLocation();
                        FRotator weapon_rot = weapon_actor->K2_GetActorRotation();

                        const double dx = weapon_loc.X() - weapon_actor_last_logged_x;
                        const double dy = weapon_loc.Y() - weapon_actor_last_logged_y;
                        const double dz = weapon_loc.Z() - weapon_actor_last_logged_z;
                        const bool moved = !weapon_actor_transform_logged ||
                                           std::sqrt(dx * dx + dy * dy + dz * dz) > WEAPON_ACTOR_MOVE_EPSILON;

                        // Movement prints densely, rest prints once every LOG_INTERVAL_TICKS. The
                        // shape of the log is itself the measurement: a continuous arc means the
                        // full version (real position sync through flight) is the only faithful
                        // option, whereas a jump straight from "in hand" to a single resting
                        // position means the MVP in ideas.md is already the whole truth.
                        if (moved || tick_count % LOG_INTERVAL_TICKS == 0)
                        {
                            Output::send(STR("[MeshGhostPseudo] WEAPONACTOR: tick={} equipped={} moved={} loc=({:.1f}, {:.1f}, {:.1f}) rot=(p={:.1f}, y={:.1f}, r={:.1f})\n"),
                                         tick_count, equipped_now, moved,
                                         weapon_loc.X(), weapon_loc.Y(), weapon_loc.Z(),
                                         weapon_rot.GetPitch(), weapon_rot.GetYaw(), weapon_rot.GetRoll());
                        }
                        if (moved)
                        {
                            weapon_actor_last_logged_x = weapon_loc.X();
                            weapon_actor_last_logged_y = weapon_loc.Y();
                            weapon_actor_last_logged_z = weapon_loc.Z();
                            weapon_actor_transform_logged = true;
                        }
                    }
                    else if (tick_count % LOG_INTERVAL_TICKS == 0)
                    {
                        Output::send(STR("[MeshGhostPseudo] WEAPONACTOR: weaponRef is non-null but has no reflected RootComponent -- not an actor.\n"));
                    }
                }

                // (3) Arm the fallback sweep on a real throw (weapon leaves the hand), then run it
                // a fraction of a second later, while the sword is genuinely airborne.
                if (prev_weapon_equipped_for_actor_trace && !equipped_now)
                {
                    weapon_actor_sweep_due_tick = tick_count + WEAPON_ACTOR_SWEEP_DELAY_TICKS;
                    Output::send(STR("[MeshGhostPseudo] WEAPONACTOR: throw detected at tick {} -- world sweep armed for tick {}.\n"),
                                 tick_count, weapon_actor_sweep_due_tick);
                }
                prev_weapon_equipped_for_actor_trace = equipped_now;

                if (weapon_actor_sweep_due_tick != 0 && tick_count >= weapon_actor_sweep_due_tick)
                {
                    weapon_actor_sweep_due_tick = 0;
                    std::vector<UObject*> all_actors;
                    UObjectGlobals::FindAllOf(STR("Actor"), all_actors);
                    size_t hits = 0;
                    for (UObject* candidate : all_actors)
                    {
                        if (!candidate)
                        {
                            continue;
                        }
                        UClass* candidate_class = candidate->GetClassPrivate();
                        // Name match on the class AND the instance, lowercased, against the words a
                        // Pseudoregalia weapon actor could plausibly be named. Deliberately loose:
                        // this is a discovery sweep whose output a human reads, so a few false
                        // positives cost nothing and a missed real hit costs the whole capture.
                        std::string class_name = candidate_class ? to_utf8(candidate_class->GetName()) : std::string();
                        std::string instance_name = to_utf8(candidate->GetName());
                        std::string haystack = class_name + " " + instance_name;
                        std::transform(haystack.begin(), haystack.end(), haystack.begin(),
                                       [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
                        if (haystack.find("weapon") == std::string::npos &&
                            haystack.find("breaker") == std::string::npos &&
                            haystack.find("sword") == std::string::npos &&
                            haystack.find("blade") == std::string::npos &&
                            haystack.find("throw") == std::string::npos)
                        {
                            continue;
                        }
                        ++hits;
                        Output::send(STR("[MeshGhostPseudo] WEAPONACTOR SWEEP: instance='{}' class='{}'\n"),
                                     candidate->GetFullName(),
                                     candidate_class ? candidate_class->GetFullName() : STR("<no class>"));
                    }
                    Output::send(STR("[MeshGhostPseudo] WEAPONACTOR SWEEP: {} weapon-like actor(s) out of {} live actors at tick {}.\n"),
                                 hits, all_actors.size(), tick_count);
                }
            }

            if constexpr (WEAPON_SYNC_TRACE)
            {
                if (tick_count % LOG_INTERVAL_TICKS == 0)
                {
                    UObject** weapon_ref_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("weaponRef"));
                    UObject** weapon_mesh_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("WeaponMesh"));
                    Output::send(STR("[MeshGhostPseudo] TRACE weapon local: weaponEquipped={} weaponRef={} WeaponMesh={}\n"),
                                 weapon_equipped_ptr ? *weapon_equipped_ptr : false,
                                 (weapon_ref_ptr && *weapon_ref_ptr) ? STR("non-null") : STR("null"),
                                 (weapon_mesh_ptr && *weapon_mesh_ptr) ? STR("non-null") : STR("null"));

                    // Follow-up to the WeaponMesh schema dump (see plan file / verified.md):
                    // found the stock engine visibility surface (bHiddenInGame, bVisible,
                    // SetHiddenInGame, SetVisibility) on WeaponMesh itself. That dump only proved
                    // the fields exist -- this traces their real live VALUES on the LOCAL player
                    // across a throw/pickup, the same "schema is not behavior" discipline every
                    // other field in this investigation has needed. Ground truth first, before
                    // touching the ghost at all.
                    if (weapon_mesh_ptr && *weapon_mesh_ptr)
                    {
                        bool* hidden_in_game_ptr = (*weapon_mesh_ptr)->GetValuePtrByPropertyNameInChain<bool>(STR("bHiddenInGame"));
                        bool* visible_ptr = (*weapon_mesh_ptr)->GetValuePtrByPropertyNameInChain<bool>(STR("bVisible"));
                        Output::send(STR("[MeshGhostPseudo] TRACE weapon local WeaponMesh: bHiddenInGame={} bVisible={}\n"),
                                     hidden_in_game_ptr ? *hidden_in_game_ptr : false,
                                     visible_ptr ? *visible_ptr : false);

                        // Both visibility flags confirmed static (verified.md) -- next hypothesis
                        // per the user's own instinct: WeaponMesh stays visible and just moves
                        // between an in-hand and a holstered socket, rather than being hidden.
                        // RelativeLocation is the standard USceneComponent property (same family
                        // already confirmed readable on this exact SDK via RelativeRotation/
                        // RelativeScale3D elsewhere in this file, e.g. VisualMesh) -- read here by
                        // analogy to an already-proven-present sibling property, not a blind guess
                        // of an unconfirmed name; nullptr-safe if it doesn't resolve on WeaponMesh
                        // specifically. A visible jump in this value across a throw/pickup would
                        // directly confirm the socket-swap theory without needing to find a real
                        // "AttachSocketName"-style property/function by name first.
                        if (FVector* rel_loc = (*weapon_mesh_ptr)->GetValuePtrByPropertyNameInChain<FVector>(STR("RelativeLocation")))
                        {
                            Output::send(STR("[MeshGhostPseudo] TRACE weapon local WeaponMesh RelativeLocation=({}, {}, {})\n"),
                                         rel_loc->X(), rel_loc->Y(), rel_loc->Z());
                        }
                        else
                        {
                            Output::send(STR("[MeshGhostPseudo] TRACE weapon local WeaponMesh has no reflected RelativeLocation property.\n"));
                        }

                        // RelativeLocation confirmed static at (0,0,0) (verified.md) -- doesn't
                        // disprove socket-swap on its own, since a relative offset can legitimately
                        // stay zero across two different sockets. Found the real answer via the
                        // schema dump instead: WeaponMesh has a genuine 'AttachSocketName'
                        // (NameProperty) plus a full attach API (GetAttachSocketName,
                        // GetSocketTransform, K2_AttachToComponent) -- tracing its real live value
                        // now, the direct test of the socket-swap theory.
                        if (FName* attach_socket = (*weapon_mesh_ptr)->GetValuePtrByPropertyNameInChain<FName>(STR("AttachSocketName")))
                        {
                            Output::send(STR("[MeshGhostPseudo] TRACE weapon local WeaponMesh AttachSocketName='{}'\n"), attach_socket->ToString());
                        }
                        else
                        {
                            Output::send(STR("[MeshGhostPseudo] TRACE weapon local WeaponMesh has no reflected AttachSocketName property.\n"));
                        }

                        // New for the inversion-test run: all four properties checked above are
                        // visibility/attachment -- the mesh ASSET reference itself was never
                        // checked. 'SkeletalMesh' is the stock USkeletalMeshComponent property,
                        // read here by the same analogy discipline as RelativeLocation above (this
                        // file already confirmed the UStaticMeshComponent sibling 'StaticMesh'
                        // works as a direct-property read elsewhere in this phase); nullptr-safe if
                        // WeaponMesh isn't actually a skeletal mesh component on this build.
                        if (UObject** skel_mesh_ptr = (*weapon_mesh_ptr)->GetValuePtrByPropertyNameInChain<UObject*>(STR("SkeletalMesh")))
                        {
                            Output::send(STR("[MeshGhostPseudo] TRACE weapon local WeaponMesh SkeletalMesh={}\n"),
                                         (skel_mesh_ptr && *skel_mesh_ptr) ? STR("non-null") : STR("null"));
                        }
                        else
                        {
                            Output::send(STR("[MeshGhostPseudo] TRACE weapon local WeaponMesh has no reflected SkeletalMesh property.\n"));
                        }
                    }
                }
            }

            // "Stuck flying after jump" fix (see RemoteGhost::target_movement_mode's comment):
            // also mirror the real CharacterMovementComponent's own MovementMode byte, confirmed
            // via reflection to be a real property on this build's stock component.
            uint8_t movement_mode = 0;
            bool orient_rotation_to_movement = false;
            if (UObject** movement_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("CharacterMovement")); movement_ptr && *movement_ptr)
            {
                if (uint8_t* movement_mode_ptr = (*movement_ptr)->GetValuePtrByPropertyNameInChain<uint8_t>(STR("MovementMode")))
                {
                    movement_mode = *movement_mode_ptr;
                }
                // Facing-direction investigation, 2026-08-13: if this is true, the ghost's own
                // CharacterMovementComponent may re-derive rotation from its own (near-zero, since
                // it's teleported not driven by real input) internal velocity every tick, fighting
                // our explicit K2_SetActorLocationAndRotation yaw write -- confirmed as a real
                // property via reflection (log_pawn_reflection_once's CharacterMovement dump), not
                // guessed at. Checking the real player's own value here, not yet acted on.
                if (bool* orient_ptr = (*movement_ptr)->GetValuePtrByPropertyNameInChain<bool>(STR("bOrientRotationToMovement")))
                {
                    orient_rotation_to_movement = *orient_ptr;
                }
            }

            // Redone landed?/jumped? pulse mirror (see PULSE_HOLD_TICKS's comment): these live on
            // animBPref, not the pawn -- read_animbp_bool does the extra hop. Edge-detected against
            // the previous tick's raw value so a pulse held true for more than one tick (plausible
            // at 60Hz) is still counted once per real landing/jump, not once per tick it reads true.
            bool landed_now = read_animbp_bool(pawn, STR("landed?"));
            bool jumped_now = read_animbp_bool(pawn, STR("jumped?"));
            if (landed_now && !prev_landed_raw)
            {
                ++landed_count;
            }
            if (jumped_now && !prev_jumped_raw)
            {
                ++jumped_count;
            }
            prev_landed_raw = landed_now;
            prev_jumped_raw = jumped_now;

            // Health trace -- see HEALTH_TRACE's own comment. Candidate names are tried in order and
            // the first that resolves is used; which one won is logged once, so the choice is
            // evidence rather than an assumption. Both int and double variants are attempted since
            // this build's health could plausibly be either.
            if constexpr (HEALTH_TRACE)
            {
                static const wchar_t* HEALTH_NAMES[] = {
                    STR("currentHealth"), STR("health"), STR("Health"), STR("hp"), STR("HP"),
                    STR("currentHP"), STR("healthPoints"), STR("currentHitPoints"),
                };
                double local_health = -1.0;
                const wchar_t* resolved_name = nullptr;
                for (const wchar_t* name : HEALTH_NAMES)
                {
                    if (double* d_ptr = pawn->GetValuePtrByPropertyNameInChain<double>(name))
                    {
                        local_health = *d_ptr;
                        resolved_name = name;
                        break;
                    }
                    if (int32_t* i_ptr = pawn->GetValuePtrByPropertyNameInChain<int32_t>(name))
                    {
                        local_health = static_cast<double>(*i_ptr);
                        resolved_name = name;
                        break;
                    }
                }
                if (!health_names_logged)
                {
                    health_names_logged = true;
                    if (resolved_name)
                    {
                        Output::send(STR("[MeshGhostPseudo] TRACE health: resolved local health property '{}' = {}\n"),
                                     resolved_name, local_health);
                    }
                    else
                    {
                        Output::send(STR("[MeshGhostPseudo] WARNING: TRACE health could not resolve ANY candidate health property on the local pawn -- the enemy-damage test will have to rely on what is seen on screen.\n"));
                    }
                }
                if (resolved_name && std::fabs(local_health - prev_local_health) > 0.0001)
                {
                    Output::send(STR("[MeshGhostPseudo] TRACE health: LOCAL {} -> {} (tick={})\n"),
                                 prev_local_health, local_health, tick_count);
                    prev_local_health = local_health;
                }
            }

            // Capsule half-height, read once per tick and used for two things: the real-slide
            // signal below, and the floor-sinking fix on the ghost side (see
            // RemoteGhost::target_capsule_half). Measured values on this build: 65 standing,
            // 22 while sliding.
            constexpr float SLIDE_CAPSULE_THRESHOLD = 50.0f;
            float local_capsule_half = 0.0f;
            if (UObject** local_cap_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("CapsuleComponent")); local_cap_ptr && *local_cap_ptr)
            {
                if (float* half_ptr = (*local_cap_ptr)->GetValuePtrByPropertyNameInChain<float>(STR("CapsuleHalfHeight")))
                {
                    local_capsule_half = *half_ptr;
                }
            }

            // Trail-VFX pulse trigger -- see afterimage_count's own comment in Plugin.hpp. Mirrors
            // the game's own 'afterImagesToSpawn' decision rather than inferring one from
            // actionState: the game's timer loop counts this DOWN as it spawns, so any INCREASE is
            // the game starting a fresh burst, and its value is the true burst size. Cannot
            // false-positive on a turn-around or a plain backflip by construction, because those
            // are moments the game itself never sets it.
            {
                int32_t* to_spawn_ptr = pawn->GetValuePtrByPropertyNameInChain<int32_t>(STR("afterImagesToSpawn"));
                int32_t to_spawn_now = to_spawn_ptr ? *to_spawn_ptr : 0;

                // Trigger A -- the game's own counted-burst decision. Cannot false-positive, but a
                // 12k-tick coverage capture recorded ZERO of these across a session full of real
                // slides, so this path alone covers almost nothing: the slide trail is spawned some
                // other way entirely. Kept because when it does fire it is authoritative, and it
                // carries the real burst size.
                bool burst_edge = (to_spawn_now > prev_local_afterimages_to_spawn);

                // Trigger B -- real-slide edge, **corrected 2026-08-15 by a plain-slide-only
                // capture**. Two earlier guesses were wrong: actionState==18 alone (also fires on a
                // turn-around skid) and actionState==18 && animJumpType==13 (that signature belongs
                // to the skid and to the slide that PRECEDES a backflip, and never appears during a
                // plain slide at all -- it fired zero times across a session of real slides).
                //
                // The measured truth: a plain slide is actionState==1 with the capsule SHRUNK from
                // 65 to 22, four runs of exactly 87 ticks each. Keying on the capsule rather than
                // an enum is deliberate -- the shrink is a physical fact of the move, whereas the
                // enums demonstrably overlap between moves and have burned three attempts now.
                uint8_t action_state_now = action_state_ptr ? *action_state_ptr : 0;
                uint8_t anim_jump_type_now = anim_jump_type_ptr ? *anim_jump_type_ptr : 0;
                // **Crouch exclusion, added 2026-08-15 from a live measurement** (user-reported:
                // the ghost trailed afterimages while crouching, which it must not). A crouch and a
                // slide are INDISTINGUISHABLE on the two fields you'd reach for first -- both read
                // capsule=22.0 (identical, not merely similar) and both set bIsCrouched=true -- so
                // tightening SLIDE_CAPSULE_THRESHOLD would have changed nothing and gating on
                // bIsCrouched would have killed the real slide trail outright. Measured across 3
                // crouches and 5 slides in one capture, moveState separates them cleanly:
                // crouch is moveState==2, slide is moveState==0. Written as "not the crouch state"
                // rather than "is the slide state" deliberately -- an unrecognised future state
                // then still gets a trail (today's behaviour) instead of silently losing one.
                constexpr uint8_t CROUCH_MOVE_STATE = 2;
                uint8_t move_state_now = move_state_ptr ? *move_state_ptr : 0;
                bool real_slide_now = (local_capsule_half > 0.0f && local_capsule_half < SLIDE_CAPSULE_THRESHOLD &&
                                       move_state_now != CROUCH_MOVE_STATE);
                bool slide_edge = (real_slide_now && !prev_local_sliding);


                // Re-fire while the slide is HELD, not only on entry -- see
                // last_slide_refire_tick's comment in Plugin.hpp. A real slide runs 24-57 ticks
                // (measured), and a single 5-image burst at the start leaves the ghost's trail
                // visibly shorter than the real player's. ~12 ticks is roughly a third of a short
                // slide at this build's measured ~150Hz, so a typical slide gets a few overlapping
                // bursts rather than one. Tune by eye; it cannot false-positive on a turn-around
                // because that skid never sets ajt=13.
                constexpr uint64_t SLIDE_REFIRE_INTERVAL_TICKS = 12;
                // Cut re-fires off partway through the slide -- see slide_start_tick's comment.
                // A slide runs a consistent 87 ticks; stopping new spawns around the halfway mark
                // lets the last images finish near the slide's own end rather than ~0.5-1s later
                // (user-observed). Tune this, not the interval, if the tail is still long: it
                // controls WHEN the last image spawns, which is what sets the overhang.
                constexpr uint64_t SLIDE_REFIRE_WINDOW_TICKS = 40;
                if (slide_edge)
                {
                    slide_start_tick = tick_count;
                }
                bool within_spawn_window = (tick_count - slide_start_tick) < SLIDE_REFIRE_WINDOW_TICKS;
                bool slide_refire = real_slide_now && !slide_edge && within_spawn_window &&
                                    (tick_count - last_slide_refire_tick) >= SLIDE_REFIRE_INTERVAL_TICKS;
                if (slide_edge || slide_refire)
                {
                    last_slide_refire_tick = tick_count;
                }

                // The bubble effect used to be approximated here by spawning afterimages, under two
                // triggers (in-bubble, and a post-jump window). **Both are gone as of 2026-08-15 --
                // superseded, not disabled.** They were the wrong mechanism twice over: the real
                // effect is the game's own `StartBubbleJumpFlash`, driven by its own
                // `hasBubbleChargedJump` flag, and the ghost now mirrors that directly in
                // tickRenders -- confirmed live to match the real player to within 0.01s across all
                // three cases including a negative control. Spawned afterimages also read as a
                // constant glow where the real effect flashes, and no window constant could ever
                // have fixed that. The full story, and the two guessed windows that failed on the
                // way, are in verified.md and pitfalls.md; the code is not kept as a fallback
                // because a wrong-looking effect is not a useful fallback for a correct one.

                // Superseded by the observed-spawn trigger below (see AFTERIMAGE_TRIGGER_OBSERVED).
                // Kept behind the flag rather than deleted only until the observed path has been
                // watched live; a reconstruction that fires at the wrong time is not a useful
                // fallback for one that mirrors the real thing, so this should go once confirmed.
                if (!AFTERIMAGE_TRIGGER_OBSERVED && !AFTERIMAGE_TRIGGER_FROM_OBSERVATION &&
                    (burst_edge || slide_edge || slide_refire))
                {
                    // Prefer the game's own count when it actually supplied one; otherwise use the
                    // real observed burst size (5, measured -- the previously hardcoded 6 left
                    // extra afterimages lingering).
                    const int32_t burst_n = burst_edge ? to_spawn_now : 5;
                    if constexpr (AFTERIMAGE_OBSERVE_COLOR)
                    {
                        // Hold the wire event back by a few ticks so it can carry the colour the
                        // game actually used -- see AFTERIMAGE_COLOR_OBSERVE_DELAY_TICKS. The
                        // increment happens in the observe block in tickLocal, not here.
                        //
                        // If a previous burst is still waiting, emit it now rather than dropping it:
                        // a lost burst is a visibly shorter trail, which is the exact symptom this
                        // area has already regressed on once.
                        //
                        // **This is the COMMON path, not the rare one, and forgetting to latch the
                        // colour here made the blue disappear entirely (found 2026-08-16 from the
                        // log's `off=` column: bursts were being cut short at 4-10 ticks against a
                        // 20-tick window, because the next trigger kept arriving first).** An
                        // earlier version incremented the counter here without applying the colour
                        // the window had already observed, so on every truncated burst -- i.e. very
                        // nearly all of them -- the observation was thrown away.
                        //
                        // Emitting must therefore be ONE operation wherever it happens. The two
                        // sites diverging is precisely how the colour got dropped, so this
                        // deliberately mirrors the emit in the observe block: latch first, then
                        // increment, and never one without the other.
                        if (afterimage_color_burst_pending)
                        {
                            // Same rule as the observe block's emit: this burst's own colour if it
                            // saw one, otherwise the baseline -- NEVER the previous burst's colour.
                            // Uses the baseline captured on the last tick because this runs before
                            // this tick's pawn read; that value is the game's constant normal trail
                            // colour, so a one-tick-old copy is equivalent.
                            if (afterimage_color_burst_have)
                            {
                                latched_afterimage_color[0] = afterimage_color_burst_color[0];
                                latched_afterimage_color[1] = afterimage_color_burst_color[1];
                                latched_afterimage_color[2] = afterimage_color_burst_color[2];
                                afterimage_have_observed_color = true;
                            }
                            else if (last_pawn_baseline_color_valid)
                            {
                                latched_afterimage_color[0] = last_pawn_baseline_color[0];
                                latched_afterimage_color[1] = last_pawn_baseline_color[1];
                                latched_afterimage_color[2] = last_pawn_baseline_color[2];
                                afterimage_have_observed_color = true;
                            }
                            if (afterimage_color_burst_logged < AFTERIMAGE_COLOR_BURST_LOG_COUNT)
                            {
                                ++afterimage_color_burst_logged;
                                Output::send(STR("[MeshGhostPseudo] AFTERIMAGE_BURST: cut off={} scans={} newTotal={} color=({:.3f}, {:.3f}, {:.3f}) have={} special={} n={} tick={}\n"),
                                             tick_count - afterimage_color_burst_tick,
                                             afterimage_color_burst_scans, afterimage_color_burst_new_total,
                                             afterimage_color_burst_color[0], afterimage_color_burst_color[1],
                                             afterimage_color_burst_color[2], afterimage_color_burst_have,
                                             afterimage_color_burst_special, afterimage_color_burst_n, tick_count);
                            }
                            ++afterimage_count;
                            afterimage_spawn_n = afterimage_color_burst_n;
                        }
                        afterimage_color_burst_pending = true;
                        afterimage_color_burst_tick = tick_count;
                        afterimage_color_burst_next_scan_tick = tick_count + AFTERIMAGE_COLOR_OBSERVE_DELAY_TICKS;
                        afterimage_color_burst_n = burst_n;
                        // Per-burst accumulators start empty, so one burst's colour can never carry
                        // into the next -- which is the bug this window exists to fix. The colour
                        // array is cleared too, not just its validity flag, so a log line can never
                        // show a stale colour beside have=false and read as though it meant it.
                        afterimage_color_burst_have = false;
                        afterimage_color_burst_special = false;
                        afterimage_color_burst_new_total = 0;
                        afterimage_color_burst_scans = 0;
                        afterimage_color_burst_color[0] = 0.0f;
                        afterimage_color_burst_color[1] = 0.0f;
                        afterimage_color_burst_color[2] = 0.0f;
                    }
                    else
                    {
                        ++afterimage_count;
                        afterimage_spawn_n = burst_n;
                    }
                    if constexpr (TRAIL_TRIGGER_TRACE)
                    {
                        Output::send(STR("[MeshGhostPseudo] TRACE trailTrigger: burst_edge={} slide_edge={} slide_refire={} n={} count={} actionState={} animJumpType={} moveState={}\n"),
                                     burst_edge, slide_edge, slide_refire,
                                     afterimage_spawn_n, afterimage_count,
                                     static_cast<int>(action_state_now), static_cast<int>(anim_jump_type_now),
                                     move_state_ptr ? static_cast<int>(*move_state_ptr) : -1);
                    }
                }
                prev_local_afterimages_to_spawn = to_spawn_now;
                prev_local_sliding = real_slide_now;

                // Bubble CHARGED-JUMP flag discovery, 2026-08-15. The flash mirror works in the
                // bubble and correctly stays off when the effect already expired, but does not
                // survive leaving the bubble WHILE active -- the peer's in-bubble state ends and
                // takes the flash with it, where the real rule (user) is "you keep it if it didn't
                // go away inside of the bubble", until the boost or landing.
                //
                // **Do not reach for another tick window.** Two were tried and both were wrong for
                // the same reason: the length is the game's business, not ours. `BP_PlayerGoatMain_C`
                // exposes `changeBubbleChargedJump(hasBubbleChargedJump: bool)`, and a Blueprint
                // "change<X>" event conventionally sets a variable of that name -- so the flag very
                // likely exists to be READ, which turns this from a duration to mirror into a
                // boolean to copy, exact by construction and ending exactly when the game says.
                //
                // Resolved by SEARCH rather than by assuming the name: this logs every bool property
                // whose name mentions a bubble or a charge, then uses the first, so the real name is
                // visible in the log instead of a guess silently failing. Falls back to the
                // in-bubble state if nothing matches, which is today's behaviour and already right
                // for two of the three cases.
                if (!bubble_charge_prop_searched && class_looks_like_player(pawn))
                {
                    bubble_charge_prop_searched = true;
                    if (UClass* pawn_class = pawn->GetClassPrivate())
                    {
                        for (FProperty* property : TFieldRange<FProperty>(pawn_class, EFieldIterationFlags::Default))
                        {
                            if (!property || property->GetClass().GetName() != STR("BoolProperty"))
                            {
                                continue;
                            }
                            StringType pname = property->GetName();
                            if (pname.find(STR("ubble")) == StringType::npos &&
                                pname.find(STR("harged")) == StringType::npos)
                            {
                                continue;
                            }
                            Output::send(STR("[MeshGhostPseudo] DIAG bubbleFlag: candidate bool property '{}'\n"), pname);
                            if (bubble_charge_prop_name.empty())
                            {
                                bubble_charge_prop_name = pname;
                            }
                        }
                    }
                    Output::send(STR("[MeshGhostPseudo] DIAG bubbleFlag: using '{}' (empty = none found, falling back to in-bubble state)\n"),
                                 bubble_charge_prop_name.empty() ? StringType(STR("<none>")) : bubble_charge_prop_name);
                }

                // BLINK_FX_SEARCH -- one-shot, see the flag's own comment. Fires on the first tick
                // the pawn is valid rather than waiting for a bubble: the function list is a
                // property of the CLASS, not of the moment, so there is nothing to be gained by
                // making the user reach a bubble first.
                if constexpr (BLINK_FX_SEARCH)
                {
                    // **class_looks_like_player guard, added after the first run wasted itself.**
                    // Without it this latched on the TITLE SCREEN's transient DefaultPawn
                    // (`Class /Script/Engine.DefaultPawn` -- which of course has no blink/timeline
                    // functions), set the one-shot flag, and never ran again on the real pawn. This
                    // file already carries that guard for exactly this hazard (see its own comment,
                    // written after the title-screen DefaultPawn caused a spawn crash) -- a one-shot
                    // that can fire before the real pawn exists MUST use it.
                    if (!blink_fx_search_done && class_looks_like_player(pawn))
                    {
                        blink_fx_search_done = true;
                        dump_functions_matching(pawn, STR("local pawn (blink/timeline search)"),
                                                {STR("link"), STR("imeline"), STR("ubble"), STR("lash"),
                                                 STR("olour"), STR("olor"), STR("aterial"), STR("cala")});
                        // The Timeline's own component is the other half: a UTimelineComponent
                        // exposes Play/Stop/SetPlaybackPosition, so if the pawn holds one by name
                        // that is the callable path. Object-typed properties whose name mentions a
                        // timeline are listed here with their real class, which says directly
                        // whether it is a component we can reach or an inlined graph construct.
                        if (UClass* pawn_class = pawn->GetClassPrivate())
                        {
                            for (FProperty* property : TFieldRange<FProperty>(pawn_class, EFieldIterationFlags::Default))
                            {
                                if (!property)
                                {
                                    continue;
                                }
                                StringType pname = property->GetName();
                                if (pname.find(STR("imeline")) == StringType::npos &&
                                    pname.find(STR("link")) == StringType::npos)
                                {
                                    continue;
                                }
                                StringType ptype = property->GetClass().GetName();
                                StringType detail = STR("<not an object property>");
                                if (ptype == STR("ObjectProperty"))
                                {
                                    UObject** ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(pname.c_str());
                                    detail = (ptr && *ptr && (*ptr)->GetClassPrivate())
                                                 ? (*ptr)->GetClassPrivate()->GetFullName()
                                                 : StringType(STR("<null>"));
                                }
                                Output::send(STR("[MeshGhostPseudo] DIAG blinkSearch: property '{}' ({}) -> {}\n"),
                                             pname, ptype, detail);
                            }
                        }
                    }
                }

                // POLE_ROTATION_TRACE -- see the flag's own comment for what each outcome means.
                if constexpr (POLE_ROTATION_TRACE)
                {
                    constexpr uint8_t FLYING_MOVEMENT_MODE = 5;
                    if (movement_mode == FLYING_MOVEMENT_MODE)
                    {
                        double vm_yaw = -9999.0;
                        if (UObject** vm_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("VisualMesh")); vm_ptr && *vm_ptr)
                        {
                            if (FRotator* vm_rot = (*vm_ptr)->GetValuePtrByPropertyNameInChain<FRotator>(STR("RelativeRotation")))
                            {
                                vm_yaw = vm_rot->GetYaw();
                            }
                        }
                        // Log on CHANGE, at 1-degree/1-unit granularity, so a slow spin still
                        // registers but a stationary hang doesn't repeat forever.
                        int yaw_q = static_cast<int>(rotation.GetYaw());
                        int vm_yaw_q = static_cast<int>(vm_yaw);
                        int x_q = static_cast<int>(location.X());
                        int y_q = static_cast<int>(location.Y());
                        if (!pole_trace_initialized || yaw_q != pole_trace_prev_yaw ||
                            vm_yaw_q != pole_trace_prev_vm_yaw || x_q != pole_trace_prev_x || y_q != pole_trace_prev_y)
                        {
                            pole_trace_initialized = true;
                            pole_trace_prev_yaw = yaw_q;
                            pole_trace_prev_vm_yaw = vm_yaw_q;
                            pole_trace_prev_x = x_q;
                            pole_trace_prev_y = y_q;
                            Output::send(STR("[MeshGhostPseudo] POLE local tick={} moveState={} actorYaw={:.1f} visualMeshYaw={:.1f} x={:.1f} y={:.1f}\n"),
                                         tick_count,
                                         move_state_ptr ? static_cast<int>(*move_state_ptr) : -1,
                                         rotation.GetYaw(), vm_yaw, location.X(), location.Y());
                        }
                    }
                    else
                    {
                        pole_trace_initialized = false;
                    }
                }

                // Coverage capture -- see TRAIL_COVERAGE_TRACE's own comment. Deliberately logs
                // afterImagesToSpawn on EVERY active tick, not just on a change, so a move that
                // produces a real afterimage without ever touching that field is visible as
                // "trail seen on screen, but this column never moved" rather than as silence.
                if constexpr (TRAIL_COVERAGE_TRACE)
                {
                    bool doing_something = (move_state_ptr && *move_state_ptr != 0) ||
                                           (action_state_ptr && *action_state_ptr != 0) ||
                                           (movement_mode != 1) ||
                                           (h_speed_ptr && *h_speed_ptr > 1.0) ||
                                           to_spawn_now > 0;
                    if (doing_something)
                    {
                        // Capsule half-height included UNGATED, 2026-08-15. An earlier version
                        // logged this only on the slide edge -- which never fires for a plain
                        // slide, the exact case being diagnosed, so it captured nothing. Gating a
                        // diagnostic behind the trigger you are trying to debug is a design error;
                        // this records it on every active tick instead, so the sinking-into-the-
                        // floor moment is always covered regardless of which trigger does or
                        // doesn't fire.
                        float local_half = -1.0f;
                        if (UObject** cap_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("CapsuleComponent")); cap_ptr && *cap_ptr)
                        {
                            if (float* half_ptr = (*cap_ptr)->GetValuePtrByPropertyNameInChain<float>(STR("CapsuleHalfHeight")))
                            {
                                local_half = *half_ptr;
                            }
                        }
                        bool* crouched_ptr = pawn->GetValuePtrByPropertyNameInChain<bool>(STR("bIsCrouched"));
                        Output::send(STR("[MeshGhostPseudo] TRACE trailCoverage: tick={} toSpawn={} moveState={} actionState={} animJumpType={} movementMode={} hSpeed={:.0f} vSpeed={:.0f} halfHeight={:.1f} crouched={} z={:.1f}\n"),
                                     tick_count,
                                     to_spawn_now,
                                     move_state_ptr ? static_cast<int>(*move_state_ptr) : -1,
                                     action_state_ptr ? static_cast<int>(*action_state_ptr) : -1,
                                     anim_jump_type_ptr ? static_cast<int>(*anim_jump_type_ptr) : -1,
                                     static_cast<int>(movement_mode),
                                     h_speed_ptr ? *h_speed_ptr : -1.0,
                                     v_speed_ptr ? *v_speed_ptr : -1.0,
                                     local_half,
                                     crouched_ptr ? *crouched_ptr : false,
                                     location.Z());
                    }
                }
            }

            // Diagnostic-only, 2026-08-15 trail-VFX investigation (see prev_spawn_tracking_particles'
            // own comment in Plugin.hpp): edge-detect 'spawnTrackingParticles?' every tick, gated by
            // ABILITY_FIELD_TRACE, so an onset/offset print lands regardless of how short the real
            // slide/ultra-hop window is -- the periodic ABILITY_FIELD_TRACE line below samples at
            // ~2s and could miss it entirely.
            if constexpr (ABILITY_FIELD_TRACE)
            {
                bool spawn_tracking_particles_now = false;
                if (bool* stp_ptr = pawn->GetValuePtrByPropertyNameInChain<bool>(STR("spawnTrackingParticles?")))
                {
                    spawn_tracking_particles_now = *stp_ptr;
                }
                if (spawn_tracking_particles_now != prev_spawn_tracking_particles)
                {
                    Output::send(STR("[MeshGhostPseudo] TRACE trailVFX: spawnTrackingParticles? {} -> {} moveState={} actionState={}\n"),
                                 prev_spawn_tracking_particles,
                                 spawn_tracking_particles_now,
                                 move_state_ptr ? static_cast<int>(*move_state_ptr) : -1,
                                 action_state_ptr ? static_cast<int>(*action_state_ptr) : -1);
                }
                prev_spawn_tracking_particles = spawn_tracking_particles_now;
            }

            // Dream Breaker THROW-animation ground truth -- see ANIM_TRACE's own comment.
            // Log-on-change rather than log-every-tick or a burst triggered by the weaponEquipped?
            // edge: the throw wind-up necessarily happens BEFORE the flag flips, so an edge-
            // triggered burst would miss the exact frames the question is about, while a 60-line-
            // per-second dump would bury them. One line per real change gives the full timeline
            // AND the tick counts (how long each state lasts), which is the send-cadence half of
            // the question.
            if constexpr (ANIM_TRACE)
            {
                UObject* local_abp = nullptr;
                if (UObject** abp_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref")); abp_ptr && *abp_ptr)
                {
                    local_abp = *abp_ptr;
                }

                // Gate the one-shot dump on animBPref actually resolving, not just on "a pawn
                // exists". First capture (2026-08-15) fired it at tick 333 against
                // Class /Script/Engine.DefaultPawn -- the placeholder pawn that exists before the
                // real BP_PlayerGoatMain_C is possessed -- so it dumped zero matching functions and
                // burned its one shot. animBPref only exists on the real player pawn, so it is the
                // precise "the thing I want to reflect is here now" signal.
                if (!throw_trace_schema_dumped && local_abp)
                {
                    throw_trace_schema_dumped = true;
                    dump_functions_matching(pawn, STR("local pawn (throw search)"),
                                            {STR("hrow"), STR("eapon"), STR("ttack"), STR("ontage"), STR("quip")});
                    if (local_abp)
                    {
                        dump_functions_matching(local_abp, STR("local pawn animBPref (throw search)"),
                                                {STR("ontage"), STR("hrow"), STR("eapon"), STR("quip")});
                    }

                    // Montage vocabulary, added 2026-08-15 after the throw fix shipped: the mirror
                    // plays whatever montage the local player plays, so the interesting question
                    // stopped being "which function?" and became "how many montages does this game
                    // have?" -- previously answerable only by triggering them one at a time and
                    // reading the name off the trace. UObjectGlobals::FindAllOf is used here rather
                    // than assumed: its signature is read directly from the vendored SDK header
                    // (RE-UE4SS deps/first/Unreal/include/Unreal/UObjectGlobals.hpp:244, MIT --
                    // agent_docs/licensing.md).
                    //
                    // **Reads LOADED objects only.** A montage whose asset hasn't been streamed in
                    // yet simply won't appear, so an absence here is not evidence the animation
                    // doesn't exist -- it means it hadn't loaded at the moment of the dump.
                    std::vector<UObject*> loaded_montages;
                    UObjectGlobals::FindAllOf(STR("AnimMontage"), loaded_montages);
                    Output::send(STR("[MeshGhostPseudo] DIAG: {} AnimMontage asset(s) loaded right now:\n"),
                                 loaded_montages.size());
                    for (UObject* montage : loaded_montages)
                    {
                        if (montage)
                        {
                            Output::send(STR("[MeshGhostPseudo] DIAG: montage asset '{}'\n"), montage->GetFullName());
                        }
                    }
                }

                bool weapon_equipped_now = false;
                if (bool* we_ptr = pawn->GetValuePtrByPropertyNameInChain<bool>(STR("weaponEquipped?")))
                {
                    weapon_equipped_now = *we_ptr;
                }
                UObject** weapon_ref_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("weaponRef"));
                bool weapon_ref_valid_now = (weapon_ref_ptr && *weapon_ref_ptr);
                int move_state_now = move_state_ptr ? static_cast<int>(*move_state_ptr) : -1;
                int action_state_now = action_state_ptr ? static_cast<int>(*action_state_ptr) : -1;
                int anim_jump_type_now = anim_jump_type_ptr ? static_cast<int>(*anim_jump_type_ptr) : -1;

                // Only ask while there IS an anim instance to ask, and only latch the getter off on
                // a real "this function doesn't exist on this build" answer. First capture
                // (2026-08-15) latched it off permanently on tick 333, when local_abp was still
                // null on the pre-possession DefaultPawn -- so the montage column read empty for the
                // whole session without a single call ever being attempted. A null receiver is "not
                // yet", not "never".
                std::string montage_now;
                if (throw_trace_montage_getter_ok && local_abp)
                {
                    throw_trace_montage_getter_ok = read_current_active_montage(local_abp, montage_now);
                }

                const bool changed = !throw_trace_initialized ||
                                     weapon_equipped_now != throw_trace_prev_weapon_equipped ||
                                     weapon_ref_valid_now != throw_trace_prev_weapon_ref_valid ||
                                     move_state_now != throw_trace_prev_move_state ||
                                     action_state_now != throw_trace_prev_action_state ||
                                     anim_jump_type_now != throw_trace_prev_anim_jump_type ||
                                     montage_now != throw_trace_prev_montage;
                if (changed)
                {
                    // capsule/crouched added 2026-08-15 for the crouch-trail false positive (see
                    // ANIM_TRACE's own comment): the trail's slide trigger keys on capsule < 50, and
                    // this is the measurement that decides whether a tighter threshold is enough or
                    // whether bIsCrouched has to gate it. Reading bIsCrouched here rather than
                    // assuming it: the same property the trailCoverage trace already reads.
                    bool crouched_now = false;
                    if (bool* crouched_ptr = pawn->GetValuePtrByPropertyNameInChain<bool>(STR("bIsCrouched")))
                    {
                        crouched_now = *crouched_ptr;
                    }
                    Output::send(STR("[MeshGhostPseudo] TRACE animState local: capsule={:.1f} crouched={}\n"),
                                 local_capsule_half, crouched_now);
                    Output::send(STR("[MeshGhostPseudo] TRACE throwAnim: tick={} weaponEquipped={} weaponRef={} moveState={} actionState={} animJumpType={} montage='{}'\n"),
                                 tick_count,
                                 weapon_equipped_now,
                                 weapon_ref_valid_now ? STR("non-null") : STR("null"),
                                 move_state_now,
                                 action_state_now,
                                 anim_jump_type_now,
                                 to_wide_ascii(montage_now));
                    throw_trace_initialized = true;
                    throw_trace_prev_weapon_equipped = weapon_equipped_now;
                    throw_trace_prev_weapon_ref_valid = weapon_ref_valid_now;
                    throw_trace_prev_move_state = move_state_now;
                    throw_trace_prev_action_state = action_state_now;
                    throw_trace_prev_anim_jump_type = anim_jump_type_now;
                    throw_trace_prev_montage = montage_now;
                }
            }

            // Field-discovery dump, gated by OBJECT_REFLECTION_DUMP (see its own comment) --
            // not tied to any specific investigation, unlike the falling-pose/ledge-hang dump
            // this was restored from. Cadenced (not one-shot) so a live capture protocol can
            // compare dumps across distinct moments: sword held vs. not, mid-cling vs. grounded,
            // etc. Dumps the local pawn and its animBPref -- the two objects every field
            // confirmed so far (moveState, landed?/jumped?, ...) has turned up on.
            if constexpr (OBJECT_REFLECTION_DUMP)
            {
                if (tick_count % OBJECT_REFLECTION_DUMP_INTERVAL_TICKS == 0)
                {
                    dump_object_reflection(pawn, STR("local pawn"));
                    if (UObject** abp_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref")); abp_ptr && *abp_ptr)
                    {
                        dump_object_reflection(*abp_ptr, STR("local pawn animBPref"));
                    }
                }
            }

            // Live-value trace for the ability field schema (see ABILITY_FIELD_TRACE's own
            // comment and PLAYER_FIELDS.md). Every pointer here is read defensively -- a name not
            // resolving just means "not this build/this object", same posture as every other
            // GetValuePtrByPropertyNameInChain call in this file, not a new pattern.
            if constexpr (ABILITY_FIELD_TRACE)
            {
                if (tick_count % LOG_INTERVAL_TICKS == 0)
                {
                    bool* weapon_equipped_ptr = pawn->GetValuePtrByPropertyNameInChain<bool>(STR("weaponEquipped?"));
                    double* charge_hold_ptr = pawn->GetValuePtrByPropertyNameInChain<double>(STR("chargeAttackHoldTime"));
                    double* current_power_ptr = pawn->GetValuePtrByPropertyNameInChain<double>(STR("currentPower"));
                    int32_t* power_level_ptr = pawn->GetValuePtrByPropertyNameInChain<int32_t>(STR("powerLevel"));
                    bool* has_ground_pound_ptr = pawn->GetValuePtrByPropertyNameInChain<bool>(STR("hasGroundPound"));
                    bool* wallride_held_ptr = pawn->GetValuePtrByPropertyNameInChain<bool>(STR("wallRideButtonHeld?"));
                    bool* can_flip_jump_ptr = pawn->GetValuePtrByPropertyNameInChain<bool>(STR("canFlipJump?"));
                    UObject** weapon_mesh_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("WeaponMesh"));
                    UObject** weapon_ref_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("weaponRef"));
                    UObject** charging_vfx_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("chargingVFX"));
                    UObject** wallride_vfx_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("wallRideVFX"));

                    bool anim_equipped_weapon = false;
                    if (UObject** abp_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref")); abp_ptr && *abp_ptr)
                    {
                        if (bool* anim_equip_ptr = (*abp_ptr)->GetValuePtrByPropertyNameInChain<bool>(STR("animEquippedWeapon")))
                        {
                            anim_equipped_weapon = *anim_equip_ptr;
                        }
                    }

                    Output::send(STR("[MeshGhostPseudo] TRACE abilities: weaponEquipped={} animEquippedWeapon={} WeaponMesh={} weaponRef={} chargeHoldTime={} chargingVFX={} currentPower={} powerLevel={} hasGroundPound={} wallRideHeld={} wallRideVFX={} canFlipJump={}\n"),
                                 weapon_equipped_ptr ? *weapon_equipped_ptr : false,
                                 anim_equipped_weapon,
                                 (weapon_mesh_ptr && *weapon_mesh_ptr) ? STR("non-null") : STR("null"),
                                 (weapon_ref_ptr && *weapon_ref_ptr) ? STR("non-null") : STR("null"),
                                 charge_hold_ptr ? *charge_hold_ptr : -1.0,
                                 (charging_vfx_ptr && *charging_vfx_ptr) ? STR("non-null") : STR("null"),
                                 current_power_ptr ? *current_power_ptr : -1.0,
                                 power_level_ptr ? *power_level_ptr : -1,
                                 has_ground_pound_ptr ? *has_ground_pound_ptr : false,
                                 wallride_held_ptr ? *wallride_held_ptr : false,
                                 (wallride_vfx_ptr && *wallride_vfx_ptr) ? STR("non-null") : STR("null"),
                                 can_flip_jump_ptr ? *can_flip_jump_ptr : false);
                }
            }

            // Dense every-tick trace for this investigation -- LOG_INTERVAL_TICKS (~2s) cannot see
            // a one-frame AnimBP pulse. Gated on "airborne or a pulse fired this tick" so a full
            // jump/land or grab/release cycle is readable without flooding the log at 60Hz while
            // grounded and idle. See ANIM_PULSE_TRACE's own comment.
            if constexpr (ANIM_PULSE_TRACE)
            {
                if (movement_mode != 1 || landed_now || jumped_now)
                {
                    uint8_t* prev_move_state_ptr = pawn->GetValuePtrByPropertyNameInChain<uint8_t>(STR("previousMoveState"));
                    uint8_t* prev_action_state_ptr = pawn->GetValuePtrByPropertyNameInChain<uint8_t>(STR("previousActionState"));
                    double* move_uptime_ptr = pawn->GetValuePtrByPropertyNameInChain<double>(STR("moveStateUptime"));
                    double* action_uptime_ptr = pawn->GetValuePtrByPropertyNameInChain<double>(STR("actionStateUptime"));
                    uint8_t* control_state_ptr = pawn->GetValuePtrByPropertyNameInChain<uint8_t>(STR("controlState"));
                    Output::send(STR("[MeshGhostPseudo] PULSE local: moveState={} prevMoveState={} actionState={} prevActionState={} moveUptime={} actionUptime={} controlState={} movementMode={} landed={} jumped={} landed_count={} jumped_count={}\n"),
                                 move_state_ptr ? static_cast<int>(*move_state_ptr) : -1,
                                 prev_move_state_ptr ? static_cast<int>(*prev_move_state_ptr) : -1,
                                 action_state_ptr ? static_cast<int>(*action_state_ptr) : -1,
                                 prev_action_state_ptr ? static_cast<int>(*prev_action_state_ptr) : -1,
                                 move_uptime_ptr ? *move_uptime_ptr : -1.0,
                                 action_uptime_ptr ? *action_uptime_ptr : -1.0,
                                 control_state_ptr ? static_cast<int>(*control_state_ptr) : -1,
                                 static_cast<int>(movement_mode),
                                 landed_now,
                                 jumped_now,
                                 landed_count,
                                 jumped_count);
                }
            }

            // Live trace for the "stuck flying after jump, slide resets it" investigation --
            // reusing the existing ~2s log cadence (LOG_INTERVAL_TICKS) so this can run through a
            // full jump/stuck/slide/recovered cycle without flooding the log.
            if (tick_count % LOG_INTERVAL_TICKS == 0)
            {
                Output::send(STR("[MeshGhostPseudo] TRACE local: moveState={} actionState={} hSpeed={} vSpeed={} animJumpType={} movementMode={} landed={} jumped={} yaw={} bOrientRotationToMovement={}\n"),
                             move_state_ptr ? static_cast<int>(*move_state_ptr) : -1,
                             action_state_ptr ? static_cast<int>(*action_state_ptr) : -1,
                             h_speed_ptr ? *h_speed_ptr : -1.0,
                             v_speed_ptr ? *v_speed_ptr : -1.0,
                             anim_jump_type_ptr ? static_cast<int>(*anim_jump_type_ptr) : -1,
                             static_cast<int>(movement_mode),
                             landed_now,
                             jumped_now,
                             rotation.GetYaw(),
                             orient_rotation_to_movement);

                // Facing-direction investigation, continued: is VisualMesh's own
                // RelativeRotation/RelativeScale3D what actually changes when the real player
                // turns around? The one-shot dump caught only a single snapshot (yaw=-90,
                // scale=(1,1,1)) -- logging on the existing trace cadence to see it live across a
                // real turn.
                if (UObject** vm_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("VisualMesh")); vm_ptr && *vm_ptr)
                {
                    FRotator* vm_rot = (*vm_ptr)->GetValuePtrByPropertyNameInChain<FRotator>(STR("RelativeRotation"));
                    FVector* vm_scale = (*vm_ptr)->GetValuePtrByPropertyNameInChain<FVector>(STR("RelativeScale3D"));
                    // RelativeLocation added for the slide mesh-offset question (SLIDE_MESH_PROBE's
                    // own comment). Kept on this slow cadence too, so the standing baseline stays
                    // in the log once the fast probe is switched back off.
                    FVector* vm_loc = (*vm_ptr)->GetValuePtrByPropertyNameInChain<FVector>(STR("RelativeLocation"));
                    Output::send(STR("[MeshGhostPseudo] TRACE local VisualMesh: rot=(pitch={},yaw={},roll={}) scale=(x={},y={},z={}) loc=(x={},y={},z={})\n"),
                                 vm_rot ? vm_rot->GetPitch() : -9999.0,
                                 vm_rot ? vm_rot->GetYaw() : -9999.0,
                                 vm_rot ? vm_rot->GetRoll() : -9999.0,
                                 vm_scale ? vm_scale->X() : -9999.0,
                                 vm_scale ? vm_scale->Y() : -9999.0,
                                 vm_scale ? vm_scale->Z() : -9999.0,
                                 vm_loc ? vm_loc->X() : -9999.0,
                                 vm_loc ? vm_loc->Y() : -9999.0,
                                 vm_loc ? vm_loc->Z() : -9999.0);
                }
                // Missing cross-check: does the REAL PLAYER's own capsule RelativeRotation change
                // correctly with turning? Only the ghost's capsule rotation was ever confirmed
                // garbage so far -- if the real player's own capsule rotation tracks turning
                // correctly here, that means capsule rotation really is the right mechanism and
                // the bug is specific to the ghost (fixable), not a wrong theory about how this
                // game drives facing at all.
                if (UObject** cap_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("CapsuleComponent")); cap_ptr && *cap_ptr)
                {
                    if (FRotator* cap_rot = (*cap_ptr)->GetValuePtrByPropertyNameInChain<FRotator>(STR("RelativeRotation")))
                    {
                        Output::send(STR("[MeshGhostPseudo] TRACE local CapsuleComponent RelativeRotation: pitch={} yaw={} roll={}\n"),
                                     cap_rot->GetPitch(), cap_rot->GetYaw(), cap_rot->GetRoll());
                    }
                    else
                    {
                        Output::send(STR("[MeshGhostPseudo] TRACE local CapsuleComponent RelativeRotation: property not found.\n"));
                    }
                }

                // Outfit/costume sync investigation, see OUTFIT_TRACE's own comment. Full value
                // dump of VisualMesh (the main body mesh -- distinct from WeaponMesh) at the same
                // ~2s cadence as everything else in this block, so two samples straddling a live
                // costume swap can be diffed to find whatever field actually changes. Also dumps
                // the pawn itself, in case the "currently equipped outfit" selector lives there
                // rather than on VisualMesh -- cheap to capture both on the same pass rather than
                // needing a second live-test round trip if the first guess is wrong.
                if constexpr (OUTFIT_TRACE)
                {
                    dump_object_property_values(pawn, STR("local pawn (outfit trace)"));
                    if (UObject** outfit_vm_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("VisualMesh")); outfit_vm_ptr && *outfit_vm_ptr)
                    {
                        dump_object_property_values(*outfit_vm_ptr, STR("local pawn VisualMesh"));
                    }
                }
            }

            // Slide mesh-offset probe. DELIBERATELY OUTSIDE the LOG_INTERVAL_TICKS block above --
            // inside it, it would inherit the 120-tick cadence and an 87-tick slide could produce
            // zero samples, which is the whole reason this exists. See SLIDE_MESH_PROBE's comment.
            //
            // CapsuleHalfHeight and actionState ride along so every sample classifies ITSELF:
            // half==65 is standing, half==22 is a plain slide (measured, verified.md). Without
            // them a bare Z is uninterpretable and the capture would rest on the tester's timing.
            if constexpr (SLIDE_MESH_PROBE)
            {
                if (tick_count % SLIDE_MESH_PROBE_INTERVAL_TICKS == 0)
                {
                    if (UObject** probe_vm_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("VisualMesh")); probe_vm_ptr && *probe_vm_ptr)
                    {
                        FVector* probe_loc = (*probe_vm_ptr)->GetValuePtrByPropertyNameInChain<FVector>(STR("RelativeLocation"));

                        float probe_half = -1.0f;
                        if (UObject** probe_cap_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("CapsuleComponent")); probe_cap_ptr && *probe_cap_ptr)
                        {
                            if (float* probe_half_ptr = (*probe_cap_ptr)->GetValuePtrByPropertyNameInChain<float>(STR("CapsuleHalfHeight")))
                            {
                                probe_half = *probe_half_ptr;
                            }
                        }

                        Output::send(STR("[MeshGhostPseudo] TRACE slideMesh: meshLoc=(x={},y={},z={}) capsuleHalf={} actionState={} moveState={}\n"),
                                     probe_loc ? probe_loc->X() : -9999.0,
                                     probe_loc ? probe_loc->Y() : -9999.0,
                                     probe_loc ? probe_loc->Z() : -9999.0,
                                     probe_half,
                                     action_state_ptr ? static_cast<int>(*action_state_ptr) : -1,
                                     move_state_ptr ? static_cast<int>(*move_state_ptr) : -1);
                    }
                }
            }

            // Trail colour, read live every tick rather than cached at spawn -- the base game
            // changes it dynamically (a perfect-timing "ultra" hop trails blue instead of yellow),
            // so a one-time read would miss exactly the case worth syncing. Falls back to the
            // game's own normal trail colour if the read fails, so a peer never receives garbage.
            LinearColorRGBA local_afterimage_color{};
            // **Read into a LOCAL, not straight into the member.** This line runs every tick while
            // the afterimage scan below runs every few, so assigning the member here republished
            // the pawn's baseline colour on every tick in between -- meaning two ticks out of three
            // the outgoing packet carried gold no matter what the scan had observed, and the ~20Hz
            // send simply landed wherever it landed. That, not detection and not the send rate, is
            // what capped blue reproduction at roughly a third (measured 10 observed, 4 arriving),
            // and it is why holding the observed colour for longer changed nothing: the hold was
            // real, but this line overwrote its result further down the same tick.
            LinearColorRGBA pawn_afterimage_color{};
            bool local_color_read_ok = read_linear_color(pawn, STR("afterimageColor"), pawn_afterimage_color);
            // Kept for the emit path in the trigger block, which runs earlier in the tick than this
            // read -- see its use there. The game's ordinary trail colour, i.e. what a burst that
            // observed nothing of its own should fall back to.
            if (local_color_read_ok)
            {
                last_pawn_baseline_color[0] = pawn_afterimage_color.r;
                last_pawn_baseline_color[1] = pawn_afterimage_color.g;
                last_pawn_baseline_color[2] = pawn_afterimage_color.b;
                last_pawn_baseline_color_valid = true;
            }
            // The pawn's value is only a STARTUP fallback, used until a real afterimage has been
            // observed. After that the latched per-burst colour stands until the next burst
            // replaces it -- see the latch in the observe block below for why nothing else may
            // touch it.
            //
            // **The latch is a MEMBER, and re-read here every tick.** local_afterimage_color is a
            // fresh zero-initialised local each tick while an observation only happens once per
            // burst, so without this the packet would carry black on every tick in between. The
            // mirror-image of that bug is what capped blue reproduction at a third before: the
            // baseline was republished into the serialized value every tick, so the ~20Hz send
            // sampled whichever tick it landed on. Read the latch, never overwrite it.
            if (afterimage_have_observed_color)
            {
                local_afterimage_color.r = latched_afterimage_color[0];
                local_afterimage_color.g = latched_afterimage_color[1];
                local_afterimage_color.b = latched_afterimage_color[2];
                local_color_read_ok = true;
            }
            else
            {
                local_afterimage_color = pawn_afterimage_color;
            }

            // **Observe the burst's real colour, once, a few ticks after it fired.** This is the
            // colour half of the ultra-blue work, deliberately split from the trail TRIGGER -- see
            // AFTERIMAGE_OBSERVE_COLOR for why they are separate flags now.
            if constexpr (AFTERIMAGE_OBSERVE_COLOR)
            {
                if (afterimage_color_burst_pending &&
                    tick_count >= afterimage_color_burst_next_scan_tick)
                {
                    const AfterimageColorObservation obs =
                        observe_local_afterimage_colors(pawn, pawn_afterimage_color, afterimage_pos_by_ptr);

                    // Accumulate ACROSS the window rather than judging one instant -- see
                    // AFTERIMAGE_COLOR_OBSERVE_WINDOW_TICKS for why a single sample attributed the
                    // blue to the wrong burst. Same tie-break as within a scan: a colour that
                    // differs from the pawn's baseline outranks one that matches it.
                    if (obs.have_color &&
                        (!afterimage_color_burst_have || (obs.have_special && !afterimage_color_burst_special)))
                    {
                        afterimage_color_burst_color[0] = obs.color.r;
                        afterimage_color_burst_color[1] = obs.color.g;
                        afterimage_color_burst_color[2] = obs.color.b;
                        afterimage_color_burst_have = true;
                    }
                    afterimage_color_burst_special = afterimage_color_burst_special || obs.have_special;
                    afterimage_color_burst_new_total += obs.images_new;
                    afterimage_color_burst_rejected_far += obs.images_rejected_far;
                    afterimage_color_burst_scans += 1;

                    const uint64_t age = tick_count - afterimage_color_burst_tick;

                    // Bounded evidence, and the drain profile in one. `off=` is ticks since the
                    // trigger and `new=` how many images appeared by then, so the log says directly
                    // how long a burst really takes to finish spawning -- which is the number the
                    // window should be sized against, rather than another guess. A silent zero on
                    // `ours=` would otherwise be indistinguishable from "no burst yet", the failure
                    // mode CLAUDE.md calls out for a probe that reads nothing.
                    if (afterimage_color_observe_logged < AFTERIMAGE_COLOR_OBSERVE_LOG_COUNT)
                    {
                        ++afterimage_color_observe_logged;
                        Output::send(STR("[MeshGhostPseudo] AFTERIMAGE_COLOR: off={} found={} ours={} new={} newTotal={} scan=({:.3f}, {:.3f}, {:.3f}) special={} burstSoFar=({:.3f}, {:.3f}, {:.3f}) burstSpecial={} baseline=({:.3f}, {:.3f}, {:.3f}) n={} tick={}\n"),
                                     age, obs.images_found, obs.images_ours, obs.images_new,
                                     afterimage_color_burst_new_total,
                                     obs.color.r, obs.color.g, obs.color.b, obs.have_special,
                                     afterimage_color_burst_color[0], afterimage_color_burst_color[1],
                                     afterimage_color_burst_color[2], afterimage_color_burst_special,
                                     pawn_afterimage_color.r, pawn_afterimage_color.g, pawn_afterimage_color.b,
                                     afterimage_color_burst_n, tick_count);
                    }

                    // **The blue moment, on its own budget.** Logged the instant a scan sees an image
                    // whose colour diverges from the baseline, so it can never be crowded out by
                    // routine sliding the way the shared budget was last run.
                    if (obs.have_special && afterimage_color_special_logged < AFTERIMAGE_COLOR_SPECIAL_LOG_COUNT)
                    {
                        ++afterimage_color_special_logged;
                        Output::send(STR("[MeshGhostPseudo] AFTERIMAGE_SPECIAL: off={} scan=({:.3f}, {:.3f}, {:.3f}) new={} newTotal={} baseline=({:.3f}, {:.3f}, {:.3f}) n={} tick={}\n"),
                                     age, obs.color.r, obs.color.g, obs.color.b,
                                     obs.images_new, afterimage_color_burst_new_total,
                                     pawn_afterimage_color.r, pawn_afterimage_color.g, pawn_afterimage_color.b,
                                     afterimage_color_burst_n, tick_count);
                    }

                    // Emit once the burst is fully accounted for, or when the window runs out.
                    // The early exit is what keeps an ordinary slide's trail prompt: a 5-image burst
                    // that finishes spawning quickly does not sit waiting for a window sized for the
                    // worst case.
                    const bool burst_fully_seen = afterimage_color_burst_n > 0 &&
                                                  afterimage_color_burst_new_total >= afterimage_color_burst_n;
                    if (burst_fully_seen || age >= AFTERIMAGE_COLOR_OBSERVE_WINDOW_TICKS)
                    {
                        // **A burst that observed nothing falls back to the BASELINE, never to the
                        // previous burst's colour.** Confirmed live 2026-08-16: the slide after an
                        // ultra came out blue even though no blue was detected during it (the
                        // capture has no AFTERIMAGE_SPECIAL line for that burst at all). The blue
                        // was not being re-detected -- it was being inherited. Holding the last
                        // latched colour across a burst that saw nothing makes the latch describe
                        // "the last colour ever seen" instead of "this burst's colour", which is
                        // exactly the property pitfalls.md's latch entry says it must not have.
                        // A burst with no observation is an ordinary one, so it gets the ordinary
                        // colour.
                        if (afterimage_color_burst_have)
                        {
                            latched_afterimage_color[0] = afterimage_color_burst_color[0];
                            latched_afterimage_color[1] = afterimage_color_burst_color[1];
                            latched_afterimage_color[2] = afterimage_color_burst_color[2];
                        }
                        else
                        {
                            latched_afterimage_color[0] = pawn_afterimage_color.r;
                            latched_afterimage_color[1] = pawn_afterimage_color.g;
                            latched_afterimage_color[2] = pawn_afterimage_color.b;
                        }
                        afterimage_have_observed_color = true;
                        local_afterimage_color.r = latched_afterimage_color[0];
                        local_afterimage_color.g = latched_afterimage_color[1];
                        local_afterimage_color.b = latched_afterimage_color[2];
                        local_color_read_ok = true;

                        if (afterimage_color_burst_logged < AFTERIMAGE_COLOR_BURST_LOG_COUNT)
                        {
                            ++afterimage_color_burst_logged;
                            Output::send(STR("[MeshGhostPseudo] AFTERIMAGE_BURST: {} off={} scans={} newTotal={} rejFar={} color=({:.3f}, {:.3f}, {:.3f}) have={} special={} n={} tick={}\n"),
                                         burst_fully_seen ? STR("complete") : STR("window"),
                                         age, afterimage_color_burst_scans, afterimage_color_burst_new_total,
                                         afterimage_color_burst_rejected_far,
                                         afterimage_color_burst_color[0], afterimage_color_burst_color[1],
                                         afterimage_color_burst_color[2], afterimage_color_burst_have,
                                         afterimage_color_burst_special, afterimage_color_burst_n, tick_count);
                        }

                        // The wire event and its colour are written together, here, and nothing else
                        // touches either afterwards -- so whichever tick the send samples, it sees
                        // the pair belonging to the latest burst.
                        ++afterimage_count;
                        afterimage_spawn_n = afterimage_color_burst_n;
                        afterimage_color_burst_pending = false;
                    }
                    else
                    {
                        afterimage_color_burst_next_scan_tick = tick_count + AFTERIMAGE_COLOR_OBSERVE_STRIDE_TICKS;
                    }
                }
                // **Observation scan.** With AFTERIMAGE_TRIGGER_FROM_OBSERVATION this is the ONLY
                // trigger: it fires on images the game really spawned, so the ghost trails exactly
                // when the player does. Without it, it runs only while no reconstructed burst is
                // pending, and fires just for deliberately-coloured images (the ultra's blue).
                else if ((AFTERIMAGE_TRIGGER_FROM_OBSERVATION || AFTERIMAGE_OBSERVE_SPECIAL_TRIGGER) &&
                         (AFTERIMAGE_TRIGGER_FROM_OBSERVATION || !afterimage_color_burst_pending) &&
                         tick_count >= afterimage_idle_next_scan_tick)
                {
                    afterimage_idle_next_scan_tick = tick_count + (AFTERIMAGE_TRIGGER_FROM_OBSERVATION
                                                                       ? AFTERIMAGE_OBSERVE_SCAN_INTERVAL_TICKS
                                                                       : AFTERIMAGE_IDLE_SCAN_INTERVAL_TICKS);
                    const AfterimageColorObservation obs =
                        observe_local_afterimage_colors(pawn, pawn_afterimage_color, afterimage_pos_by_ptr);

                    // **The first scan of a session only PRIMES the position map.** Every image in
                    // the pool is unseen at that point, so it would otherwise look like one enormous
                    // spawn and fire a spurious burst on the ghost.
                    if (!afterimage_pos_primed)
                    {
                        afterimage_pos_primed = true;
                    }
                    else if (AFTERIMAGE_TRIGGER_FROM_OBSERVATION ? (obs.images_new > 0) : obs.have_special)
                    {
                        // The game spawned images and coloured them deliberately, with no local
                        // trigger accounting for them. Mirror it: latch the colour and emit the wire
                        // event together, exactly as the burst path does -- one operation, never a
                        // counter without its colour.
                        latched_afterimage_color[0] = obs.color.r;
                        latched_afterimage_color[1] = obs.color.g;
                        latched_afterimage_color[2] = obs.color.b;
                        afterimage_have_observed_color = true;
                        local_afterimage_color = obs.color;
                        local_color_read_ok = true;

                        // Carry the real burst size the game produced rather than a guess, matching
                        // how the ghost side already consumes the counter/N pair.
                        ++afterimage_count;
                        afterimage_spawn_n = obs.images_new;

                        if (afterimage_color_idle_logged < AFTERIMAGE_COLOR_SPECIAL_LOG_COUNT)
                        {
                            ++afterimage_color_idle_logged;
                            // `img=` and `sinceLast=` are the pair that answered why an ultra emitted
                            // twice: the same pointer means the pool handed one actor back, two
                            // pointers mean the game really spawned two. `rejFar=` is how many
                            // movers were rejected as pool retirements rather than births.
                            Output::send(STR("[MeshGhostPseudo] AFTERIMAGE_IDLE: observed spawn found={} ours={} new={} rejFar={} farNew={:.0f} color=({:.3f}, {:.3f}, {:.3f}) img={} sinceLast={} baseline=({:.3f}, {:.3f}, {:.3f}) tick={}\n"),
                                         obs.images_found, obs.images_ours, obs.images_new,
                                         obs.images_rejected_far, std::sqrt(obs.farthest_new_dist_sq),
                                         obs.color.r, obs.color.g, obs.color.b,
                                         static_cast<void*>(obs.special_image),
                                         afterimage_idle_last_emit_tick == 0 ? 0 : tick_count - afterimage_idle_last_emit_tick,
                                         pawn_afterimage_color.r, pawn_afterimage_color.g, pawn_afterimage_color.b,
                                         tick_count);
                        }
                        afterimage_idle_last_emit_tick = tick_count;
                    }
                }
            }

            // **The ultra hop's blue, solved 2026-08-16 -- read the colour off the AFTERIMAGE, not
            // off the pawn.** `status.md` parked this after `afterimageColor` was proven never to
            // change during a real ultra, and that finding was correct; it was simply the wrong
            // object. A live capture of every afterimage's own `Color` shows normal images at
            // (1.000, 0.888, 0.260) and ultra images at (0.000, 0.787, 1.000) -- so the ultra path
            // sets the colour per-afterimage and bypasses the pawn field entirely.
            //
            // This mirrors the observed colour rather than detecting an ultra, which matters: the
            // repeated failure here was trying to identify the ultra STATE, and this needs no such
            // test. Whatever the game decides -- ultra, a future variant, a mod -- the ghost copies
            // the colour the game actually used. Same principle as the recall glow's presence
            // mirror, and the reason neither needs to know the rule.
            //
            // Enumerated by exact class so this stays cheap enough to ship (only afterimages, not
            // every actor), at a bounded cadence, and holds its last value between scans. The
            // pawn's afterimageColor above remains the fallback for when no afterimage is alive.
            // The same scan also drives the trail TRIGGER now, not just its colour -- see
            // AFTERIMAGE_TRIGGER_OBSERVED. Counting afterimages the game really created replaces
            // reconstructing when it might have created them, which fixes two things at once:
            // slide timing (the old trigger keyed on a capsule shrink, so it led or lagged the real
            // burst) and coverage (it only knew about slides, which is why an ultra hop produced no
            // ghost trail at all -- confirmed in the capture, where every ghost afterimage was gold
            // and only the local player had blue ones).
            // **Gated by the flag that owns it.** Previously only the counter increment INSIDE this
            // block was gated, so setting AFTERIMAGE_TRIGGER_OBSERVED=false left the entire scan --
            // the expensive part -- still running every few ticks. That is why the earlier "revert"
            // A/B changed nothing and produced the wrong conclusion that the trigger revamp was
            // innocent: a flag flip was not a revert, and only a bisect against real commits caught
            // it. If a flag is meant to be an off-switch, it has to disable the work, not just the
            // decision the work feeds.
            if (AFTERIMAGE_TRIGGER_OBSERVED && tick_count % AFTERIMAGE_COLOR_SCAN_INTERVAL_TICKS == 0)
            {
                std::vector<UObject*> afterimages;
                UObjectGlobals::FindAllOf(STR("BP_AfterImage_C"), afterimages);
                const std::string pawn_name = to_utf8(pawn->GetName());
                std::set<std::string> alive;
                int new_images = 0;
                // The pawn's own afterimageColor -- the baseline an ordinary trail is drawn in, and
                // what the tie-break inside the loop is measured against. Taken from the local
                // read above rather than from the member, which by this point may already hold an
                // observed colour being held.
                const LinearColorRGBA baseline_afterimage_color = pawn_afterimage_color;
                bool batch_has_special_color = false;
                for (UObject* image : afterimages)
                {
                    if (!image)
                    {
                        continue;
                    }
                    // Must be OUR afterimage: `cachedMesh` names the character it was snapshotted
                    // from, and a ghost's own images are in this list too. Without this filter the
                    // ghost's colour would feed back into itself and its trail would self-trigger.
                    UObject** cached_ptr = image->GetValuePtrByPropertyNameInChain<UObject*>(STR("cachedMesh"));
                    const bool is_ours = cached_ptr && *cached_ptr &&
                                         to_utf8((*cached_ptr)->GetFullName()).find(pawn_name) != std::string::npos;

                    // Trace (1) LOCAL and (3) RESULT in one pass -- every new afterimage, whoever
                    // it belongs to. A ghost's images appearing gold here while the local player's
                    // are blue is the decisive observation.
                    if constexpr (TRAIL_COLOR_TRACE)
                    {
                        std::string trace_name = to_utf8(image->GetFullName());
                        if (local_afterimages_traced.find(trace_name) == local_afterimages_traced.end())
                        {
                            local_afterimages_traced.insert(trace_name);
                            // Birth tick + which character it belongs to, so its lifetime can be
                            // reported when it disappears (see the sweep after this loop).
                            afterimage_lifetimes[trace_name] = {tick_count, is_ours};
                            LinearColorRGBA trace_color{};
                            const bool ok = read_linear_color(image, STR("Color"), trace_color);
                            // Position and tick, added 2026-08-16: the counts came out equal
                            // (32/32) while the user could plainly see a denser trail on the real
                            // player than on the ghost. Equal counts do NOT settle that, and
                            // assuming they did would have been the wrong call -- both sides are
                            // counted by this same scan, so anything it misses it misses
                            // symmetrically and still reports parity. What density actually
                            // depends on is how many images exist and how far apart they sit, so
                            // both are recorded here and compared afterwards instead of judged by
                            // eye. Two distinguishable outcomes: images bunched at one position
                            // means the ghost's bursts are collapsing (a send-rate problem), while
                            // genuinely fewer images spread over the same path means this scan is
                            // missing spawns (a sampling problem).
                            std::string owner = (cached_ptr && *cached_ptr) ? to_utf8((*cached_ptr)->GetFullName()) : std::string("<none>");
                            FVector image_loc = static_cast<AActor*>(image)->K2_GetActorLocation();
                            Output::send(STR("[MeshGhostPseudo] TRAILCOLOR image: mine={} rgb=({:.3f}, {:.3f}, {:.3f}) ok={} at=({:.0f}, {:.0f}, {:.0f}) tick={} from='{}'\n"),
                                         is_ours, trace_color.r, trace_color.g, trace_color.b, ok,
                                         image_loc.X(), image_loc.Y(), image_loc.Z(), tick_count,
                                         to_wide_ascii(owner));
                        }
                    }

                    if (!is_ours)
                    {
                        continue;
                    }
                    std::string image_name = to_utf8(image->GetFullName());
                    alive.insert(image_name);

                    // **Count REUSE, not just creation.** Measured 2026-08-16: across 122 tracked
                    // afterimages, not one ever disappeared -- the lifetime sweep produced zero
                    // samples. These actors are pooled and re-used, never destroyed, so treating
                    // "a name we have not seen" as the spawn signal silently undercounted every
                    // burst after the pool stopped growing. That is precisely why the real trail
                    // looked denser than the ghost's while spawn count, spacing and position all
                    // measured as matching: both sides were being counted by the same blind rule.
                    //
                    // A reused image betrays itself by TELEPORTING: an afterimage is a frozen
                    // snapshot and never moves once placed, so any position change means the pool
                    // handed it back out at the player's current location. Threshold is generous
                    // because the alternative to a jump is exactly zero movement, not a small one.
                    const FVector image_loc = static_cast<AActor*>(image)->K2_GetActorLocation();
                    auto known = afterimage_last_pos.find(image_name);
                    bool is_new_spawn = false;
                    if (known == afterimage_last_pos.end())
                    {
                        is_new_spawn = true; // genuinely new object -- the pool grew
                    }
                    else if (!AFTERIMAGE_COUNT_REUSE)
                    {
                        is_new_spawn = false;
                    }
                    else
                    {
                        const double dx = image_loc.X() - std::get<0>(known->second);
                        const double dy = image_loc.Y() - std::get<1>(known->second);
                        const double dz = image_loc.Z() - std::get<2>(known->second);
                        is_new_spawn = (dx * dx + dy * dy + dz * dz) > (AFTERIMAGE_REUSE_MOVE_THRESHOLD * AFTERIMAGE_REUSE_MOVE_THRESHOLD);
                    }
                    afterimage_last_pos[image_name] = {image_loc.X(), image_loc.Y(), image_loc.Z()};
                    if (!is_new_spawn)
                    {
                        continue;
                    }
                    ++new_images;
                    LinearColorRGBA image_color{};
                    if (!read_linear_color(image, STR("Color"), image_color))
                    {
                        continue;
                    }

                    // **Tie-break within a batch, and it is load-bearing.** A scan can see several
                    // new images at once, and simply taking the last one meant whichever the
                    // enumeration happened to return last won -- so a batch holding one blue ultra
                    // image and one gold image was a coin flip. Measured: 2 blue images locally,
                    // only 1 reproduced on the ghost, with totals otherwise matching exactly
                    // (33/33). That is the whole of the "blue sometimes, yellow other times" bug.
                    //
                    // The rule: an image whose colour differs from the pawn's own afterimageColor
                    // wins. That field is by definition the baseline the ordinary trail uses, so a
                    // divergence from it is the game deliberately colouring one image differently
                    // -- the salient one. Losing a gold image among blues is invisible; losing the
                    // blue is precisely what was reported. This is a tie-break over observed
                    // values, not an inference about game state: it never asks whether an ultra is
                    // happening, only which of two observed colours matters more.
                    constexpr float COLOR_MATCH_EPSILON = 0.01f;
                    const bool differs_from_baseline =
                        std::fabs(image_color.r - baseline_afterimage_color.r) > COLOR_MATCH_EPSILON ||
                        std::fabs(image_color.g - baseline_afterimage_color.g) > COLOR_MATCH_EPSILON ||
                        std::fabs(image_color.b - baseline_afterimage_color.b) > COLOR_MATCH_EPSILON;
                    // **Latch the colour to the event, and change it only on the next event.**
                    //
                    // This replaces three stacked heuristics -- a batch tie-break, a special-colour
                    // hold window, and an observed-colour window -- that were each added to patch
                    // the previous one's shortfall. Together they over-applied badly: 6 blue images
                    // locally produced 98 blue ones on the ghost. Layering timers to protect a
                    // value from being overwritten was the wrong shape; the fix is to stop
                    // overwriting it.
                    //
                    // The rule is now exact rather than approximate. `afterimage_count` and this
                    // colour describe ONE event, they are written together here, and nothing else
                    // touches the colour afterwards -- not the per-tick pawn read, not a later
                    // ordinary image, not a timer. Whenever the ~20Hz send samples the packet it
                    // therefore sees the colour belonging to the most recent burst, whichever tick
                    // it happens to land on. That is correct by construction, with no window to
                    // size and no race to lose, which is why the earlier attempts kept missing:
                    // they tried to make a sampling race land favourably instead of removing it.
                    local_afterimage_color = image_color;
                    local_color_read_ok = true;
                    batch_has_special_color = batch_has_special_color || differs_from_baseline;
                    afterimage_have_observed_color = true;
                }
                // Replacing the set rather than inserting into it prunes images the game has
                // already reclaimed, so this cannot grow without bound over a session.
                local_afterimages_seen = std::move(alive);

                // **Lifetime, which is what the density question actually turns on now.** Spawn
                // count, spacing and position are all measured as matching one-for-one between the
                // player and the ghost, yet the player's trail plainly looks denser. The remaining
                // way that can be true is that the ghost's images do not LAST as long -- fewer of
                // them on screen at any instant reads exactly as a thinner trail, no matter how
                // faithfully they were spawned.
                //
                // Plausible mechanism worth naming so the result can be judged: BP_AfterImage_C
                // drives its own fade from a Timeline (Timeline_0_opacity), and a Timeline needs
                // the actor to tick. An actor spawned by this adapter onto an unpossessed ghost may
                // not run it the same way. This does not assume that -- it just measures how long
                // each side's images survive, which distinguishes it from every other explanation.
                // **Ground truth, measured off the world rather than off this detector.** Every
                // number so far has been produced by the same scan that was undercounting, so it
                // could only ever agree with itself. This instead counts how many afterimages are
                // ALIVE and attributed to each character at the same instant -- the thing a person
                // actually perceives as trail density. If the player has many alive and the ghost
                // few, the shortfall is real and downstream of detection (the ghost's spawn call
                // producing fewer than asked); if both are similar, then density is not about
                // count at all and the remaining candidate is how they look, not how many.
                if constexpr (TRAIL_COLOR_TRACE)
                {
                    // Cadence chosen for the ISOLATED single-slide test (user's idea, 2026-08-16):
                    // start fresh, perform exactly one slide, stop. Every previous capture ran for
                    // minutes and mixed many moves, so totals accumulated and each number had to be
                    // teased apart from everything else that had happened. One slide on a clean
                    // session gives one burst per side and nothing else, which makes a fade curve
                    // directly readable instead of inferred. ~15Hz is dense enough to see a fade
                    // that lasts about a second, and the volume only stays sane BECAUSE the test is
                    // deliberately tiny -- this cadence would be far too noisy for a long session.
                    if (tick_count % 10 == 0)
                    {
                        // Creation parity is now measured and exact (40 vs 40), so counting bodies
                        // says nothing more. What a person sees is how many are VISIBLE at an
                        // instant, and these actors fade themselves via a Timeline
                        // (`Timeline_0_opacity` in the schema dump) rather than being destroyed --
                        // which is also why the pool only ever grows. So this counts images that
                        // are actually opaque enough to see, alongside the raw bodies.
                        //
                        // The property name carries a Blueprint-compile GUID suffix, so it is found
                        // by PREFIX rather than by the exact name from one dump -- an exact name
                        // would be a value copied from a single observation, and would silently
                        // read nothing on any other build of the game.
                        int alive_mine = 0, alive_ghost = 0;
                        int visible_mine = 0, visible_ghost = 0;
                        // The actual opacity values, not just a count over a threshold: with one
                        // slide the two curves can be compared directly, and a curve distinguishes
                        // "never becomes visible" from "fades faster" -- which a count cannot.
                        std::string opacities_mine, opacities_ghost;
                        for (UObject* image : afterimages)
                        {
                            if (!image)
                            {
                                continue;
                            }
                            UObject** cm = image->GetValuePtrByPropertyNameInChain<UObject*>(STR("cachedMesh"));
                            if (!cm || !*cm)
                            {
                                continue;
                            }
                            const bool mine = to_utf8((*cm)->GetFullName()).find(pawn_name) != std::string::npos;

                            float opacity = -1.0f;
                            if (UClass* image_class = image->GetClassPrivate())
                            {
                                for (FProperty* prop : TFieldRange<FProperty>(image_class, EFieldIterationFlags::Default))
                                {
                                    if (!prop || prop->GetClass().GetName() != STR("FloatProperty"))
                                    {
                                        continue;
                                    }
                                    if (StringType(prop->GetName()).find(STR("opacity")) == StringType::npos)
                                    {
                                        continue;
                                    }
                                    if (float* op = image->GetValuePtrByPropertyNameInChain<float>(prop->GetName().c_str()))
                                    {
                                        opacity = *op;
                                    }
                                    break;
                                }
                            }
                            const bool visible = opacity > 0.01f;
                            // **Height, added to test the user's hypothesis (2026-08-16).** The
                            // slide floor-sinking fix raises the ghost's whole actor by
                            // (65 - peer_half), i.e. +43 mid-slide, because an unpossessed ghost
                            // never runs the crouch logic that drops the real player's mesh. An
                            // afterimage is placed at the ACTOR's location and carries its own
                            // fixed mesh offset, so the ghost's snapshots could land ~43 units off
                            // from where its visible body is -- floating or buried -- and only
                            // during a slide. That is the first candidate that is slide-specific,
                            // which is what the symptom has been all along.
                            //
                            // Printed as a Z per side rather than a count, because this is the one
                            // axis every previous instrument collapsed away: positions were only
                            // ever compared in X (where the +150 loopback offset was confirmed) and
                            // heights were never differenced at all.
                            const double image_z = static_cast<AActor*>(image)->K2_GetActorLocation().Z();
                            char buf[24];
                            std::snprintf(buf, sizeof(buf), "%.2f@%.0f ", opacity, image_z);
                            if (mine)
                            {
                                ++alive_mine;
                                visible_mine += visible ? 1 : 0;
                                if (opacities_mine.size() < 90) { opacities_mine += buf; }
                            }
                            else
                            {
                                ++alive_ghost;
                                visible_ghost += visible ? 1 : 0;
                                if (opacities_ghost.size() < 90) { opacities_ghost += buf; }
                            }
                        }
                        // Only print while something is actually on screen, so an idle session
                        // produces no lines at all and the single slide's curve stands alone.
                        if (alive_mine > 0 || alive_ghost > 0)
                        {
                            Output::send(STR("[MeshGhostPseudo] TRAILALIVE: bodies mine={} ghost={} | VISIBLE mine={} ghost={} | opac mine=[{}] ghost=[{}] | tick={}\n"),
                                         alive_mine, alive_ghost, visible_mine, visible_ghost,
                                         to_wide_ascii(opacities_mine), to_wide_ascii(opacities_ghost),
                                         tick_count);
                        }
                    }
                }

                if constexpr (TRAIL_COLOR_TRACE)
                {
                    std::vector<UObject*> now_alive;
                    UObjectGlobals::FindAllOf(STR("BP_AfterImage_C"), now_alive);
                    std::set<std::string> now_names;
                    for (UObject* image : now_alive)
                    {
                        if (image)
                        {
                            now_names.insert(to_utf8(image->GetFullName()));
                        }
                    }
                    for (auto it = afterimage_lifetimes.begin(); it != afterimage_lifetimes.end();)
                    {
                        if (now_names.find(it->first) == now_names.end())
                        {
                            Output::send(STR("[MeshGhostPseudo] TRAILLIFE: {} lived {} ticks (mine={})\n"),
                                         to_wide_ascii(it->first.substr(it->first.rfind('.') + 1)),
                                         tick_count - it->second.first, it->second.second);
                            it = afterimage_lifetimes.erase(it);
                        }
                        else
                        {
                            ++it;
                        }
                    }
                }

                // Batch composition. Two attempts at the blue loss have now failed (a tie-break,
                // then a faster scan), and the counts say why they were shots in the dark: 16 blue
                // images locally, 6 reproduced, totals otherwise matching exactly. That pattern is
                // consistent with several different causes -- blues sharing a batch and collapsing
                // into one increment, blues never being seen as new, or the burst size not
                // carrying them -- and they need different fixes.
                //
                // So this prints what each batch actually contained and what was chosen from it.
                // The decisive comparison is `blue` against `n`: if a batch holds 3 blue images and
                // sends n=3, the ghost should produce 3 blue ones, and any shortfall is downstream
                // in the burst. If batches hold blues but the chosen colour is gold, the tie-break
                // is not firing. If blues never appear in any batch at all, they are being missed
                // by the scan entirely and no amount of colour logic will help.
                if constexpr (TRAIL_COLOR_TRACE)
                {
                    if (new_images > 0)
                    {
                        int blue_in_batch = 0;
                        for (UObject* image : afterimages)
                        {
                            if (!image)
                            {
                                continue;
                            }
                            LinearColorRGBA c{};
                            if (read_linear_color(image, STR("Color"), c) && c.r < 0.5f && c.b > 0.5f)
                            {
                                ++blue_in_batch;
                            }
                        }
                        Output::send(STR("[MeshGhostPseudo] TRAILBATCH: n={} chose=({:.3f}, {:.3f}, {:.3f}) special={} blueAliveNow={} tick={}\n"),
                                     new_images,
                                     local_afterimage_color.r, local_afterimage_color.g, local_afterimage_color.b,
                                     batch_has_special_color, blue_in_batch, tick_count);
                    }
                }

                if (AFTERIMAGE_TRIGGER_OBSERVED && new_images > 0)
                {
                    // One wire increment carrying the real burst size, matching how the ghost side
                    // already consumes this pair (a counter that survives the send rate, plus N).
                    ++afterimage_count;
                    afterimage_spawn_n = new_images;
                }
            }
            if (!local_color_read_ok)
            {
                local_afterimage_color = LinearColorRGBA{1.0f, 1.0f, 1.0f, 1.0f};
            }

            // Edge-logged colour change -- see prev_local_afterimage_color's comment in Plugin.hpp.
            // Every-tick change detection, NOT the ~2s trace cadence: a colour that only differs
            // for the duration of one ultra hop (~690ms measured) could be missed entirely by a
            // periodic sample, which would falsely look like "afterimageColor never turns blue."
            if constexpr (TRAIL_TRIGGER_TRACE)
            {
                constexpr float COLOR_EPSILON = 0.002f;
                bool changed = (std::fabs(local_afterimage_color.r - prev_local_afterimage_color[0]) > COLOR_EPSILON) ||
                               (std::fabs(local_afterimage_color.g - prev_local_afterimage_color[1]) > COLOR_EPSILON) ||
                               (std::fabs(local_afterimage_color.b - prev_local_afterimage_color[2]) > COLOR_EPSILON);
                if (changed)
                {
                    Output::send(STR("[MeshGhostPseudo] TRACE trailColor local: read_ok={} rgb=({:.3f},{:.3f},{:.3f}) actionState={} tick={}\n"),
                                 local_color_read_ok,
                                 local_afterimage_color.r, local_afterimage_color.g, local_afterimage_color.b,
                                 action_state_ptr ? static_cast<int>(*action_state_ptr) : -1,
                                 tick_count);
                    prev_local_afterimage_color[0] = local_afterimage_color.r;
                    prev_local_afterimage_color[1] = local_afterimage_color.g;
                    prev_local_afterimage_color[2] = local_afterimage_color.b;
                }
            }

            // Cling-gem / wall-ride state, edge-logged -- see prev_wallride_button_held's comment
            // in Plugin.hpp and WALLRIDE_TRACE's own comment.
            if constexpr (WALLRIDE_TRACE)
            {
                bool* wr_held_ptr = pawn->GetValuePtrByPropertyNameInChain<bool>(STR("wallRideButtonHeld?"));
                bool* can_wr_ptr = pawn->GetValuePtrByPropertyNameInChain<bool>(STR("canWallRun"));
                int32_t* clings_ptr = pawn->GetValuePtrByPropertyNameInChain<int32_t>(STR("currentWallRunClings"));
                UObject** wr_vfx_ptr = pawn->GetValuePtrByPropertyNameInChain<UObject*>(STR("wallRideVFX"));

                bool wr_held_now = wr_held_ptr ? *wr_held_ptr : false;
                bool can_wr_now = can_wr_ptr ? *can_wr_ptr : false;
                int32_t clings_now = clings_ptr ? *clings_ptr : -1;
                bool wr_vfx_valid_now = (wr_vfx_ptr && *wr_vfx_ptr);

                if (wr_held_now != prev_wallride_button_held ||
                    can_wr_now != prev_can_wall_run ||
                    clings_now != prev_current_wall_run_clings ||
                    wr_vfx_valid_now != prev_wallride_vfx_valid)
                {
                    Output::send(STR("[MeshGhostPseudo] TRACE wallRide: buttonHeld={} canWallRun={} clings={} wallRideVFX={} actionState={} moveState={} movementMode={} tick={}\n"),
                                 wr_held_now, can_wr_now, clings_now,
                                 wr_vfx_valid_now ? STR("non-null") : STR("null"),
                                 action_state_ptr ? static_cast<int>(*action_state_ptr) : -1,
                                 move_state_ptr ? static_cast<int>(*move_state_ptr) : -1,
                                 static_cast<int>(movement_mode),
                                 tick_count);
                    prev_wallride_button_held = wr_held_now;
                    prev_can_wall_run = can_wr_now;
                    prev_current_wall_run_clings = clings_now;
                    prev_wallride_vfx_valid = wr_vfx_valid_now;
                }
            }

            // Ultra-state candidates, edge-logged -- see prev_ultra_cap's comment in Plugin.hpp.
            // Read defensively (a name not resolving just means "not this build/this object"), same
            // posture as every other GetValuePtrByPropertyNameInChain call in this file.
            if constexpr (TRAIL_TRIGGER_TRACE)
            {
                bool* ultra_cap_ptr = pawn->GetValuePtrByPropertyNameInChain<bool>(STR("ultraCap"));
                double* full_ultra_ptr = pawn->GetValuePtrByPropertyNameInChain<double>(STR("fullUltraModifier"));
                double* capped_ultra_ptr = pawn->GetValuePtrByPropertyNameInChain<double>(STR("cappedUltraModifier"));

                bool ultra_cap_now = ultra_cap_ptr ? *ultra_cap_ptr : false;
                double full_ultra_now = full_ultra_ptr ? *full_ultra_ptr : -1.0;
                double capped_ultra_now = capped_ultra_ptr ? *capped_ultra_ptr : -1.0;
                int32_t anim_jump_type_now = anim_jump_type_ptr ? static_cast<int32_t>(*anim_jump_type_ptr) : -1;

                constexpr double ULTRA_EPSILON = 0.0001;
                bool ultra_changed = (ultra_cap_now != prev_ultra_cap) ||
                                     (std::fabs(full_ultra_now - prev_full_ultra_modifier) > ULTRA_EPSILON) ||
                                     (std::fabs(capped_ultra_now - prev_capped_ultra_modifier) > ULTRA_EPSILON) ||
                                     (anim_jump_type_now != prev_anim_jump_type);
                if (ultra_changed)
                {
                    Output::send(STR("[MeshGhostPseudo] TRACE ultraState: ultraCap={} fullUltraModifier={:.4f} cappedUltraModifier={:.4f} animJumpType={} actionState={} vSpeed={:.1f} tick={}\n"),
                                 ultra_cap_now, full_ultra_now, capped_ultra_now, anim_jump_type_now,
                                 action_state_ptr ? static_cast<int>(*action_state_ptr) : -1,
                                 v_speed_ptr ? *v_speed_ptr : -1.0,
                                 tick_count);
                    prev_ultra_cap = ultra_cap_now;
                    prev_full_ultra_modifier = full_ultra_now;
                    prev_capped_ultra_modifier = capped_ultra_now;
                    prev_anim_jump_type = anim_jump_type_now;
                }
            }

            // landed_count/jumped_count are monotonic (see Plugin.hpp's comment on them), so unlike
            // the old bool latch, no clear-after-send handoff step is needed -- whatever value is
            // baked into this tick's JSON is simply the count as of this tick; on_update no longer
            // needs to touch these members at all.
            //
            // std::format runs unlocked -- found in a review pass: it's a pure computation with
            // no access to any state on_update's thread also touches, so holding state_mutex
            // across it (as this used to) only needlessly extended the critical section against
            // that other thread for no correctness benefit. Only the final assignment into
            // cached_local_state_json, which on_update does read, needs the lock.
            std::string local_state = std::format(
                "{{\"type\":\"local_state\",\"payload\":{{\"state\":{{\"area_id\":\"{}\",\"position\":[{},{},{}],"
                "\"orientation\":[{},{},{}],\"anim\":\"idle\","
                "\"extras\":{{\"move_state\":{},\"action_state\":{},\"h_speed\":{},\"v_speed\":{},\"anim_jump_type\":{},\"movement_mode\":{},"
                "\"land_count\":{},\"jump_count\":{},\"weapon_equipped\":{},\"outfit_mesh\":\"{}\",\"afterimage_count\":{},"
                "\"montage\":\"{}\",\"montage_count\":{},\"montage_stop_count\":{},"
                "\"afterimage_n\":{},\"capsule_half\":{:.1f},\"bubble_charged\":{},"
                "\"afterimage_color\":[{:.4f},{:.4f},{:.4f}],"
                // Thrown Dream Breaker -- see the local read above. Only the flag is always
                // present; the class path and transform are sent as fixed one-decimal values
                // (0.1 Unreal units is well under a visible difference) specifically to bound
                // this block's size, since agent_docs/contract.md caps extras at
                // MaxExtrasBytes = 1024 and an unbounded double can print 17 significant digits.
                // Measured worst case with this block: ~689 bytes.
                "\"weapon_thrown\":{},\"weapon_class\":\"{}\",\"weapon_state\":{},\"weapon_glow\":\"{}\",\"recall_glow\":{},"
                "\"weapon_pos\":[{:.1f},{:.1f},{:.1f}],\"weapon_rot\":[{:.1f},{:.1f},{:.1f}]}}"
                "}}}}}}",
                json_escape(area_id),
                location.X(),
                location.Y(),
                location.Z(),
                rotation.GetPitch(),
                rotation.GetYaw(),
                rotation.GetRoll(),
                move_state_ptr ? static_cast<int>(*move_state_ptr) : 0,
                action_state_ptr ? static_cast<int>(*action_state_ptr) : 0,
                h_speed_ptr ? *h_speed_ptr : 0.0,
                v_speed_ptr ? *v_speed_ptr : 0.0,
                anim_jump_type_ptr ? static_cast<int>(*anim_jump_type_ptr) : 0,
                static_cast<int>(movement_mode),
                landed_count,
                jumped_count,
                (weapon_equipped_ptr && *weapon_equipped_ptr) ? 1 : 0,
                json_escape(outfit_mesh),
                afterimage_count,
                json_escape(montage_path),
                montage_count,
                montage_stop_count,
                afterimage_spawn_n,
                local_capsule_half,
                local_bubble_charged ? 1 : 0,
                local_afterimage_color.r,
                local_afterimage_color.g,
                local_afterimage_color.b,
                weapon_thrown ? 1 : 0,
                json_escape(weapon_class),
                weapon_state,
                json_escape(weapon_glow),
                local_recall_glow ? 1 : 0,
                weapon_x,
                weapon_y,
                weapon_z,
                weapon_pitch,
                weapon_yaw,
                weapon_roll);
            {
                std::lock_guard<std::mutex> lock(state_mutex);
                cached_local_state_json = std::move(local_state);
            }
        }
        else
        {
            ticks_since_pawn_valid = 0; // e.g. back at the title screen -- re-arm the spawn delay
            std::lock_guard<std::mutex> lock(state_mutex);
            cached_local_state_json = R"({"type":"local_state","payload":{"state":null}})";
        }

        std::vector<std::string> lines_to_process;
        bool disconnect_cleanup_pending = false;
        {
            std::lock_guard<std::mutex> lock(state_mutex);
            lines_to_process.swap(pending_incoming_lines);
            disconnect_cleanup_pending = bridge_disconnect_cleanup_pending;
            bridge_disconnect_cleanup_pending = false;
        }
        for (const std::string& line : lines_to_process)
        {
            handle_bridge_line(line, pawn_obj, controller);
        }
        if (disconnect_cleanup_pending)
        {
            release_all_ghosts_parked(STR("bridge disconnected"));
        }

        // Redraw every currently-known remote unconditionally, every tick -- per PROTOCOL.md,
        // not only on ticks where new network data arrived.
        for (auto& [id, remote] : remotes)
        {
            if (!remote.ghost)
            {
                continue;
            }
            // Staleness check, ported from Lua's per-tick `not remote.ghost:IsValid()` poll
            // (probe_ghost/Scripts/main.lua:787-794). See actor_is_alive's own comment for why
            // this is IsValid()'s real C++ equivalent, not a guess.
            //
            // Reviewed for the same cached-raw-pointer risk that caused a real, confirmed crash
            // in the camera fight-back's cached view target (that mechanism was removed
            // 2026-08-16; see verified.md): calling
            // ->IsUnreachable() on a raw AActor* is only safe if the object is merely GC-
            // unreachable-but-still-allocated, not if its memory has actually been freed already.
            // For the one destruction path this codebase has ever actually observed -- a level
            // transition -- that's covered proactively, not reactively: release_all_ghosts fires
            // in the very same LoadMap PRE hook (before the transition proceeds) and nulls
            // remote.ghost there, so by the time this line would run afterward, `if (!remote.ghost)
            // continue;` above has already skipped it; this check never sees a LoadMap-transition-
            // freed pointer at all. This line remains as a defensive second layer for any actor
            // destruction that *doesn't* route through UEngine::LoadMap (a streaming sub-level
            // unload, EndPlay-driven destruction, unrelated GC) -- genuinely possible, but not a
            // path this project has ever reproduced a crash through, unlike the LoadMap one. Not
            // hardened further pending an actual reproduction, per CLAUDE.md's "no addresses/fixes
            // from memory" standard applied to speculative crash fixes: a change here carries real
            // risk in a file with a proven crash history from exactly this class of edit.
            if (!actor_is_alive(remote.ghost))
            {
                Output::send(STR("[MeshGhostPseudo] remote {} ghost is no longer valid (level transition) -- releasing stale reference, will respawn fresh.\n"),
                             to_wide_ascii(id));
                hijacked_actors.erase(remote.ghost);
                // The recall glow is attached to this ghost -- it dies with the actor, so only the
                // reference needs clearing before a fresh ghost spawns its own.
                remote.recall_glow_component = nullptr;
                remote.recall_glow_shown = false;
                remote.recall_glow_swept = false;
                remote.spawn_weapon_trace_tick = 0;
                remote.spawn_weapon_traced_at_spawn = false;
                remote.spawn_weapon_traced_after = false;
            // **Re-arm every "already synced" latch, because the NEXT ghost is a different actor.**
            // Found 2026-08-16 while reading this path for the spawn-mid-throw capture. These
            // latches exist to avoid re-calling transition functions every tick, but they describe
            // a ghost that is about to stop existing. A replacement ghost constructs itself from
            // the LOCAL player's save, so if the peer's value happens to equal what was last synced
            // to the old ghost, there is no edge, the transition function is never called, and the
            // new ghost keeps its construction state forever -- wearing the local player's outfit,
            // or holding a sword the peer has thrown. Same bug family as the dangling prop pointer:
            // per-ghost state that outlived its ghost.
            remote.weapon_equip_call_armed = false;
            remote.last_synced_weapon_equipped = false;
            remote.last_synced_outfit_mesh.clear();
            remote.last_failed_outfit_mesh.clear();
                remote.ghost = nullptr;
                remote.owning_world = nullptr;
                continue;
            }
            // Cheaper secondary check: only meaningful once current_world has actually resolved
            // this tick (it's null on ticks where the local pawn/controller aren't found, e.g.
            // mid-transition -- don't treat that as "the world changed", just skip the check).
            if (current_world && remote.owning_world && remote.owning_world != current_world)
            {
                Output::send(STR("[MeshGhostPseudo] remote {} ghost's world changed (local player transitioned) -- releasing stale reference, will respawn fresh.\n"),
                             to_wide_ascii(id));
                hijacked_actors.erase(remote.ghost);
                // The recall glow is attached to this ghost -- it dies with the actor, so only the
                // reference needs clearing before a fresh ghost spawns its own.
                remote.recall_glow_component = nullptr;
                remote.recall_glow_shown = false;
                remote.recall_glow_swept = false;
                remote.spawn_weapon_trace_tick = 0;
                remote.spawn_weapon_traced_at_spawn = false;
                remote.spawn_weapon_traced_after = false;
            // **Re-arm every "already synced" latch, because the NEXT ghost is a different actor.**
            // Found 2026-08-16 while reading this path for the spawn-mid-throw capture. These
            // latches exist to avoid re-calling transition functions every tick, but they describe
            // a ghost that is about to stop existing. A replacement ghost constructs itself from
            // the LOCAL player's save, so if the peer's value happens to equal what was last synced
            // to the old ghost, there is no edge, the transition function is never called, and the
            // new ghost keeps its construction state forever -- wearing the local player's outfit,
            // or holding a sword the peer has thrown. Same bug family as the dangling prop pointer:
            // per-ghost state that outlived its ghost.
            remote.weapon_equip_call_armed = false;
            remote.last_synced_weapon_equipped = false;
            remote.last_synced_outfit_mesh.clear();
            remote.last_failed_outfit_mesh.clear();
                remote.ghost = nullptr;
                remote.owning_world = nullptr;
                continue;
            }
            FVector target_loc(remote.target_x, remote.target_y, remote.target_z);
            FRotator target_rot(remote.target_pitch, remote.target_yaw, remote.target_roll);
            // Facing-direction root cause fix, 2026-08-13: the real bug was never bTeleport --
            // it was the vendored SDK's K2_SetActorLocationAndRotation marshaling FRotator's
            // Pitch/Yaw/Roll as hardcoded float into a double-sized slot on this UE5 game (see
            // call_set_actor_location_and_rotation's comment for the full root cause). bTeleport
            // is still true here, matching the local-test path and the "this is a teleport, not a
            // physics move" reasoning below -- just no longer the fix itself.
            call_set_actor_location_and_rotation(remote.ghost, target_loc, target_rot);

            // Thrown Dream Breaker -- a second, independent actor with its own lifetime. Placed
            // here, after the ghost's own staleness checks have run, so it never spawns a loose
            // sword for a peer whose ghost has just been invalidated by a level transition.
            tick_remote_weapon(id, remote, current_world);

            // The empty-hand recall glow. Edge-gated inside, so this is a cheap no-op on the vast
            // majority of ticks.
            tick_remote_recall_glow(id, remote);

            if constexpr (GHOST_SPAWN_WEAPON_TRACE)
            {
                tick_ghost_spawn_weapon_trace(id, remote);
            }

            if constexpr (AFTERIMAGE_DISCOVERY)
            {
                tick_afterimage_discovery(remote.ghost);
            }

            // Runs on whichever ghost comes first and only that one -- the probe's value is being
            // able to say "that look is this asset", which two ghosts showing different effects at
            // once would destroy. Guarded by its own last-switch tick, so the loop calling it once
            // per remote per tick doesn't advance the cycle faster with more peers present.
            if constexpr (VFX_CATALOG_PROBE)
            {
                tick_vfx_catalog_probe(remote.ghost);
            }

            // Bubble FLASH mirror, 2026-08-15 -- the real mechanism, replacing the afterimage
            // approximation (see BUBBLE_SPAWNS_AFTERIMAGES in tickLocal).
            //
            // **Found by asking the class what its API is called**, the same step that produced
            // `Montage_Play` and with it the entire montage mirror. `BP_PlayerGoatMain_C` carries
            // `StartBubbleJumpFlash(Condition: bool)` and `changeBubbleChargedJump(
            // hasBubbleChargedJump: bool)` -- named for exactly the effect and exactly the state the
            // user described, instead of anything this adapter had to infer.
            //
            // Driven off the peer's own in-bubble state (moveState==7 && movementMode==5, measured)
            // rather than a guessed duration, which is the whole point: the previous version could
            // not stop at the right time because it was counting ticks instead of following the
            // peer. Called on EDGES only, never per tick -- these are "start"/"change" verbs, and
            // hammering a Blueprint event every frame is how you get an effect that retriggers
            // instead of running.
            //
            // **NOT yet confirmed to do anything visible on a ghost.** `CustomPlayMontage` is this
            // project's recorded precedent for a Blueprint wrapper that returns cleanly on a ghost
            // and does nothing, so the call firing is not the result -- the user watching is. If
            // this comes back a clean negative, the montage saga's lesson applies: look for the
            // stock engine call underneath the wrapper (here, the `Blink`/`Timeline_*`
            // TimelineComponents the same dump found, which have Play/Stop of their own).
            {
                constexpr uint8_t IN_BUBBLE_MOVE_STATE = 7;
                constexpr uint8_t BUBBLE_MOVEMENT_MODE = 5;
                bool peer_in_bubble = (clamp_to_uint8(remote.target_move_state) == IN_BUBBLE_MOVE_STATE &&
                                       clamp_to_uint8(remote.target_movement_mode) == BUBBLE_MOVEMENT_MODE);
                // **The peer's own charged flag wins when it has one** -- that is the whole fix for
                // "leaving the bubble while it was active didn't keep it". The in-bubble state ends
                // the moment the peer jumps out, so driving from it necessarily drops the effect
                // there; the game's flag stays true until the boost or a landing, which is exactly
                // the rule the user described, maintained by the game rather than timed by us.
                // OR'd with the in-bubble state rather than replacing it, so a peer on an older
                // build that never sends the flag keeps today's working in-bubble behaviour instead
                // of losing the effect entirely.
                bool peer_flash_on = peer_in_bubble || remote.target_bubble_charged;
                if (peer_flash_on != remote.ghost_bubble_flash_on)
                {
                    remote.ghost_bubble_flash_on = peer_flash_on;
                    bool charged_ok = call_bool_ufunction(remote.ghost, STR("changeBubbleChargedJump"),
                                                          STR("hasBubbleChargedJump"), peer_flash_on);
                    bool flash_ok = call_bool_ufunction(remote.ghost, STR("StartBubbleJumpFlash"),
                                                        STR("Condition"), peer_flash_on);
                    Output::send(STR("[MeshGhostPseudo] BUBBLE ghost {}: flash={} (in_bubble={} peerCharged={}) changeBubbleChargedJump={} StartBubbleJumpFlash={}\n"),
                                 to_wide_ascii(id), peer_flash_on, peer_in_bubble, remote.target_bubble_charged,
                                 charged_ok, flash_ok);
                }
            }

            // POLE_ROTATION_TRACE, ghost half -- see the flag's comment. Reads the ghost's ACTUAL
            // yaw back from the world rather than echoing target_rot (CLAUDE.md: never log the value
            // you just wrote), plus its VisualMesh relative yaw, which is where this game is already
            // known to express facing. Throttled to the existing ~2s cadence: the local half logs on
            // change and carries the timing, this only needs to answer "did the ghost follow".
            if constexpr (POLE_ROTATION_TRACE)
            {
                constexpr uint8_t FLYING_MOVEMENT_MODE = 5;
                if (clamp_to_uint8(remote.target_movement_mode) == FLYING_MOVEMENT_MODE &&
                    tick_count % MONTAGE_DIVERGENCE_CHECK_INTERVAL_TICKS == 0)
                {
                    FRotator actual = remote.ghost->K2_GetActorRotation();
                    double g_vm_yaw = -9999.0;
                    if (UObject** g_vm = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("VisualMesh")); g_vm && *g_vm)
                    {
                        if (FRotator* g_vm_rot = (*g_vm)->GetValuePtrByPropertyNameInChain<FRotator>(STR("RelativeRotation")))
                        {
                            g_vm_yaw = g_vm_rot->GetYaw();
                        }
                    }
                    Output::send(STR("[MeshGhostPseudo] POLE ghost {} tick={} moveState={} wantYaw={:.1f} actualYaw={:.1f} visualMeshYaw={:.1f}\n"),
                                 to_wide_ascii(id), tick_count,
                                 static_cast<int>(clamp_to_uint8(remote.target_move_state)),
                                 target_rot.GetYaw(), actual.GetYaw(), g_vm_yaw);
                }
            }

            // Ghost animation (see verified.md's "ghost animation" entry): the ghost is a full
            // spawned clone of the same BP_PlayerGoatMain_C class, so it has its own
            // moveState/actionState/horizontalSpeed/verticalSpeed/animJumpType and its own
            // already-attached ABP_PlayerGoat_C anim instance mirroring them every tick, same as
            // the real player. Writing the real player's values onto the ghost's copies each tick
            // should make the ghost's anim instance drive itself the same way -- no direct AnimBP
            // writes needed. No-ops safely (nullptr checks) in hijack mode, where the ghost is a
            // StaticMeshActor with no such properties.
            if (uint8_t* g_move_state = remote.ghost->GetValuePtrByPropertyNameInChain<uint8_t>(STR("moveState")))
            {
                *g_move_state = clamp_to_uint8(remote.target_move_state);
            }
            if (uint8_t* g_action_state = remote.ghost->GetValuePtrByPropertyNameInChain<uint8_t>(STR("actionState")))
            {
                *g_action_state = clamp_to_uint8(remote.target_action_state);
            }
            if (double* g_h_speed = remote.ghost->GetValuePtrByPropertyNameInChain<double>(STR("horizontalSpeed")))
            {
                *g_h_speed = remote.target_h_speed;
            }
            if (double* g_v_speed = remote.ghost->GetValuePtrByPropertyNameInChain<double>(STR("verticalSpeed")))
            {
                *g_v_speed = remote.target_v_speed;
            }
            if (uint8_t* g_anim_jump_type = remote.ghost->GetValuePtrByPropertyNameInChain<uint8_t>(STR("animJumpType")))
            {
                *g_anim_jump_type = clamp_to_uint8(remote.target_anim_jump_type);
            }
            // "Stuck flying after jump" fix -- see RemoteGhost::target_movement_mode's comment.
            if (UObject** g_movement_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("CharacterMovement")); g_movement_ptr && *g_movement_ptr)
            {
                if (uint8_t* g_movement_mode = (*g_movement_ptr)->GetValuePtrByPropertyNameInChain<uint8_t>(STR("MovementMode")))
                {
                    *g_movement_mode = clamp_to_uint8(remote.target_movement_mode);
                }
            }
            // Ghost-side state timeline for the ledge-lingering question -- see ANIM_TRACE's own
            // comment. Logged right after the writes above, on change only, so it lines up
            // line-for-line with the local timeline and the gap between "the real player let go"
            // and "the ghost was told" can simply be read off the timestamps. Logs what was
            // WRITTEN this tick (the values driving the ghost's AnimBP), which is the thing whose
            // arrival time is in question.
            if constexpr (ANIM_TRACE)
            {
                int move_state_applied = static_cast<int>(clamp_to_uint8(remote.target_move_state));
                int action_state_applied = static_cast<int>(clamp_to_uint8(remote.target_action_state));
                int movement_mode_applied = static_cast<int>(clamp_to_uint8(remote.target_movement_mode));
                // animJumpType added 2026-08-15: the first capture showed a climb-up exit is
                // exactly 'moveState=1 actionState=0 animJumpType=6' for ~0.4s where a drop-down is
                // animJumpType=0 -- i.e. the one field that distinguishes the case that looks wrong
                // from the case that looks right was the one field this trace didn't carry.
                int anim_jump_type_applied = static_cast<int>(clamp_to_uint8(remote.target_anim_jump_type));
                if (!remote.anim_trace_initialized ||
                    move_state_applied != remote.anim_trace_prev_move_state ||
                    action_state_applied != remote.anim_trace_prev_action_state ||
                    movement_mode_applied != remote.anim_trace_prev_movement_mode ||
                    anim_jump_type_applied != remote.anim_trace_prev_anim_jump_type)
                {
                    // Independent readback of what the ghost ACTUALLY holds plus what it's actually
                    // playing, rather than only the values just written -- CLAUDE.md's "never log
                    // the value you just wrote as proof it worked", and the specific question here
                    // is whether the ghost is still in the LedgeGrab montage while it looks stuck.
                    int rb_move = -1, rb_ajt = -1;
                    if (uint8_t* rb_ms = remote.ghost->GetValuePtrByPropertyNameInChain<uint8_t>(STR("moveState")))
                    {
                        rb_move = static_cast<int>(*rb_ms);
                    }
                    if (uint8_t* rb_aj = remote.ghost->GetValuePtrByPropertyNameInChain<uint8_t>(STR("animJumpType")))
                    {
                        rb_ajt = static_cast<int>(*rb_aj);
                    }
                    std::string rb_montage;
                    if (UObject** g_abp_rb = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref")); g_abp_rb && *g_abp_rb)
                    {
                        read_current_active_montage(*g_abp_rb, rb_montage);
                    }
                    Output::send(STR("[MeshGhostPseudo] TRACE animState ghost {}: moveState={} actionState={} movementMode={} animJumpType={} | readback moveState={} animJumpType={} montage='{}'\n"),
                                 to_wide_ascii(id), move_state_applied, action_state_applied, movement_mode_applied,
                                 anim_jump_type_applied, rb_move, rb_ajt, to_wide_ascii(rb_montage));
                    remote.anim_trace_prev_anim_jump_type = anim_jump_type_applied;
                    remote.anim_trace_initialized = true;
                    remote.anim_trace_prev_move_state = move_state_applied;
                    remote.anim_trace_prev_action_state = action_state_applied;
                    remote.anim_trace_prev_movement_mode = movement_mode_applied;
                }
            }

            // Dream Breaker visibility mirror -- see RemoteGhost::target_weapon_equipped's
            // comment. **Reordered 2026-08-15** (real fix attempt #6, see verified.md's animBPref
            // spawn-snapshot entry): the raw property writes below used to run BEFORE these two
            // function calls, every tick, unconditionally -- so by the time
            // updateWeaponEquip/changeEquippedWeapon actually fired on a real transition,
            // weaponEquipped?/animEquippedWeapon had ALREADY been overwritten to the new value on
            // that same tick. If either function's own Blueprint graph does the ordinary "only
            // play the transition if the value actually changed" comparison against the pawn's
            // current property (a common pattern for a named "update"/"change" event), it would
            // always see old==new and silently do nothing -- which would explain both calls
            // failing identically without either being the wrong function. Calling them FIRST,
            // while the ghost's own property still holds the OLD value, is a real, testable fix
            // for that specific failure mode -- not yet confirmed live.
            if (!remote.weapon_equip_call_armed || remote.target_weapon_equipped != remote.last_synced_weapon_equipped)
            {
                if constexpr (WEAPON_SYNC_TRACE)
                {
                    Output::send(STR("[MeshGhostPseudo] TRACE weapon ghost {}: calling changeEquippedWeapon/updateWeaponEquip({}) -- armed={} prev={}\n"),
                                 to_wide_ascii(id), remote.target_weapon_equipped, remote.weapon_equip_call_armed, remote.last_synced_weapon_equipped);
                }
                call_change_equipped_weapon(remote.ghost, remote.target_weapon_equipped);
                if (UObject** g_abp_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref")); g_abp_ptr && *g_abp_ptr)
                {
                    call_update_weapon_equip(*g_abp_ptr, remote.target_weapon_equipped);
                }

                // call_manage_recall_idle_fx(remote.ghost) was wired in here on this same edge and
                // live-tested 2026-08-15: NO glow appeared (see verified.md's
                // "manageRecallIdleFX: NEGATIVE" entry). Removed rather than left in as a no-op --
                // it spawns a sound as well as a Niagara system, so an unproven call sitting in the
                // shipped weapon path is a real (if small) risk for zero current benefit. The
                // helper itself is kept, documented, ready for a retry once the precondition its
                // IsValid guards need (plausibly a real thrown-weapon actor via 'weaponRef') can
                // actually be satisfied on a ghost.
                remote.last_synced_weapon_equipped = remote.target_weapon_equipped;
                remote.weapon_equip_call_armed = true;
            }
            // Montage mirror -- see RemoteGhost::target_montage. Deliberately NOT tied to the
            // weapon-equip edge above: this is the general "the peer's character started playing
            // an animation montage" path, and the Dream Breaker throw is simply its first
            // customer. Counter-gated the same way as the land/jump pulses, so a montage shorter
            // than the send interval still arrives.
            bool montage_started_this_tick = false;
            if (remote.target_montage_count > remote.last_seen_montage_count && !remote.target_montage.empty())
            {
                remote.last_seen_montage_count = remote.target_montage_count;
                montage_started_this_tick = true;
                UObject* montage_obj = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, to_wide_ascii(remote.target_montage).c_str());
                // Type check, same reasoning as the outfit mesh's: a path that resolves to
                // something that isn't a montage must not be handed to CustomPlayMontage.
                if (montage_obj && montage_obj->GetClassPrivate() && montage_obj->GetClassPrivate()->GetName() != STR("AnimMontage"))
                {
                    Output::send(STR("[MeshGhostPseudo] WARNING: montage path '{}' resolved to a {}, not an AnimMontage -- ignoring.\n"),
                                 to_wide_ascii(remote.target_montage), montage_obj->GetClassPrivate()->GetName());
                    montage_obj = nullptr;
                }
                if (montage_obj)
                {
                    // call_custom_play_montage(remote.ghost, montage_obj) was here and is a
                    // recorded NEGATIVE -- see call_montage_play's comment. The helper is kept,
                    // documented, and simply not called: the game's own wrapper is still the more
                    // "correct" entry point in principle, and would be the thing to revisit if the
                    // ghost ever gains the possession state it seems to need.
                    float play_length = -1.0f;
                    // Suppressed wholesale while GHOST_SELF_MONTAGE_PROBE is on -- the counter above
                    // still advances so nothing backlogs, but no montage is started. See that flag.
                    if constexpr (!GHOST_SELF_MONTAGE_PROBE)
                    {
                        if (UObject** g_abp_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref")); g_abp_ptr && *g_abp_ptr)
                        {
                            play_length = call_montage_play(*g_abp_ptr, montage_obj);
                        }
                    }
                    if constexpr (ANIM_TRACE)
                    {
                        // Arm the post-call readback (see montage_readback_ticks_left's comment).
                        remote.montage_readback_ticks_left = 12;
                        // play_length is the engine's own verdict: >0 is the length of the montage
                        // it started, 0 means it declined, -1 means the call was never made. Still
                        // not proof the animation is VISIBLE -- only the user watching the ghost
                        // establishes that -- but unlike CustomPlayMontage's silent success it
                        // distinguishes "started" from "refused" without waiting for the readback.
                        Output::send(STR("[MeshGhostPseudo] TRACE montage ghost {}: Montage_Play('{}') length={:.3f} count={}\n"),
                                     to_wide_ascii(id), to_wide_ascii(remote.target_montage), play_length, remote.target_montage_count);
                    }
                }
                else if (remote.target_montage != remote.last_failed_montage ||
                         tick_count - remote.last_montage_warn_tick >= LOG_INTERVAL_TICKS)
                {
                    // Throttled per last_failed_montage's comment -- a peer on a build whose
                    // montage assets this machine doesn't have must not spam a warning per throw.
                    Output::send(STR("[MeshGhostPseudo] WARNING: montage path '{}' did not resolve on this machine -- ghost keeps its current animation.\n"),
                                 to_wide_ascii(remote.target_montage));
                    remote.last_failed_montage = remote.target_montage;
                    remote.last_montage_warn_tick = tick_count;
                }
            }

            // Stop half of the montage mirror -- see the local montage_stop_count's comment for the
            // ledge-grab symptom that motivated it. Checked AFTER the start block above so that a
            // sample carrying both a stop and a start (one montage ending as the next begins, which
            // the send cadence can easily merge into one packet) doesn't stop the montage it just
            // started -- ordering matters here in exactly the way the weapon call/write reorder
            // taught.
            if (remote.target_montage_stop_count > remote.last_seen_montage_stop_count)
            {
                remote.last_seen_montage_stop_count = remote.target_montage_stop_count;
                // Only stop if a montage didn't just START on this same tick -- see above. This has
                // to be an explicit flag set by the start block: comparing the counters here would
                // always read "no start", because the start block advances last_seen_montage_count
                // itself, so the check would stop the very montage just started.
                // Suppressed while either probe is on -- see MONTAGE_PROBES_SUPPRESS_ADAPTER_STOPS.
                if (!montage_started_this_tick && !MONTAGE_PROBES_SUPPRESS_ADAPTER_STOPS)
                {
                    if (UObject** g_abp_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref")); g_abp_ptr && *g_abp_ptr)
                    {
                        // **0.0f, corrected 2026-08-15 from a live capture.** This was 0.1f on the
                        // reasoning that a normal end-of-animation deserves a soft blend rather
                        // than the land/jump pulse's hard snap. The measurement says otherwise: on
                        // a ledge climb-UP (no landing, so the pulse never fires and this is the
                        // only stop that runs) the ghost kept playing LedgeGrab_Montage for ~2s
                        // after this call, readback-confirmed -- while a drop-DOWN cleared fine,
                        // because the landing pulse's 0.0f stop was doing the real work there. The
                        // hard stop is the one shape known to work on a ghost's anim instance on
                        // this build; the soft blend is not, and this is not the place to find out
                        // why. See verified.md's ledge-grab entry.
                        call_montage_stop(*g_abp_ptr, 0.0f);
                        if constexpr (ANIM_TRACE)
                        {
                            // Read back IMMEDIATELY, same tick, right after the call -- the one
                            // measurement that splits the two remaining explanations for the
                            // ledge-climb-up lingering (~1.4s, measured). If this reads 'none', the
                            // stop works and something RE-STARTS the montage afterwards; if it
                            // still reads the montage, the call itself is a no-op here even though
                            // the byte-identical call in the land/jump pulse below demonstrably
                            // works. Guessing between those two produced one wrong fix already
                            // (the 0.1f->0.0f blend change, which measured as no change at all).
                            std::string after_stop;
                            read_current_active_montage(*g_abp_ptr, after_stop);
                            Output::send(STR("[MeshGhostPseudo] TRACE montage ghost {}: Montage_Stop (stop_count={}) -- immediately after, playing='{}'\n"),
                                         to_wide_ascii(id), remote.target_montage_stop_count, to_wide_ascii(after_stop));
                        }
                    }
                }
            }

            // Montage divergence correction, 2026-08-15 -- the fix for the ledge-climb-up
            // lingering, after two wrong guesses (a blend-time change that measured as no change,
            // and a "the stop call doesn't work" theory the readback disproved).
            //
            // **Root cause, PROVEN 2026-08-15 by GHOST_SELF_MONTAGE_PROBE across three runs** (this
            // block originally shipped against an explicitly-unproven guess, which the probe then
            // showed to be wrong -- see verified.md, and note the fix survived being wrong because
            // it was deliberately written not to depend on the guess):
            //  * The ghost self-starts montages. With every montage call in this file compiled out,
            //    the ghost still began `dreamLady_LedgeGrab_Montage` on its own, all three runs.
            //  * It is NOT collision. Run 2 with GHOST_COLLISION_ENABLED=false behaved identically,
            //    with the ghost visibly unable to hang on the ledge and stuck in the pose anyway.
            //  * It is the STATE SYNC, and it fires on the transition OUT of the hang, not into it.
            //    The ghost held the synced hang state (moveState=3/movementMode=5) for a full 5s
            //    playing nothing, then started the montage ~0.42s after being told the hang ended
            //    (moveState->1, movementMode->3, animJumpType 6->0). This adapter writes those
            //    fields, `ABP_PlayerGoat_C` acts on them, and the graph plays the climb-up montage.
            //
            // So the self-start is the game's own animation logic working correctly on a pawn clone
            // -- exactly what mirroring state is supposed to buy. What a ghost cannot do is FINISH
            // it: the montage holds a section that input-driven logic normally advances, and a ghost
            // has no controller, so the pose sticks forever. Correcting it from outside is therefore
            // the right shape, not a workaround, and no "stop syncing that field" fix is wanted --
            // that would trade a stuck pose for a dead one.
            //
            // The rule: the peer is the authority on what montage its ghost plays. If what the ghost
            // is playing differs from what the peer is playing, the ghost's is wrong.
            //
            // **Widened 2026-08-15 from "peer plays nothing" to "peer plays something else."** The
            // original only ran when `target_montage` was empty, so a ghost that self-started the
            // wrong montage *while the peer played a different one* stayed uncorrected until the
            // peer's own montage ended. On a ledge that window is short; on a climbing pole, where a
            // peer may play a climb montage continuously, it is not -- which makes this a candidate
            // for the "ghost returns stuck in a climb pose" bug (status.md), still unconfirmed.
            // When the peer IS playing something, the correction re-plays it in the same breath
            // rather than leaving the ghost bare. That cannot loop: if the re-play fails the ghost
            // ends up playing nothing, and this block does nothing at all when the ghost is idle.
            //
            // Suppressed while either montage probe is on -- these are montage calls on a ghost like
            // any other. GHOST_SELF_MONTAGE_PROBE needs them gone to see what the ghost does alone;
            // MONTAGE_CATALOG_PROBE needs them gone because it deliberately plays montages the peer
            // isn't playing, which is precisely what this block exists to undo.
            if (!MONTAGE_PROBES_SUPPRESS_ADAPTER_STOPS &&
                tick_count % MONTAGE_DIVERGENCE_CHECK_INTERVAL_TICKS == 0)
            {
                if (UObject** g_abp_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref")); g_abp_ptr && *g_abp_ptr)
                {
                    std::string ghost_montage;
                    if (read_current_active_montage(*g_abp_ptr, ghost_montage) &&
                        !ghost_montage.empty() && ghost_montage != "none")
                    {
                        // read_current_active_montage returns UE's "ClassName /Path" full name while
                        // target_montage is the bare path (the local send strips it for
                        // StaticFindObject's sake -- see the outfit mirror's comment for the same
                        // strip and why). Compare like with like, or every tick looks divergent.
                        const size_t space_pos = ghost_montage.find(' ');
                        const std::string ghost_path =
                            (space_pos != std::string::npos) ? ghost_montage.substr(space_pos + 1) : ghost_montage;

                        if (ghost_path != remote.target_montage)
                        {
                            call_montage_stop(*g_abp_ptr, 0.0f);

                            // Peer is playing something else -- put the ghost on the RIGHT montage
                            // instead of just leaving it bare until the next start pulse, which for
                            // a long-held montage might not come for seconds.
                            float restored_length = -1.0f;
                            if (!remote.target_montage.empty())
                            {
                                if (UObject* want = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, to_wide_ascii(remote.target_montage).c_str());
                                    want && want->GetClassPrivate() && want->GetClassPrivate()->GetName() == STR("AnimMontage"))
                                {
                                    restored_length = call_montage_play(*g_abp_ptr, want);
                                }
                            }
                            if constexpr (ANIM_TRACE)
                            {
                                Output::send(STR("[MeshGhostPseudo] TRACE montage ghost {}: divergence -- ghost played '{}', peer wants '{}', stopped (restore length={:.3f})\n"),
                                             to_wide_ascii(id), to_wide_ascii(ghost_path),
                                             to_wide_ascii(remote.target_montage.empty() ? std::string("(nothing)") : remote.target_montage),
                                             restored_length);
                            }
                        }
                    }
                }
            }

            // GHOST_SELF_MONTAGE_PROBE's read-only half -- see that flag's comment for what each
            // outcome means. Polls on the same interval as the divergence check it replaces, and
            // logs one line per CHANGE so a whole session of ledge grabs stays readable. The peer's
            // own target_montage rides along on every line: while the probe is on this adapter
            // starts nothing, so a ghost montage with the peer showing '(none)' is a self-start,
            // and one matching the peer's would mean the mirror is somehow still firing (it can't
            // be -- every call site is compiled out -- but the line proves it rather than assuming).
            if constexpr (GHOST_SELF_MONTAGE_PROBE)
            {
                if (tick_count % MONTAGE_DIVERGENCE_CHECK_INTERVAL_TICKS == 0)
                {
                    if (UObject** g_abp_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref")); g_abp_ptr && *g_abp_ptr)
                    {
                        std::string ghost_montage;
                        if (read_current_active_montage(*g_abp_ptr, ghost_montage))
                        {
                            if (!remote.self_probe_initialized || ghost_montage != remote.self_probe_prev_montage)
                            {
                                remote.self_probe_initialized = true;
                                remote.self_probe_prev_montage = ghost_montage;
                                Output::send(STR("[MeshGhostPseudo] PROBE selfmontage ghost {} tick {}: ghost now playing '{}' (peer target '{}') -- adapter started NOTHING\n"),
                                             to_wide_ascii(id), tick_count, to_wide_ascii(ghost_montage),
                                             to_wide_ascii(remote.target_montage.empty() ? std::string("(none)") : remote.target_montage));
                            }
                        }
                    }
                }
            }

            // MONTAGE_CATALOG_PROBE -- see that flag's comment. Advances on its own wall-clock-ish
            // interval, independent of anything the peer does, and plays each entry on the ghost via
            // the same call_montage_play the production mirror uses, so a result here transfers
            // directly to the mirror rather than being a property of the probe. Logs the resolved
            // asset and Montage_Play's own length verdict; only the user watching establishes that
            // the animation is VISIBLE, which is the whole reason this exists.
            if constexpr (MONTAGE_CATALOG_PROBE)
            {
                if (!remote.catalog_probe_started ||
                    tick_count - remote.catalog_probe_last_tick >= CATALOG_PROBE_INTERVAL_TICKS)
                {
                    if (remote.catalog_probe_started)
                    {
                        remote.catalog_probe_index = (remote.catalog_probe_index + 1) % CATALOG_PROBE_MONTAGES.size();
                    }
                    remote.catalog_probe_started = true;
                    remote.catalog_probe_last_tick = tick_count;

                    const std::string label = CATALOG_PROBE_MONTAGES[remote.catalog_probe_index];
                    if (UObject* montage_obj = find_loaded_montage_by_label(label))
                    {
                        float play_length = -1.0f;
                        if (UObject** g_abp_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref")); g_abp_ptr && *g_abp_ptr)
                        {
                            play_length = call_montage_play(*g_abp_ptr, montage_obj);
                        }
                        Output::send(STR("[MeshGhostPseudo] PROBE catalog ghost {} tick {}: '{}' -> Montage_Play('{}') length={:.3f} -- WATCH THE GHOST NOW\n"),
                                     to_wide_ascii(id), tick_count, to_wide_ascii(label),
                                     montage_obj->GetFullName(), play_length);
                    }
                }
            }

            // Independent readback of what the GHOST's own anim instance is actually playing, for
            // the ticks right after a CustomPlayMontage call -- see montage_readback_ticks_left's
            // comment for why this exists and what each outcome means. Re-fetches animBPref fresh
            // and asks the game, rather than trusting the call's own return value.
            if constexpr (ANIM_TRACE)
            {
                if (remote.montage_readback_ticks_left > 0)
                {
                    --remote.montage_readback_ticks_left;
                    std::string ghost_montage;
                    bool asked = false;
                    if (UObject** g_abp_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref")); g_abp_ptr && *g_abp_ptr)
                    {
                        asked = read_current_active_montage(*g_abp_ptr, ghost_montage);
                    }
                    Output::send(STR("[MeshGhostPseudo] TRACE montage ghost {} readback t+{}: asked={} playing='{}'\n"),
                                 to_wide_ascii(id),
                                 11 - remote.montage_readback_ticks_left,
                                 asked,
                                 to_wide_ascii(ghost_montage));
                }
            }

            // Property write kept as a safety-net sync AFTER the calls above, in case either
            // function has prerequisites/side effects this adapter doesn't drive -- unconditional,
            // every tick, same as before the reorder.
            if (bool* g_weapon_equipped = remote.ghost->GetValuePtrByPropertyNameInChain<bool>(STR("weaponEquipped?")))
            {
                *g_weapon_equipped = remote.target_weapon_equipped;
            }
            if (UObject** g_abp_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref")); g_abp_ptr && *g_abp_ptr)
            {
                if (bool* g_anim_equipped_weapon = (*g_abp_ptr)->GetValuePtrByPropertyNameInChain<bool>(STR("animEquippedWeapon")))
                {
                    *g_anim_equipped_weapon = remote.target_weapon_equipped;
                }
            }
            if constexpr (WEAPON_SYNC_TRACE)
            {
                if (tick_count % LOG_INTERVAL_TICKS == 0)
                {
                    // Independent readback -- re-fetches the pointers fresh rather than reusing
                    // g_weapon_equipped/g_anim_equipped_weapon above, per CLAUDE.md's "never log
                    // the value you just wrote as proof it worked" rule.
                    bool* rb_weapon_equipped = remote.ghost->GetValuePtrByPropertyNameInChain<bool>(STR("weaponEquipped?"));
                    UObject** rb_weapon_mesh = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("WeaponMesh"));
                    // New for the inversion-test run: weaponRef was only ever traced on the local
                    // pawn (see the local WEAPON_SYNC_TRACE block's own comment -- an earlier trace
                    // showed it "genuinely toggles," but its ghost-side value was never recorded).
                    UObject** rb_weapon_ref = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("weaponRef"));
                    bool rb_anim_equipped = false;
                    if (UObject** rb_abp_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref")); rb_abp_ptr && *rb_abp_ptr)
                    {
                        if (bool* rb_anim_ptr = (*rb_abp_ptr)->GetValuePtrByPropertyNameInChain<bool>(STR("animEquippedWeapon")))
                        {
                            rb_anim_equipped = *rb_anim_ptr;
                        }
                    }
                    Output::send(STR("[MeshGhostPseudo] TRACE weapon ghost {}: target_weapon_equipped={} readback_weaponEquipped={} readback_animEquippedWeapon={} readback_WeaponMesh={} readback_weaponRef={}\n"),
                                 to_wide_ascii(id),
                                 remote.target_weapon_equipped,
                                 rb_weapon_equipped ? *rb_weapon_equipped : false,
                                 rb_anim_equipped,
                                 (rb_weapon_mesh && *rb_weapon_mesh) ? STR("non-null") : STR("null"),
                                 (rb_weapon_ref && *rb_weapon_ref) ? STR("non-null") : STR("null"));

                    // Same mesh-asset check as the local block, on the ghost's own WeaponMesh.
                    if (rb_weapon_mesh && *rb_weapon_mesh)
                    {
                        UObject** rb_skel_mesh = (*rb_weapon_mesh)->GetValuePtrByPropertyNameInChain<UObject*>(STR("SkeletalMesh"));
                        Output::send(STR("[MeshGhostPseudo] TRACE weapon ghost {} WeaponMesh SkeletalMesh={}\n"),
                                     to_wide_ascii(id),
                                     (rb_skel_mesh && *rb_skel_mesh) ? STR("non-null") : STR("null"));
                    }
                }
            }

            // Trail-VFX prototype test -- see AFTERIMAGE_CALL_TEST's own comment. Fixed ~3s
            // cadence, not tied to any real trigger yet; purely answers "does calling this
            // function on the ghost produce a visible afterimage at all."
            if constexpr (AFTERIMAGE_CALL_TEST)
            {
                constexpr uint64_t AFTERIMAGE_CALL_TEST_INTERVAL_TICKS = 180;
                if (tick_count % AFTERIMAGE_CALL_TEST_INTERVAL_TICKS == 0)
                {
                    Output::send(STR("[MeshGhostPseudo] TRACE afterimage: calling Spawn After Image on ghost {}\n"),
                                 to_wide_ascii(id));
                    call_spawn_after_image(remote.ghost, 1.0f);
                }
            }

            // Outfit/costume mirror -- see RemoteGhost::target_outfit_mesh's comment. Edge-gated
            // like the weapon calls above (only resolve/assign on an actual change, not every
            // redraw tick) -- unlike weapon, this is a pure direct-property mesh-asset swap, no
            // function call involved, so there's no call-order hazard to worry about here.
            // Retry throttle (see RemoteGhost::last_failed_outfit_mesh's comment): a target that
            // previously failed to resolve (e.g. a peer's modded outfit this machine doesn't have)
            // only gets retried once per LOG_INTERVAL_TICKS, not every tick -- a genuinely new
            // target is still tried immediately regardless of the throttle.
            bool outfit_is_new_target = !remote.target_outfit_mesh.empty() && remote.target_outfit_mesh != remote.last_synced_outfit_mesh;
            bool outfit_retry_due = remote.target_outfit_mesh == remote.last_failed_outfit_mesh &&
                                     (tick_count - remote.last_outfit_attempt_tick) < LOG_INTERVAL_TICKS;
            if (outfit_is_new_target && !outfit_retry_due)
            {
                // First real live test (screenshot) found the raw property write alone produces a
                // T-pose -- the mesh reference sticks but the engine never re-binds/re-inits the
                // anim instance against it, the classic symptom of skipping the real UE setter
                // (USkinnedMeshComponent::SetSkeletalMesh(mesh, bReinitPose) is the well-known
                // engine-side API for exactly this on other UE versions, but its real availability/
                // signature on THIS build's reflection surface is unconfirmed -- this build has
                // already shown many UFunctions silently missing from reflection while direct
                // property writes work. One-shot function-name dump of VisualMesh, gated behind
                // DUMP_VISUALMESH_FUNCTIONS, to find what's actually callable before guessing a
                // name -- same discipline as every other function call in this file (signature
                // confirmed via reflection first, never assumed from general UE knowledge alone).
                if constexpr (DUMP_VISUALMESH_FUNCTIONS)
                {
                    if (UObject** g_visual_mesh_for_dump = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("VisualMesh")); g_visual_mesh_for_dump && *g_visual_mesh_for_dump)
                    {
                        dump_object_reflection(*g_visual_mesh_for_dump, STR("ghost VisualMesh (outfit function search)"));
                    }
                }

                // StaticFindObject<UObject*>(nullptr, nullptr, path) -- grounded via RE-UE4SS's own
                // official C++ mod guide (docs/guides/creating-a-c++-mod.md), same pattern already
                // used for the SetViewTargetWithBlend UFunction lookup elsewhere in this file, just
                // with UObject* instead of UFunction*/UClass*.
                UObject* outfit_mesh_obj = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, to_wide_ascii(remote.target_outfit_mesh).c_str());
                // Type check, found while reasoning about modded-costume peers: target_outfit_mesh
                // is peer-controlled data (json_string_field's own comment already flags every
                // extras field this way), and StaticFindObject with Class=nullptr matches ANY
                // object at that path regardless of type -- without this check, a malformed or
                // adversarial path could resolve to something that isn't a USkeletalMesh at all,
                // and get written into a SkeletalMesh-typed property slot anyway (a real type-
                // confusion risk, not just a cosmetic bug). GetClassPrivate()->GetName() is the
                // same mechanism already used throughout this file's own dumpers to identify an
                // object's class -- confirmed "SkeletalMesh" is the real class name printed for
                // every genuine outfit asset seen so far (e.g. dump_object_property_values' own
                // "SkeletalMesh (ObjectProperty) = SkeletalMesh /Game/..." output).
                if (outfit_mesh_obj && outfit_mesh_obj->GetClassPrivate() && outfit_mesh_obj->GetClassPrivate()->GetName() != STR("SkeletalMesh"))
                {
                    Output::send(STR("[MeshGhostPseudo] WARNING: outfit mesh '{}' resolved to a non-SkeletalMesh object (class '{}') -- refusing to apply.\n"),
                                 to_wide_ascii(remote.target_outfit_mesh), outfit_mesh_obj->GetClassPrivate()->GetName());
                    outfit_mesh_obj = nullptr;
                }
                if (outfit_mesh_obj)
                {
                    if (UObject** g_visual_mesh = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("VisualMesh")); g_visual_mesh && *g_visual_mesh)
                    {
                        // T-pose fix, 2026-08-15: call the real setter FIRST, applying the same
                        // ordering lesson the Dream Breaker fix already taught this file (a raw
                        // property write done before a state-changing call can make that call see
                        // no real transition) -- here the risk is the opposite direction, but the
                        // same principle: let the function that's supposed to do the real work run
                        // against a clean, not-yet-clobbered state, then keep the direct writes as
                        // a safety net afterward, not the other way around.
                        call_set_skeletal_mesh_asset(*g_visual_mesh, outfit_mesh_obj);
                        // Both properties written directly, kept as a safety net -- the live
                        // value-diff that found this field (verified.md's outfit-trace entry)
                        // showed SkeletalMesh and SkinnedAsset changing together on every real
                        // costume swap; writing only one and hoping the engine keeps the other in
                        // sync is exactly the kind of untested assumption this project's own
                        // discipline says to avoid.
                        if (UObject** g_skel_mesh = (*g_visual_mesh)->GetValuePtrByPropertyNameInChain<UObject*>(STR("SkeletalMesh")))
                        {
                            *g_skel_mesh = outfit_mesh_obj;
                        }
                        if (UObject** g_skinned_asset = (*g_visual_mesh)->GetValuePtrByPropertyNameInChain<UObject*>(STR("SkinnedAsset")))
                        {
                            *g_skinned_asset = outfit_mesh_obj;
                        }
                    }
                    remote.last_synced_outfit_mesh = remote.target_outfit_mesh;
                    remote.last_failed_outfit_mesh.clear();

                    // Independent readback -- re-fetches the pointer fresh rather than reusing
                    // g_skel_mesh above, per CLAUDE.md's "never log the value you just wrote as
                    // proof it worked" rule. Not gated behind OUTFIT_TRACE -- this is a one-shot
                    // log per real outfit change (edge-gated above), not a per-tick trace, so it's
                    // cheap enough to keep on permanently the same as the "spawned ghost" log line.
                    UObject** rb_skel_mesh = nullptr;
                    if (UObject** rb_visual_mesh = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("VisualMesh")); rb_visual_mesh && *rb_visual_mesh)
                    {
                        rb_skel_mesh = (*rb_visual_mesh)->GetValuePtrByPropertyNameInChain<UObject*>(STR("SkeletalMesh"));
                    }
                    Output::send(STR("[MeshGhostPseudo] outfit mesh applied for ghost {}: target='{}' readback={}\n"),
                                 to_wide_ascii(id), to_wide_ascii(remote.target_outfit_mesh),
                                 (rb_skel_mesh && *rb_skel_mesh) ? (*rb_skel_mesh)->GetFullName() : STR("null"));
                }
                else
                {
                    remote.last_failed_outfit_mesh = remote.target_outfit_mesh;
                    remote.last_outfit_attempt_tick = tick_count;
                    Output::send(STR("[MeshGhostPseudo] WARNING: outfit mesh '{}' not found via StaticFindObject -- ghost {} outfit not updated (will retry periodically).\n"),
                                 to_wide_ascii(remote.target_outfit_mesh), to_wide_ascii(id));
                }
            }

            // Redone landed?/jumped? pulse mirror (see PULSE_HOLD_TICKS's comment): a rising edge
            // in the received counter arms a hold window, decremented every tick regardless of
            // whether a new render_remote line arrived this tick (this loop runs unconditionally
            // per PROTOCOL.md), and write_animbp_bool targets the ghost's own animBPref -- the
            // object these fields actually live on, unlike every other field mirrored above.
            bool land_edge = remote.target_land_count > remote.last_seen_land_count;
            bool jump_edge = remote.target_jump_count > remote.last_seen_jump_count;
            if (land_edge)
            {
                remote.last_seen_land_count = remote.target_land_count;
                remote.landed_hold_ticks = PULSE_HOLD_TICKS;
            }
            if (jump_edge)
            {
                remote.last_seen_jump_count = remote.target_jump_count;
                remote.jumped_hold_ticks = PULSE_HOLD_TICKS;
            }
            bool write_landed = remote.landed_hold_ticks > 0;
            bool write_jumped = remote.jumped_hold_ticks > 0;
            write_animbp_bool(remote.ghost, STR("landed?"), write_landed);
            write_animbp_bool(remote.ghost, STR("jumped?"), write_jumped);
            if (remote.landed_hold_ticks > 0)
            {
                --remote.landed_hold_ticks;
            }
            if (remote.jumped_hold_ticks > 0)
            {
                --remote.jumped_hold_ticks;
            }

            // Trail-VFX pulse fire, 2026-08-15 (see afterimage_count's comment in Plugin.hpp and
            // verified.md's "Spawn After Image call confirmed" entry). Unlike landed?/jumped?
            // above, this calls a real function rather than writing an AnimBP bool, so there is no
            // hold-window to arm -- ProcessEvent either fires on this tick or it doesn't, same
            // shape as the weapon-visibility calls' edge gate.
            //
            // **Rearchitected, 2026-08-15** (see afterimage_count's own comment in Plugin.hpp and
            // verified.md for the full account): the APPLY side here is unchanged from the
            // confirmed-working version (write afterImagesToSpawn, then call spawnNumAfterimages --
            // see call_spawn_num_afterimages' own comment); only the TRIGGER changed, from a
            // polled actionState/hSpeed heuristic to a real UFunction hook on the local pawn. Kept
            // deliberately separate per CLAUDE.md's "one diagnostic at a time" -- an earlier pass
            // changed both at once and regressed a working visual while chasing the trigger.
            if (remote.target_afterimage_count > remote.last_seen_afterimage_count)
            {
                // Real burst size from the sender's own game rather than a hardcoded 6 -- a wrong
                // count left extra afterimages lingering after a slide (user-observed). Falls back
                // to 6 only if a peer on an older build sends no value, so this degrades to the
                // previous behaviour instead of spawning nothing.
                int32_t spawn_count = static_cast<int32_t>(remote.target_afterimage_spawn_n);
                if (spawn_count <= 0)
                {
                    spawn_count = 6;
                }
                if (int32_t* count_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<int32_t>(STR("afterImagesToSpawn")))
                {
                    *count_ptr = spawn_count;
                }

                // Trail colour written immediately BEFORE the burst is triggered, so the spawn
                // picks it up -- ordering deliberate, and the same lesson the Dream Breaker
                // weapon fix was built on (a value written after the call that consumes it is
                // simply too late). See write_linear_color_rgb's own comment for why alpha is
                // left alone.
                float write_r = remote.target_afterimage_color[0];
                float write_g = remote.target_afterimage_color[1];
                float write_b = remote.target_afterimage_color[2];
                bool have_color = remote.afterimage_color_valid;
                if constexpr (AFTERIMAGE_COLOR_TEST_OVERRIDE)
                {
                    // Diagnostic only -- see AFTERIMAGE_COLOR_TEST_OVERRIDE's own comment.
                    write_r = AFTERIMAGE_COLOR_TEST_RGB[0];
                    write_g = AFTERIMAGE_COLOR_TEST_RGB[1];
                    write_b = AFTERIMAGE_COLOR_TEST_RGB[2];
                    have_color = true;
                }
                bool color_written = have_color &&
                                     write_linear_color_rgb(remote.ghost, STR("afterimageColor"), write_r, write_g, write_b);

                // Trace (2) WRITE -- the colour as it exists on this side of the wire, immediately
                // before the burst that should consume it.
                if constexpr (TRAIL_COLOR_TRACE)
                {
                    Output::send(STR("[MeshGhostPseudo] TRAILCOLOR write: rgb=({:.3f}, {:.3f}, {:.3f}) have_color={} written={} n={}\n"),
                                 write_r, write_g, write_b, have_color, color_written, spawn_count);
                }

                if constexpr (TRAIL_TRIGGER_TRACE)
                {
                    Output::send(STR("[MeshGhostPseudo] TRACE trailTrigger ghost {}: wrote afterImagesToSpawn={} color=({:.3f},{:.3f},{:.3f}) color_written={} calling spawnNumAfterimages target={} last_seen={}\n"),
                                 to_wide_ascii(id), spawn_count, write_r, write_g, write_b, color_written,
                                 remote.target_afterimage_count, remote.last_seen_afterimage_count);
                }
                call_spawn_num_afterimages(remote.ghost);
                remote.last_seen_afterimage_count = remote.target_afterimage_count;

                // Independent readback, per CLAUDE.md's "never log the value you just wrote as
                // proof it worked" -- re-fetches the ghost's own afterImagesToSpawn AFTER the call
                // rather than trusting that the call ran. Distinguishes the two live hypotheses for
                // "the trigger fires but nothing appears on a slide": if this still reads the value
                // we wrote and never decreases on later ticks, spawnNumAfterimages' internal loop
                // is not running at all (a no-op, like manageRecallIdleFX was); if it counts down,
                // the loop IS spawning and the afterimages are being created but not seen, which is
                // a completely different problem (position, scale, lifetime, visibility).
                if constexpr (TRAIL_TRIGGER_TRACE)
                {
                    if (int32_t* rb_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<int32_t>(STR("afterImagesToSpawn")))
                    {
                        Output::send(STR("[MeshGhostPseudo] TRACE trailTrigger ghost {}: readback afterImagesToSpawn={} immediately after call\n"),
                                     to_wide_ascii(id), *rb_ptr);
                    }
                    // Ghost's own capsule, to compare against the local one logged on the slide
                    // edge -- see that block's comment for the sinking-into-the-floor theory.
                    if (UObject** g_cap_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("CapsuleComponent")); g_cap_ptr && *g_cap_ptr)
                    {
                        float* g_half_ptr = (*g_cap_ptr)->GetValuePtrByPropertyNameInChain<float>(STR("CapsuleHalfHeight"));
                        Output::send(STR("[MeshGhostPseudo] TRACE slideCapsule ghost {}: CapsuleHalfHeight={} z={}\n"),
                                     to_wide_ascii(id), g_half_ptr ? *g_half_ptr : -1.0f, remote.target_z);
                    }
                }
            }

            // Ghost health watch -- the other half of the enemy-damage test. If the ghost's own
            // health drops when an enemy hits it, and the local health drops at the same tick, that
            // is the propagation actually happening rather than the player simply being hit too.
            if constexpr (HEALTH_TRACE)
            {
                static const wchar_t* GHOST_HEALTH_NAMES[] = {
                    STR("currentHealth"), STR("health"), STR("Health"), STR("hp"), STR("HP"),
                    STR("currentHP"), STR("healthPoints"), STR("currentHitPoints"),
                };
                for (const wchar_t* name : GHOST_HEALTH_NAMES)
                {
                    double g_health = -1.0;
                    bool found = false;
                    if (double* d_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<double>(name))
                    {
                        g_health = *d_ptr;
                        found = true;
                    }
                    else if (int32_t* i_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<int32_t>(name))
                    {
                        g_health = static_cast<double>(*i_ptr);
                        found = true;
                    }
                    if (found)
                    {
                        if (std::fabs(g_health - remote.last_seen_ghost_health) > 0.0001)
                        {
                            Output::send(STR("[MeshGhostPseudo] TRACE health: GHOST {} '{}' {} -> {} (tick={})\n"),
                                         to_wide_ascii(id), name, remote.last_seen_ghost_health, g_health, tick_count);
                            remote.last_seen_ghost_health = g_health;
                        }
                        break;
                    }
                }
            }

            // NOTE: mirroring the ghost's CapsuleHalfHeight was tried here 2026-08-15 and removed.
            // It provably applied (readback showed 22 during slides) but did NOT fix the visual --
            // see the slide_z_comp block at the receive site for the measured reason and the fix
            // that replaced it. Leaving the resize in alongside that Z compensation would also be
            // actively wrong: it would leave the ghost's collision capsule floating above the floor
            // rather than around its feet.

            // Ghost-side burst drain watch -- the other half of the readback above. Logged every
            // tick the ghost's own counter is non-zero, so the shape of the drain (5,4,3,... vs
            // stuck at 5) is visible across the whole burst rather than only at the call instant.
            if constexpr (TRAIL_TRIGGER_TRACE)
            {
                if (int32_t* drain_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<int32_t>(STR("afterImagesToSpawn")); drain_ptr && *drain_ptr != 0)
                {
                    Output::send(STR("[MeshGhostPseudo] TRACE trailTrigger ghost {}: drain afterImagesToSpawn={} tick={}\n"),
                                 to_wide_ascii(id), *drain_ptr, tick_count);
                }
            }

            // Cling-gem (wall-ride) VFX trigger -- see WALLRUN_TRIGGER_TEST's own comment.
            // moveState==4 is the confirmed cling marker and is already mirrored onto this ghost,
            // so this fires once per cling on the rising edge rather than every tick of one.
            if constexpr (WALLRUN_TRIGGER_TEST)
            {
                uint8_t wallrun_move_state = static_cast<uint8_t>(remote.target_move_state);
                if (wallrun_move_state == 4 && remote.last_wallrun_move_state != 4)
                {
                    if constexpr (WALLRIDE_TRACE)
                    {
                        Output::send(STR("[MeshGhostPseudo] TRACE wallRide ghost {}: moveState entered 4, calling doWallRun\n"),
                                     to_wide_ascii(id));
                    }
                    call_do_wall_run(remote.ghost);

                    // Ghosts are SILENT by design -- MeshGhost is a visual-only layer (see the
                    // project brief), and triggering the pawn's own systems on a ghost gets us its
                    // audio for free whether we want it or not. We don't: a peer's cling sound
                    // coming from across the room is noise, and it multiplies with player count.
                    // Stopped immediately after the call that started it rather than on the way out
                    // (the falling edge still stops it too, as a safety net) so it is never
                    // audible, instead of playing until the cling ends.
                    if (UObject** sfx_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("wallRideSFX")); sfx_ptr && *sfx_ptr)
                    {
                        const wchar_t* which = call_audio_component_stop(*sfx_ptr);
                        if constexpr (WALLRIDE_TRACE)
                        {
                            Output::send(STR("[MeshGhostPseudo] TRACE wallRide ghost {}: suppressed wallRideSFX at start via {}\n"),
                                         to_wide_ascii(id), which);
                        }
                    }
                }
                else if (wallrun_move_state != 4 && remote.last_wallrun_move_state == 4)
                {
                    // Falling edge -- see call_component_deactivate's own comment. Without this the
                    // effect started above never ends (confirmed live: it followed the ghost around
                    // while walking). Deactivates the component rather than nulling the property,
                    // matching what the real player's own logic evidently does.
                    if (UObject** vfx_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("wallRideVFX")); vfx_ptr && *vfx_ptr)
                    {
                        call_component_deactivate(*vfx_ptr);
                        if constexpr (WALLRIDE_TRACE)
                        {
                            Output::send(STR("[MeshGhostPseudo] TRACE wallRide ghost {}: moveState left 4, deactivated wallRideVFX\n"),
                                         to_wide_ascii(id));
                        }
                    }
                    else if constexpr (WALLRIDE_TRACE)
                    {
                        Output::send(STR("[MeshGhostPseudo] TRACE wallRide ghost {}: moveState left 4 but wallRideVFX is null -- nothing to deactivate\n"),
                                     to_wide_ascii(id));
                    }

                    // Paired SFX -- see call_audio_component_stop's own comment. doWallRun starts
                    // this alongside the VFX, and without stopping it the cling sound looped
                    // forever after the peer left the wall (confirmed live, same session).
                    if (UObject** sfx_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("wallRideSFX")); sfx_ptr && *sfx_ptr)
                    {
                        const wchar_t* which = call_audio_component_stop(*sfx_ptr);
                        if constexpr (WALLRIDE_TRACE)
                        {
                            Output::send(STR("[MeshGhostPseudo] TRACE wallRide ghost {}: stopped wallRideSFX via {}\n"),
                                         to_wide_ascii(id), which);
                        }
                    }
                }
                remote.last_wallrun_move_state = wallrun_move_state;
            }

            // Ledge-hang-stuck-forever fix (see call_montage_stop's own comment for the full
            // theory and how Montage_Stop's real signature was confirmed): a land_edge or
            // jump_edge is exactly the moment the real player left whatever held pose they were
            // in (dropping off a ledge and touching ground fires a landed pulse; jumping off fires
            // a jumped pulse -- confirmed via the live trace of a real hang->release->land cycle),
            // so this is the right moment to force-stop any lingering montage on the ghost too,
            // not merely mirror the continuous state that a montage doesn't listen to anyway.
            //
            // Suppressed while either probe is on (MONTAGE_PROBES_SUPPRESS_ADAPTER_STOPS) -- this is
            // the LAST montage call this file makes on a ghost, and the self-probe needs all of them
            // gone, not most. It is also the one that had been masking the self-start all along, as
            // that probe went on to prove.
            if ((land_edge || jump_edge) && !MONTAGE_PROBES_SUPPRESS_ADAPTER_STOPS)
            {
                if (UObject** g_abp_for_montage = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("animBPref")); g_abp_for_montage && *g_abp_for_montage)
                {
                    // Blend-out tightened 2026-08-13 (user-confirmed live: the fix worked but the
                    // ghost held the hang pose a bit longer than the real player, on top of the
                    // ~100ms interpolation delay already inherent to the pipeline) -- 0.0s cuts
                    // instead of blending, closing the rest of the gap.
                    call_montage_stop(*g_abp_for_montage, 0.0f);
                    if constexpr (ANIM_TRACE)
                    {
                        // Same immediate readback as the montage-mirror stop above, on the pulse's
                        // own call -- this is the control. Both calls are byte-identical, so if
                        // this one clears the montage and the other doesn't, the difference is
                        // context/timing and not the call, which is exactly what needs proving
                        // before anything else is changed.
                        std::string after_pulse_stop;
                        read_current_active_montage(*g_abp_for_montage, after_pulse_stop);
                        Output::send(STR("[MeshGhostPseudo] TRACE montage ghost {}: PULSE Montage_Stop (land={} jump={}) -- immediately after, playing='{}'\n"),
                                     to_wide_ascii(id), land_edge, jump_edge, to_wide_ascii(after_pulse_stop));
                    }
                    if constexpr (ANIM_PULSE_TRACE)
                    {
                        Output::send(STR("[MeshGhostPseudo] PULSE remote {}: called Montage_Stop (land_edge={} jump_edge={})\n"),
                                     to_wide_ascii(id),
                                     land_edge,
                                     jump_edge);
                    }
                }
            }

            if constexpr (ANIM_PULSE_TRACE)
            {
                if (write_landed || write_jumped || land_edge || jump_edge)
                {
                    // Readback immediately after the write above -- per CLAUDE.md, "it ran without
                    // errors" is not evidence the AnimBP's own update graph didn't immediately
                    // overwrite it before the next frame renders.
                    bool rb_landed = read_animbp_bool(remote.ghost, STR("landed?"));
                    bool rb_jumped = read_animbp_bool(remote.ghost, STR("jumped?"));
                    Output::send(STR("[MeshGhostPseudo] PULSE remote {}: land_count={} jump_count={} landed_hold={} jumped_hold={} wrote_landed={} wrote_jumped={} readback_landed={} readback_jumped={}\n"),
                                 to_wide_ascii(id),
                                 remote.target_land_count,
                                 remote.target_jump_count,
                                 remote.landed_hold_ticks,
                                 remote.jumped_hold_ticks,
                                 write_landed,
                                 write_jumped,
                                 rb_landed,
                                 rb_jumped);
                }
            }

            if (tick_count % LOG_INTERVAL_TICKS == 0)
            {
                // Read back what actually stuck on the ghost after our writes above, not just
                // what we intended to write -- "ran without errors" isn't evidence something took
                // effect, per CLAUDE.md.
                uint8_t* rb_move_state = remote.ghost->GetValuePtrByPropertyNameInChain<uint8_t>(STR("moveState"));
                uint8_t* rb_action_state = remote.ghost->GetValuePtrByPropertyNameInChain<uint8_t>(STR("actionState"));
                double* rb_v_speed = remote.ghost->GetValuePtrByPropertyNameInChain<double>(STR("verticalSpeed"));
                int rb_movement_mode = -1;
                if (UObject** rb_movement_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("CharacterMovement")); rb_movement_ptr && *rb_movement_ptr)
                {
                    if (uint8_t* rb_movement_mode_ptr = (*rb_movement_ptr)->GetValuePtrByPropertyNameInChain<uint8_t>(STR("MovementMode")))
                    {
                        rb_movement_mode = static_cast<int>(*rb_movement_mode_ptr);
                    }
                }
                Output::send(STR("[MeshGhostPseudo] TRACE remote {}: sent moveState={} actionState={} vSpeed={} movementMode={} | readback moveState={} actionState={} vSpeed={} movementMode={}\n"),
                             to_wide_ascii(id),
                             static_cast<int>(remote.target_move_state),
                             static_cast<int>(remote.target_action_state),
                             remote.target_v_speed,
                             static_cast<int>(remote.target_movement_mode),
                             rb_move_state ? static_cast<int>(*rb_move_state) : -1,
                             rb_action_state ? static_cast<int>(*rb_action_state) : -1,
                             rb_v_speed ? *rb_v_speed : -1.0,
                             rb_movement_mode);

                FVector actual_loc = remote.ghost->K2_GetActorLocation();
                Output::send(STR("[MeshGhostPseudo] remote {} redraw: intended=({},{},{}) actual=({},{},{})\n"),
                             to_wide_ascii(id),
                             target_loc.X(),
                             target_loc.Y(),
                             target_loc.Z(),
                             actual_loc.X(),
                             actual_loc.Y(),
                             actual_loc.Z());

                // Facing-direction investigation, 2026-08-13: read back the ghost's actual yaw
                // after our K2_SetActorLocationAndRotation write, to see whether it's sticking or
                // being reverted (e.g. by the ghost's own CharacterMovementComponent, if
                // bOrientRotationToMovement is fighting it -- see the local-side TRACE log).
                FRotator actual_rot = remote.ghost->K2_GetActorRotation();
                // Cross-check via direct property reflection -- K2_GetActorRotation()'s own
                // readback came back as implausible garbage on a previous run despite
                // K2_GetActorLocation() on the same object working fine in the same call. This
                // retry's first version read via RootComponent and got the exact same garbage as
                // the native call, which (since the ghost visually looks stable, not glitching)
                // points at reading the wrong object rather than genuinely corrupt data --
                // RootComponent may not resolve reliably on a freshly spawned actor. Retrying via
                // CapsuleComponent instead, already proven reliable elsewhere in this file
                // (log_pawn_reflection_once's dump, the animation-state mirroring code).
                double reflected_yaw = -9999.0;
                if (UObject** g_capsule_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<UObject*>(STR("CapsuleComponent")); g_capsule_ptr && *g_capsule_ptr)
                {
                    if (FRotator* g_relative_rot = (*g_capsule_ptr)->GetValuePtrByPropertyNameInChain<FRotator>(STR("RelativeRotation")))
                    {
                        reflected_yaw = g_relative_rot->GetYaw();
                    }
                }
                Output::send(STR("[MeshGhostPseudo] TRACE remote {} yaw: sent={} K2_actual={} reflected_actual={}\n"),
                             to_wide_ascii(id),
                             target_rot.GetYaw(),
                             actual_rot.GetYaw(),
                             reflected_yaw);

                bool* hidden_ptr = remote.ghost->GetValuePtrByPropertyNameInChain<bool>(STR("bHidden"));
                if (hidden_ptr)
                {
                    *hidden_ptr = true;
                    *hidden_ptr = false;
                }
            }
        }
    }

    // Phase 7.5-in-C++, step 3 (hijack redesign): pure networking now -- connects, sends the
    // latest cached local_state (built by game_thread_tick, the real game thread), and hands off
    // received lines for game_thread_tick to process. No actor reads/writes happen on this thread
    // anymore (see game_thread_tick's doc comment for why that mattered).
    auto Plugin::on_update() -> void
    {
        if (!unreal_ready)
        {
            return;
        }

        ++tick_count;
        ++ticks_since_ready;

        if (POSSESS_TRACE && tick_count <= possess_watch_until_tick)
        {
            // Bounded window after a spawn, never a permanent per-tick log.
            if (auto [watch_controller, watch_pawn] = find_local_controller_and_pawn(); watch_controller)
            {
                UObject** held = watch_controller->GetValuePtrByPropertyNameInChain<UObject*>(STR("Pawn"));
                Output::send(STR("[MeshGhostPseudo] POSSESS_TRACE watch tick={} controller_pawn={}\n"),
                             tick_count,
                             (held && *held) ? (*held)->GetFullName() : STR("(none)"));
            }
        }

        if (!bridge)
        {
            return;
        }

        bridge->tick_connect();

        // Two states now, not one. A socket exists (is_connected) as soon as some core answers
        // on some port -- that is when the hello goes out. Whether that core will HAVE us is a
        // separate question it answers with bridge_ready or reject (agent_docs/contract.md), and
        // only then is it safe to send frames: on a busy core the answer is a reject, and
        // anything sent in between would be talking to a session about to be closed.
        //
        // Conflating the two deadlocks: the hello is what starts the handshake, so gating it on
        // the handshake's result means it is never sent at all.
        bool now_connected = bridge->is_ready();
        if (core_launcher)
        {
            // Driven off the connection state rather than called directly by tick_connect, so
            // BridgeClient stays what it says it is (a socket, nothing else) and the launcher
            // never runs unless a connect has actually failed -- which is what makes reusing an
            // already-running core the default rather than a special case.
            if (bridge->is_connected())
            {
                core_launcher->tick_connected();
            }
            else
            {
                // Only ever spawn where the sweep found NOTHING listening. A port that answered
                // and said it was busy belongs to another game's core, and contract.md is
                // explicit that an adapter only stops -- or starts over -- a core it owns.
                uint16_t spawn_on = 0;
                if (bridge->spawnable_port(spawn_on))
                {
                    core_launcher->tick_disconnected(spawn_on);
                }
            }
        }
        if (bridge_was_connected && !now_connected)
        {
            // See release_all_ghosts_parked's comment -- the actual parking must happen on the
            // game thread, so this only arms the flag; game_thread_tick does the real work.
            std::lock_guard<std::mutex> lock(state_mutex);
            bridge_disconnect_cleanup_pending = true;
        }
        bridge_was_connected = now_connected;

        // Hello on CONNECTED, not on ready -- it is the message that asks the question.
        if (bridge->is_connected() && !bridge->hello_sent())
        {
            std::string hello = std::string("{\"type\":\"hello\",\"payload\":{\"game_id\":\"") + GAME_ID +
                "\",\"game_version\":\"" + ADAPTER_VERSION + "\"}}";
            if (bridge->send_line(hello))
            {
                bridge->mark_hello_sent();
            }
        }

        // Read the socket whenever one EXISTS, not only once the core has accepted us: the
        // acceptance (bridge_ready) arrives over this same socket, and poll_lines is what
        // consumes it. Gating the read on readiness deadlocks -- the adapter connects, sends
        // hello, never reads the answer, times out, blacklists the port, and loops. Found live
        // 2026-08-16 as a 12s reconnect cycle in UE4SS.log, and it is the SAME mistake as
        // gating the hello itself on readiness, one layer down.
        std::vector<std::string> received_lines;
        if (bridge->is_connected())
        {
            received_lines = bridge->poll_lines();
        }

        if (now_connected)
        {
            std::string local_state_to_send;
            {
                std::lock_guard<std::mutex> lock(state_mutex);
                local_state_to_send = cached_local_state_json;
            }
            if (!local_state_to_send.empty())
            {
                bridge->send_line(local_state_to_send);
            }

            if (!received_lines.empty())
            {
                std::lock_guard<std::mutex> lock(state_mutex);
                for (std::string& line : received_lines)
                {
                    pending_incoming_lines.push_back(std::move(line));
                }
            }
        }

        if (tick_count % LOG_INTERVAL_TICKS == 0)
        {
            const auto& stats = bridge->stats();
            Output::send<LogLevel::Normal>(
                STR("[MeshGhostPseudo] bridge: connected={} connect_attempts={} send_ok={} send_fail={} "
                    "lines_received={} lines_malformed={}\n"),
                bridge->is_connected(),
                stats.connect_attempts,
                stats.send_ok,
                stats.send_fail,
                stats.lines_received,
                stats.lines_malformed);
        }
    }
} // namespace MeshGhostPseudo
