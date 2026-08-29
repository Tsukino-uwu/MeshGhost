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

    // Set this to move the whole bridge port range, the same variable Emerald and Crystal already
    // honour. Highest precedence, because it is what a launcher or a dev script sets for one run.
    inline constexpr auto BRIDGE_PORT_ENV = "MESHGHOST_BRIDGE_PORT";

    // The folder this DLL sits in. Shared rather than duplicated: the launcher needs it to find
    // meshghost.exe, and the bridge needs it to find config.json, and two copies of a
    // path-resolution routine is exactly the kind of divergence this adapter has been bitten by.
    auto module_directory() -> std::wstring;

    // The base of the bridge port walk, resolved once at startup.
    //
    // Precedence: MESHGHOST_BRIDGE_PORT, then "local_game_bridge" in the config.json beside this
    // DLL, then the compiled-in default. That middle step is the one a player has: until
    // 2026-08-28 this mod's port was a compile-time constant, so editing local_game_bridge did
    // nothing and a 0.9.9 user reported exactly that -- "setting the config to 7780 it still
    // starts at 7778". The setting was in the file they were told to edit and was read only by
    // the core, while the mod both chose its own port and passed it to the core with -bridge,
    // overriding what they had written.
    //
    // Returns the default rather than failing on anything unparseable: a typo in a cosmetic port
    // setting must not stop a game's mod from loading.
    auto resolve_bridge_base_port(uint16_t fallback) -> uint16_t;

    // "Is there a file of this name sitting beside this DLL?" -- the dev-toggle question, answered
    // without a second copy of the module-directory dance that resolve_bridge_base_port already
    // needs. A running game cannot be given a new compile-time flag, and this repo's Pseudoregalia
    // rule is to iterate in-session rather than pay a relaunch per experiment
    // (adapters/pseudoregalia/CLAUDE.md), so a diagnostic that has to be flipped WHILE the user
    // stands in the room being measured is flipped by creating and deleting a file.
    //
    // Names a file, never a path: a path belongs to one machine and this is a public repo.
    auto dev_toggle_present(const wchar_t* file_name) -> bool;

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
