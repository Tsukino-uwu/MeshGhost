#pragma once

// Phase 7.2 hello-world UE4SS C++ mod. Not the real adapter -- proves a C++ mod can build
// against this machine's UE4SS v3.0.1 and load alongside the already-installed AP_Randomizer
// C++ mod (agent_docs/phases/phase7.md). CppUserModBase interface confirmed by reading
// UE4SS/include/Mod/CppUserModBase.hpp directly (RE-UE4SS, MIT -- agent_docs/licensing.md),
// not from memory. No pseudoregalia-archipelago source was read to write this.

#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <Mod/CppUserModBase.hpp>

namespace RC::Unreal
{
    class UObject;
    class AActor;
    class UWorld;
    class UFunction;
} // namespace RC::Unreal

namespace MeshGhostPseudo
{
    class BridgeClient;

    // One entry per remote player_id, driven entirely by render_remote/despawn_remote -- mirrors
    // the Lua adapter's `remotes` table (adapters/pseudoregalia/probe_ghost/Scripts/main.lua).
    //
    // Phase 7.6: the "no working destroy mechanism" verdict from the original "Fatal world leaks
    // detected" investigation (lowlevelfatalerror-file-d-build-ue5-sync-zazzy-star.md) was reached
    // entirely from calls made off the game thread (on_update(), UE4SS's own polling thread) --
    // discovered only afterwards, during the separate render-freeze investigation. The Lua
    // adapter, which DID spawn a clone of the player's pawn class successfully across real area
    // transitions, always made its spawn/reposition calls inside ExecuteInGameThread. Spawn-based
    // ghosts are back (see SPAWN_BASED_GHOSTS in Plugin.cpp) as a game-thread retest of that
    // verdict; the old hijack-an-existing-StaticMeshActor path (`ensure_ghost_hijacked`) is kept
    // intact as a one-constant revert if the leak reproduces.
    struct RemoteGhost
    {
        RC::Unreal::AActor* ghost{nullptr};
        RC::Unreal::UWorld* owning_world{nullptr}; // which UWorld `ghost` belongs to (spawned into, or hijacked from)
        double target_x{}, target_y{}, target_z{};
        double target_pitch{}, target_yaw{}, target_roll{};

        // Facing-direction bisection, 2026-08-13: rotation reads correct immediately after
        // SpawnActor and immediately after Possess() (same tick as spawn), but garbage by the
        // time the ~2s-interval TRACE log next reads it -- up to ~120 ticks of blind spot. Counts
        // redraw-loop ticks since this ghost was created so the first several can be logged
        // unconditionally, to find out whether corruption happens on the very next tick or later.
        uint32_t ticks_since_spawn{0};

        // Mirrors of the real player's own animation-driving state (see verified.md's "ghost
        // animation" entry) -- BP_PlayerGoatMain_C's ABP_PlayerGoat_C anim instance reads these
        // same fields (moveState/actionState/horizontalSpeed/verticalSpeed/animJumpType) off its
        // owning pawn every tick and mirrors them into its own locals, so writing them onto the
        // ghost's pawn each tick (game_thread_tick) makes the ghost's own already-attached anim
        // instance animate itself the same way for CONTINUOUS state. That reasoning does not hold
        // for landed?/jumped? below -- see target_land_count's comment.
        double target_move_state{}, target_action_state{}, target_h_speed{}, target_v_speed{}, target_anim_jump_type{};

        // Found live 2026-08-13: without this, the ghost gets stuck in an airborne/"flying" pose
        // after a jump (a slide forces a reset, since that's a different, non-grounded-gated
        // transition). Leading theory: the ghost's own real CharacterMovementComponent can never
        // detect ground contact (SetActorEnableCollision(false) in ensure_ghost_spawned, kept
        // deliberately so the ghost never physically pushes the real player), and at least one
        // AnimBP transition reads that component's real MovementMode directly rather than only
        // the moveState byte mirrored above. Confirmed via reflection dump that MovementMode is a
        // real, plain ByteProperty on the stock engine CharacterMovementComponent here (not a
        // custom subclass) -- mirrored the same opaque-copy way as moveState/actionState.
        double target_movement_mode{};

