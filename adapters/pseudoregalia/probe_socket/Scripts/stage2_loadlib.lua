-- MeshGhost Phase 7 socket-capability probe, Stage 2 (RISKIER): attempts to actually load the
-- vendored LuaSocket core into UE4SS's embedded Lua and create (not connect) a local TCP socket
-- object. Only run this after Stage 1 (main.lua) confirmed package.loadlib/package.cpath are
-- present -- and only with the user's explicit go-ahead, per agent_docs/phases/phase7.md.
--
-- NOT WIRED IN as this mod's entry point. UE4SS Lua mods load Scripts/main.lua as their fixed
-- entry point, so Stage 1's main.lua stays the default. To run Stage 2: back up the currently
-- deployed ue4ss/Mods/MeshGhostSocketProbe/Scripts/main.lua, then copy THIS file over it,
-- restart the game, and watch UE4SS.log. Restore the Stage 1 main.lua afterward either way.
--
-- Why this is riskier than Emerald's equivalent (adapters/bizhawk/pokemon/emerald/probes/phase3_loopback.lua):
-- BizHawk's Lua host is a real, separate lua54.dll, so Phase 3 could preload a byte-identical
-- copy of BizHawk's own lua54.dll and know the socket core binds to a compatible instance
-- (confirmed empirically at the time, see phase3_loopback.lua's own comment and
-- agent_docs/architecture.md). UE4SS's Lua 5.4 is statically compiled INTO UE4SS.dll -- it does
-- not export a lua54.dll at all. So the preload below loads OUR vendored lua54.dll (a distinct,
-- independently-built Lua 5.4 runtime) into the process, while the lua_State* that
-- luaopen_socket_core actually receives is UE4SS's own internal state. If the two Lua 5.4
-- builds don't agree on internal struct layout, this can corrupt memory instead of failing
-- cleanly -- there is no way to fully rule that out from outside UE4SS's source, only reduce
-- the blast radius (see the deliberately minimal steps below) and watch the result live.
--
-- Deliberately conservative about what it does once loaded: creates a local socket.tcp() object
-- and immediately closes it. Does NOT bind, connect, or send/receive a single byte -- if
-- luaopen_socket_core() itself doesn't corrupt anything, this is the smallest possible next
-- check before trying real network I/O in a later step.

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    local path = src:match("^@(.*[/\\])")
    return path or "./"
end

local SCRIPT_DIR = scriptDir()

print("[MeshGhostSocketProbe] Stage 2: attempting to load LuaSocket core into UE4SS's embedded Lua.\n")

local function preloadLua54()
    print("[MeshGhostSocketProbe] Stage 2: preloading vendored lua54.dll (side effect only, symbol lookup expected to fail)...\n")
    local ok, err = pcall(function()
        package.loadlib(SCRIPT_DIR .. "lib/x64/lua54.dll", "meshghost_force_preload")
    end)
    print(string.format("[MeshGhostSocketProbe] Stage 2: preload pcall returned ok=%s err=%s\n", tostring(ok), tostring(err)))
end

local function loadSocketCore()
    if package.config:sub(1, 1) ~= "\\" then
        error("MeshGhost Phase 7 Stage 2: only Windows is supported by the vendored LuaSocket binary.")
    end
    local luaMajor, luaMinor = _VERSION:match("Lua (%d+)%.(%d+)")
    if luaMajor ~= "5" or luaMinor ~= "4" then
        error("MeshGhost Phase 7 Stage 2: only Lua 5.4 is supported by the vendored LuaSocket binary (got " .. tostring(_VERSION) .. ").")
    end

    preloadLua54()

    local dllPath = SCRIPT_DIR .. "lib/x64/socket-windows-5-4.dll"
    print("[MeshGhostSocketProbe] Stage 2: calling package.loadlib for socket-windows-5-4.dll (luaopen_socket_core) -- this is the risky call.\n")
    local opener = assert(package.loadlib(dllPath, "luaopen_socket_core"))
    print("[MeshGhostSocketProbe] Stage 2: loadlib returned an opener function without erroring. Calling it now.\n")
    local core = opener()
    print("[MeshGhostSocketProbe] Stage 2: luaopen_socket_core() returned without erroring.\n")
    return core
end

local okLoad, socketCoreOrErr = pcall(loadSocketCore)
if not okLoad then
    print(string.format("[MeshGhostSocketProbe] Stage 2: FAILED to load socket core: %s\n", tostring(socketCoreOrErr)))
    print("[MeshGhostSocketProbe] Stage 2 complete (load failed, nothing further attempted).\n")
    return
end

local socketCore = socketCoreOrErr
print(string.format("[MeshGhostSocketProbe] Stage 2: type(socketCore) = %s\n", type(socketCore)))
if type(socketCore) == "table" then
    print(string.format("[MeshGhostSocketProbe] Stage 2: type(socketCore.tcp) = %s\n", type(socketCore.tcp)))
end

print("[MeshGhostSocketProbe] Stage 2: attempting socket.tcp() -- object creation only, no connect/bind/send.\n")
local okTcp, sockOrErr = pcall(function()
    return socketCore.tcp()
end)
if okTcp then
    print(string.format("[MeshGhostSocketProbe] Stage 2: socket.tcp() succeeded, type=%s. Closing it immediately.\n", type(sockOrErr)))
    pcall(function()
        sockOrErr:close()
    end)
    print("[MeshGhostSocketProbe] Stage 2: socket closed.\n")
else
    print(string.format("[MeshGhostSocketProbe] Stage 2: socket.tcp() failed: %s\n", tostring(sockOrErr)))
end

print("[MeshGhostSocketProbe] Stage 2 complete. Report back what UE4SS.log shows -- including whether\n")
print("[MeshGhostSocketProbe] the game is still stable -- before any further step (e.g. real bind/connect).\n")
