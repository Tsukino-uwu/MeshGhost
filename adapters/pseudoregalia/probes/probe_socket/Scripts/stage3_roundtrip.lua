-- Socket probe, stage 3: a real connect/send/receive round trip against the bridge protocol, with dummy frames.
-- Deploy by copying it over Scripts/main.lua. Needs the loopback relay and a Pseudoregalia core on 127.0.0.1:7778
-- running before the game starts; a render_remote back for our own dummy state proves send and receive both work.

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    local path = src:match("^@(.*[/\\])")
    return path or "./"
end

local SCRIPT_DIR = scriptDir()
local BRIDGE_HOST = "127.0.0.1"
local BRIDGE_PORT = 7778

local function log(fmt, ...)
    print(string.format("[MeshGhostSocketProbe] Stage 3: " .. fmt .. "\n", ...))
end

local function preloadLua54()
    pcall(function()
        package.loadlib(SCRIPT_DIR .. "lib/x64/lua54.dll", "meshghost_force_preload")
    end)
end

local function loadSocketCore()
    preloadLua54()
    local dllPath = SCRIPT_DIR .. "lib/x64/socket-windows-5-4.dll"
    return assert(package.loadlib(dllPath, "luaopen_socket_core"))()
end

local okLoad, socketCoreOrErr = pcall(loadSocketCore)
if not okLoad then
    log("FAILED to load socket core: %s", tostring(socketCoreOrErr))
    return
end
local socketCore = socketCoreOrErr
log("socket core loaded (repeat of Stage 2, expected to succeed).")

local okRun, runErr = pcall(function()
    local sock = socketCore.tcp()
    -- Blocking with a timeout: a one-shot run at load, with the core expected to be listening already.
    sock:settimeout(3)

    log("connecting to %s:%d ...", BRIDGE_HOST, BRIDGE_PORT)
    local ok, err = sock:connect(BRIDGE_HOST, BRIDGE_PORT)
    if ok ~= 1 then
        log("connect FAILED: %s (is run-core-pseudoregalia.bat running?)", tostring(err))
        pcall(function() sock:close() end)
        return
    end
    log("connected.")

    local helloLine = '{"type":"hello","payload":{"game_id":"pseudoregalia"}}'
    log("sending hello: %s", helloLine)
    local sentOk, sendErr = sock:send(helloLine .. "\n")
    if not sentOk then
        log("send FAILED: %s", tostring(sendErr))
        pcall(function() sock:close() end)
        return
    end
    log("hello sent (%d bytes).", sentOk)

    local stateLine = '{"type":"local_state","payload":{"state":{"area_id":"stage3_probe","position":[1,2],"orientation":"0","anim":"idle"}}}'
    log("sending local_state: %s", stateLine)
    sentOk, sendErr = sock:send(stateLine .. "\n")
    if not sentOk then
        log("send FAILED: %s", tostring(sendErr))
        pcall(function() sock:close() end)
        return
    end
    log("local_state sent (%d bytes).", sentOk)

    -- The core pushes render_remote only while handling a new local_state, so a fresh frame precedes each receive.
    for i = 1, 5 do
        local nextStateLine = string.format(
            '{"type":"local_state","payload":{"state":{"area_id":"stage3_probe","position":[%d,2],"orientation":"0","anim":"idle"}}}',
            i)
        sock:send(nextStateLine .. "\n")

        log("receive attempt %d...", i)
        local line, recvErr = sock:receive()
        if line then
            log("RECEIVED: %s", line)
        elseif recvErr == "timeout" then
            log("receive timed out, trying again.")
        else
            log("receive FAILED: %s", tostring(recvErr))
            break
        end
    end

    pcall(function() sock:close() end)
    log("socket closed.")
end)

if not okRun then
    log("round trip pcall caught an error: %s", tostring(runErr))
end

log("complete. Report back what UE4SS.log AND meshghost.exe's own console both show, and whether the game stayed stable.")