        // Landing/jump pulse mirror, redone 2026-08-13 (follow-up session). The first attempt at
        // this (a plain bool, read/written on the PAWN) was a no-op on both ends: a real reflection
        // dump (log_pawn_reflection_once) proved 'landed?'/'jumped?' exist ONLY on animBPref (the
        // AnimBP instance, ABP_PlayerGoat_C), never on BP_PlayerGoatMain_C itself -- the pawn's only
        // landing-related member is 'playerLanded?', a MulticastInlineDelegateProperty (an event,
        // not a flag). Every prior TRACE local: line confirms it: landed=false jumped=false on
        // every sample, including ticks where movementMode=3 (Falling). So the theory that the
        // landing transition is gated on a one-shot AnimBP pulse the ghost never receives (its
        // CharacterMovementComponent can never detect ground contact with collision disabled, so
        // its own LandedDelegate/'landed?' pulse never fires) was never actually tested.
        //
        // This redo reads/writes animBPref->landed?/jumped? directly on both ends. It also switches
        // from a bool to a monotonic counter, because a single-tick bool pulse is the wrong shape
        // for this pipeline: Core.DefaultMinSendInterval (50ms) drops roughly 2 of every 3 frames
        // from a ~60Hz game thread before the relay ever sees them, and remoteBuffer.lerp holds
        // extras from the OLDER bracketing snapshot, so a snapshot renderTime steps over is never
        // returned at all. A counter that only ever increases survives both: the receiver fires the
        // one-shot on any observed increase over target_land_count/target_jump_count.
        double target_land_count{}, target_jump_count{};
        double last_seen_land_count{}, last_seen_jump_count{};
        // Ticks remaining to hold landed?/jumped? true on the ghost's own AnimBP once a rising edge
        // is observed -- the AnimBP's own update graph may re-evaluate and overwrite a single-tick
        // write before its state machine transition gets a chance to see it. See PULSE_HOLD_TICKS.
        uint32_t landed_hold_ticks{0}, jumped_hold_ticks{0};

        // Lua's trySpawnRemoteGhost guards spawning with a `remote.spawning` re-entrancy flag
        // because its spawn call is deferred through ExecuteInGameThread -- a gap exists between
        // "decided to spawn" and "the ghost field is actually set" where a re-check could fire
        // twice. game_thread_tick() already runs on the game thread throughout, so
        // ensure_ghost_spawned's SpawnActor call is synchronous and `ghost` is set before it
        // returns -- no such gap exists here, so no equivalent flag is needed.
    };

    class Plugin : public RC::CppUserModBase
    {
      public:
        Plugin();
        ~Plugin() override;

        auto on_unreal_init() -> void override;

        // Phase 7.5-in-C++: step 1 proved real position reflection works natively, step 2 added
        // the real bridge connection, step 3 parses render_remote/despawn_remote and drives
        // ghosts -- redesigned from spawn-based to hijack-based after the world-leak crash
        // investigation found no working actor-destroy mechanism on this build. Fires every
        // engine tick.
        auto on_update() -> void override;

      private:
        auto handle_bridge_line(const std::string& line, RC::Unreal::UObject* local_pawn, RC::Unreal::UObject* local_controller) -> void;

        // Phase 7.6: spawns a clone of the local player's own pawn class (ported field-for-field
        // from the Lua adapter's trySpawnRemoteGhost, probe_ghost/Scripts/main.lua:596-650), then
        // immediately re-possesses the real local player -- the already-confirmed Phase 7.4
        // auto-possess safety fix. Selected via SPAWN_BASED_GHOSTS in Plugin.cpp.
        auto ensure_ghost_spawned(const std::string& player_id, RC::Unreal::UObject* local_pawn, RC::Unreal::UObject* local_controller) -> void;

