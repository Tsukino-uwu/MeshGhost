-- MeshGhost Phase 7 socket-capability probe, Stage 3: a real bind/connect/send/receive round
-- trip against the actual bridge protocol, the one thing Stage 2 deliberately left untested
-- (see agent_docs/verified.md and agent_docs/phases/phase7.md -- Stage 2 confirmed
-- socket.tcp() object creation is safe, but never called :connect()/:send()/:receive()).
--
-- NOT WIRED IN as this mod's entry point (same reason as Stage 2 -- UE4SS Lua mods always load
-- Scripts/main.lua). Deploy by swapping this file in as main.lua, same as Stage 2.
--
-- Requires, started BEFORE launching the game:
--   dev-scripts\run-relay-loopback.bat   (meshghost-relay.exe -loopback)
--   dev-scripts\run-core-pseudoregalia.bat (meshghost.exe -game=pseudoregalia -bridge=127.0.0.1:7778)
-- With no adapter connected yet, the core waits for this script's hello before dialing the
-- relay (Stage B's deferred-connect behavior, cmd/meshghost/main.go) -- so meshghost.exe's own
-- console output is a second, independent source of truth alongside UE4SS.log.
--
-- What this sends is NOT a real local_state read (that's 7.1's job, not yet ported into a
-- socket-carrying script) -- it's one hardcoded dummy frame, purely to exercise the wire path.
-- run-relay-loopback.bat echoes each client's own state back to itself as "<id>-ghost", so a
-- successful round trip here means receiving a render_remote frame back for our own dummy
-- state -- the clearest possible signal that send AND receive both work, not just connect.

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
    -- Blocking with a timeout, not the non-blocking-retry-per-frame pattern the real emerald
    -- adapter uses (phase3_loopback.lua) -- this is a one-shot probe run once at mod load, not
    -- a per-frame loop, and the core is expected to already be up and listening.
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

    -- Up to 3 blocking reads (3s timeout each, ~9s worst case): run-relay-loopback.bat should
    -- echo our own state back as a render_remote for "<our-id>-ghost" within one relay tick.
    for i = 1, 3 do
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
