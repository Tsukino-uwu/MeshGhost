-- Phase 5.5 snapshot, not maintained: the adapter as it stood when it split from meshghost_emerald.lua, which is the
-- shipped file and where any Emerald change belongs. The phase4_multiplayer.lua round trip with the real Brendan/May
-- sprite decoded from ROM and drawn with gui.drawPixel (gender, facing, walk and run poses), and the local gender
-- sent in extras.gender. Never writes memory.

local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
-- gSaveBlock2Ptr; playerGender is read once, as gender does not change mid-session.
local GSAVEBLOCK2PTR_ADDR = 0x03005d90
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
local GSPRITECOORDOFFSETX_ADDR = 0x02021bbc
local GSPRITECOORDOFFSETY_ADDR = 0x02021bbe

local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c

local function inOverworld()
    local callback2 = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    return callback2 == CB2_OVERWORLD_ADDR or callback2 == CB2_OVERWORLD_ADDR + 1
end

local TILE = 16

local BRIDGE_HOST = "127.0.0.1"
local BRIDGE_PORT = tonumber(os.getenv("MESHGHOST_BRIDGE_PORT") or "") or 7778

-- Sent in the bridge Hello, so the core can join the relay without a game set in config.json.
local GAME_ID = "emerald"

-- This script's own version, compared by equality only: it catches peers running different revisions.
local ADAPTER_VERSION = "phase5.5"

local FACING = { [1] = "south", [2] = "north", [3] = "west", [4] = "east" }

-- Both genders' sprite frames, decoded once at start: the ROM data never changes.

local GOBJECTEVENTPIC_BRENDANNORMAL_ADDR = 0x084975f8
local GOBJECTEVENTPAL_BRENDAN_ADDR = 0x084987f8
local GOBJECTEVENTPIC_MAYNORMAL_ADDR = 0x084a3078
local GOBJECTEVENTPAL_MAY_ADDR = 0x084a4278
-- Running is its own pic table with the walk table's palette.
local GOBJECTEVENTPIC_BRENDANRUNNING_ADDR = 0x08497ef8
local GOBJECTEVENTPIC_MAYRUNNING_ADDR = 0x084a3978
local FRAME_WIDTH_TILES = 2
local FRAME_HEIGHT_TILES = 4
local FRAME_WIDTH_PX = FRAME_WIDTH_TILES * 8
local FRAME_HEIGHT_PX = FRAME_HEIGHT_TILES * 8
local FRAMES_PER_PIC_TABLE = 9

-- Direction -> idle frame, 4-step sequence and hFlip; walking and running share it, east is west mirrored.
local DIRECTION_ANIM = {
    south = { idle = 0, steps = { 3, 0, 4, 0 }, hFlip = false },
    north = { idle = 1, steps = { 5, 1, 6, 1 }, hFlip = false },
    west  = { idle = 2, steps = { 7, 2, 8, 2 }, hFlip = false },
    east  = { idle = 2, steps = { 7, 2, 8, 2 }, hFlip = true },
}
-- Per-pose hold durations, indexed like DIRECTION_ANIM's steps.
local WALK_POSE_DURATIONS = { 8, 8, 8, 8 }
local RUN_POSE_DURATIONS = { 5, 3, 5, 3 }

local function expand5to8(v5) return (v5 << 3) | (v5 >> 2) end

local function decodePalette(addr)
    local pal = {}
    for i = 0, 15 do
        local c = memory.read_u16_le(addr + i * 2)
        local r5 = c & 0x1F
        local g5 = (c >> 5) & 0x1F
        local b5 = (c >> 10) & 0x1F
        pal[i] = { r = expand5to8(r5), g = expand5to8(g5), b = expand5to8(b5) }
    end
    return pal
end

