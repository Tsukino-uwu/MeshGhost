-- Phase 3: loopback. The local player's state goes through the core and a -loopback relay, which echoes it as
-- "<id>-ghost", and comes back drawn as a trailing ghost. Its one socket is to the local core, never a relay.

local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
local GSPRITECOORDOFFSETX_ADDR = 0x02021bbc
local GSPRITECOORDOFFSETY_ADDR = 0x02021bbe

-- A remote is drawn at the local player's screen position plus the tile delta between them times TILE.
local TILE = 16
local GHOST_IMAGE_SIZE = 16

local BRIDGE_HOST = "127.0.0.1"
local BRIDGE_PORT = 7778

local FACING = { [1] = "south", [2] = "north", [3] = "west", [4] = "east" }

-- A script opened in the Lua Console is a chunk named "main", so debug.getinfo has no path; BizHawk does set the
-- process's working directory to the script's own, so ask the OS for it.

local function scriptDir()
    local pwd = io.popen and io.popen("cd"):read("*l")
    if not pwd or pwd == "" then
        error("MeshGhost Phase 3: could not determine the script's own directory (io.popen \"cd\" unavailable or returned nothing).")
    end
    return pwd .. "\\"
end

local SCRIPT_DIR = scriptDir()
local GHOST_IMAGE_PATH = SCRIPT_DIR .. "assets/ghost_placeholder.bmp"

-- LuaSocket's compiled core, loaded directly: Windows, x64 and Lua 5.4 only, failing loudly otherwise.

