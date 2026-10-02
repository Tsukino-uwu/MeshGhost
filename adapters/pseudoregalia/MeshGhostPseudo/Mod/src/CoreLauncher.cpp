#include <CoreLauncher.hpp>

#include <cctype>
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

        // The directory this DLL lives in, no trailing separator; from the module, since a game's working directory is
        // whatever its launcher chose.
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
                // A full buffer means the path was truncated: grow and retry.
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

    // The folder holding the outer pseudoregalia folder (<Root>\pseudoregalia\Binaries\Win64\<exe>), from the game
    // module rather than this DLL, so UE4SS's Mods nesting does not matter. Empty on failure; callers skip empties.
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

    // Where the client, config.json, its log and its replay\ folder live: the game's root folder and nowhere else, so
    // there is one place a config can be and the log can name it. A list so another location needs no caller change.
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

    // config_text reads the first config.json that exists and caches it for CONFIG_CACHE_MS: the readers run several
    // times per poll, and config.json stays live, as the client re-reads it too. A modification-time check would be
    // another filesystem call per query, most of what the cache saves. `found` tells "no config.json" from "empty".
    constexpr auto CONFIG_CACHE_MS = 250;

    auto config_text(bool& found) -> const std::string&
    {
        static std::string cached;
        static bool cached_found = false;
        static auto last_read = std::chrono::steady_clock::time_point{};

        const auto now = std::chrono::steady_clock::now();
        if (last_read == std::chrono::steady_clock::time_point{} ||
            now - last_read >= std::chrono::milliseconds(CONFIG_CACHE_MS))
        {
            last_read = now;
            cached.clear();
            cached_found = false;
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
                cached.assign((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
                cached_found = true;
                break; // the first config.json found decides, key or no key
            }
        }
        found = cached_found;
        return cached;
    }

    // A string value by key, hand-parsed: this file has no JSON library. False when the key is absent, so a caller
    // keeps its own default; the value comes back verbatim, and the code that applies it validates it.
    auto config_string_value(const char* key, std::string& out) -> bool
    {
        {
            bool found = false;
            const std::string& text = config_text(found);
            if (!found)
            {
                return false;
            }
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

    // `missing` is what an absent key means, which differs per setting.
    auto config_bool_value(const char* key, bool missing) -> bool
    {
        {
            bool found = false;
            const std::string& text = config_text(found);
            if (!found)
            {
                return missing;
            }
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

    auto config_number_value(const char* key, double& out) -> bool
    {
        {
            bool found = false;
            const std::string& text = config_text(found);
            if (!found)
            {
                return false;
            }
            const std::string quoted = std::string("\"") + key + "\"";
            const size_t k = text.find(quoted);
            if (k == std::string::npos)
            {
                return false;
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
            if (i >= text.size() || !(std::isdigit(static_cast<unsigned char>(text[i])) || text[i] == '-' || text[i] == '.'))
            {
                return false;
            }
            char* end = nullptr;
            const double value = std::strtod(text.c_str() + i, &end);
            if (!end || end == text.c_str() + i)
            {
                return false;
            }
            out = value;
            return true;
        }
        return false;
    }

    auto resolve_bridge_base_port(uint16_t fallback) -> uint16_t
    {
        // The environment wins: the same variable as the two Lua adapters, so one launcher setting moves every game.
        if (char* env = nullptr; _dupenv_s(&env, nullptr, BRIDGE_PORT_ENV) == 0 && env != nullptr)
        {
            const unsigned long parsed = std::strtoul(env, nullptr, 10);
            free(env);
            if (parsed >= 1 && parsed <= 65535)
            {
                return static_cast<uint16_t>(parsed);
            }
        }

        // Then "local_game_bridge" in config.json, read by hand ("host:port" in quotes); anything unrecognised falls
        // through to the default.
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
                    // The digits after the last colon, so an IPv6 host or a bare port still resolves.
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

    // "autostart": false means use whichever client is running, the env var's job in the file a player already edits.
    // Absent, or anything but false, means autostart.
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
        // Read once: autostart is a launch-time decision.
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
            // -exit-with-pid covers a crash; stopping it here makes the ghost leave the moment the player quits.
            TerminateProcess(static_cast<HANDLE>(child_handle), 0);
        }
        CloseHandle(static_cast<HANDLE>(child_handle));
        child_handle = nullptr;
        child_pid = 0;
    }

    auto CoreLauncher::tick_connected() -> void
    {
        // "Did it start its own core or find mine?" comes first in a report, and with no console this log is where.
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
            // Our own child's port answered busy: another copy of the game reached it first, and "my child runs" would
            // never spawn again. Forget it, never kill it (a game uses it), and start a fresh core below. Only on busy:
            // forgetting it whenever the sweep moved on made two restarting instances chase each other's cores.
            Output::send(STR("[MeshGhostPseudo] the core this mod started (pid {}, port {}) is serving another game -- leaving it to that game and starting another on port {}.\n"),
                         child_pid, last_spawn_port, spawn_port);
            CloseHandle(static_cast<HANDLE>(child_handle));
            child_handle = nullptr;
            child_pid = 0;
        }
        if (child_still_running())
        {
            // Alive but not answering yet: a core takes a moment to bind, and a second spawn would fight it for it.
            return;
        }

        uint64_t now = now_ms();
        // The cooldown is per port: when two games start at once the loser's core cannot bind and exits, and its
        // adapter must try the next port promptly, not after the old port's cooldown.
        if (spawn_port == last_spawn_port && last_spawn_ms != 0 && now - last_spawn_ms < SPAWN_RETRY_INTERVAL_MS)
        {
            return;
        }

        // The child runs in the client's folder, so its config.json, meshghost.log and replay\ folder live there too.
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
            // Said once: a missing exe does not fix itself mid-session, and it is also what an antivirus quarantine
            // looks like from in here.
            spawn_disabled = true;
            Output::send(STR("[MeshGhostPseudo] meshghost.exe was not found -- not starting a core. Put it in the "
                             "game's own folder (the one Steam installed, next to the inner pseudoregalia folder) "
                             "alongside config.json, or in the MeshGhostPseudo mod folder; if it was there, check "
                             "whether antivirus removed it.\n"));
            return;
        }
        Output::send(STR("[MeshGhostPseudo] using meshghost.exe from {} -- its config.json, meshghost.log and replay folder live there.\n"), dir);

        // No relay settings, on purpose: the child reads config.json from the working directory set below.
        std::wstring command = L"\"" + exe + L"\" -exit-with-pid=" + std::to_wstring(GetCurrentProcessId()) +
                               L" -bridge=127.0.0.1:" + std::to_wstring(spawn_port);

        STARTUPINFOW startup{};
        startup.cb = sizeof(startup);
        PROCESS_INFORMATION process{};

        // CREATE_NO_WINDOW: the console app never creates a console, so nothing flashes; the core honours show_console.
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
