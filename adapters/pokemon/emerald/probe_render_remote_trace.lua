-- MeshGhost dev probe: a headless companion to meshghost_emerald.lua that connects to the same
-- bridge protocol (same addresses, same networking, same JSON -- all identical to and copied
-- from that script, see its header for the full derivation/citations) but does NOT decode or
-- draw a sprite. Its only job is to print, every ~2s, this client's own area/position and
-- every currently-known remote's area/position/match status. Never writes memory.
--
-- Why this exists: found live 2026-08-14 during the first real non-loopback two-peer Emerald
-- test, ghosts weren't rendering and the cause turned out to be a launch-time mistake (the
-- second BizHawk instance never got MESHGHOST_BRIDGE_PORT set, so both instances silently
-- shared one core's bridge) -- see agent_docs/pitfalls.md's "Running two instances of the same
-- emulator/game silently collide on a shared default port" entry. Diagnosing that took adding
-- throttled trace logging directly into the shipping adapter and internal/core, then reverting
-- both once confirmed. This probe exists so that trace capability doesn't need to be
-- re-added/re-reverted in the shipping script next time -- load this instead, alongside or
-- instead of meshghost_emerald.lua, to see the same local/remote area+position trace without
-- touching the file that ships.
--
-- Usage: load this in BizHawk's Lua Console the same way as meshghost_emerald.lua (same
-- MESHGHOST_BRIDGE_PORT env var convention). Can run standing in for a real adapter (it does
-- send its own real local_state, so it participates in the room like a normal peer, just with
-- no visible ghost) or alongside a real running adapter on a different bridge port to observe
-- that peer's own traffic pattern from a second vantage point.

local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24

local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c

local function inOverworld()
    local callback2 = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    return callback2 == CB2_OVERWORLD_ADDR or callback2 == CB2_OVERWORLD_ADDR + 1
end

local BRIDGE_HOST = "127.0.0.1"
local BRIDGE_PORT = tonumber(os.getenv("MESHGHOST_BRIDGE_PORT") or "") or 7778

local GAME_ID = "emerald"
local ADAPTER_VERSION = "probe_render_remote_trace"

local FACING = { [1] = "south", [2] = "north", [3] = "west", [4] = "east" }

----------------------------------------------------------------------------
-- Paths -- identical to meshghost_emerald.lua, see its header for why
-- debug.getinfo does NOT work here.
----------------------------------------------------------------------------

local function scriptDir()
    local pwd = io.popen and io.popen("cd"):read("*l")
    if not pwd or pwd == "" then
        error("MeshGhost probe: could not determine the script's own directory (io.popen \"cd\" unavailable or returned nothing).")
    end
    return pwd .. "\\"
end

local SCRIPT_DIR = scriptDir()

----------------------------------------------------------------------------
-- LuaSocket -- identical to meshghost_emerald.lua, see its header.
----------------------------------------------------------------------------

local function preloadLua54()
    pcall(function()
        package.loadlib(SCRIPT_DIR .. "lib/x64/lua54.dll", "meshghost_force_preload")
    end)
end

local function loadSocketCore()
    if package.config:sub(1, 1) ~= "\\" then
        error("MeshGhost probe: only Windows is supported by the vendored LuaSocket binary so far.")
    end
    local luaMajor, luaMinor = _VERSION:match("Lua (%d+)%.(%d+)")
    if luaMajor ~= "5" or luaMinor ~= "4" then
        error("MeshGhost probe: only Lua 5.4 is supported by the vendored LuaSocket binary so far (got " .. _VERSION .. ").")
    end
    local arch = os.getenv("PROCESSOR_ARCHITECTURE") or ""
    if not arch:find("64") then
        error("MeshGhost probe: only x64 is supported by the vendored LuaSocket binary so far.")
    end
    preloadLua54()
    local dllPath = SCRIPT_DIR .. "lib/x64/socket-windows-5-4.dll"
    return assert(package.loadlib(dllPath, "luaopen_socket_core"))()
end

local socketCore = loadSocketCore()

----------------------------------------------------------------------------
-- Minimal JSON -- identical to meshghost_emerald.lua, see its header.
----------------------------------------------------------------------------

local JSON_STRING_ESCAPES = {
    ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}
local function jsonString(s)
    s = s:gsub('[\\"%c]', function(c)
        return JSON_STRING_ESCAPES[c] or string.format("\\u%04x", c:byte())
    end)
    return '"' .. s .. '"'
end

local function encodeLocalState(areaId, x, y, orientation, anim)
    return string.format(
        '{"type":"local_state","payload":{"state":{"area_id":%s,"position":[%s,%s],"orientation":%s,"anim":%s}}}',
        jsonString(areaId), tostring(x), tostring(y), jsonString(orientation), jsonString(anim))
end

local ENCODED_NO_SEND = '{"type":"local_state","payload":{"state":null}}'