        // Finds an already-existing, already-registered StaticMeshActor in the local player's
        // current world and repurposes it as the remote's ghost -- never spawns anything, so
        // there is never anything that needs destroying. Kept as the SPAWN_BASED_GHOSTS=false
        // fallback path. See RemoteGhost's own comment for why.
        auto ensure_ghost_hijacked(const std::string& player_id, RC::Unreal::UObject* local_pawn) -> void;

        // Stops tracking a remote's ghost. Does NOT destroy/touch the underlying actor. Under the
        // hijack design this was never ours to destroy; under the spawn design (Phase 7.6), a
        // level transition destroys it out from under us anyway (confirmed live, Lua saga), so by
        // the time this runs there is nothing left to destroy either way -- see the staleness
        // check in game_thread_tick, which is what actually detects and clears a dead ghost.
        auto release_ghost(const std::string& player_id) -> void;
        auto release_all_ghosts(const wchar_t* reason) -> void;

        // Found live 2026-08-14: closing the core process (meshghost.exe) drops the bridge
        // connection, but neither despawn_remote (the core never gets a chance to send it) nor
        // the LoadMap PRE hook (no area transition happened) fires -- a remote's ghost was left
        // standing frozen and visible indefinitely. Unlike release_all_ghosts's LoadMap case,
        // no level teardown is coming to reclaim the actor here, so this parks every remaining
        // ghost the same way a real despawn_remote does (see release_ghost). Must run on the
        // game thread, same requirement as release_ghost's own actor write -- called from
        // game_thread_tick, armed by on_update noticing the connected->disconnected edge.
        auto release_all_ghosts_parked(const wchar_t* reason) -> void;

        auto log_remote_state(const wchar_t* context) -> void;

        // THE fix for the render-freeze bug, found 2026-08-13: on_update() runs on UE4SS's own
        // internal polling thread (confirmed directly from UE4SS's source, UE4SSProgram.cpp:
        // ProfilerSetThreadName("UE4SS-UpdateThread"), a ~5ms std::this_thread::sleep_for loop) --
        // NOT the real Unreal game thread. Every actor write this mod ever made was happening off
        // the game thread, which explains "position reads back correctly (same-thread readback)
        // but never visually updates (never reaches the renderer's expected sync point)". This
        // method runs all actor-touching work (hijack search/writes, redraws, bHidden toggle) from
        // inside an EngineTick post-hook instead, which genuinely runs on the game thread -- the
        // same mechanism Lua's ExecuteInGameThread(EGameThreadMethod.EngineTick) uses under the
        // hood.
        auto game_thread_tick() -> void;

        // Phase 7.6: re-opens Phase 7.4's camera bug (a StaticMeshActor never stole the camera, so
        // the hijack design never needed this). Two ProcessEvent-hook-based attempts never fired
        // even once, confirmed by a read-only diagnostic run with zero log output -- root cause
        // read directly from UE4SS's own Lua RegisterHook implementation
        // (RE-UE4SS/UE4SS/src/Mod/LuaMod.cpp:3907-3921): SetViewTargetWithBlend is a native
        // function, and native UFunctions are hooked via UFunction::RegisterPreHook/RegisterPostHook
        // directly on the function object, not via a ProcessEvent filter -- a fundamentally
        // different, narrower set of calls. This version uses RegisterPreHook and rewrites the
        // NewViewTarget argument in the engine's own argument buffer (TheStack.Locals(), via
        // UnrealScriptFunctionCallableContext::GetParams<T>()) before the real call proceeds --
        // see its body for the full design and why this needs no second call/deferral at all.
        auto register_camera_fightback_hook() -> void;

