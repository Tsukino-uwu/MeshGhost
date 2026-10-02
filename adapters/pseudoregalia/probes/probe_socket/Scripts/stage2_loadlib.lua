-- Socket probe, stage 2: loads the vendored LuaSocket core into UE4SS's embedded Lua and creates, then closes, a TCP
-- socket; it never binds, connects or sends. UE4SS's Lua is compiled into UE4SS.dll, so the preloaded lua54.dll is a
-- second runtime, and a layout mismatch between the two can corrupt memory rather than fail. To run it, back up the
-- deployed MeshGhostSocketProbe\Scripts\main.lua, copy this over it, restart the game, read UE4SS.log, then restore.

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
