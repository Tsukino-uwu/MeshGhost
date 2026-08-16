#include <CoreLauncher.hpp>

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
        auto module_directory() -> std::wstring
        {
            HMODULE self{};
            if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                    reinterpret_cast<LPCWSTR>(&module_directory),
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

    auto CoreLauncher::tick_disconnected(uint16_t spawn_port) -> void
    {
        if (spawn_disabled)
        {
            return;
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

        std::wstring dir = module_directory();
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