local decodeValue -- forward declaration

local function skipWs(s, i)
    local _, j = s:find("^[ \t\r\n]*", i)
    return j + 1
end

local function decodeString(s, i)
    local j = i + 1
    local out = {}
    while true do
        local c = s:sub(j, j)
        if c == "" then
            error("json: unterminated string")
        elseif c == '"' then
            return table.concat(out), j + 1
        elseif c == "\\" then
            local e = s:sub(j + 1, j + 1)
            if e == "n" then table.insert(out, "\n")
            elseif e == "t" then table.insert(out, "\t")
            elseif e == "r" then table.insert(out, "\r")
            elseif e == "u" then
                local hex = s:sub(j + 2, j + 5)
                table.insert(out, string.char(tonumber(hex, 16) % 256))
                j = j + 4
            else
                table.insert(out, e)
            end
            j = j + 2
        else
            table.insert(out, c)
            j = j + 1
        end
    end
end

local function decodeNumber(s, i)
    local _, j, num = s:find("^(-?%d+%.?%d*[eE]?[%+%-]?%d*)", i)
    if not num then error("json: expected number") end
    return tonumber(num), j + 1
end

local function decodeObject(s, i)
    local obj = {}
    i = skipWs(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
        local key
        key, i = decodeString(s, i)
        i = skipWs(s, i)
        if s:sub(i, i) ~= ":" then error("json: expected ':'") end
        i = skipWs(s, i + 1)
        local val
        val, i = decodeValue(s, i)
        obj[key] = val
        i = skipWs(s, i)
        local c = s:sub(i, i)
        if c == "," then
            i = skipWs(s, i + 1)
        elseif c == "}" then
            return obj, i + 1
        else
            error("json: expected ',' or '}'")
        end
    end
end

local function decodeArray(s, i)
    local arr = {}
    i = skipWs(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
        local val
        val, i = decodeValue(s, i)
        table.insert(arr, val)
        i = skipWs(s, i)
        local c = s:sub(i, i)
        if c == "," then
            i = skipWs(s, i + 1)
        elseif c == "]" then
            return arr, i + 1
        else
            error("json: expected ',' or ']'")
        end
    end
end

decodeValue = function(s, i)
    i = skipWs(s, i)
    local c = s:sub(i, i)
    if c == "{" then return decodeObject(s, i)
    elseif c == "[" then return decodeArray(s, i)
    elseif c == '"' then return decodeString(s, i)
    elseif c == "t" then
        if s:sub(i, i + 3) ~= "true" then error("json: bad literal") end
        return true, i + 4
    elseif c == "f" then
        if s:sub(i, i + 4) ~= "false" then error("json: bad literal") end
        return false, i + 5
    elseif c == "n" then
        if s:sub(i, i + 3) ~= "null" then error("json: bad literal") end
        return nil, i + 4
    else
        return decodeNumber(s, i)
    end
end

local function jsonDecode(line)
    local ok, val = pcall(function()
        local v = decodeValue(line, 1)
        return v
    end)
    if not ok then return nil end
    return val
end

----------------------------------------------------------------------------
-- Bridge connection -- identical to meshghost_emerald.lua, see its header.
----------------------------------------------------------------------------

local sock = nil
local connected = false
local recvPartial = ""

local function connectBridge()
    if not sock then
        sock = socketCore.tcp()
        sock:settimeout(0)
    end
    local ok, err = sock:connect(BRIDGE_HOST, BRIDGE_PORT)
    if ok == 1 or err == "already connected" then
        connected = true
    elseif err ~= "timeout" then
        pcall(function() sock:close() end)
        sock = nil
    end
end

local function resetBridge()
    if connected then
        console.log("MeshGhost probe: bridge connection lost, will retry connecting.")
    end
    if sock then pcall(function() sock:close() end) end
    sock = nil
    connected = false
    recvPartial = ""
end

local function sendLine(line)
    line = line .. "\n"
    local sent, err, lastByte = sock:send(line)
    if sent then return end
    if err == "timeout" and (lastByte or 0) == 0 then
        return
    end
    resetBridge()
end

----------------------------------------------------------------------------
-- Local state reading -- identical to meshghost_emerald.lua, see its header.
----------------------------------------------------------------------------

local lastMapGroup, lastMapNum = nil, nil

local function mapJustChanged(mapGroup, mapNum)
    local changed = lastMapGroup ~= nil and (mapGroup ~= lastMapGroup or mapNum ~= lastMapNum)
    lastMapGroup, lastMapNum = mapGroup, mapNum
    return changed
end

local function getLocalState()
    local base = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
    if base == 0 then return nil end

    local x = memory.read_s16_le(base + 0x00)
    local y = memory.read_s16_le(base + 0x02)
    local mapGroup = memory.read_s8(base + 0x04)
    local mapNum = memory.read_s8(base + 0x05)

    if mapJustChanged(mapGroup, mapNum) then return nil end

    local flags = memory.read_u8(GPLAYERAVATAR_ADDR + 0x00)
    local runningState = memory.read_u8(GPLAYERAVATAR_ADDR + 0x02)
    local objectEventId = memory.read_u8(GPLAYERAVATAR_ADDR + 0x05)
    local dashing = (flags & 0x80) ~= 0

    local objEventAddr = GOBJECTEVENTS_ADDR + (objectEventId * OBJECTEVENT_SIZE)
    local facingRaw = memory.read_u16_le(objEventAddr + 0x18) & 0xF
    local orientation = FACING[facingRaw] or "south"

    local anim
    if runningState == 2 and dashing then
        anim = "running"
    elseif runningState == 2 then
        anim = "walking"
    else
        anim = "idle"
    end

    return {
        areaId = mapGroup .. ":" .. mapNum,
        x = x,
        y = y,
        orientation = orientation,
        anim = anim,
    }
end

----------------------------------------------------------------------------
-- Remote set + trace. This is the one part that's NOT copied from
-- meshghost_emerald.lua -- that script draws remotes, this one only prints.
----------------------------------------------------------------------------

local remotes = {}

local function handleBridgeLine(line)
    local env = jsonDecode(line)
    if not env or type(env) ~= "table" then return end

    if env.type == "render_remote" then
        local payload = env.payload
        if type(payload) == "table" and type(payload.state) == "table" and payload.player_id then
            local st = payload.state
            local pos = st.position
            if type(pos) == "table" and pos[1] and pos[2] then
                remotes[payload.player_id] = {
                    areaId = st.area_id,
                    x = pos[1],
                    y = pos[2],
                }
            end
        end
    elseif env.type == "despawn_remote" then
        local payload = env.payload
        if type(payload) == "table" and payload.player_id then
            remotes[payload.player_id] = nil
        end
    end
end

local function drainBridge()
    while true do
        local line, err, partial = sock:receive("*l", recvPartial)
        if line then
            recvPartial = ""
            handleBridgeLine(line)
        elseif err == "timeout" then
            recvPartial = partial or ""
            return
        else
            recvPartial = ""
            resetBridge()
            remotes = {}
            return
        end
    end
end

local frameCounter = 0
local lastTraceFrame = -1000
local TRACE_INTERVAL_FRAMES = 120 -- ~2s

local function traceRemotes(localAreaId)
    if frameCounter - lastTraceFrame < TRACE_INTERVAL_FRAMES then return end
    lastTraceFrame = frameCounter
    local remoteCount = 0
    for _ in pairs(remotes) do remoteCount = remoteCount + 1 end
    console.log(string.format("MeshGhost probe TRACE: localArea=%s knownRemotes=%d", tostring(localAreaId), remoteCount))
    for id, remote in pairs(remotes) do
        console.log(string.format("MeshGhost probe TRACE:   remote %s area=%s pos=(%s,%s) match=%s",
            tostring(id), tostring(remote.areaId), tostring(remote.x), tostring(remote.y),
            tostring(remote.areaId == localAreaId)))
    end
end

----------------------------------------------------------------------------
-- Main loop -- same tick model as meshghost_emerald.lua, minus sprite drawing.
----------------------------------------------------------------------------

if not memory.usememorydomain("System Bus") then
    console.log("ERROR: 'System Bus' memory domain not found on this core.")
    console.log("Domains available: " .. memory.getmemorydomainlist())
    return
end

console.log("MeshGhost render_remote trace probe running.")
console.log("Connecting to bridge at " .. BRIDGE_HOST .. ":" .. BRIDGE_PORT .. " ...")

local function runFrame()
    frameCounter = frameCounter + 1

    if not connected then
        connectBridge()
        if connected then
            console.log("MeshGhost probe: connected to bridge.")
            sendLine(string.format('{"type":"hello","payload":{"game_id":%s,"game_version":%s}}', jsonString(GAME_ID), jsonString(ADAPTER_VERSION)))
            remotes = {}
        end
    end

    if connected then
        local state = getLocalState()
        local localAreaId
        if state then
            localAreaId = state.areaId
            sendLine(encodeLocalState(state.areaId, state.x, state.y, state.orientation, state.anim))
        else
            sendLine(ENCODED_NO_SEND)
        end

        if connected then
            drainBridge()
        end

        if connected and inOverworld() and localAreaId then
            traceRemotes(localAreaId)
        end
    end
end

local lastFrameErrorLogged = 0
while true do
    local ok, err = pcall(runFrame)
    if not ok and frameCounter - lastFrameErrorLogged > 300 then
        console.log("MeshGhost probe: frame error: " .. tostring(err))
        lastFrameErrorLogged = frameCounter
    end
    emu.frameadvance()
end
