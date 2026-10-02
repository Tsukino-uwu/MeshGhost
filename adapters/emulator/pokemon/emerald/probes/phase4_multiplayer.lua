-- MeshGhost — Emerald with two real players, a frozen snapshot (dev tool, read-only, vanilla only, never shipped).
-- Sends the player's state to this instance's own core over the bridge and draws each remote on the same map as a
-- placeholder image. MESHGHOST_BRIDGE_PORT is that core's -bridge port (7778 if unset), read from the environment
-- BizHawk started with, so set it before launching BizHawk.

local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
local GSPRITECOORDOFFSETX_ADDR = 0x02021bbc
local GSPRITECOORDOFFSETY_ADDR = 0x02021bbe

-- Remotes are drawn only on the overworld's callback: battle and full-screen menus leave it and make the player's
-- sprite a bad anchor; dialogue and the base pause menu do not. It reads with the Thumb bit set, so +1 counts too.
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c

local function inOverworld()
    local callback2 = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    return callback2 == CB2_OVERWORLD_ADDR or callback2 == CB2_OVERWORLD_ADDR + 1
end

local TILE = 16
local GHOST_IMAGE_SIZE = 16

local BRIDGE_HOST = "127.0.0.1"
-- 7778 is the core's own -bridge default, so a single instance needs no setup.
local BRIDGE_PORT = tonumber(os.getenv("MESHGHOST_BRIDGE_PORT") or "") or 7778

local FACING = { [1] = "south", [2] = "north", [3] = "west", [4] = "east" }

----------------------------------------------------------------------------
-- The script's folder, from the working directory BizHawk sets to it: debug.getinfo can name the chunk "main".
----------------------------------------------------------------------------

local function scriptDir()
    local pwd = io.popen and io.popen("cd"):read("*l")
    if not pwd or pwd == "" then
        error("MeshGhost Phase 4: could not determine the script's own directory (io.popen \"cd\" unavailable or returned nothing).")
    end
    return pwd .. "\\"
end

local SCRIPT_DIR = scriptDir()
local GHOST_IMAGE_PATH = SCRIPT_DIR .. "assets/ghost_placeholder.bmp"

----------------------------------------------------------------------------
-- LuaSocket's compiled core, loaded directly: Windows, x64 and Lua 5.4 only.
----------------------------------------------------------------------------

-- The socket DLL imports lua54.dll by name, which Windows will not find beside it but reuses once it is loaded.
local function preloadLua54()
    -- The symbol does not exist: loadlib keeps the library loaded anyway, and only that load is wanted.
    pcall(function()
        package.loadlib(SCRIPT_DIR .. "../lib/x64/lua54.dll", "meshghost_force_preload")
    end)
end

local function loadSocketCore()
    if package.config:sub(1, 1) ~= "\\" then
        error("MeshGhost Phase 4: only Windows is supported by the vendored LuaSocket binary so far.")
    end
    local luaMajor, luaMinor = _VERSION:match("Lua (%d+)%.(%d+)")
    if luaMajor ~= "5" or luaMinor ~= "4" then
        error("MeshGhost Phase 4: only Lua 5.4 is supported by the vendored LuaSocket binary so far (got " .. _VERSION .. ").")
    end
    local arch = os.getenv("PROCESSOR_ARCHITECTURE") or ""
    if not arch:find("64") then
        error("MeshGhost Phase 4: only x64 is supported by the vendored LuaSocket binary so far.")
    end
    preloadLua54()
    local dllPath = SCRIPT_DIR .. "../lib/x64/socket-windows-5-4.dll"
    return assert(package.loadlib(dllPath, "luaopen_socket_core"))()
end

local socketCore = loadSocketCore()

----------------------------------------------------------------------------
-- Minimal JSON for the bridge's own shapes: the decoder reads only our core's
-- canonical output, never network input.
----------------------------------------------------------------------------

local function jsonString(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
    return '"' .. s .. '"'
end

-- player_id, seq and timestamp are left out: the core stamps them on every forward.
local function encodeLocalState(areaId, x, y, orientation, anim)
    return string.format(
        '{"type":"local_state","payload":{"state":{"area_id":%s,"position":[%s,%s],"orientation":%s,"anim":%s}}}',
        jsonString(areaId), tostring(x), tostring(y), jsonString(orientation), jsonString(anim))
end

local ENCODED_NO_SEND = '{"type":"local_state","payload":{"state":null}}'

local decodeValue

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

local function jsonDecode(line)
    local ok, val = pcall(function()
        local v = decodeValue(line, 1)
        return v
    end)
    if not ok then return nil end
    return val
end

----------------------------------------------------------------------------
-- Bridge: non-blocking TCP to the local core, NDJSON. receive() holds a
-- partial line itself and returns "timeout" until the line is whole.
----------------------------------------------------------------------------

local sock = nil
local connected = false

-- Called every frame until connected: a pending connect() returns "timeout", a finished one "already connected".
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
        console.log("MeshGhost Phase 4: bridge connection lost, will retry connecting.")
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

----------------------------------------------------------------------------
-- Local state.
----------------------------------------------------------------------------

local lastMapGroup, lastMapNum = nil, nil

-- The frame a map change is first seen reads untrusted: gSaveBlock1Ptr relocates during the transition.
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

-- The player's sprite on screen: the anchor every remote is placed from.
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

----------------------------------------------------------------------------
-- Remotes: upserted by render_remote, removed by despawn_remote, and redrawn
-- from this table every frame, never once per receipt.
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
    -- Unknown types are ignored, for forward compatibility.
end

local function drainBridge()
    while true do
        local line, err = sock:receive()
        if line then
            handleBridgeLine(line)
        elseif err == "timeout" then
            return
        else
            -- Anything but "timeout" is fatal, not only "closed": a killed core reports something else.
            resetBridge()
            remotes = {} -- no stale ghost left on screen
            return
        end
    end
end

----------------------------------------------------------------------------
-- Drawing: each remote at the player's screen position plus the tile delta.
----------------------------------------------------------------------------

-- The anchor is the sprite's top-left, a tile above the feet on a 16x32 overworld sprite.
local GHOST_Y_CORRECTION = TILE

local function drawRemotes(localAreaId, playerMapX, playerMapY)
    local playerScreenX, playerScreenY = playerScreenPos()
    for _, remote in pairs(remotes) do
        if remote.areaId == localAreaId then
            local screenX = playerScreenX + (remote.x - playerMapX) * TILE
            local screenY = playerScreenY + (remote.y - playerMapY) * TILE + GHOST_Y_CORRECTION
            gui.drawImage(GHOST_IMAGE_PATH, screenX, screenY, GHOST_IMAGE_SIZE, GHOST_IMAGE_SIZE)
        end
        -- A remote in another area stays in the set, undrawn: area_id is compared by equality only.
    end
end

----------------------------------------------------------------------------
-- Main loop, once per frame: connect if needed, send, drain, redraw.
----------------------------------------------------------------------------

if not memory.usememorydomain("System Bus") then
    console.log("ERROR: 'System Bus' memory domain not found on this core.")
    console.log("Domains available: " .. memory.getmemorydomainlist())
    return
end

console.log("MeshGhost Phase 4 multiplayer adapter running.")
console.log("Connecting to bridge at " .. BRIDGE_HOST .. ":" .. BRIDGE_PORT .. " ...")

while true do
    -- BizHawk's overlay never clears itself, so it is cleared every frame, connected or not.
    gui.clearGraphics()

    if not connected then
        connectBridge()
        if connected then
            console.log("MeshGhost Phase 4: connected to bridge.")
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

        if connected and inOverworld() then
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