-- The socket DLL imports lua54.dll by name, and Windows does not search the DLL's own folder for it; loading the
-- vendored copy (byte-identical to BizHawk's) by full path first makes the loader reuse it.
local function preloadLua54()
    -- The symbol lookup fails on purpose: Lua keeps the library loaded anyway, and only that is wanted.
    pcall(function()
        package.loadlib(SCRIPT_DIR .. "../lib/x64/lua54.dll", "meshghost_force_preload")
    end)
end

local function loadSocketCore()
    if package.config:sub(1, 1) ~= "\\" then
        error("MeshGhost Phase 3: only Windows is supported by the vendored LuaSocket binary so far.")
    end
    local luaMajor, luaMinor = _VERSION:match("Lua (%d+)%.(%d+)")
    if luaMajor ~= "5" or luaMinor ~= "4" then
        error("MeshGhost Phase 3: only Lua 5.4 is supported by the vendored LuaSocket binary so far (got " .. _VERSION .. ").")
    end
    local arch = os.getenv("PROCESSOR_ARCHITECTURE") or ""
    if not arch:find("64") then
        error("MeshGhost Phase 3: only x64 is supported by the vendored LuaSocket binary so far.")
    end
    preloadLua54()
    local dllPath = SCRIPT_DIR .. "../lib/x64/socket-windows-5-4.dll"
    return assert(package.loadlib(dllPath, "luaopen_socket_core"))()
end

local socketCore = loadSocketCore()

-- Minimal JSON, our own: the encoder makes only the bridge's shapes, the decoder reads only our core's canonical lines.

local function jsonString(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
    return '"' .. s .. '"'
end

-- The bridge's local_state envelope; the core stamps player_id, seq and timestamp itself.
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
                table.insert(out, e) -- covers \" \\ \/ and anything unexpected verbatim
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

-- nil on any parse failure: a malformed line is dropped, as unknown fields and types are.
local function jsonDecode(line)
    local ok, val = pcall(function()
        local v = decodeValue(line, 1)
        return v
    end)
    if not ok then return nil end
    return val
end

-- Non-blocking TCP to the local core, NDJSON. LuaSocket keeps a partial line across receive() calls, answering
-- "timeout" until a whole one has arrived.

local sock = nil
local connected = false

-- A non-blocking connect answers "timeout" while in progress and "already connected" once it has completed.
local function connectBridge()
    if not sock then
        sock = socketCore.tcp()
        sock:settimeout(0)
    end
    local ok, err = sock:connect(BRIDGE_HOST, BRIDGE_PORT)
    if ok == 1 or err == "already connected" then
        connected = true
    end
end

local function resetBridge()
    if connected then
        console.log("MeshGhost Phase 3: bridge connection lost, will retry connecting.")
    end
    if sock then pcall(function() sock:close() end) end
    sock = nil
    connected = false
end

local function sendLine(line)
    local ok, err = sock:send(line .. "\n")
    if not ok and err ~= "timeout" then
        resetBridge()
    end
end

-- Local state, at phase1_probe.lua's addresses.

local lastMapGroup, lastMapNum = nil, nil

-- The read on the frame a map change is first seen is untrusted: gSaveBlock1Ptr may be mid-move.
local function mapJustChanged(mapGroup, mapNum)
    local changed = lastMapGroup ~= nil and (mapGroup ~= lastMapGroup or mapNum ~= lastMapNum)
    lastMapGroup, lastMapNum = mapGroup, mapNum
    return changed
end

-- nil means do not send this frame: no save loaded, or the map-change frame.
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
        anim = "idle" -- covers runningState 0 (idle) and 1 (turning, no position change)
    end

    return {
        areaId = mapGroup .. ":" .. mapNum,
        x = x,
        y = y,
        orientation = orientation,
        anim = anim,
    }
end

-- The player's own screen position, by phase2_ghost.lua's formula: the anchor a remote's is computed from.
local function playerScreenPos()
    local spriteId = memory.read_u8(GPLAYERAVATAR_ADDR + 0x04)
    local spriteAddr = GSPRITES_ADDR + (spriteId * SPRITE_SIZE)

    local sx = memory.read_s16_le(spriteAddr + 0x20)
    local sy = memory.read_s16_le(spriteAddr + 0x22)
    local sx2 = memory.read_s16_le(spriteAddr + 0x24)
    local sy2 = memory.read_s16_le(spriteAddr + 0x26)
    local cx = memory.read_s8(spriteAddr + 0x28)
    local cy = memory.read_s8(spriteAddr + 0x29)

    local coordOffsetX = memory.read_s16_le(GSPRITECOORDOFFSETX_ADDR)
    local coordOffsetY = memory.read_s16_le(GSPRITECOORDOFFSETY_ADDR)

    return sx + sx2 + cx + coordOffsetX, sy + sy2 + cy + coordOffsetY
end

-- Remote ghosts: the core upserts with render_remote and removes with despawn_remote; all are redrawn every frame.

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
                    orientation = st.orientation,
                    anim = st.anim,
                }
            end
        end
    elseif env.type == "despawn_remote" then
        local payload = env.payload
        if type(payload) == "table" and payload.player_id then
            remotes[payload.player_id] = nil
        end
    end
    -- Unknown types are ignored.
end

local function drainBridge()
    while true do
        local line, err = sock:receive()
        if line then
            handleBridgeLine(line)
        elseif err == "timeout" then
            return -- nothing more buffered right now
        else
            -- Anything but "timeout" means the link is gone: a killed core need not report "closed".
            resetBridge()
            remotes = {} -- don't leave a stale ghost frozen on screen forever
            return
        end
    end
end


local function drawRemotes(localAreaId, playerMapX, playerMapY)
    local playerScreenX, playerScreenY = playerScreenPos()
    for _, remote in pairs(remotes) do
        if remote.areaId == localAreaId then
            local screenX = playerScreenX + (remote.x - playerMapX) * TILE
            local screenY = playerScreenY + (remote.y - playerMapY) * TILE
            gui.drawImage(GHOST_IMAGE_PATH, screenX, screenY, GHOST_IMAGE_SIZE, GHOST_IMAGE_SIZE)
        end
        -- A remote in another area is not drawn (area_id compares by equality only), which is not a despawn.
    end
end

-- Once per frame: connect if needed, send local state, apply what the core pushed, redraw every remote.

if not memory.usememorydomain("System Bus") then
    console.log("ERROR: 'System Bus' memory domain not found on this core.")
    console.log("Domains available: " .. memory.getmemorydomainlist())
    return
end

console.log("MeshGhost Phase 3 loopback adapter running.")
console.log("Connecting to bridge at " .. BRIDGE_HOST .. ":" .. BRIDGE_PORT .. " ...")

while true do
    -- Lua-drawn images persist between frames, so clear unconditionally, or a ghost no longer drawn freezes in place.
    gui.clearGraphics()

    if not connected then
        connectBridge()
        if connected then
            console.log("MeshGhost Phase 3: connected to bridge.")
        end
    end

    if connected then
        local state = getLocalState()
        if state then
            sendLine(encodeLocalState(state.areaId, state.x, state.y, state.orientation, state.anim))
        else
            sendLine(ENCODED_NO_SEND)
        end

        if connected then -- sendLine may have reset the connection on error
            drainBridge()
        end

        if connected then
            local base = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
            if base ~= 0 then
                local playerMapX = memory.read_s16_le(base + 0x00)
                local playerMapY = memory.read_s16_le(base + 0x02)
                local mapGroup = memory.read_s8(base + 0x04)
                local mapNum = memory.read_s8(base + 0x05)
                drawRemotes(mapGroup .. ":" .. mapNum, playerMapX, playerMapY)
            end
        end
    end

    emu.frameadvance()
end
