#pragma once

// Starts and reaps the local MeshGhost core, so starting the game is the whole ritual. The core gets no relay
// address, transport or rate, since an adapter has no say in how it reaches the relay: only the bridge port, a pid
// to die with, and the game's root folder as its working directory, where it finds config.json itself.

#include <cstdint>
#include <string>
#include <vector>

namespace MeshGhostPseudo
{
    // Wait before respawning after a spawn that gave no working bridge: long enough that a core failing at startup
    // (a port taken, antivirus eating the exe) is not a spawn loop, short enough that a slow first start recovers.
    inline constexpr uint64_t SPAWN_RETRY_INTERVAL_MS = 10000;

    // Set (to anything) to keep the mod from starting a core: for launchers that run their own, and as the escape
    // hatch if antivirus objects to a game mod starting a program.
    inline constexpr auto NO_AUTOSTART_ENV = "MESHGHOST_NO_AUTOSTART";

    // Moves the whole bridge port range, the variable Emerald and Crystal honour; highest precedence.
    inline constexpr auto BRIDGE_PORT_ENV = "MESHGHOST_BRIDGE_PORT";

    // The folder this DLL sits in, where the dev toggle and tuning files live.
    auto module_directory() -> std::wstring;
    // The game's root folder (empty on failure), and the folders the client, config.json and log may live in: the
    // game root alone.
    auto game_root_directory() -> std::wstring;
    auto config_search_dirs() -> std::vector<std::wstring>;

    // The base of the bridge port walk, resolved once at startup: MESHGHOST_BRIDGE_PORT, then "local_game_bridge" in
    // config.json, then the default. Anything unparseable gives the default: a typo in a port setting must not stop
    // the mod loading.
    auto resolve_bridge_base_port(uint16_t fallback) -> uint16_t;

    auto config_string_value(const char* key, std::string& out) -> bool;
    auto config_bool_value(const char* key, bool missing) -> bool;
    // False when the key is absent or not a number, so a caller keeps its own default.
    auto config_number_value(const char* key, double& out) -> bool;

    // True when config.json carries "autostart": false.
    auto config_disables_autostart() -> bool;

    // Whether a file of this name sits beside this DLL: a dev toggle a running game can flip without a relaunch.
    // Names a file, never a path.
    auto dev_toggle_present(const wchar_t* file_name) -> bool;

    class CoreLauncher
    {
      public:
        CoreLauncher();
        ~CoreLauncher();

        CoreLauncher(const CoreLauncher&) = delete;
        auto operator=(const CoreLauncher&) -> CoreLauncher& = delete;

        // Call on a tick where the bridge is not connected: spawns a core on spawn_port, where nothing listens, subject
        // to SPAWN_RETRY_INTERVAL_MS. The port comes from BridgeClient's sweep each call, since with two games running
        // it moves. Reached only after a failed connect, so a core already running is used, never duplicated.
        auto tick_disconnected(uint16_t spawn_port, uint16_t busy_port) -> void;

        // The port of the still-running child this launcher started, 0 otherwise, so the sweep waits on it.
        auto child_port() const -> uint16_t
        {
            return child_still_running() ? last_spawn_port : 0;
        }

        // Call on a tick where the bridge is connected: logs once when the core was found rather than started.
        auto tick_connected() -> void;

      private:
        // Only a child this launcher spawned: a core it merely found may be serving another game.
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
