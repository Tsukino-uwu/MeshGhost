#include <CoreLauncher.hpp>

#include <cstdlib>
#include <fstream>
#include <iterator>
#include <vector>

#include <DynamicOutput/DynamicOutput.hpp>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <chrono>

namespace MeshGhostPseudo
{
    using namespace RC;

    namespace
    {
        auto now_ms() -> uint64_t
        {
            return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
                                             std::chrono::steady_clock::now().time_since_epoch())
                                             .count());
        }

        // Returns the directory this DLL lives in, with no trailing separator.
        //
        // Resolved from the module rather than from the working directory or the game's install
        // path, because neither is reliable here: this mod is dropped into the GAME's UE4SS
        // Mods folder, so there is nothing to walk up to a MeshGhost release folder, and a
        // game's working directory is whatever its launcher chose. This DLL's own folder is the
        // fixed point; the client's folder is found from it (config_search_dirs).
        auto module_directory_impl() -> std::wstring
        {
            HMODULE self{};
            if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                    reinterpret_cast<LPCWSTR>(&module_directory_impl),
                                    &self))
            {
                return {};
            }

            std::wstring path(MAX_PATH, L'\0');
            for (;;)
            {
                DWORD len = GetModuleFileNameW(self, path.data(), static_cast<DWORD>(path.size()));
                if (len == 0)
                {
                    return {};
                }
                // Truncation is reported by filling the buffer exactly, so grow and retry
                // rather than silently using a cut-off path (a long Steam library path on a
                // drive with deep folders is not exotic).
                if (len < path.size())
                {
                    path.resize(len);
                    break;
                }
                path.resize(path.size() * 2);
            }

            auto slash = path.find_last_of(L"\\/");
            if (slash == std::wstring::npos)
            {
                return {};
            }
            path.resize(slash);
            return path;
        }

        auto file_exists(const std::wstring& path) -> bool
        {
            DWORD attrs = GetFileAttributesW(path.c_str());
            return attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_DIRECTORY);
        }
    } // namespace

    auto module_directory() -> std::wstring
    {
        return module_directory_impl();
    }

    // The folder Steam installed the game into -- the one holding the OUTER "pseudoregalia"
    // folder, three levels above the game's own exe:
    //   <Root>\pseudoregalia\Binaries\Win64\pseudoregalia-Win64-Shipping.exe
    // Resolved from the GAME module (handle nullptr), not from this DLL, so it does not depend on
    // how deep UE4SS nests its Mods folder. Empty on any failure; every caller skips empties.
    auto game_root_directory() -> std::wstring
    {
        std::wstring path(MAX_PATH, L'\0');
        for (;;)
        {
            DWORD len = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
            if (len == 0)
            {
                return {};
            }
            if (len < path.size())
            {
                path.resize(len);
                break;
            }
            path.resize(path.size() * 2);
        }
        for (int up = 0; up < 4; ++up) // the exe name, Win64, Binaries, the inner pseudoregalia
        {
            auto slash = path.find_last_of(L"\\/");
            if (slash == std::wstring::npos)
            {
                return {};
            }
            path.resize(slash);
        }
        return path;
    }

    // Where the client, its config.json, its log and its replay\ folder live: the game's ROOT
    // folder, and nowhere else. The user's call, 2026-09-05, a full swap: "dll deep nested,
    // client/config easy access" -- the DLL has to sit where UE4SS loads it, the file a player
    // edits does not, and five folders deep is where nobody looks. Until v1.1.5 the mod folder
    // (and the dlls folder beside this DLL) were searched instead; they are deliberately NOT a
    // fallback now, so there is exactly one place a config can be and the log can name it. A
    // list rather than a string so the callers' loops read the same as before, and so a second
    // location can be added without touching them if that decision is ever revisited.
    auto config_search_dirs() -> std::vector<std::wstring>
    {
        return {game_root_directory()};
    }

    auto dev_toggle_present(const wchar_t* file_name) -> bool
    {
        const std::wstring dir = module_directory_impl();
        if (dir.empty() || file_name == nullptr)
        {
            return false;
        }
        return file_exists(dir + L"\\" + file_name);
    }

    // Reads a STRING value out of the mod's config.json, by key. Same two directories and the
    // same deliberately small hand parse as resolve_bridge_base_port and
    // config_disables_autostart -- this file has no JSON library and does not want one for three
    // keys.
    //
    // Returns false when the key is absent, so a caller keeps its own default rather than
    // inheriting an empty string. Whatever is between the quotes is returned verbatim: a colour is
    // validated by the code that applies it (set_plate_color takes "#RRGGBB" and ignores anything
    // else), which keeps the "what is a valid colour" answer in one place.
    auto config_string_value(const char* key, std::string& out) -> bool
    {
        for (const std::wstring& dir : config_search_dirs())
        {
            if (dir.empty())
            {
                continue;
            }
            std::ifstream f(dir + L"/config.json");
            if (!f)
            {
                continue;
            }
            const std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
            const std::string quoted = std::string("\"") + key + "\"";
            const size_t k = text.find(quoted);
            if (k == std::string::npos)
            {
                return false; // the first config.json found decides, key or no key
            }
            size_t i = text.find(':', k + quoted.size());
            if (i == std::string::npos)
            {
                return false;
            }
            ++i;
            while (i < text.size() && (text[i] == ' ' || text[i] == '\t'))
            {
                ++i;
            }
            if (i >= text.size() || text[i] != '"')
            {
                return false;
            }
            const size_t start = i + 1;
            const size_t close = text.find('"', start);
            if (close == std::string::npos)
            {
                return false;
            }
            out = text.substr(start, close - start);
            return true;
        }
        return false;
    }

    // The bool counterpart. `missing` is what an absent key means, which differs per setting --
    // "indicator" defaults ON because a player who never edits the file should still get feedback
    // from a hotkey they pressed.
    auto config_bool_value(const char* key, bool missing) -> bool
    {
        for (const std::wstring& dir : config_search_dirs())
        {
            if (dir.empty())
            {
                continue;
            }
            std::ifstream f(dir + L"/config.json");
            if (!f)
            {
                continue;
            }
            const std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
            const std::string quoted = std::string("\"") + key + "\"";
            const size_t k = text.find(quoted);
            if (k == std::string::npos)
            {
                return missing;
            }
            size_t i = text.find(':', k + quoted.size());
            if (i == std::string::npos)
            {
                return missing;
            }
            ++i;
            while (i < text.size() && (text[i] == ' ' || text[i] == '\t'))
            {
                ++i;
            }
            return text.compare(i, 4, "true") == 0;
        }
        return missing;
    }

    auto resolve_bridge_base_port(uint16_t fallback) -> uint16_t
    {
        // 1. The environment wins. Same variable name as the two Lua adapters, so one launcher
        //    setting moves every game's range the same way.
        if (char* env = nullptr; _dupenv_s(&env, nullptr, BRIDGE_PORT_ENV) == 0 && env != nullptr)
        {
            const unsigned long parsed = std::strtoul(env, nullptr, 10);
            free(env);
            if (parsed >= 1 && parsed <= 65535)
            {
                return static_cast<uint16_t>(parsed);
            }
        }

        // 2. "local_game_bridge" in the mod's config.json -- the file the player is told to edit.
        //    Read by hand rather than with a JSON parser: this mod has none, the shape is fixed
        //    ("host:port" in quotes), and adding a parser for one key would be the larger change.
        //    Anything unrecognised falls through to the default rather than failing.
        //
        //    UE4SS LOADS A C++ MOD FROM <ModFolder>\dlls\main.dll, so module_directory() is the
        //    dlls folder and NOT the folder a player drags into their game -- config.json sits one
        //    level UP. The first version of this read the dlls folder, found nothing, and silently
        //    used the default, which the user saw as the config being ignored outright. The
        //    launcher below has carried a comment saying exactly this since it was written; this
        //    code was added forty lines away from it and did not read it.
        //
        //    Both are checked, parent first, matching how the launcher looks for meshghost.exe:
        //    the player's folder is the answer, and the dlls folder is there so a developer
        //    copying files by hand is not caught out.
        for (const std::wstring& dir : config_search_dirs())
        {
            if (dir.empty())
            {
                continue;
            }
            std::ifstream f(dir + L"\\config.json");
            if (f)
            {
                const std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
                const std::string key = "\"local_game_bridge\"";
                if (const size_t k = text.find(key); k != std::string::npos)
                {
                    // Value is "host:port"; take the digits after the LAST colon inside the quotes
                    // so an IPv6 host, or a bare port, still resolves sensibly.
                    const size_t open_q = text.find('"', k + key.size());
                    const size_t close_q = open_q == std::string::npos ? std::string::npos : text.find('"', open_q + 1);
                    if (close_q != std::string::npos)
                    {
                        const std::string value = text.substr(open_q + 1, close_q - open_q - 1);
                        const size_t colon = value.rfind(':');
                        const std::string port_text = colon == std::string::npos ? value : value.substr(colon + 1);
                        const unsigned long parsed = std::strtoul(port_text.c_str(), nullptr, 10);
                        if (parsed >= 1 && parsed <= 65535)
                        {
                            return static_cast<uint16_t>(parsed);
                        }
                    }
                }
            }
        }

        return fallback;
    }

    // "autostart": false in the config.json the mod's client reads says "do not start a client;
    // use whichever one is running" -- the user's call 2026-09-03: MESHGHOST_NO_AUTOSTART did the
    // same job, but "environment variable" means nothing to most players and a line in the file
    // they already edit does. Same two directories and the same hand parse as
    // resolve_bridge_base_port. Absent, or anything but false, means autostart.
    auto config_disables_autostart() -> bool
    {
        for (const std::wstring& dir : config_search_dirs())
        {
            if (dir.empty())
            {
                continue;
            }
            std::ifstream f(dir + L"\\config.json");
            if (!f)
            {
                continue;
            }
            const std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
            const std::string key = "\"autostart\"";
            const size_t k = text.find(key);
            if (k == std::string::npos)
            {
                return false; // the first config.json found decides, key or no key
            }
            size_t i = k + key.size();
            while (i < text.size() && (text[i] == ' ' || text[i] == ':' || text[i] == '\t'))
            {
                ++i;
            }
            return text.compare(i, 5, "false") == 0;
        }
        return false;
    }

    CoreLauncher::CoreLauncher()
    {
        // Env var read once at construction: it's a launch-time decision, and re-reading it
        // every tick would be a syscall per tick for something that cannot change usefully
        // mid-session.
        size_t required{};
        if (getenv_s(&required, nullptr, 0, NO_AUTOSTART_ENV) == 0 && required > 0)
        {
            spawn_disabled = true;
            Output::send(STR("[MeshGhostPseudo] MESHGHOST_NO_AUTOSTART is set -- not starting a core. "
                             "Start meshghost.exe yourself.\n"));
        }
        else if (config_disables_autostart())
        {
            spawn_disabled = true;
            Output::send(STR("[MeshGhostPseudo] \"autostart\": false in config.json -- not starting a core. "
                             "Start meshghost.exe yourself.\n"));
        }
    }

    CoreLauncher::~CoreLauncher()
    {
        terminate_child();
    }

    auto CoreLauncher::child_still_running() const -> bool
    {
        if (child_handle == nullptr)
        {
            return false;
        }
        return WaitForSingleObject(static_cast<HANDLE>(child_handle), 0) == WAIT_TIMEOUT;
    }

    auto CoreLauncher::terminate_child() -> void
    {
        if (child_handle == nullptr)
        {
            return;
        }
        if (child_still_running())
        {
            // The core also exits on its own once this process does (-exit-with-pid), which is
            // what covers a crash. This is the clean path: stopping it here means the player's
            // ghost leaves the room the moment they quit, rather than up to a poll later.
            TerminateProcess(static_cast<HANDLE>(child_handle), 0);
        }
        CloseHandle(static_cast<HANDLE>(child_handle));
        child_handle = nullptr;
        child_pid = 0;
    }

    auto CoreLauncher::tick_connected() -> void
    {
        // Say which of the two happened, once per connection. "Did it start its own core or
        // find mine?" is the first question worth answering when someone reports two processes,
        // a stale config, or a ghost that never appears -- and with no console window anywhere,
        // this log line is where they'd look.
        if (child_handle == nullptr && !logged_reuse)
        {
            Output::send(STR("[MeshGhostPseudo] using a MeshGhost core that was already running.\n"));
            logged_reuse = true;
        }
    }

    auto CoreLauncher::tick_disconnected(uint16_t spawn_port, uint16_t busy_port) -> void
    {
        if (spawn_disabled)
        {
            return;
        }
        if (child_still_running() && last_spawn_port != 0 && busy_port == last_spawn_port)
        {
            // OUR OWN CHILD'S PORT ANSWERED "BUSY" WHILE THE CHILD IS ALIVE: another copy of the
            // game reached it first. Read as "my child is running, so I have a core", nothing
            // below would ever spawn again, and the walk would find silence on every other port
            // for the rest of the session -- watched on TEVI's launcher 2026-09-02 (two copies
            // launched a few seconds apart), fixed there the same night and mirrored here. The
            // child is not terminated: a game is using it. Forget it, so a fresh core starts at
            // the cursor below. ONLY on "busy": the first version also forgot it when the sweep
            // merely moved on, and two instances restarting together then chased each other's
            // fresh cores round the range (Emerald, the same night).
            Output::send(STR("[MeshGhostPseudo] the core this mod started (pid {}, port {}) is serving another game -- leaving it to that game and starting another on port {}.\n"),
                         child_pid, last_spawn_port, spawn_port);
            CloseHandle(static_cast<HANDLE>(child_handle));
            child_handle = nullptr;
            child_pid = 0;
        }
        if (child_still_running())
        {
            // Spawned already and still alive, just not answering yet -- a core takes a moment
            // to bind its listener. Waiting is correct; spawning a second one here is how you
            // get a pile of processes fighting over one port.
            return;
        }

        uint64_t now = now_ms();
        // The cooldown is per PORT, not global: if the sweep has moved on to a different free
        // port, waiting out a previous port's cooldown would be waiting for nothing. This is the
        // case two games starting at once produce -- both find the same free port, both spawn,
        // and the loser's core exits immediately because it cannot bind, so its adapter needs to
        // try the next port promptly rather than in ten seconds.
        if (spawn_port == last_spawn_port && last_spawn_ms != 0 && now - last_spawn_ms < SPAWN_RETRY_INTERVAL_MS)
        {
            return;
        }

        // Where the client lives decides where its config.json, meshghost.log and replay\ folder
        // live too: the child runs with that folder as its working directory. Game root first,
        // then the mod folder, then the dlls folder -- see config_search_dirs for why that order.
        std::wstring exe, dir;
        for (const std::wstring& candidate : config_search_dirs())
        {
            if (candidate.empty())
            {
                continue;
            }
            if (file_exists(candidate + L"\\meshghost.exe"))
            {
                dir = candidate;
                exe = dir + L"\\meshghost.exe";
                break;
            }
        }
        if (exe.empty())
        {
            // Said once, then never again: a missing exe does not fix itself mid-session, and a
            // per-tick complaint would bury everything else in the log. This is also what an
            // antivirus quarantine looks like from in here, so the message names that
            // possibility -- see agent_docs/risks.md.
            spawn_disabled = true;
            Output::send(STR("[MeshGhostPseudo] meshghost.exe was not found -- not starting a core. Put it in the "
                             "game's own folder (the one Steam installed, next to the inner pseudoregalia folder) "
                             "alongside config.json, or in the MeshGhostPseudo mod folder; if it was there, check "
                             "whether antivirus removed it.\n"));
            return;
        }
        Output::send(STR("[MeshGhostPseudo] using meshghost.exe from {} -- its config.json, meshghost.log and replay folder live there.\n"), dir);

        // No relay settings here, on purpose -- see this class's header comment. The child reads
        // config.json out of the working directory set below.
        std::wstring command = L"\"" + exe + L"\" -exit-with-pid=" + std::to_wstring(GetCurrentProcessId()) +
                               L" -bridge=127.0.0.1:" + std::to_wstring(spawn_port);

        STARTUPINFOW startup{};
        startup.cb = sizeof(startup);
        PROCESS_INFORMATION process{};

        // CREATE_NO_WINDOW is the whole point: a console app spawned this way never creates a
        // console at all, so there is no window to flash and hide. (A player who wants one back
        // sets show_console in config.json, which the core acts on itself.)
        BOOL ok = CreateProcessW(exe.c_str(),
                                 command.data(),
                                 nullptr,
                                 nullptr,
                                 FALSE,
                                 CREATE_NO_WINDOW,
                                 nullptr,
                                 dir.c_str(),
                                 &startup,
                                 &process);
        last_spawn_ms = now;
        last_spawn_port = spawn_port;

        if (!ok)
        {
            Output::send(STR("[MeshGhostPseudo] could not start meshghost.exe (error {}).\n"), GetLastError());
            return;
        }

        CloseHandle(process.hThread);
        child_handle = process.hProcess;
        child_pid = process.dwProcessId;
        Output::send(STR("[MeshGhostPseudo] started meshghost.exe (pid {}).\n"), child_pid);
    }
} // namespace MeshGhostPseudo
