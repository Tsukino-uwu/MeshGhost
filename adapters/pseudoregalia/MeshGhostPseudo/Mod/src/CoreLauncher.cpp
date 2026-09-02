#include <CoreLauncher.hpp>

#include <cstdlib>
#include <fstream>
#include <iterator>

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
        // game's working directory is whatever its launcher chose. The one thing that is always
        // true is that meshghost.exe ships beside this DLL.
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

    auto dev_toggle_present(const wchar_t* file_name) -> bool
    {
        const std::wstring dir = module_directory_impl();
        if (dir.empty() || file_name == nullptr)
        {
            return false;
        }
        return file_exists(dir + L"\\" + file_name);
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
        std::wstring dirs[2];
        dirs[1] = module_directory();
        dirs[0] = dirs[1];
        if (auto slash = dirs[0].find_last_of(L"\\/"); slash != std::wstring::npos)
        {
            dirs[0].resize(slash);
        }
        for (const std::wstring& dir : dirs)
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
        std::wstring dirs[2];
        dirs[1] = module_directory();
        dirs[0] = dirs[1];
        if (auto slash = dirs[0].find_last_of(L"\\/"); slash != std::wstring::npos)
        {
            dirs[0].resize(slash);
        }
        for (const std::wstring& dir : dirs)
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

        std::wstring dir = module_directory();  // the exported one, same result
        if (dir.empty())
        {
            spawn_disabled = true;
            Output::send(STR("[MeshGhostPseudo] could not resolve this mod's own folder -- not starting a core. "
                             "Start meshghost.exe yourself.\n"));
            return;
        }

        // UE4SS loads a C++ mod from <ModFolder>\dlls\main.dll, so the module directory is the
        // dlls folder, NOT the folder a player drags into their game. The exe ships in the mod
        // folder (one up) because that is the thing they can see and edit config.json in; the
        // dlls folder is checked too so a developer copying files by hand isn't caught out.
        std::wstring parent = dir;
        if (auto slash = parent.find_last_of(L"\\/"); slash != std::wstring::npos)
        {
            parent.resize(slash);
        }

        std::wstring exe = parent + L"\\meshghost.exe";
        if (!file_exists(exe))
        {
            exe = dir + L"\\meshghost.exe";
        }
        else
        {
            dir = parent;
        }
        if (!file_exists(exe))
        {
            // Said once, then never again: a missing exe does not fix itself mid-session, and a
            // per-tick complaint would bury everything else in the log. This is also what an
            // antivirus quarantine looks like from in here, so the message names that
            // possibility -- see agent_docs/risks.md.
            spawn_disabled = true;
            Output::send(STR("[MeshGhostPseudo] meshghost.exe is not in the MeshGhostPseudo folder -- not "
                             "starting a core. It should sit next to this mod's dlls folder, alongside "
                             "config.json; if it was there, check whether antivirus removed it.\n"));
            return;
        }

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
