#pragma once

// Starts (and reaps) the local MeshGhost core process, so a player never has to run
// meshghost.exe themselves.
//
// Why this exists: a Pseudoregalia speedrunner tried MeshGhost and said the separate
// client exe defeats the point -- the interactions worth having were the unplanned ones,
// both people simply having it on while practising, and nobody launches a second program
// for an encounter they haven't planned. Starting the game has to be the whole ritual.
//
// What this does NOT do, deliberately: it passes the core no relay address, no transport,
// and no rate. agent_docs/contract.md's invariant is that an adapter "has no say in HOW the
// core reaches the relay" -- so the child is given a working directory (this mod's own
// folder) and finds config.json there by itself, exactly as it would if a human had
// double-clicked it in that folder. The only arguments passed are this mod's own bridge
// port, which is the adapter's end of a local socket and always was its business, and a pid
// to die with. Spawning a process is a lifecycle act, not a protocol one.
//
// See agent_docs/architecture.md's autostart ADR.

#include <cstdint>
#include <string>

namespace MeshGhostPseudo
{
    // How long to wait before spawning again after a spawn that didn't result in a working
    // bridge. Long enough that a core failing at startup (a port already taken, an antivirus
    // eating the exe) doesn't turn into a process-spawn loop, short enough that a genuinely
    // slow first start still recovers on its own.
    inline constexpr uint64_t SPAWN_RETRY_INTERVAL_MS = 10000;

    // Set this environment variable (to anything) to keep the mod from starting a core.
    // For the dev-scripts launchers, which run their own core with specific flags, and as
    // the escape hatch if a machine's antivirus objects to a game mod starting a program --
    // see agent_docs/risks.md.
    inline constexpr auto NO_AUTOSTART_ENV = "MESHGHOST_NO_AUTOSTART";

    class CoreLauncher
    {
      public:
        CoreLauncher();
        ~CoreLauncher();

        CoreLauncher(const CoreLauncher&) = delete;
        auto operator=(const CoreLauncher&) -> CoreLauncher& = delete;

        // Call on a tick where the bridge is NOT connected, passing a port where nothing is
        // listening. Spawns a core there, subject to SPAWN_RETRY_INTERVAL_MS.
        //
        // The port is a per-call argument rather than a constructor value because it is now a
        // runtime answer from BridgeClient's sweep: with two games running, the free port is not
        // the same one every time, and a launcher holding a stale number would respawn into a
        // collision forever (the core exits immediately if it cannot bind).
        //
        // Hanging this off the failure path is what makes "reuse a core that's already
        // running" free rather than a feature: we only ever get here after a connect attempt
        // failed, so a core the player started themselves -- or a native one on the Linux
        // side of a Proton prefix, which this mod could never have spawned or killed -- is
        // simply used, and never duplicated.
        auto tick_disconnected(uint16_t spawn_port) -> void;

        // Call on a tick where the bridge IS connected, so the next disconnection is treated
        // as fresh rather than as a continuation of an old spawn's cooldown.
        auto tick_connected() -> void;

      private:
        // Terminates the child if (and only if) we spawned it and it's still running. Never
        // touches a core we merely found: killing a process another program owns is not this
        // mod's business, and the player may well be using it for a second game.
        auto terminate_child() -> void;
        auto child_still_running() const -> bool;

        uint16_t last_spawn_port{0};
        void* child_handle{nullptr}; // HANDLE, as void* so this header needs no <windows.h>
        uint32_t child_pid{};
        uint64_t last_spawn_ms{};
        bool spawn_disabled{false}; // set once, if autostart is off or the exe isn't there
        bool logged_reuse{false};
    };
} // namespace MeshGhostPseudo
