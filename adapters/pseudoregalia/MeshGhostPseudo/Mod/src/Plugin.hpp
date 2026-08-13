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
} // namespace RC::Unreal

namespace MeshGhostPseudo
{
    class BridgeClient;

    // One entry per remote player_id, driven entirely by render_remote/despawn_remote -- mirrors
    // the Lua adapter's `remotes` table (adapters/pseudoregalia/probe_ghost/Scripts/main.lua).
    // `ghost` is a HIJACKED, already-existing level actor (a StaticMeshActor found via FindAllOf),
    // never one we spawned -- see the "Fatal world leaks detected" investigation
    // (lowlevelfatalerror-file-d-build-ue5-sync-zazzy-star.md): no working destroy mechanism was
    // ever found for actors spawned at runtime on this build, so this design never spawns
    // anything that would need destroying in the first place.
    struct RemoteGhost
    {
        RC::Unreal::AActor* ghost{nullptr};
        RC::Unreal::UWorld* hijack_world{nullptr}; // which UWorld `ghost` belongs to
        double target_x{}, target_y{}, target_z{};
        double target_pitch{}, target_yaw{}, target_roll{};
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
        auto handle_bridge_line(const std::string& line, RC::Unreal::UObject* local_pawn) -> void;

        // Finds an already-existing, already-registered StaticMeshActor in the local player's
        // current world and repurposes it as the remote's ghost -- never spawns anything, so
        // there is never anything that needs destroying. See RemoteGhost's own comment for why.
        auto ensure_ghost_hijacked(const std::string& player_id, RC::Unreal::UObject* local_pawn) -> void;

        // Stops tracking a remote's ghost. Does NOT destroy/touch the underlying actor -- it was
        // never ours to destroy, and the level's own normal (working, unlike our attempted
        // spawns) teardown handles it exactly like any other real prop once its world unloads.
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

        // Bridge networking (on_update, UE4SS's own thread) and actor work (game_thread_tick,
        // the real game thread) now run concurrently -- this guards the state both sides touch.
        std::mutex state_mutex;
        std::vector<std::string> pending_incoming_lines; // filled by on_update, drained by game_thread_tick
        std::string cached_local_state_json;             // built by game_thread_tick, sent by on_update

        bool unreal_ready{false};
        uint64_t tick_count{0};
        uint64_t ticks_since_ready{0};
        std::unique_ptr<BridgeClient> bridge;
        std::unordered_map<std::string, RemoteGhost> remotes;
        std::unordered_set<RC::Unreal::AActor*> hijacked_actors; // prevents two remotes sharing one prop
        RC::Unreal::UWorld* last_logged_world{nullptr};
    };
} // namespace MeshGhostPseudo