-- One frame as a flat list of {x, y, color} (0xAARRGGBB), skipping palette index 0 (transparent).
local function decodeFramePixels(picAddr, frameIndex, palette)
    local frameAddr = picAddr + frameIndex * (FRAME_WIDTH_TILES * FRAME_HEIGHT_TILES * 32)
    local pixels = {}
    for py = 0, FRAME_HEIGHT_PX - 1 do
        local tileRow = py // 8
        local localY = py % 8
        for px = 0, FRAME_WIDTH_PX - 1 do
            local tileCol = px // 8
            local localX = px % 8
            local tileIndex = tileRow * FRAME_WIDTH_TILES + tileCol
            local tileByteOffset = tileIndex * 32 + localY * 4 + (localX // 2)
            local b = memory.read_u8(frameAddr + tileByteOffset)
            local index
            if localX % 2 == 0 then
                index = b & 0x0F
            else
                index = (b >> 4) & 0x0F
            end
            if index ~= 0 then
                local c = palette[index]
                local color = (0xFF << 24) | (c.r << 16) | (c.g << 8) | c.b
                pixels[#pixels + 1] = { x = px, y = py, color = color }
            end
        end
    end
    return pixels
end

-- genderFrames[gender][pose][i], pose "walk" (idle frames exist only there) or "run", all decoded at startup.
local genderFrames = { male = { walk = {}, run = {} }, female = { walk = {}, run = {} } }
local function loadGenderFrames()
    local malePalette = decodePalette(GOBJECTEVENTPAL_BRENDAN_ADDR)
    local femalePalette = decodePalette(GOBJECTEVENTPAL_MAY_ADDR)
    for i = 0, FRAMES_PER_PIC_TABLE - 1 do
        genderFrames.male.walk[i] = decodeFramePixels(GOBJECTEVENTPIC_BRENDANNORMAL_ADDR, i, malePalette)
        genderFrames.male.run[i] = decodeFramePixels(GOBJECTEVENTPIC_BRENDANRUNNING_ADDR, i, malePalette)
        genderFrames.female.walk[i] = decodeFramePixels(GOBJECTEVENTPIC_MAYNORMAL_ADDR, i, femalePalette)
        genderFrames.female.run[i] = decodeFramePixels(GOBJECTEVENTPIC_MAYRUNNING_ADDR, i, femalePalette)
    end
end

local function scriptDir()
    local pwd = io.popen and io.popen("cd"):read("*l")
    if not pwd or pwd == "" then
        error("MeshGhost Phase 5.5: could not determine the script's own directory (io.popen \"cd\" unavailable or returned nothing).")
    end
    return pwd .. "\\"
end

local SCRIPT_DIR = scriptDir()

-- lua54.dll is preloaded by full path before the socket DLL, as in phase4_multiplayer.lua.

local function preloadLua54()
    pcall(function()
        package.loadlib(SCRIPT_DIR .. "../lib/x64/lua54.dll", "meshghost_force_preload")
    end)
end

local function loadSocketCore()
    if package.config:sub(1, 1) ~= "\\" then
        error("MeshGhost Phase 5.5: only Windows is supported by the vendored LuaSocket binary so far.")
    end
    local luaMajor, luaMinor = _VERSION:match("Lua (%d+)%.(%d+)")
    if luaMajor ~= "5" or luaMinor ~= "4" then
        error("MeshGhost Phase 5.5: only Lua 5.4 is supported by the vendored LuaSocket binary so far (got " .. _VERSION .. ").")
    end
    local arch = os.getenv("PROCESSOR_ARCHITECTURE") or ""
    if not arch:find("64") then
        error("MeshGhost Phase 5.5: only x64 is supported by the vendored LuaSocket binary so far.")
    end
    preloadLua54()
    local dllPath = SCRIPT_DIR .. "../lib/x64/socket-windows-5-4.dll"
    return assert(package.loadlib(dllPath, "luaopen_socket_core"))()
end

local socketCore = loadSocketCore()

----------------------------------------------------------------------------
----------------------------------------------------------------------------

local JSON_STRING_ESCAPES = {
    ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}
local function jsonString(s)
    -- Control characters are escaped too: an unescaped \n would split one NDJSON line into two.
    s = s:gsub('[\\"%c]', function(c)
        return JSON_STRING_ESCAPES[c] or string.format("\\u%04x", c:byte())
    end)
    return '"' .. s .. '"'
end

-- gender rides in extras, which the core and relay treat as opaque.
local function encodeLocalState(areaId, x, y, orientation, anim, gender)
    return string.format(
        '{"type":"local_state","payload":{"state":{"area_id":%s,"position":[%s,%s],"orientation":%s,"anim":%s,"extras":{"gender":%s}}}}',
        jsonString(areaId), tostring(x), tostring(y), jsonString(orientation), jsonString(anim), jsonString(gender))
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

local sock = nil
local connected = false
local recvPartial = "" -- straddling-line remainder from the last drainBridge() timeout; belongs
                        -- to the current connection, so resetBridge() clears it too.

local function connectBridge()
    if not sock then
        sock = socketCore.tcp()
        sock:settimeout(0)
    end
    local ok, err = sock:connect(BRIDGE_HOST, BRIDGE_PORT)
    if ok == 1 or err == "already connected" then
        connected = true
    elseif err ~= "timeout" then
        -- "timeout" is a connect still in progress; anything else is a real failure, and a socket that failed a
        -- connect is not reliably reusable, so the next tick allocates a fresh one.
        pcall(function() sock:close() end)
        sock = nil
    end
end

local function resetBridge()
    if connected then
        console.log("MeshGhost Phase 5.5: bridge connection lost, will retry connecting.")
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
        -- Nothing went out: the next tick sends fresh state anyway.
        return
    end
    -- A partial send would leave a newline-less fragment that corrupts the NDJSON framing: reconnect cleanly.
    resetBridge()
end

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

-- "male"/"female", or nil before a save is loaded; called once, as gender does not change mid-session.
local function readLocalGender()
    local base = memory.read_u32_le(GSAVEBLOCK2PTR_ADDR)
    if base == 0 then return nil end
    local gender = memory.read_u8(base + 0x08)
    return (gender == 1) and "female" or "male"
end

-- Sub-tile smoothing: SaveBlock1's position is a whole tile that changes once per completed step, so the ghost
-- glides from the previous tile to the new one over that step's measured duration.

local STEP_DURATION_FRAMES = { walking = 16, running = 8 }

local frameCounter = 0
local prevTileX, prevTileY = nil, nil
local committedTileX, committedTileY = nil, nil
local committedAreaId = nil
local tileChangeFrame = 0
-- Locked in when the step commits, so a change of anim mid-glide cannot make the fraction jump.
local activeStepDuration = STEP_DURATION_FRAMES.walking

local function smoothPosition(rawX, rawY, areaId, anim)
    if committedTileX == nil or areaId ~= committedAreaId then
        -- First sample or a map transition: snap rather than glide.
        prevTileX, prevTileY = rawX, rawY
        committedTileX, committedTileY = rawX, rawY
        committedAreaId = areaId
        tileChangeFrame = frameCounter
        activeStepDuration = STEP_DURATION_FRAMES[anim] or STEP_DURATION_FRAMES.walking
    elseif rawX ~= committedTileX or rawY ~= committedTileY then
        prevTileX, prevTileY = committedTileX, committedTileY
        committedTileX, committedTileY = rawX, rawY
        tileChangeFrame = frameCounter
        activeStepDuration = STEP_DURATION_FRAMES[anim] or STEP_DURATION_FRAMES.walking
    end

    local fraction = (frameCounter - tileChangeFrame) / activeStepDuration
    if fraction > 1 then fraction = 1 end
    if fraction < 0 then fraction = 0 end

    return prevTileX + (committedTileX - prevTileX) * fraction,
           prevTileY + (committedTileY - prevTileY) * fraction
end

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

-- Remote ghosts, upserted by render_remote and removed by despawn_remote, redrawn every frame. An update merges
-- into its entry, so the walk-cycle frame survives a new position.

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
                local r = remotes[payload.player_id]
                if not r then
                    r = { animTimer = 0, animStepIndex = 0 }
                    remotes[payload.player_id] = r
                end
                r.areaId = st.area_id
                r.x = pos[1]
                r.y = pos[2]
                r.orientation = st.orientation
                r.anim = st.anim
                -- extras is opaque; a peer without gender draws as male.
                r.gender = (type(st.extras) == "table" and st.extras.gender) or "male"
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
        -- With settimeout(0) a line straddling the read boundary comes back as a partial; it is fed back as the
        -- next receive's prefix rather than dropped.
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

-- Steps a remote's walk/run cycle one frame and returns the frame to draw; a new direction or anim restarts it.
local function advanceAnim(remote, dirInfo)
    if remote.lastAnim ~= remote.anim or remote.lastOrientation ~= remote.orientation then
        remote.animTimer = 0
        remote.animStepIndex = 1
        remote.lastAnim = remote.anim
        remote.lastOrientation = remote.orientation
    end

    local durations = (remote.anim == "running") and RUN_POSE_DURATIONS or WALK_POSE_DURATIONS
    local framesPerStep = durations[remote.animStepIndex]
    remote.animTimer = remote.animTimer + 1
    if remote.animTimer >= framesPerStep then
        remote.animTimer = 0
        remote.animStepIndex = (remote.animStepIndex % #dirInfo.steps) + 1
    end
    return dirInfo.steps[remote.animStepIndex]
end

local function drawSpriteFrame(gender, pose, frameIndex, hFlip, screenX, screenY)
    local genderSet = genderFrames[gender] or genderFrames.male
    local pixels = (genderSet[pose] or genderSet.walk)[frameIndex]
    for i = 1, #pixels do
        local p = pixels[i]
        local px = hFlip and (FRAME_WIDTH_PX - 1 - p.x) or p.x
        gui.drawPixel(screenX + px, screenY + p.y, p.color)
    end
end

local function drawRemotes(localAreaId, playerMapX, playerMapY)
    local playerScreenX, playerScreenY = playerScreenPos()
    for _, remote in pairs(remotes) do
        if remote.areaId == localAreaId then
            local screenX = playerScreenX + (remote.x - playerMapX) * TILE
            local screenY = playerScreenY + (remote.y - playerMapY) * TILE

            local dirInfo = DIRECTION_ANIM[remote.orientation] or DIRECTION_ANIM.south
            local frameIndex, pose
            if remote.anim == "walking" or remote.anim == "running" then
                pose = (remote.anim == "running") and "run" or "walk"
                frameIndex = advanceAnim(remote, dirInfo)
            else
                remote.animTimer = 0
                remote.animStepIndex = 1
                remote.lastAnim = remote.anim
                remote.lastOrientation = remote.orientation
                pose = "walk" -- idle frames (0-2) only exist in the walk/Normal pic table
                frameIndex = dirInfo.idle
            end

            drawSpriteFrame(remote.gender, pose, frameIndex, dirInfo.hFlip, screenX, screenY)
        end
        -- A remote in another area is not drawn, which is not the same as despawning it.
    end
end

-- The adapter drives the tick: connect if needed, send local state, drain the core, redraw every remote.

if not memory.usememorydomain("System Bus") then
    console.log("ERROR: 'System Bus' memory domain not found on this core.")
    console.log("Domains available: " .. memory.getmemorydomainlist())
    return
end

console.log("MeshGhost Phase 5.5 sprite adapter running.")
console.log("Decoding Brendan/May sprite frames...")
loadGenderFrames()
console.log("Connecting to bridge at " .. BRIDGE_HOST .. ":" .. BRIDGE_PORT .. " ...")

local localGender = nil -- resolved lazily, first frame a save is loaded (see readLocalGender)

-- One frame of work, pcall-wrapped below so one bad remote or read skips a frame instead of ending the session.
local function runFrame()
    frameCounter = frameCounter + 1
    gui.clearGraphics()

    if not connected then
        connectBridge()
        if connected then
            console.log("MeshGhost Phase 5.5: connected to bridge.")
            -- The hello must be the first message on a fresh connection.
            sendLine(string.format('{"type":"hello","payload":{"game_id":%s,"game_version":%s}}', jsonString(GAME_ID), jsonString(ADAPTER_VERSION)))
            -- A fresh bridge connection is a fresh core, so every remote the old one reported is stale.
            remotes = {}
        end
    end

    if connected then
        local state = getLocalState()
        local smoothX, smoothY, smoothAreaId
        if state then
            if not localGender then
                localGender = readLocalGender()
                if localGender then
                    console.log("MeshGhost Phase 5.5: local gender = " .. localGender)
                end
            end
            smoothX, smoothY = smoothPosition(state.x, state.y, state.areaId, state.anim)
            smoothAreaId = state.areaId
            sendLine(encodeLocalState(state.areaId, smoothX, smoothY, state.orientation, state.anim, localGender or "male"))
        else
            sendLine(ENCODED_NO_SEND)
        end

        if connected then
            drainBridge()
        end

        -- Anchored on the smoothed position just sent, not a raw tile re-read, or a still remote wobbles while
        -- the player is mid-step; nothing is drawn on the frame the state is nil.
        if connected and inOverworld() and smoothX then
            drawRemotes(smoothAreaId, smoothX, smoothY)
        end
    end
end

local lastFrameErrorLogged = 0
while true do
    local ok, err = pcall(runFrame)
    if not ok then
        -- Rate-limited: a per-frame error would otherwise spam the console every 1/60s.
        if frameCounter - lastFrameErrorLogged > 300 then
            console.log("MeshGhost Phase 5.5: frame error (continuing): " .. tostring(err))
            lastFrameErrorLogged = frameCounter
        end
    end
    emu.frameadvance()
end