        // Bridge networking (on_update, UE4SS's own thread) and actor work (game_thread_tick,
        // the real game thread) now run concurrently -- this guards the state both sides touch.
        std::mutex state_mutex;
        std::vector<std::string> pending_incoming_lines; // filled by on_update, drained by game_thread_tick
        std::string cached_local_state_json;             // built by game_thread_tick, sent by on_update
        // Bridge-disconnect ghost cleanup handoff (see release_all_ghosts_parked's comment):
        // on_update notices the connected->disconnected edge and sets the pending flag;
        // game_thread_tick drains it and does the actual (game-thread-only) parking.
        bool bridge_was_connected{false};
        bool bridge_disconnect_cleanup_pending{false};

        // Local landed?/jumped? edge counters for the redone pulse mirror (see
        // RemoteGhost::target_land_count's comment). Incremented once per rising edge of the real
        // pawn's animBPref->landed?/jumped? (read in game_thread_tick, on the game thread), so
        // prev_landed_raw/prev_jumped_raw track the previous tick's raw value purely to detect that
        // edge -- without them the same landing would count once per tick the flag happens to still
        // read true. Never cleared/reset: a monotonic counter needs no thread-handoff clear-after-
        // send step the way the old bool latch did, since "did land_count increase since I last
        // looked" is well-defined regardless of which snapshots got sent.
        uint32_t landed_count{0}, jumped_count{0};
        bool prev_landed_raw{false}, prev_jumped_raw{false};

        bool unreal_ready{false};
        uint64_t tick_count{0};
        uint64_t ticks_since_ready{0};
        // Ticks since the local pawn most recently became valid -- resets to 0 whenever it's not
        // (e.g. at the title screen). Gates SPAWN_DELAY_TICKS in ensure_ghost_spawned, mirroring
        // Lua's original diagnostic setup (main.lua's SPAWN_DELAY_TICKS/followTick,
        // agent_docs/phases/phase7.md's Phase 7.4 saga) that first caught the camera re-pick on
        // camera: let the player's own camera settle on a real target before any ghost exists,
        // so the moment it swaps away is a clean, isolated, observable event.
        uint64_t ticks_since_pawn_valid{0};
        std::unique_ptr<BridgeClient> bridge;
        std::unordered_map<std::string, RemoteGhost> remotes;
        std::unordered_set<RC::Unreal::AActor*> hijacked_actors; // prevents two remotes sharing one prop
        RC::Unreal::UWorld* last_logged_world{nullptr};

        // Camera fight-back state (Phase 7.6), mirrors Lua's lastKnownGoodViewTarget/anyGhostSpawned.
        // No pending/deferred fields needed -- the RegisterPreHook design rewrites the engine's own
        // argument buffer in place, synchronously, before the real call runs.
        RC::Unreal::UFunction* svtwb_function{nullptr}; // cached "SetViewTargetWithBlend", found once
        RC::Unreal::AActor* last_known_good_view_target{nullptr};
        bool any_ghost_ever_spawned{false};

        // Callback/hook IDs, captured so ~Plugin can unregister them explicitly on mod
        // unload/reload -- found in a review pass: previously discarded, leaving every
        // Register*Callback/RegisterPreHook detour pointing at this (about-to-be-freed) Plugin
        // instance active with no way to remove it. Stored as the underlying primitive types
        // (Hook::GlobalCallbackId is uint64_t, RC::Unreal::CallbackId is int32_t) rather than
        // pulling <Unreal/Hooks.hpp> into this widely-included header, the same reasoning
        // BridgeClient.hpp already applies to storing its SOCKET as a uintptr_t. Hook::ERROR_ID
        // (0) is this file's real sentinel for "never registered"; -1 mirrors that for the
        // UFunction hook, whose own ID counter starts elsewhere and would not plausibly land on
        // a negative value.
        uint64_t load_map_pre_callback_id{0};
        uint64_t engine_tick_post_callback_id{0};
        int32_t svtwb_hook_id{-1};
    };
} // namespace MeshGhostPseudo
