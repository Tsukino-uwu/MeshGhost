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

        auto log_remote_state(const wchar_t* context) -> void;

        // User-requested 2026-08-13: isolate the render-freeze investigation from the network
        // layer entirely -- when true, the game-thread tick (below) skips BridgeClient/core/relay
        // completely and just hijacks one object, then repositions it to (local pawn position +
        // a fixed offset) every tick, driven purely by local reflection reads. Removes networking
        // as a variable; tests only whether this specific object/build can sustain per-tick
        // repositioning indefinitely. No .bat files need to be running for this mode.
        auto run_local_offset_test_tick() -> void;

        // THE fix for the render-freeze bug, found 2026-08-13: on_update() runs on UE4SS's own
        // internal polling thread (confirmed directly from UE4SS's source, UE4SSProgram.cpp:
        // ProfilerSetThreadName("UE4SS-UpdateThread"), a ~5ms std::this_thread::sleep_for loop) --
        // NOT the real Unreal game thread. Every actor write this mod ever made was happening off
        // the game thread, which explains "position reads back correctly (same-thread readback)
        // but never visually updates (never reaches the renderer's expected sync point)". This
        // method runs all actor-touching work (hijack search/writes, redraws, bHidden toggle, and
        // for LOCAL_OFFSET_TEST_MODE, the local pawn read too) from inside an EngineTick post-hook
        // instead, which genuinely runs on the game thread -- the same mechanism Lua's
        // ExecuteInGameThread(EGameThreadMethod.EngineTick) uses under the hood.
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
    };
} // namespace MeshGhostPseudo
