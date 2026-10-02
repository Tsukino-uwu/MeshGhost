-- MeshGhost: the Pokémon Emerald adapter.
--
-- Writes game RAM, object RAM only (gObjectEvents, gSprites, the sprite-tile allocation bitmap, and the shadow-OAM
-- window above gOamLimit that the hardware tier uses), never a save; cosmetic only, behind the ROM guard below.
-- A pokeemerald symbol named in a comment says where the decompilation puts a mechanism: a pointer, never evidence.

local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GSAVEBLOCK2PTR_ADDR = 0x03005d90
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
-- Beside gSprites in EWRAM, so a build that moves gSprites moves these too: read them with spriteAddrOffset added.
local GSPRITECOORDOFFSETX_ADDR = 0x02021bbc
local GSPRITECOORDOFFSETY_ADDR = 0x02021bbe

-- Archipelago's recompile moves gObjectEvents and gPlayerAvatar by this much; detected at startup, never assumed.
local AVATAR_ADDR_ARCHIPELAGO_SHIFT = 0x284
-- Other builds' shifts are literals at their use sites: the main chunk is at Lua's 200-local ceiling.

local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c

local CB2_OVERWORLD_ARCHIPELAGO_ADDR = 0x080867f1

local function inOverworld()
    local callback2 = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    -- When gMain has moved (EX SPEEDCHOICE), callback2 is not a ROM address and this test cannot be asked; fall
    -- back to whether the player's object event exists, which cannot tell a paused field state from a running one.
    -- A global: the locals it needs are declared below this function, so naming them here would read nil.
    if callback2 < 0x08000000 or callback2 >= 0x0A000000 then
        return MG_FIELD_FALLBACK ~= nil and MG_FIELD_FALLBACK()
    end
    return callback2 == CB2_OVERWORLD_ADDR or callback2 == CB2_OVERWORLD_ADDR + 1
        or callback2 == CB2_OVERWORLD_ARCHIPELAGO_ADDR or callback2 == CB2_OVERWORLD_ARCHIPELAGO_ADDR + 1
        or callback2 == 0x080864d4 or callback2 == 0x080864d5 -- SPEEDCHOICE 1.2.2
end

local TILE = 16 -- pixels

local BRIDGE_HOST = "127.0.0.1"
-- A core serves one adapter, so walk the ports from the base and take the first core that answers bridge_ready.
local BRIDGE_BASE_PORT = 7778
local BRIDGE_PORT_COUNT = 8
-- An explicit port is used as is, never walked. The global comes first: a loader can set it on a running emulator,
-- while the environment is fixed when BizHawk launches.
local BRIDGE_PORT_OVERRIDE = tonumber(MESHGHOST_BRIDGE_PORT
    or os.getenv("MESHGHOST_BRIDGE_PORT") or "")
-- Silence is not acceptance: 1.5s to answer.
local HELLO_ANSWER_FRAMES = 90
local BUSY_PORT_COOLDOWN_FRAMES = 600 -- 10s

-- Sent in the bridge hello, so the core needs no "game" in config.json; matches the release folder's name.
local GAME_ID = "emerald"

-- This script's version, not the ROM's (no address for one is known); compared by equality only.
local ADAPTER_VERSION = "phase8-spawn"

local FACING = { [1] = "south", [2] = "north", [3] = "west", [4] = "east" }

----------------------------------------------------------------------------
-- Sprite decode, both genders: decoded once at start, since the ROM data never changes.
----------------------------------------------------------------------------

local GOBJECTEVENTPIC_BRENDANNORMAL_ADDR = 0x084975f8
local GOBJECTEVENTPAL_BRENDAN_ADDR = 0x084987f8
local GOBJECTEVENTPIC_MAYNORMAL_ADDR = 0x084a3078
local GOBJECTEVENTPAL_MAY_ADDR = 0x084a4278
-- Running is its own pic table, not a faster walk, drawn with the same palette as each gender's Normal table.
local GOBJECTEVENTPIC_BRENDANRUNNING_ADDR = 0x08497ef8
local GOBJECTEVENTPIC_MAYRUNNING_ADDR = 0x084a3978

-- Archipelago's recompile moves this whole sprite and palette block; detected at startup, never assumed.
local SPRITE_ADDR_ARCHIPELAGO_SHIFT = 0x7530

local FRAME_WIDTH_TILES = 2
local FRAME_HEIGHT_TILES = 4
local FRAME_WIDTH_PX = FRAME_WIDTH_TILES * 8
local FRAME_HEIGHT_PX = FRAME_HEIGHT_TILES * 8
local FRAMES_PER_PIC_TABLE = 9

-- Direction -> idle frame, 4-step cycle, flip (east is west mirrored); running uses the same indices in its table.
local DIRECTION_ANIM = {
    south = { idle = 0, steps = { 3, 0, 4, 0 }, hFlip = false },
    north = { idle = 1, steps = { 5, 1, 6, 1 }, hFlip = false },
    west  = { idle = 2, steps = { 7, 2, 8, 2 }, hFlip = false },
    east  = { idle = 2, steps = { 7, 2, 8, 2 }, hFlip = true },
}
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

-- One frame as {x, y, color}, color 0xAARRGGBB for gui.drawPixel, skipping palette index 0 (transparent).
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

-- genderFrames[gender][pose][i]: decoded pixels per frame; idle frames exist only in the walk table. It also holds
-- file-wide state, since the main chunk is at Lua's 200-local ceiling.
local genderFrames = { male = { walk = {}, run = {} }, female = { walk = {}, run = {} } }

-- Which layout this ROM has, by Brendan's palette's first four bytes at each known shift; vanilla if none matches.
local BRENDAN_PAL_REF_BYTES = { 0x0e, 0x53, 0x5f, 0x5b }
local function bytesMatchAt(addr, refBytes)
    for i, expected in ipairs(refBytes) do
        if memory.read_u8(addr + i - 1) ~= expected then
            return false
        end
    end
    return true
end

local function detectSpriteAddrOffset()
    if bytesMatchAt(GOBJECTEVENTPAL_BRENDAN_ADDR, BRENDAN_PAL_REF_BYTES) then
        console.log("MeshGhost: sprite data found at the vanilla ROM address.")
        return 0
    end
    if bytesMatchAt(GOBJECTEVENTPAL_BRENDAN_ADDR + SPRITE_ADDR_ARCHIPELAGO_SHIFT, BRENDAN_PAL_REF_BYTES) then
        console.log("MeshGhost: sprite data found at the known Archipelago-shifted ROM address.")
        return SPRITE_ADDR_ARCHIPELAGO_SHIFT
    end
    if bytesMatchAt(GOBJECTEVENTPAL_BRENDAN_ADDR + 0x6408, BRENDAN_PAL_REF_BYTES) then -- SPEEDCHOICE
        console.log("MeshGhost: sprite data found at the known SPEEDCHOICE-shifted ROM address.")
        return 0x6408
    end
    -- EX SPEEDCHOICE moves its sprite data and its graphics-info table by different amounts, so it needs two offsets.
    if bytesMatchAt(GOBJECTEVENTPAL_BRENDAN_ADDR + 0x9CB78, BRENDAN_PAL_REF_BYTES) then
        console.log("MeshGhost: sprite data found at the known EX SPEEDCHOICE-shifted ROM address.")
        genderFrames.tableOffset = 0x1E6DBC
        return 0x9CB78
    end
    console.log("MeshGhost: WARNING -- Brendan/May sprite data not found at the vanilla address "
        .. "or the known Archipelago-shifted address. Falling back to vanilla addresses, but "
        .. "the decoded sprite is likely wrong on this ROM.")
    return 0
end

-- True if one of the 16 object events at this base is the player's: isPlayer set, localId 0xFF, and a plausible
-- mapGroup, since abandoned memory reading FF 03 FF 03 passes the first two at every entry.
local MAP_GROUPS_COUNT = 34
local function playerObjEventExistsAt(gObjectEventsBase)
    for i = 0, 15 do
        local addr = gObjectEventsBase + i * OBJECTEVENT_SIZE
        local isPlayerBit = memory.read_u8(addr + 0x02) & 0x1
        local localId = memory.read_u8(addr + 0x08)
        local mapGroup = memory.read_u8(addr + 0x0a)
        if isPlayerBit == 1 and localId == 0xff and mapGroup < MAP_GROUPS_COUNT then
            return true
        end
    end
    return false
end

-- Resolved lazily: retried every frame until the player's object event exists, which it does not during the intro.
local avatarAddrOffset = 0

local avatarAddrConfirmed = false

-- inOverworld()'s fallback when gMain has moved; assigned here, where the locals it needs exist.
MG_FIELD_FALLBACK = function()
    return avatarAddrConfirmed and playerObjEventExistsAt(GOBJECTEVENTS_ADDR + avatarAddrOffset)
end

local function tryDetectAvatarAddrOffset()
    if playerObjEventExistsAt(GOBJECTEVENTS_ADDR) then
        console.log("MeshGhost: gObjectEvents/gPlayerAvatar found at the vanilla ROM address.")
        avatarAddrOffset = 0
        avatarAddrConfirmed = true
        return
    end
    if playerObjEventExistsAt(GOBJECTEVENTS_ADDR + AVATAR_ADDR_ARCHIPELAGO_SHIFT) then
        console.log("MeshGhost: gObjectEvents/gPlayerAvatar found at the known Archipelago-shifted address.")
        avatarAddrOffset = AVATAR_ADDR_ARCHIPELAGO_SHIFT
        avatarAddrConfirmed = true
        return
    end
    if playerObjEventExistsAt(GOBJECTEVENTS_ADDR + 0xA4) then -- SPEEDCHOICE 1.2.2
        console.log("MeshGhost: gObjectEvents/gPlayerAvatar found at the known SPEEDCHOICE-shifted address.")
        avatarAddrOffset = 0xA4
        genderFrames.spriteAddrOffset = 0x4 -- gSprites
        avatarAddrConfirmed = true
        return
    end
    -- EX SPEEDCHOICE 0.4.0, whose IWRAM moved too (iwramOffset).
    if playerObjEventExistsAt(GOBJECTEVENTS_ADDR + 0xC80) then
        console.log("MeshGhost: gObjectEvents/gPlayerAvatar found at the known EX SPEEDCHOICE-shifted address.")
        avatarAddrOffset = 0xC80
        genderFrames.spriteAddrOffset = 0x20
        genderFrames.iwramOffset = -0x10E0 -- gSaveBlock1Ptr/2Ptr, see session.saveBlockPtr
        genderFrames.camOffset = -0x10D0 -- the camera block, sixteen bytes off the save block's
        avatarAddrConfirmed = true
        return
    end
    -- Not found yet (intro, title screen): retried next frame rather than latching a guess.
end

local function loadGenderFrames()
    local offset = detectSpriteAddrOffset()
    -- Cached: the same shift moves the graphics-info pointer table that graphicsInfo() reads.
    genderFrames.romOffset = offset
    local malePalette = decodePalette(GOBJECTEVENTPAL_BRENDAN_ADDR + offset)
    local femalePalette = decodePalette(GOBJECTEVENTPAL_MAY_ADDR + offset)
    for i = 0, FRAMES_PER_PIC_TABLE - 1 do
        genderFrames.male.walk[i] = decodeFramePixels(GOBJECTEVENTPIC_BRENDANNORMAL_ADDR + offset, i, malePalette)
        genderFrames.male.run[i] = decodeFramePixels(GOBJECTEVENTPIC_BRENDANRUNNING_ADDR + offset, i, malePalette)
        genderFrames.female.walk[i] = decodeFramePixels(GOBJECTEVENTPIC_MAYNORMAL_ADDR + offset, i, femalePalette)
        genderFrames.female.run[i] = decodeFramePixels(GOBJECTEVENTPIC_MAYRUNNING_ADDR + offset, i, femalePalette)
    end
end

-- Where this file is, from debug.getinfo; the working directory is the script's folder only when opened by hand.
local function scriptDir()
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        local dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$")
        if dir and dir ~= "" then
            return dir .. "/"
        end
    end
    -- Loaded with --lua=, BizHawk reports source as [string "main"], so a launcher can pass the folder instead.
    -- The game-specific name first: all scripts share one process, so a plain one would reach the next adapter.
    local fromEnv = MESHGHOST_SCRIPT_DIR
        or os.getenv("MESHGHOST_SCRIPT_DIR_EMERALD")
        or os.getenv("MESHGHOST_SCRIPT_DIR")
    if fromEnv and fromEnv ~= "" then
        return (fromEnv:gsub("[/\\]$", "")) .. "/"
    end

    -- Last resort: the working directory, via a cmd whose window flashes; right only when the two agree.
    local pwd = io.popen and io.popen("cd"):read("*l")
    if not pwd or pwd == "" then
        error("MeshGhost: could not determine the script's own directory. Load this file from "
            .. "BizHawk's Lua Console, or set MESHGHOST_SCRIPT_DIR to the folder holding it.")
    end
    return pwd .. "\\"
end

local SCRIPT_DIR = scriptDir()

----------------------------------------------------------------------------
-- LuaSocket, with lua54.dll preloaded by full path: the socket DLL imports it by name, and Windows won't find it.
----------------------------------------------------------------------------

-- LoadLibrary does not accept forward slashes, so DLL paths get backslashes.
local function dllPath(rel)
    return (SCRIPT_DIR .. rel):gsub("/", "\\")
end

local function preloadLua54()
    pcall(function()
        package.loadlib(dllPath("lib/x64/lua54.dll"), "meshghost_force_preload")
    end)
end

local function loadSocketCore()
    if package.config:sub(1, 1) ~= "\\" then
        error("MeshGhost: only Windows is supported by the vendored LuaSocket binary so far.")
    end
    local luaMajor, luaMinor = _VERSION:match("Lua (%d+)%.(%d+)")
    if luaMajor ~= "5" or luaMinor ~= "4" then
        error("MeshGhost: only Lua 5.4 is supported by the vendored LuaSocket binary so far (got " .. _VERSION .. ").")
    end
    local arch = os.getenv("PROCESSOR_ARCHITECTURE") or ""
    if not arch:find("64") then
        error("MeshGhost: only x64 is supported by the vendored LuaSocket binary so far.")
    end
    preloadLua54()
    local socketDll = dllPath("lib/x64/socket-windows-5-4.dll")
    local loader, loadErr = package.loadlib(socketDll, "luaopen_socket_core")
    if not loader then
        error(string.format("MeshGhost: could not load %s (%s)", socketDll, tostring(loadErr)))
    end
    return loader()
end

-- A log file beside the script, in logs/ when that folder exists (creating it would need a shell). The name carries
-- the emulator's pid: two instances reloading in the same second would otherwise share one file.
local logfile
do
    local okPid, pid = pcall(function()
        luanet.load_assembly("System")
        return luanet.import_type("System.Diagnostics.Process").GetCurrentProcess().Id
    end)
    -- No luanet: fall back to a pinned port, then the clock; any discriminator beats two writers in one file.
    local tag = (okPid and pid) or BRIDGE_PORT_OVERRIDE
        or math.floor((os.clock() % 1) * 100000)
    local name = string.format("meshghost_emerald_%s_%s.log", os.date("%Y%m%d_%H%M%S"), tostring(tag))
    logfile = io.open(SCRIPT_DIR .. "logs/" .. name, "w") or io.open(SCRIPT_DIR .. name, "w")
    -- Buffered: a flush is a synchronous disk write on the emulator's thread, so it is flushed on a timer instead.
    if logfile then
        pcall(function() logfile:setvbuf("full", 16384) end)
    end
    genderFrames.xmapCachePath = SCRIPT_DIR .. "logs/xmap_cache.txt"
end

local rawConsoleLog = console.log
console.log = function(msg)
    rawConsoleLog(msg)
    if logfile then
        logfile:write(tostring(msg), "\n")
    end
end

-- Where the bridge port range starts, from local_game_bridge in the player's config.json, read by hand: one key of a
-- fixed shape. In a do block, so its locals cost none of the main chunk's 200. MESHGHOST_BRIDGE_PORT still wins.
do
    -- The same config files, in the same order, that the autostart switch reads.
    local candidates = {
        SCRIPT_DIR .. "config.json",
        SCRIPT_DIR .. "../../../config.json",
        SCRIPT_DIR .. "../../../../config.json",
    }
    for _, path in ipairs(candidates) do
        local f = io.open(path, "r")
        if f then
            local text = f:read("*a")
            f:close()
            local port = tonumber(string.match(text or "",
                '"local_game_bridge"%s*:%s*"[^"]*:(%d+)"'))
            if port and port >= 1 and port <= 65535 and port ~= BRIDGE_BASE_PORT then
                console.log(string.format(
                    "MeshGhost: bridge ports %d-%d, from local_game_bridge in config.json",
                    port, port + BRIDGE_PORT_COUNT - 1))
                BRIDGE_BASE_PORT = port
            end
            -- The first readable config wins, key or not: a later one belongs to a different install.
            break
        end
    end
end

-- File only, unflushed: per-tick lines in the console would scroll the startup lines (the ROM, the addresses) away.
local flushCountdown = 0
local function logFile(msg)
    if logfile then
        logfile:write(msg, "\n")
    end
end

-- One flush every five seconds: a single frame's hitch that often, not one per write. Called once per frame.
local function flushLogPeriodically()
    if not logfile then
        return
    end
    flushCountdown = flushCountdown + 1
    if flushCountdown >= 300 then
        flushCountdown = 0
        pcall(function() logfile:flush() end)
    end
end

local socketCore = loadSocketCore()

----------------------------------------------------------------------------
-- Minimal JSON.
----------------------------------------------------------------------------

local JSON_STRING_ESCAPES = {
    ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}
local function jsonString(s)
    -- Control characters too: a raw newline would split one NDJSON line into two.
    s = s:gsub('[\\"%c]', function(c)
        return JSON_STRING_ESCAPES[c] or string.format("\\u%04x", c:byte())
    end)
    return '"' .. s .. '"'
end

-- The player's graphics id names its state (bike, surf, rod...), sent in extras with the sprite's offset. A new
-- graphic is held until its offset settles: the rod's pos2 lands four frames after the graphic, and only the sender
-- sees every frame.
local function localGraphicsId()
    if not avatarAddrConfirmed then return nil end
    local objId = memory.read_u8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05)
    if objId > 15 then return nil end
    local gfx = memory.read_u8(GOBJECTEVENTS_ADDR + avatarAddrOffset + objId * OBJECTEVENT_SIZE
        + 0x05)
    -- Inlined: sprAddr and rs16 are defined further down, and a forward reference would read a nil global.
    local sox = memory.read_s16_le(GSPRITES_ADDR + (genderFrames.spriteAddrOffset or 0)
        + memory.read_u8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04) * SPRITE_SIZE + 0x24)
    if gfx ~= genderFrames.sentGfx then
        -- Held six calls (one a frame) to clear the measured four-frame settle; calls, because frameCounter is
        -- declared below. Graphics with no lagging offset skip the hold (walker, bikes, surf, field-move pose,
        -- underwater): it only added lag, and for surf it split the graphic from the jump that goes with it.
        local KNOWN_OFFSETFREE = { [0]=true, [89]=true, [1]=true, [90]=true, [63]=true, [91]=true,
            [2]=true, [92]=true, [3]=true, [93]=true, [111]=true, [112]=true }
        if KNOWN_OFFSETFREE[gfx] then
            genderFrames.sentGfx = gfx
        elseif gfx ~= genderFrames.pendingGfx then
            genderFrames.pendingGfx, genderFrames.pendingTicks = gfx, 0
        else
            genderFrames.pendingTicks = (genderFrames.pendingTicks or 0) + 1
            if genderFrames.pendingTicks >= 6 then genderFrames.sentGfx = gfx end
        end
        if gfx ~= genderFrames.sentGfx then
            -- Frozen with the held graphic, not zeroed: the pair on the wire must have been true together.
            return genderFrames.sentGfx
        end
    end
    genderFrames.sendSox = sox
    genderFrames.sendSoy = memory.read_s16_le(GSPRITES_ADDR + (genderFrames.spriteAddrOffset or 0)
        + memory.read_u8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04) * SPRITE_SIZE + 0x26)
    return gfx
end

-- sanim, sidx and spaused: the sprite's animation number, frame and paused bit, which a ghost has no task to drive.
-- noanim: disableAnim, which outranks a movement; on ice the character crosses tiles with its legs still.
-- invis, boat, fly and flyk describe a character the engine stopped drawing (Briney's boat, the Fly cutscene).
-- The door (dk, dx, dy) is appended only while a door is open, so the everyday packet does not grow.
local function encodeLocalState(areaId, x, y, orientation, anim, gender, gfx, sanim, sidx, act,
    sox, soy, spaused, pspeed, noanim, invis, boat, fly, flyk, dk, dx, dy, mspd)
    local door = ""
    if dk then
        door = string.format(',"dk":%s,"dx":%s,"dy":%s', jsonString(dk), tostring(dx), tostring(dy))
    end
    -- mspd is MOVE_SPEED_*, appended like the door so no argument position moves. It is the only field that names
    -- every gait (anim knows walking and running, pspeed reads standing on foot); an older peer leaves it nil.
    local ms = ""
    if mspd then ms = string.format(',"mspd":%d', mspd) end
    -- What went on the wire, for the seam trace: a receiver cannot tell a move from a rebase.
    genderFrames.sentArea, genderFrames.sentX, genderFrames.sentY = areaId, x, y
    return string.format(
        '{"type":"local_state","payload":{"state":{"area_id":%s,"position":[%s,%s],"orientation":%s,"anim":%s,"extras":{"gender":%s,"gfx":%s,"sanim":%s,"sidx":%s,"act":%s,"sox":%s,"soy":%s,"spaused":%s,"pspeed":%s,"noanim":%s,"invis":%s,"boat":%s,"fly":%s,"flyk":%s%s}}}}',
        jsonString(areaId), tostring(x), tostring(y), jsonString(orientation), jsonString(anim),
        jsonString(gender), tostring(gfx or "null"), tostring(sanim or "null"),
        tostring(sidx or "null"), tostring(act or "null"),
        tostring(sox or "null"), tostring(soy or "null"), tostring(spaused or "null"),
        tostring(pspeed or "null"), tostring(noanim or "null"),
        tostring(invis or "null"), tostring(boat or "null"),
        tostring(fly or "null"), tostring(flyk or "null"), door .. ms)
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
                -- The four hex digits must be there: one malformed escape in peer extras would cost the whole line.
                local hex = s:sub(j + 2, j + 5)
                local cp = #hex == 4 and hex:match("^%x%x%x%x$") and tonumber(hex, 16) or nil
                if cp then
                    table.insert(out, string.char(cp % 256))
                    j = j + 4
                else
                    table.insert(out, "?")
                end
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

local function decodeObject(s, i, depth)
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
        val, i = decodeValue(s, i, depth)
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

local function decodeArray(s, i, depth)
    local arr = {}
    i = skipWs(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
        local val
        val, i = decodeValue(s, i, depth)
        -- Not table.insert: a JSON null is nil, and table.insert(t, nil) raises in Lua 5.4, dropping the line.
        arr[#arr + 1] = val
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

decodeValue = function(s, i, depth)
    -- Depth cap: extras is bounded by size, not shape. A parameter, not a counter local (the 200-local ceiling).
    depth = (depth or 0) + 1
    if depth > 64 then error("json: too deeply nested") end
    i = skipWs(s, i)
    local c = s:sub(i, i)
    if c == "{" then return decodeObject(s, i, depth)
    elseif c == "[" then return decodeArray(s, i, depth)
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
-- Bridge connection.
----------------------------------------------------------------------------

-- Declared here because the port walk below reads it; a later local would be a nil global there.
local frameCounter = 0

local sock = nil
local connected = false
-- Forward-declared: resetBridge() calls it, and its pcall would swallow a nil global and leave ghosts standing.
local despawnAllGhosts
-- Forward-declared: the despawn handler (handleBridgeLine) sits above its definition.
local forgetPeerRenderState
-- connected is the socket; ready means the core answered bridge_ready, so this core is ours.
local ready = false
local recvPartial = "" -- a line split across reads; per connection, so resetBridge() clears it

-- Ports that answered but would not have us, with the frame their cooldown ends.
local busyUntil = {}

-- frames is the backoff, until_ the deadline it sets; one table, for the 200-local ceiling.
local relayDown = { frames = 600, until_ = 0 } -- 600 frames = 10s
local currentPort = nil
local helloSentAtFrame = nil

local function markPortBusy(port, why)
    if port then
        busyUntil[port] = frameCounter + BUSY_PORT_COOLDOWN_FRAMES
        console.log(string.format("MeshGhost: port %d %s -- skipping it for %ds.",
            port, why, BUSY_PORT_COOLDOWN_FRAMES // 60))
    end
end

-- A short blocking connect: a sweep needs a yes or no per port within one frame, and loopback refuses at once.
local function tryPort(port)
    local s = socketCore.tcp()
    if not s then return false end
    s:settimeout(0.05)
    local ok = s:connect(BRIDGE_HOST, port)
    if not ok then
        pcall(function() s:close() end)
        return false
    end
    s:settimeout(0)
    -- Nagle off: one small line a frame. pcall'd: setoption is an extension a vendored build may lack.
    pcall(function() s:setoption("tcp-nodelay", true) end)
    sock, connected, ready, recvPartial = s, true, false, ""
    currentPort = port
    return true
end

-- The first port with nothing listening, from the last sweep: where autostart puts a new core, since the base port
-- may be another copy's. A port that rejected us is somebody else's core, skipped through busyUntil instead.
local firstFreePort = nil

-- One sweep across the whole range per attempt, so a free core a few ports up is found at once.
local function connectBridge()
    if BRIDGE_PORT_OVERRIDE then
        firstFreePort = BRIDGE_PORT_OVERRIDE
        -- The cooldown applies here too, or a rejecting core is retried and logged every frame.
        if (busyUntil[BRIDGE_PORT_OVERRIDE] or 0) <= frameCounter then
            tryPort(BRIDGE_PORT_OVERRIDE)
        end
        return
    end
    firstFreePort = nil
    for i = 0, BRIDGE_PORT_COUNT - 1 do
        local port = BRIDGE_BASE_PORT + i
        if (busyUntil[port] or 0) <= frameCounter then
            if tryPort(port) then return end
            -- Nothing answered here, so it is free for a core of our own.
            if not firstFreePort then firstFreePort = port end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Autostart: start a core ourselves, and let it die with the emulator.
--
-- os.execute and io.popen run cmd, whose window flashes. luanet's ProcessStartInfo with UseShellExecute false and
-- CreateNoWindow true has no shell and no window, and -exit-with-pid (EmuHawk's pid) ends the core with it.
local coreChild, coreSpawnFrame, coreSpawnFailed = nil, nil, false

-- MESHGHOST_NO_AUTOSTART or "autostart": false in config.json opts out (an antivirus may object to one program
-- starting another). The first config.json found decides; an IIFE, since the file has no local to spare.
local AUTOSTART = os.getenv("MESHGHOST_NO_AUTOSTART") == nil and (function()
    for _, dir in ipairs({ SCRIPT_DIR, SCRIPT_DIR .. "../../../", SCRIPT_DIR .. "../../../../" }) do
        local f = io.open(dir .. "config.json", "rb")
        if f then
            local text = f:read("*a") or ""
            f:close()
            return not text:find('"autostart"%s*:%s*false')
        end
    end
    return true
end)()

-- Only beside this script: copying meshghost.exe here is the opt-in, so an install that never opted in spawns
-- nothing. MESHGHOST_CORE_DIR comes first, for a repo checkout.
local function findCoreExe()
    local candidates = { SCRIPT_DIR .. "meshghost.exe" }
    local devDir = os.getenv("MESHGHOST_CORE_DIR")
    if devDir and devDir ~= "" then
        table.insert(candidates, 1, devDir .. "/meshghost.exe")
    end
    for _, path in ipairs(candidates) do
        local f = io.open(path, "rb")
        if f then
            f:close()
            return path
        end
    end
    return nil
end

local function coreStillRunning()
    if not coreChild then return false end
    local ok, exited = pcall(function() return coreChild.HasExited end)
    if not ok then return false end
    return not exited
end

local function startCore(port)
    -- Our child answered busy (another instance took it): forget it, never kill it, and start another. Only on
    -- busy, never on silence, or two instances restarting together chase each other's cores round the range.
    if coreStillRunning() and coreSpawnFrame and coreSpawnFrame.busy and port then
        console.log(string.format("MeshGhost: the core this script started on port %d is serving another instance -- leaving it and starting another on port %d.", coreSpawnFrame.port, port))
        coreChild = nil
    end
    if not AUTOSTART or coreSpawnFailed or coreStillRunning() then return end
    -- No free port in the range: a core spawned here could not bind.
    if not port then return end
    -- A core takes a moment to bind; spawning again sooner piles up processes on one port.
    if coreSpawnFrame and (frameCounter - coreSpawnFrame.frame) < 300 then return end

    local exe = findCoreExe()
    if not exe then
        coreSpawnFailed = true
        console.log("MeshGhost: meshghost.exe not found near this script -- not starting a core. "
            .. "Start it yourself, or put a copy beside this file.")
        return
    end

    coreSpawnFrame = { frame = frameCounter, port = port }
    local ok, err = pcall(function()
        luanet.load_assembly("System") -- without this import_type returns nil
        local Process = luanet.import_type("System.Diagnostics.Process")
        local StartInfo = luanet.import_type("System.Diagnostics.ProcessStartInfo")
        local si = StartInfo()
        si.FileName = exe
        -- No relay settings: the core reads config.json, and -relay here would override it.
        si.Arguments = string.format("-exit-with-pid=%d -bridge=%s:%d",
            Process.GetCurrentProcess().Id, BRIDGE_HOST, port)
        -- The core reads config.json from its working directory: this game's own folder when it has one, else the
        -- exe's. Inheriting the emulator's directory left it on built-in defaults.
        do
            local own = io.open(SCRIPT_DIR .. "config.json", "rb")
            if own then own:close() end
            si.WorkingDirectory = own and SCRIPT_DIR or (exe:gsub("meshghost%.exe$", ""))
            console.log("MeshGhost: the core reads " .. si.WorkingDirectory .. "config.json"
                .. (own and " (this game's own)" or " (the release root's; put a config.json beside this script to give this game its own)"))
        end
        si.UseShellExecute = false
        si.CreateNoWindow = true
        coreChild = Process.Start(si)
    end)
    if not ok then
        coreSpawnFailed = true
        console.log("MeshGhost: could not start a core: " .. tostring(err))
        return
    end
    console.log(string.format("MeshGhost: started a core (no window) on bridge port %d; "
        .. "it will exit with the emulator.", port))
end

local function resetBridge()
    if connected then
        console.log("MeshGhost: bridge connection lost, will retry connecting.")
    end
    if sock then pcall(function() sock:close() end) end
    -- A dropped bridge makes every remote stale, and a spawned object would persist in the game.
    pcall(despawnAllGhosts)
    -- And the hardware tier's entries: nothing in the engine clears them before the next map load.
    pcall(hwReleaseAll, true)
    sock = nil
    connected = false
    ready = false
    helloSentAtFrame = nil
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
    -- A partial send would leave a newline-less fragment that corrupts the framing: drop and reconnect.
    resetBridge()
end

----------------------------------------------------------------------------
-- Local state reading.
----------------------------------------------------------------------------

-- One table, not two locals (the 200-local ceiling).
local lastMap = { group = nil, num = nil }

local function mapJustChanged(mapGroup, mapNum)
    local changed = lastMap.group ~= nil and (mapGroup ~= lastMap.group or mapNum ~= lastMap.num)
    if changed then lastMap.changedAt = frameCounter end
    lastMap.group, lastMap.num = mapGroup, mapNum
    return changed
end

-- Session gate: nothing is sent until the player is in game. A non-null gSaveBlock1Ptr is not that (it is set at
-- the CONTINUE screen), so it is a latch: it opens on the first overworld frame, stays open through battles and
-- warps, and closes when the pointer reads null again (title screen, soft reset). session.ended marks the close,
-- and the bridge is dropped so peers despawn the ghost: the core never expires a peer's last sample.
local session = { live = false, ended = false }

-- A pointer outside EWRAM reads as 0, so the existing == 0 guards skip a ROM whose save blocks live elsewhere;
-- BizHawk answers an out-of-range read with a console warning, not an error.
session.saveBlockPtr = function(addr)
    -- The IWRAM shift (EX SPEEDCHOICE) is applied here, so every deref site gets it.
    local ptr = memory.read_u32_le(addr + (genderFrames.iwramOffset or 0))
    if ptr >= 0x02000000 and ptr < 0x02040000 then return ptr end
    if ptr ~= 0 and not session.badPtrLogged then
        session.badPtrLogged = true
        console.log(string.format(
            "MeshGhost: the save-block pointer at %08X reads %08X, which is not EWRAM -- this "
                .. "ROM is not one this adapter has addresses for. Nothing will be sent or "
                .. "drawn. Logged once; the reads are skipped rather than warned about every "
                .. "frame.", addr, ptr))
    end
    return 0
end

local function getLocalState()
    local base = session.saveBlockPtr(GSAVEBLOCK1PTR_ADDR)
    if base == 0 then
        if session.live then session.ended = true end
        session.live = false
        return nil
    end

    if not session.live then
        if not inOverworld() then return nil end
        session.live = true
        console.log("MeshGhost: in game -- now sending local state.")
    end

    local x = memory.read_s16_le(base + 0x00)
    local y = memory.read_s16_le(base + 0x02)
    -- Unsigned, as xmapScan reads the connection entries: signed, an id of 128 or more would miss the seam lookup.
    local mapGroup = memory.read_u8(base + 0x04)
    local mapNum = memory.read_u8(base + 0x05)

    if mapJustChanged(mapGroup, mapNum) then return nil end

    local flags = memory.read_u8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x00)
    local runningState = memory.read_u8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x02)
    local objectEventId = memory.read_u8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05)
    local dashing = (flags & 0x80) ~= 0

    local objEventAddr = GOBJECTEVENTS_ADDR + avatarAddrOffset + (objectEventId * OBJECTEVENT_SIZE)
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

-- Called once, after the player is in the overworld, so an uninitialised byte from the intro cannot latch.
local function readLocalGender()
    local base = session.saveBlockPtr(GSAVEBLOCK2PTR_ADDR)
    if base == 0 then return nil end
    local gender = memory.read_u8(base + 0x08)
    return (gender == 1) and "female" or "male"
end

----------------------------------------------------------------------------
-- Sub-tile position smoothing. The save block holds whole tiles, so the sender ramps from the previous tile to the
-- new one over the step's fixed frame count; measuring the gap instead misreads tap-then-pause play.
----------------------------------------------------------------------------

local STEP_DURATION_FRAMES = { walking = 16, running = 8 }

-- A drawn peer is smoothed by a rate-limited filter with no clock of its own, so it cannot beat against the game's
-- scroll. drawnDelay trails the target by N frames: 0, since a delayed ghost slides across a screen that stopped
-- with the player; 8 reproduces the spawned tier, for a side-by-side comparison.
genderFrames.drawnDelay = tonumber(MESHGHOST_EMERALD_DRAWN_DELAY_FRAMES
    or os.getenv("MESHGHOST_EMERALD_DRAWN_DELAY_FRAMES") or "") or 0

local function glideRemote(r, targetX, targetY)
    -- The delay line: a 32-slot ring of recent positions, read drawnDelay frames back.
    r.hist = r.hist or {}
    -- Slots are reused, not reallocated, and carry the facing so it describes the same instant as the position.
    local slot = r.hist[frameCounter % 32]
    if slot then
        slot[1], slot[2], slot[3] = targetX, targetY, r.orientation
    else
        r.hist[frameCounter % 32] = { targetX, targetY, r.orientation }
    end
    local old = r.hist[(frameCounter - genderFrames.drawnDelay) % 32]
    -- For the painted tier; nil until the ring fills, when the draw site uses the live facing.
    r.gOrient = old and old[3] or nil
    if old then targetX, targetY = old[1], old[2] end

    -- First sight, a new area, or over two tiles: a warp or a dropped peer, so snap rather than filter.
    if r.gX == nil or r.gAreaId ~= r.areaId
        or math.abs(targetX - r.gX) > 2 or math.abs(targetY - r.gY) > 2 then
        r.gX, r.gY, r.gAreaId = targetX, targetY, r.areaId
        r.gMoved, r.gDist = false, 0
        return r.gX, r.gY
    end
    r.gAreaId = r.areaId

    -- Constant speed toward the target, never an ease: a character crosses a tile at a fixed speed and stops.
    local prevX, prevY = r.gX, r.gY
    -- Target speed over an 8-frame window: the stream is bursty, so frame to frame it reads zero most frames. It
    -- is measured drawnDelay + WINDOW back, in the same time frame as the delayed target; the pair must fit the ring.
    local WINDOW = 8
    local lookBack = genderFrames.drawnDelay + WINDOW
    if lookBack >= 32 then lookBack = WINDOW end
    local was = r.hist[(frameCounter - lookBack) % 32]
    local tspd = 0
    if was then
        tspd = (math.abs(targetX - was[1]) + math.abs(targetY - was[2])) / WINDOW
    elseif r.tgtPrevX then
        tspd = math.abs(targetX - r.tgtPrevX) + math.abs(targetY - r.tgtPrevY)
    end
    r.tgtPrevX, r.tgtPrevY = targetX, targetY
    -- Floor 0.02 tiles a frame closes a sub-pixel gap; cap 0.25 (a tile in four frames, the Mach Bike) spreads a
    -- jump in the stream over several frames instead of one.
    local ddx, ddy = targetX - r.gX, targetY - r.gY
    local dist = math.abs(ddx) + math.abs(ddy)
    -- A character finishes its step at speed: the peak speed is the floor until the ghost arrives, then cleared.
    if tspd > (r.gSpd or 0) then r.gSpd = tspd end
    if dist <= 0.05 then r.gSpd = nil end
    local limit = math.min(math.max(tspd, r.gSpd or 0, 0.02) * 1.25, 0.25)

    -- Move at a speed the engine produces, whole pixels a frame by MOVE_SPEED_*: 1, 2, 2-3, 4, 8. FAST_2 (the acro
    -- bike, 2,3,3,2,3,3) is entered at its maximum: this is a ceiling, and the wire carries the real pattern.
    -- pspeed is gPlayerAvatar.bikeSpeed, 0 standing and on foot even when running, so anim covers walking.
    local ENGINE_PX = { [0] = 1, [1] = 2, [2] = 3, [3] = 4, [4] = 8 }
    local ANIM_PX = { walking = 1, running = 2 }
    local PLAYER_SPEED_PX = { [1] = 1, [2] = 2, [3] = 4, [4] = 8 }
    -- mspd first: it indexes the engine's own step table. anim and pspeed are the fallback, and neither knows a bike.
    local quantum = r.mspd and ENGINE_PX[r.mspd]
    if not quantum then
        quantum = ANIM_PX[r.anim]
        local vehiclePx = r.pspeed and PLAYER_SPEED_PX[r.pspeed]
        if vehiclePx and (not quantum or vehiclePx > quantum) then quantum = vehiclePx end
    end
    -- The travelling quantum is held until the model arrives, so a stop or a turn never crawls the last bit in.
    if quantum then
        r.gQuantum = quantum
    elseif r.gQuantum and dist > 0.02 then
        quantum = r.gQuantum
    end
    if dist <= 0.02 then r.gQuantum = nil end
    if quantum then
        if dist > 1 then
            -- Covering ground means the next real quantum up (running), never a fraction.
            local faster = (quantum <= 1 and 2) or (quantum <= 2 and 4) or 8
            if faster > quantum then quantum = faster end
        end
        limit = quantum / TILE
    end
    -- Within one frame's reach, become the target: moving at the peer's own speed would never close a gap.
    if dist > 0 and dist <= limit then
        r.gX, r.gY = targetX, targetY
        r.gAxis = nil
    elseif dist > 0 then
        local move = math.min(dist, limit)
        -- One axis at a time, dominant first: nothing in Emerald moves diagonally, so a corner is two legs.
        local ax, ay = math.abs(ddx), math.abs(ddy)
        -- The axis sticks until its remainder is under a quarter pixel, or near arrival it would staircase.
        local EPS = 0.015
        if r.gAxis == "x" and ax <= EPS then r.gAxis = nil end
        if r.gAxis == "y" and ay <= EPS then r.gAxis = nil end
        if r.gAxis == nil then r.gAxis = (ax >= ay) and "x" or "y" end
        if r.gAxis == "x" then ay = 0 else ax = 0 end
        if ax >= ay then
            local spend = math.min(move, ax)
            if ddx ~= 0 then r.gX = r.gX + (ddx > 0 and spend or -spend) end
            move = move - spend
            if move > 0 and ddy ~= 0 then
                local sp2 = math.min(move, ay)
                r.gY = r.gY + (ddy > 0 and sp2 or -sp2)
            end
        else
            local spend = math.min(move, ay)
            if ddy ~= 0 then r.gY = r.gY + (ddy > 0 and spend or -spend) end
            move = move - spend
            if move > 0 and ddx ~= 0 then
                local sp2 = math.min(move, ax)
                r.gX = r.gX + (ddx > 0 and sp2 or -sp2)
            end
        end
    end
    -- MESHGHOST_EMERALD_MOVE_TRACE (probe, off by default): target, model and deltas, a line per frame per peer.
    if MESHGHOST_EMERALD_MOVE_TRACE then
        genderFrames.mvBuf = genderFrames.mvBuf or {}
        local b = genderFrames.mvBuf
        b[#b + 1] = string.format(
            "p%s f=%d tgt=%.4f,%.4f d(tgt)=%.4f,%.4f model=%.4f,%.4f d(model)=%.4f,%.4f "
                .. "dist=%.4f limit=%.4f pspeed=%s anim=%s",
            tostring(currentPort), frameCounter, targetX, targetY,
            targetX - (r.mvPrevTX or targetX), targetY - (r.mvPrevTY or targetY),
            r.gX, r.gY, r.gX - prevX, r.gY - prevY,
            dist, limit, tostring(r.pspeed), tostring(r.anim))
        r.mvPrevTX, r.mvPrevTY = targetX, targetY
        if #b >= 240 then
            local tf = io.open(SCRIPT_DIR .. "probes/movetrace.log", "a")
            if tf then
                tf:write(table.concat(b, string.char(10)) .. string.char(10))
                tf:close()
            end
            genderFrames.mvBuf = {}
        end
    end
    -- Face the way it moves: the wire's facing flips at the start of a step, while the last one is still playing.
    local mvx, mvy = r.gX - prevX, r.gY - prevY
    if math.abs(mvx) > 0.001 or math.abs(mvy) > 0.001 then
        if math.abs(mvx) >= math.abs(mvy) then
            r.gFacing = (mvx > 0) and "east" or "west"
        else
            r.gFacing = (mvy > 0) and "south" or "north"
        end
    end
    local dx, dy = math.abs(r.gX - prevX), math.abs(r.gY - prevY)

    -- A filter never quite arrives, so moving means still meaningfully closing.
    r.gMoved = (math.abs(targetX - r.gX) + math.abs(targetY - r.gY)) > 0.02
    -- Stopped: the facing comes from the wire again, since a turn on the spot shows in no position.
    if not r.gMoved then r.gFacing = nil end
    -- Tiles covered: the engine changes pose every 8 pixels, whatever rate positions arrived at.
    r.gDist = (r.gDist or 0) + dx + dy
    -- Walking into a wall covers no ground, so a peer reported walking with a still target advances the cycle
    -- anyway. Asked of the target, a discrete wire value, not of the filter, which never lands exactly.
    if targetX == r.lastTX and targetY == r.lastTY then
        -- Half pace: walking into a wall is slower than walking.
        if r.anim == "running" then r.gDist = r.gDist + 0.0625
        elseif r.anim == "walking" then r.gDist = r.gDist + 0.03125 end
    end
    r.lastTX, r.lastTY = targetX, targetY
    return r.gX, r.gY
end

local prevTileX, prevTileY = nil, nil
local committedTileX, committedTileY = nil, nil
local committedAreaId = nil
local tileChangeFrame = 0
-- The current step's duration, fixed when it commits, so a change of anim mid-glide cannot make it jump.
local activeStepDuration = STEP_DURATION_FRAMES.walking
-- True only while gliding a real committed step, not the snap after a first sample or map change; gates diagnostics.
local inRealGlide = false
-- Cleared one call late, so the completion frame still reads inRealGlide for the diagnostics.
local glideJustCompleted = false

-- stepFrames is the engine's step length for the player's gait, read at the send site (anim reads walking on a bike).
local function smoothPosition(rawX, rawY, areaId, anim, stepFrames)
    if glideJustCompleted then
        inRealGlide = false
        glideJustCompleted = false
    end

    -- A seam is not a warp: xmapRebase leaves the seam's tile delta, so both endpoints move into the new map's
    -- numbering and the step in flight finishes. A warp leaves no delta and snaps.
    local seam = genderFrames.xmapSeam
    local carried = false
    -- Only if the rebased tile is where the engine has the player, so a savestate load onto a connected map snaps.
    if committedTileX ~= nil and areaId ~= committedAreaId and seam
        and seam.from == committedAreaId and seam.to == areaId
        and math.abs((committedTileX + seam.dx) - rawX) <= 1
        and math.abs((committedTileY + seam.dy) - rawY) <= 1 then
        genderFrames.xmapSeam = nil
        prevTileX, prevTileY = prevTileX + seam.dx, prevTileY + seam.dy
        committedTileX, committedTileY = committedTileX + seam.dx, committedTileY + seam.dy
        committedAreaId = areaId
        carried = true
    end
    if not carried and (committedTileX == nil or areaId ~= committedAreaId) then
        -- First sample or a map change: nothing to glide from, so snap.
        prevTileX, prevTileY = rawX, rawY
        committedTileX, committedTileY = rawX, rawY
        committedAreaId = areaId
        tileChangeFrame = frameCounter
        activeStepDuration = stepFrames or STEP_DURATION_FRAMES[anim] or STEP_DURATION_FRAMES.walking
        inRealGlide = false
    elseif rawX ~= committedTileX or rawY ~= committedTileY then
        prevTileX, prevTileY = committedTileX, committedTileY
        committedTileX, committedTileY = rawX, rawY
        tileChangeFrame = frameCounter
        activeStepDuration = stepFrames or STEP_DURATION_FRAMES[anim] or STEP_DURATION_FRAMES.walking
        inRealGlide = true
    end

    local fraction = (frameCounter - tileChangeFrame) / activeStepDuration
    if fraction >= 1 then glideJustCompleted = true end
    if fraction > 1 then fraction = 1 end
    if fraction < 0 then fraction = 0 end

    return prevTileX + (committedTileX - prevTileX) * fraction,
           prevTileY + (committedTileY - prevTileY) * fraction
end

-- Diagnostic: our glide against the real sprite's per-frame motion, during real glides only.
local DIAG_STEP_CURVE = false
local DIAG_STEP_CURVE_MAX_LOGS = 3600
-- Diagnostics share one table, so shipped code keeps the local slots.
local diag = { stepCurveLogs = 0, prevRealX = nil, prevRealY = nil, screenPosLogs = 0 }

local DIAG_SCREENPOS_PARTS = false
local DIAG_SCREENPOS_PARTS_MAX_LOGS = 200

local function playerScreenPos()
    local spriteId = memory.read_u8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04)
    -- Through the gSprites shift: every painted peer is positioned against this.
    local spriteAddr = GSPRITES_ADDR + (genderFrames.spriteAddrOffset or 0)
        + (spriteId * SPRITE_SIZE)

    local sx = memory.read_s16_le(spriteAddr + 0x20)
    local sy = memory.read_s16_le(spriteAddr + 0x22)
    local sx2 = memory.read_s16_le(spriteAddr + 0x24)
    local sy2 = memory.read_s16_le(spriteAddr + 0x26)
    local cx = memory.read_s8(spriteAddr + 0x28)
    local cy = memory.read_s8(spriteAddr + 0x29)

    local coordOffsetX = memory.read_s16_le(GSPRITECOORDOFFSETX_ADDR + (genderFrames.spriteAddrOffset or 0))
    local coordOffsetY = memory.read_s16_le(GSPRITECOORDOFFSETY_ADDR + (genderFrames.spriteAddrOffset or 0))

    -- Diagnostic: each term of the sum, spriteId included, during real glides only.
    if DIAG_SCREENPOS_PARTS and inRealGlide and diag.screenPosLogs < DIAG_SCREENPOS_PARTS_MAX_LOGS then
        diag.screenPosLogs = diag.screenPosLogs + 1
        console.log(string.format(
            "MeshGhost DIAG PARTS: frame=%d spriteId=%d sx=%d sy=%d sx2=%d sy2=%d cx=%d cy=%d coordOffsetX=%d coordOffsetY=%d",
            frameCounter, spriteId, sx, sy, sx2, sy2, cx, cy, coordOffsetX, coordOffsetY))
    end

    return sx + sx2 + cx + coordOffsetX, sy + sy2 + cy + coordOffsetY
end

----------------------------------------------------------------------------
-- Remote ghost set (the tick model): upserted by render_remote, removed by despawn_remote, redrawn every frame.
-- Updates merge into the entry, so the walk cycle survives a new position.
----------------------------------------------------------------------------

local remotes = {}

-- Cross-map ghosts: a peer on a map connected to ours (a route seam) is translated at ingest into our tile frame, so
-- everything downstream sees local coordinates; any other peer stays hidden. Houses are reached only by warp and a
-- map two away is not in the connection list, so this is also the house rule and the distance cull.
genderFrames.xmap = { scanStep = 1, scanAt = 0, hits = {}, groupsAt = nil,
    conns = nil, connsFor = nil, ourW = 0, ourH = 0 }

-- The scan result is cached across loads, keyed by the ROM's game code and checked against the live header copy
-- before use. xmapCachePath is set in the log-open block above; declaring it here would wipe it.
genderFrames.xmapTryCache = function()
    local xm = genderFrames.xmap
    if not genderFrames.xmapCachePath then return false end
    local f = io.open(genderFrames.xmapCachePath, "r")
    if not f then return false end
    local line = f:read("*l") f:close()
    local code, addr = string.match(line or "", "^(%x+) (%x+)")
    if not code or tonumber(code, 16) ~= memory.read_u32_le(0x080000AC) then return false end
    local base = tonumber(addr, 16)
    local sb1 = session.saveBlockPtr(0x03005d8c)
    if sb1 == 0 then return false end
    local grp, num = memory.read_u8(sb1 + 0x04), memory.read_u8(sb1 + 0x05)
    local ga = memory.read_u32_le(base + grp * 4)
    if ga < 0x08000000 or ga >= 0x09000000 then return false end
    local hdr = memory.read_u32_le(ga + num * 4)
    if hdr < 0x08000000 or hdr >= 0x09000000 then return false end
    for k = 0, 12, 4 do
        if memory.read_u32_le(hdr + k) ~= memory.read_u32_le(0x02037318 + k) then return false end
    end
    xm.groupsAt = base
    console.log("MeshGhost: cross-map ghosts armed instantly (cached gMapGroups verified)")
    return true
end
genderFrames.xmapSaveCache = function()
    -- Loud on every exit: a silent miss re-opens the arming window the cache exists to close.
    if not genderFrames.xmapCachePath then
        console.log("MeshGhost: xmap cache NOT saved -- path never set")
        return
    end
    local f = io.open(genderFrames.xmapCachePath, "w")
    if not f then
        console.log("MeshGhost: xmap cache NOT saved -- cannot write " .. genderFrames.xmapCachePath)
    end
    if f then
        f:write(string.format("%08X %08X", memory.read_u32_le(0x080000AC),
            genderFrames.xmap.groupsAt) .. string.char(10))
        f:close()
    end
end

genderFrames.xmapLocalKey = function()
    local sb1 = session.saveBlockPtr(0x03005d8c)
    if sb1 == 0 then return nil end
    return memory.read_u8(sb1 + 0x04) .. ":" .. memory.read_u8(sb1 + 0x05)
end

-- One 128KB ROM chunk per frame; three passes find the map header, its group array, then gMapGroups.
genderFrames.xmapScan = function()
    local xm = genderFrames.xmap
    -- A failed pass retries after a pause: a seam crossed mid-pass can leave it with no candidate.
    if xm.groupsAt then return end
    if xm.scanStep > 3 then
        if not xm.retryAt then xm.retryAt = frameCounter + 300 end
        if frameCounter < xm.retryAt then return end
        xm.scanStep, xm.scanAt, xm.retryAt = 1, 0, nil
    end
    local GMH = 0x02037318
    if xm.scanAt == 0 then
        xm.scanAt = 0x08000000
        xm.hits = {}
        if xm.scanStep == 1 then
            xm.target = memory.read_u32_le(GMH)
            -- A snapshot, not the live copy: a seam crossed mid-pass swaps the header under the scan.
            xm.sig = {}
            for k = 0, 12, 4 do xm.sig[k] = memory.read_u32_le(GMH + k) end
            local sb1s = session.saveBlockPtr(0x03005d8c)
            xm.sigGrp, xm.sigNum = memory.read_u8(sb1s + 0x04), memory.read_u8(sb1s + 0x05)
        elseif xm.scanStep == 2 then xm.target = xm.romHeader
        else xm.target = xm.groupArray end
        if not xm.target or xm.target == 0 then xm.scanStep = 4 return end
    end
    local b = memory.read_bytes_as_array(xm.scanAt, 0x20000)
    local t = xm.target
    local b0, b1 = t % 256, math.floor(t / 256) % 256
    local b2, b3 = math.floor(t / 65536) % 256, math.floor(t / 16777216) % 256
    for i = 1, 0x20000 - 3, 4 do
        if b[i] == b0 and b[i + 1] == b1 and b[i + 2] == b2 and b[i + 3] == b3 then
            xm.hits[#xm.hits + 1] = xm.scanAt + i - 1
        end
    end
    xm.scanAt = xm.scanAt + 0x20000
    if xm.scanAt < 0x09000000 then return end
    local sb1 = session.saveBlockPtr(0x03005d8c)
    if sb1 == 0 then xm.scanAt = 0 return end
    if xm.scanStep == 1 then
        local m
        local count = 0
        for _, a in ipairs(xm.hits) do
            local ok = true
            for k = 0, 12, 4 do
                if memory.read_u32_le(a + k) ~= xm.sig[k] then ok = false break end
            end
            if ok then m = a count = count + 1 end
        end
        if count ~= 1 then xm.scanStep = 4 return end   -- ambiguous: the retry re-snapshots
        xm.romHeader = m
    elseif xm.scanStep == 2 then
        local num = xm.sigNum
        for _, a in ipairs(xm.hits) do
            if memory.read_u32_le(a - num * 4 + num * 4) == xm.romHeader then
                xm.groupArray = a - num * 4
                break
            end
        end
        if not xm.groupArray then xm.scanStep = 4 return end
    else
        local grp = xm.sigGrp
        for _, a in ipairs(xm.hits) do
            local base = a - grp * 4
            if memory.read_u32_le(base + grp * 4) == xm.groupArray then xm.groupsAt = base break end
        end
        if xm.groupsAt then
            console.log("MeshGhost: cross-map ghosts armed (gMapGroups self-located at "
                .. string.format("%08X", xm.groupsAt) .. ")")
            genderFrames.xmapSaveCache()
        end
        xm.scanStep = 4
        return
    end
    xm.scanStep = xm.scanStep + 1
    xm.scanAt = 0
end

genderFrames.xmapDims = function(g, n)
    local xm = genderFrames.xmap
    local hdr = memory.read_u32_le(memory.read_u32_le(xm.groupsAt + g * 4) + n * 4)
    if hdr < 0x08000000 or hdr >= 0x09000000 then return nil end
    local lay = memory.read_u32_le(hdr)
    if lay < 0x08000000 then return nil end
    return memory.read_s32_le(lay), memory.read_s32_le(lay + 4)
end

genderFrames.xmapBuild = function(localKey)
    local xm = genderFrames.xmap
    xm.conns, xm.connsFor = {}, localKey
    local sb1 = session.saveBlockPtr(0x03005d8c)
    local g, n = memory.read_u8(sb1 + 0x04), memory.read_u8(sb1 + 0x05)
    local w, h = genderFrames.xmapDims(g, n)
    if not w or w <= 0 or w > 1000 then return end
    xm.ourW, xm.ourH = w, h
    local connPtr = memory.read_u32_le(0x02037318 + 0x0c)
    if connPtr < 0x08000000 or connPtr >= 0x09000000 then return end   -- a house: no connections
    local count = memory.read_s32_le(connPtr)
    local list = memory.read_u32_le(connPtr + 4)
    if count < 0 or count > 8 or list < 0x08000000 then return end
    for i = 0, count - 1 do
        local c = list + i * 12
        local dir = memory.read_u8(c)
        if dir >= 1 and dir <= 4 then                 -- dive/emerge are warps in spirit: excluded
            local cg, cn = memory.read_u8(c + 8), memory.read_u8(c + 9)
            local nw, nh = genderFrames.xmapDims(cg, cn)
            if nw then
                xm.conns[cg .. ":" .. cn] =
                    { dir = dir, off = memory.read_s32_le(c + 4), w = nw, h = nh }
            end
        end
    end
end

-- From the wire values: a peer on a connected map within the margin moves into our tile frame; any other stays hidden.
genderFrames.xmapTranslate = function(r, localKey)
    if not r.srcAreaId then return end
    if r.srcAreaId == localKey then
        r.areaId, r.x, r.y = localKey, r.sx, r.sy
        return
    end
    local xm = genderFrames.xmap
    local c = xm.conns and xm.connsFor == localKey and xm.conns[r.srcAreaId] or nil
    if not c then r.areaId = r.srcAreaId return end
    local lx, ly
    if c.dir == 2 then lx, ly = r.sx + c.off, r.sy - c.h          -- north: neighbor above
    elseif c.dir == 1 then lx, ly = r.sx + c.off, r.sy + xm.ourH  -- south
    elseif c.dir == 3 then lx, ly = r.sx - c.w, r.sy + c.off      -- west
    else lx, ly = r.sx + xm.ourW, r.sy + c.off end                -- east
    -- Existence reaches 10 tiles past the edge, 3 beyond the engine's 7-tile border, so a peer exists before the
    -- screen can show it; chooseSpawned still stops the spawned tier at 7, past which its grid coordinate is negative.
    if lx >= -10 and ly >= -10 and lx <= xm.ourW + 9 and ly <= xm.ourH + 9 then
        r.areaId, r.x, r.y = localKey, lx, ly
    else
        r.areaId = r.srcAreaId                                     -- connected but out of range
    end
end

-- MESHGHOST_EMERALD_TEST_PEER = "g:n,x,y" (x may be "px"): a synthetic standing peer to test cross-map with. Dev only.
genderFrames.xmapTestPeer = function(localKey)
    local cfg = MESHGHOST_EMERALD_TEST_PEER or os.getenv("MESHGHOST_EMERALD_TEST_PEER")
    -- "off", "none" or empty retires it: the flag usually lives in the emulator's environment, which no reload unsets.
    if not cfg or cfg == "off" or cfg == "none" or cfg == "" then
        -- Dropping the entry is enough: both tiers reap a peer whose remote is gone, the way a real player leaves
        -- (and despawnGhost is declared below, so calling it here would hit a nil global).
        remotes["xmap-test"] = nil
        return
    end
    local area, xs, ys = string.match(cfg, "^([%d]+:[%d]+),([%w]+),([%-%d]+)$")
    if not area then return end
    local x
    if xs == "px" then
        local sb1 = session.saveBlockPtr(0x03005d8c)
        x = memory.read_s16_le(sb1 + 0x00)
    else
        x = tonumber(xs)
    end
    local r = remotes["xmap-test"]
    if not r then
        r = { animTimer = 0, animStepIndex = 0 }
        remotes["xmap-test"] = r
    end
    r.srcAreaId, r.sx, r.sy = area, x, tonumber(ys)
    r.orientation, r.anim, r.gender = "south", "idle", "male"
    r.gfx, r.sanim, r.sidx, r.act, r.spaused, r.sox, r.soy = 0, 4, 1, 0, 1, 0, 0
end

-- A seam crossing shifts every peer's old-frame state by the seam delta, read from the old map's connection entry
-- toward the new one, instead of letting it read as a teleport. A warp has no entry and keeps the teardown.
genderFrames.xmapRebase = function(newKey)
    local xm = genderFrames.xmap
    local c = xm.conns and xm.conns[newKey] or nil
    if not c then return end
    xm.rebasedAt = frameCounter
    local dx, dy
    if c.dir == 2 then dx, dy = -c.off, c.h
    elseif c.dir == 1 then dx, dy = -c.off, -xm.ourH
    elseif c.dir == 3 then dx, dy = c.w, -c.off
    else dx, dy = -xm.ourW, -c.off end
    for _, r in pairs(remotes) do
        if r.gX then r.gX, r.gY = r.gX + dx, r.gY + dy end
        if r.tgtPrevX then r.tgtPrevX, r.tgtPrevY = r.tgtPrevX + dx, r.tgtPrevY + dy end
        if r.hist then
            for _, p in pairs(r.hist) do p[1], p[2] = p[1] + dx, p[2] + dy end
        end
    end
    -- The paint anchor is in tile units too, so it moves by the same delta, and stamping its area stops anchorFrame
    -- re-latching mid-handover; origin/originStill are screen positions and stay. Handed over through genderFrames
    -- because `tiering` is declared below; anchorFrame applies it this frame, before either tier paints.
    genderFrames.xmapAnchorShift = { dx = dx, dy = dy, key = newKey }
    -- The send path takes the same delta: smoothPosition would otherwise snap on the area change and put a whole tile
    -- on the wire in one frame. Stashed here because xmapBuild replaces the departing map's connections this frame.
    genderFrames.xmapSeam = { dx = dx, dy = dy, from = xm.lastKey, to = newKey, at = frameCounter }
    -- Count only: ghostAlive is declared below this function.
    local n = 0
    for _, g in pairs(genderFrames.xmapGhosts or {}) do
        if g.mapX then g.mapX, g.mapY = g.mapX + dx, g.mapY + dy end
        n = n + 1
    end
    logFile(string.format("f=%d XMAP rebase -> %s d=%d,%d ghosts=%d", frameCounter, newKey, dx, dy, n))
end

genderFrames.xmapTick = function()
    local localKey = genderFrames.xmapLocalKey()
    if not localKey then return end
    local xm = genderFrames.xmap
    if not xm.groupsAt then
        if not xm.cacheTried then
            xm.cacheTried = true
            genderFrames.xmapTryCache()
        end
        if not xm.groupsAt then genderFrames.xmapScan() end
    end
    if xm.lastKey and xm.lastKey ~= localKey then genderFrames.xmapRebase(localKey) end
    xm.lastKey = localKey
    if xm.groupsAt and xm.connsFor ~= localKey then genderFrames.xmapBuild(localKey) end
    genderFrames.xmapTestPeer(localKey)
    for _, r in pairs(remotes) do genderFrames.xmapTranslate(r, localKey) end
end

local function handleBridgeLine(line)
    local env = jsonDecode(line)
    if not env or type(env) ~= "table" then return end

    if env.type == "bridge_ready" then
        ready = true
        console.log(string.format("MeshGhost: bridge_ready on port %s -- this core is ours.",
            tostring(currentPort)))
    elseif env.type == "reject" then
        -- The core's reason is logged as given: never branched on, never replaced by a guess.
        local payload = env.payload
        local reason = tostring(type(payload) == "table" and payload.reason or "no reason given")
        console.log("MeshGhost: rejected (" .. reason .. ")")
        -- Only "busy" or "already_serving" means walk to the next port; any other refusal means this core is fine and
        -- something upstream is not, so wait on it. Branch on `code`, never the prose: every permanent refusal
        -- contains the word "relay". An empty code is an older core, the one case the substring rule still runs.
        local code = type(payload) == "table" and type(payload.code) == "string" and payload.code or ""
        local retryable = type(payload) == "table" and payload.retryable == true
        local walkOn
        if code == "" then
            walkOn = not reason:find("relay", 1, true)
        else
            walkOn = (code == "busy") or (code == "already_serving")
        end
        if not walkOn then
            if code ~= "" and not retryable then
                -- A refusal that will not fix itself is said plainly, never retried in silence.
                console.log("MeshGhost: that refusal is PERMANENT (" .. code .. ") -- waiting will not "
                    .. "fix it; check the client's config.json")
            end
            relayDown.until_ = frameCounter + relayDown.frames
            resetBridge()
            return
        end
        local isBusy
        if code == "" then
            isBusy = reason:find("busy", 1, true) ~= nil
        else
            isBusy = code == "busy"
        end
        if isBusy and coreSpawnFrame and currentPort == coreSpawnFrame.port then
            coreSpawnFrame.busy = true -- our own child has another game: startCore may forget it
        end
        markPortBusy(currentPort, "refused us (" .. reason .. ")")
        resetBridge()
    elseif env.type == "session_policy" then
        -- Only "disabled" and "enabled" are acted on: guessing "off" for an unknown value is a change nobody asked for.
        local payload = env.payload
        local want = type(payload) == "table" and type(payload.ghost_collision) == "string"
            and payload.ghost_collision or ""
        if want == "disabled" or want == "enabled" then
            local off = (want == "disabled")
            -- On `session`, not `tiering`: tiering is declared below this dispatch, so here it is a nil global.
            if off ~= session.noCollisionPolicy then
                session.noCollisionPolicy = off
                console.log("MeshGhost: ghost collision " .. want .. " by the session policy -- "
                    .. (off and "peers are walk-through" or "peers can block you"))
            end
        end
    elseif env.type == "render_remote" then
        local payload = env.payload
        -- A player id must be a string: every tier below calls playerId:match, which raises on a number, and a table
        -- id would grow `remotes` without bound.
        if type(payload) == "table" and type(payload.state) == "table" and type(payload.player_id) == "string" then
            local st = payload.state
            local pos = st.position
            -- Both coordinates must be finite numbers: a string raises in the tile arithmetic, and NaN or 1e999
            -- passes every comparison as a ghost that is nowhere. Refused, the update is dropped whole.
            local function finite(n)
                return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
            end
            if type(pos) == "table" and finite(pos[1]) and finite(pos[2]) then
                local r = remotes[payload.player_id]
                if not r then
                    r = { animTimer = 0, animStepIndex = 0 }
                    remotes[payload.player_id] = r
                end
                r.areaId = st.area_id
                r.x = pos[1]
                r.y = pos[2]
                -- The wire values, kept: xmapTranslate re-derives areaId/x/y from them every frame, and runs here
                -- too so a fresh state is never a frame stale.
                r.srcAreaId, r.sx, r.sy = st.area_id, pos[1], pos[2]
                genderFrames.xmapTranslate(r, genderFrames.xmapLocalKey())
                r.orientation = st.orientation
                r.anim = st.anim
                -- Only the two genders the frame tables know, else "male": any other value (a number, a table, a
                -- genderFrames method name) broke the draw loop for every peer sorted after it.
                local g = type(st.extras) == "table" and st.extras.gender or nil
                r.gender = (g == "male" or g == "female") and g or "male"
                -- The peer's own graphic (absent from an older peer, which borrows this machine's player graphic).
                -- A new graphic is adopted only once two consecutive updates agree on it and its offset: the game
                -- sets a new graphic before its task applies the offset (fishing), a pose nobody sees on the player
                -- but a ghost would replay in a clean frame.
                local newGfx = (type(st.extras) == "table" and tonumber(st.extras.gfx)) or nil
                local newSox = (type(st.extras) == "table" and tonumber(st.extras.sox)) or 0
                -- A surf jump (act 0x3A..0x3D) skips the wait: the game sets that graphic and the jump in one step,
                -- so it cannot arrive half-formed.
                local newAct = (type(st.extras) == "table" and tonumber(st.extras.act)) or nil
                local pair = tostring(newGfx) .. ":" .. tostring(newSox)
                if pair == r.statePair
                    or (newAct and newAct >= 0x3a and newAct <= 0x3d) then r.gfx = newGfx end
                r.statePair = pair
                if r.gfx == nil then r.gfx = newGfx end
                -- The animation is taken only with its graphic: an animation number means nothing against another
                -- graphic's table, and adopting it early made a (graphic, animation) pair the peer was never in.
                -- `act` is not held: it is a movement action, not indexed by graphic.
                local sa = (type(st.extras) == "table" and tonumber(st.extras.sanim)) or nil
                local si = (type(st.extras) == "table" and tonumber(st.extras.sidx)) or nil
                if r.gfx == newGfx then
                    r.sanim = (sa and sa >= 0 and sa <= 255 and math.floor(sa) == sa) and sa or nil
                    r.sidx = (si and si >= 0 and si <= 255 and math.floor(si) == si) and si or nil
                end
                local ac = (type(st.extras) == "table" and tonumber(st.extras.act)) or nil
                r.act = (ac and ac >= 0 and ac <= 255 and math.floor(ac) == ac) and ac or nil
                -- Peer-controlled, so bounded: an offset beyond a tile or two is a ghost pushed through a wall.
                local ox = (type(st.extras) == "table" and tonumber(st.extras.sox)) or nil
                local oy = (type(st.extras) == "table" and tonumber(st.extras.soy)) or nil
                r.sox = (ox and ox >= -32 and ox <= 32) and math.floor(ox) or nil
                r.soy = (oy and oy >= -32 and oy <= 32) and math.floor(oy) or nil
                -- Whether the peer's sprite animation is held; nil (an older peer) leaves it to the engine.
                local sp = (type(st.extras) == "table" and tonumber(st.extras.spaused)) or nil
                r.spaused = sp ~= nil and sp ~= 0 or nil
                -- Whether the peer is forbidden an animation, the one statement that survives a movement.
                local na = (type(st.extras) == "table" and tonumber(st.extras.noanim)) or nil
                r.noanim = na ~= nil and na ~= 0 or nil
                local ps = (type(st.extras) == "table" and tonumber(st.extras.pspeed)) or nil
                r.pspeed = (ps and ps >= 0 and ps <= 4 and math.floor(ps) == ps) and ps or nil
                -- MOVE_SPEED_*, the one field that describes every gait: `anim` knows walking and running, and
                -- `pspeed` reads standing both on foot and on the Acro Bike.
                local ms = (type(st.extras) == "table" and tonumber(st.extras.mspd)) or nil
                r.mspd = (ms and ms >= 0 and ms <= 4 and math.floor(ms) == ms) and ms or nil
                -- The states where the engine does not draw the character; all nil from an older peer.
                local iv = (type(st.extras) == "table" and tonumber(st.extras.invis)) or nil
                r.invis = iv ~= nil and iv ~= 0 or nil
                -- Fed to graphicsInfo, whose range check is the backstop; the receive side refuses an unknown vehicle.
                local bt = (type(st.extras) == "table" and tonumber(st.extras.boat)) or nil
                r.boat = (bt and bt >= 0 and bt <= 255 and math.floor(bt) == bt) and bt or nil
                local fl = (type(st.extras) == "table" and tonumber(st.extras.fly)) or nil
                r.fly = (fl == 1 or fl == 2) and fl or nil
                -- The bird's arc phase: the engine steps it by 4 and wraps at 0x100, so nothing else is a phase.
                local fk = (type(st.extras) == "table" and tonumber(st.extras.flyk)) or nil
                r.flyk = (fk and fk >= 0 and fk < 0x100 and math.floor(fk) == fk) and fk or nil
                -- The door, absent on every frame without one. Bounded: it becomes a grid coordinate the engine will
                -- DMA tiles for, and door.gfxFor's metatile check is the backstop behind this gate.
                local dk = type(st.extras) == "table" and st.extras.dk or nil
                local dx = (type(st.extras) == "table" and tonumber(st.extras.dx)) or nil
                local dy = (type(st.extras) == "table" and tonumber(st.extras.dy)) or nil
                if (dk == "o" or dk == "c" or dk == "h")
                    and dx and dy and dx >= 0 and dy >= 0 and dx < 1024 and dy < 1024
                    and math.floor(dx) == dx and math.floor(dy) == dy then
                    r.dk, r.dx, r.dy = dk, dx, dy
                else
                    r.dk, r.dx, r.dy = nil, nil, nil
                    -- A packet with no door ends a door event: the key (kind, tile) carries no time, so the same
                    -- door used twice would otherwise be suppressed as already seen.
                    r.dKey = nil
                end
            end
        end
    elseif env.type == "despawn_remote" then
        local payload = env.payload
        if type(payload) == "table" and type(payload.player_id) == "string" then
            remotes[payload.player_id] = nil
            -- Here, not in despawnGhost: that returns early unless the peer holds an engine object slot, which the
            -- shipped drawn-only ladder never gives one.
            forgetPeerRenderState(payload.player_id)
        end
    end
end

local function drainBridge()
    while true do
        -- A reject inside handleBridgeLine closes the socket and nils `sock`.
        if not connected or not sock then return end
        -- With settimeout(0) a line split across reads comes back as (nil, "timeout", partial); the partial is
        -- fed back as the next receive's prefix.
        local line, err, partial = sock:receive("*l", recvPartial)
        if line then
            recvPartial = ""
            handleBridgeLine(line)
        elseif err == "timeout" then
            recvPartial = partial or ""
            -- Bounded: a core that never sends a newline grows this, and it is copied into every receive, so the
            -- cost is quadratic. 16 KiB, as Pseudoregalia's buffer: the core's re-wrapped render_remote line can
            -- exceed the relay's 4095-byte state line.
            if #recvPartial > 16384 then
                logFile(string.format("bridge buffered %d bytes with no newline -- reconnecting",
                    #recvPartial))
                recvPartial = ""
                resetBridge()
                remotes = {}
            end
            return
        else
            recvPartial = ""
            logFile(string.format("bridge receive failed: %s (partial %d bytes)", tostring(err),
                partial and #partial or 0))
            resetBridge()
            remotes = {}
            return
        end
    end
end

----------------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------------

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

-- Run-length cache for the drawn tier: each row becomes horizontal runs once per (gender, pose, frame), so drawing
-- costs a gui.drawLine per run, not a drawPixel per pixel. A mirrored frame flips the run endpoints. On genderFrames,
-- not a local: the main chunk is at Lua's 200-local ceiling.
genderFrames.runCache = {}

genderFrames.runsFromPixels = function(pixels)
    -- Bucket by row: the pixel list is not guaranteed row-major.
    local rows = {}
    for i = 1, #pixels do
        local px = pixels[i]
        local row = rows[px.y]
        if not row then row = {} rows[px.y] = row end
        row[px.x] = px.color
    end

    local runs = {}
    for y, row in pairs(rows) do
        local x = 0
        while x < FRAME_WIDTH_PX do
            local color = row[x]
            if color then
                local x2 = x
                while row[x2 + 1] == color do x2 = x2 + 1 end
                runs[#runs + 1] = { y = y, x1 = x, x2 = x2, color = color }
                x = x2 + 1
            else
                x = x + 1
            end
        end
    end
    return runs
end

genderFrames.runsFor = function(gender, pose, frameIndex)
    local __t0 = MESHGHOST_EMERALD_PROFILE and os.clock() or nil
    if __t0 then MG_RF_N = (MG_RF_N or 0) + 1 end
    local key = gender .. ":" .. pose .. ":" .. frameIndex
    local cached = genderFrames.runCache[key]
    if cached then
        if __t0 then MG_RF_T = (MG_RF_T or 0) + (os.clock() - __t0) end
        return cached
    end
    local genderSet = genderFrames[gender] or genderFrames.male
    local runs = genderFrames.runsFromPixels((genderSet[pose] or genderSet.walk)[frameIndex])
    genderFrames.runCache[key] = runs
    if __t0 then MG_RF_T = (MG_RF_T or 0) + (os.clock() - __t0) end
    return runs
end

-- The walker's frame decoded again with the live reflection palette: the cached frames have the ROM palette baked
-- in, and a colour cannot be mapped back to its index. Stamped with the palette's contents, so a fade or map change
-- invalidates it.
genderFrames.walkerReflectRuns = function(gender, pose, frameIndex, palSlot)
    local key = string.format("wr:%s:%s:%d:%d", gender, pose, frameIndex, palSlot & 0x0f)
    local stamp = genderFrames.paletteStamp(palSlot)
    local cached = genderFrames.peerRunCache[key]
    if cached and cached.palStamp == stamp then return cached end
    local off = genderFrames.romOffset or 0
    local pic
    if gender == "female" then
        pic = (pose == "run") and GOBJECTEVENTPIC_MAYRUNNING_ADDR or GOBJECTEVENTPIC_MAYNORMAL_ADDR
    else
        pic = (pose == "run") and GOBJECTEVENTPIC_BRENDANRUNNING_ADDR
            or GOBJECTEVENTPIC_BRENDANNORMAL_ADDR
    end
    -- OBJ palette RAM: 16 palettes of 16 colours, 32 bytes each, from 0x05000200.
    local pal = {}
    for i = 0, 15 do
        -- Not `r16`: that local is declared below this function.
        local c = memory.read_u16_le(0x05000200 + (palSlot & 0x0f) * 32 + i * 2)
        pal[i] = { r = expand5to8(c & 0x1F), g = expand5to8((c >> 5) & 0x1F),
            b = expand5to8((c >> 10) & 0x1F) }
    end
    local runs = genderFrames.runsFromPixels(decodeFramePixels(pic + off, frameIndex, pal))
    runs.palStamp = stamp
    genderFrames.peerRunCache[key] = runs
    return runs
end

local function drawRun(x1, x2, y, color)
    if x2 < x1 then return end
    if x1 == x2 then
        gui.drawPixel(x1, y, color)
    else
        gui.drawLine(x1, y, x2, y, color)
    end
end

-- panelRows[row] is the {x1, x2} the game drew its own UI into on that 8-pixel row (tiering.scanPanel). The clip is
-- per run and per row, so a ghost beside the START menu stays whole and one behind a text box keeps its head.
-- dim is the scene's brightness, 0 to 1: a painted ghost sits on the finished frame and dims only if we scale it.
-- keepSpans applies here too: a peer on foot is drawn from these frames, not its own graphic.
local function drawSpriteFrame(gender, pose, frameIndex, hFlip, screenX, screenY, panelRows, dim,
    keepSpans)
    drawRunList(genderFrames.runsFor(gender, pose, frameIndex), FRAME_WIDTH_PX, hFlip,
        screenX, screenY, panelRows, dim, nil, nil, keepSpans)
end

-- One run list at a screen position, with the panel clip and scene tint both draw paths share. A global: the main
-- chunk is at Lua's 200-local ceiling.
-- vFlipHeight draws the frame upside down in a box that tall (a reflection); xScale scales it about its centre (a
-- rippling reflection); keepSpans[y] lists the only x ranges drawable on screen row y, the opposite of panelRows,
-- because a painted reflection has no OAM priority to sink it under the land.
function drawRunList(runs, frameWidth, hFlip, screenX, screenY, panelRows, dim, vFlipHeight,
    xScale, keepSpans)
    -- Counted so the frame's end can tell a vanish (nothing painted) from a fallback. A bare global: `tiering` is
    -- declared below this function.
    MG_DRAWN_CALLS = (MG_DRAWN_CALLS or 0) + 1
    -- Under the profile flag: passes and runs this frame, to tell many cheap calls from few costly ones.
    local profT0
    if MESHGHOST_EMERALD_PROFILE then
        MG_DRAWN_PASSES = (MG_DRAWN_PASSES or 0) + 1
        MG_DRAWN_RUNS = (MG_DRAWN_RUNS or 0) + #runs
        -- Times this function only, separating the per-run loop from the per-peer setup around it.
        profT0 = os.clock()
    end
    local tintAdd = genderFrames.tintAdd or 0
    local tinting = (dim and dim < 0.99) or tintAdd > 0.5
    local dimM = dim or 1
    for i = 1, #runs do
        local r = runs[i]
        local color = r.color
        -- The scene's blend, c * dim + add, fitted once a frame in drawRemotes; the additive term washes the copy
        -- out in a fade to white, as at a cave mouth.
        if tinting then
            local m, add = dimM, tintAdd
            local rr = math.floor(((color >> 16) & 0xFF) * m + add)
            local gg = math.floor(((color >> 8) & 0xFF) * m + add)
            local bb = math.floor((color & 0xFF) * m + add)
            if rr > 255 then rr = 255 end
            if gg > 255 then gg = 255 end
            if bb > 255 then bb = 255 end
            color = (0xFF << 24) | (rr << 16) | (gg << 8) | bb
        end
        -- The mirror is h - y, not h - 1 - y: the engine's reflection is an affine sprite, and a GBA affine
        -- transform is centred on h/2.
        local y = screenY + (vFlipHeight and (vFlipHeight - r.y) or r.y)
        local x1, x2 = r.x1, r.x2
        if hFlip then x1, x2 = frameWidth - 1 - r.x2, frameWidth - 1 - r.x1 end
        if xScale then
            -- The hardware's mapping, inverted: an affine sprite samples texture = (x - cx) * a / 256 + cx, truncated,
            -- for each screen pixel, so source run [x1, x2] covers [cx + (x1 - cx) * s, cx + (x2 + 1 - cx) * s) with
            -- s = 256 / a. One rounding rule at both ends keeps a one-pixel run one pixel wide while it slides.
            local mid = frameWidth / 2
            local nx1 = math.ceil(mid + (x1 - mid) * xScale)
            local nx2 = math.ceil(mid + (x2 + 1 - mid) * xScale) - 1
            x1, x2 = nx1, nx2
            if x2 < x1 then x2 = x1 end
        end
        local ax1, ax2 = screenX + x1, screenX + x2

        -- A run cut to the water can survive as several pieces; the panel clip runs per piece.
        local pieces = keepSpans and keepSpans[math.floor(y)]
        local nPieces = 1
        if keepSpans then nPieces = pieces and #pieces or 0 end
        for k = 1, nPieces do
            local kx1, kx2 = ax1, ax2
            if pieces then
                local pc = pieces[k]
                if kx1 < pc[1] then kx1 = pc[1] end
                if kx2 > pc[2] then kx2 = pc[2] end
            end
            -- The cave's lit circle is intersected, not subtracted: outside it the hardware shows nothing.
            local fl, fr = genderFrames.flashSpan(y)
            if fl then
                if kx1 < fl then kx1 = fl end
                if kx2 > fr then kx2 = fr end
            end
            if kx1 <= kx2 then
                -- math.floor, not >>: y is a float from the sub-tile smoothing, and >> raises on one.
                local span = panelRows and y >= 0 and panelRows[math.floor(y / 8)]
                if span and kx2 >= span[1] and kx1 <= span[2] then
                    -- Counted (published as clipped=): that the clip ran is not that it did anything.
                    genderFrames.clippedRuns = (genderFrames.clippedRuns or 0) + 1
                    if kx1 < span[1] then
                        drawRun(kx1, math.min(kx2, span[1] - 1), y, color)
                        MG_SPANS = (MG_SPANS or 0) + 1
                    end
                    if kx2 > span[2] then
                        drawRun(math.max(kx1, span[2] + 1), kx2, y, color)
                        MG_SPANS = (MG_SPANS or 0) + 1
                    end
                else
                    drawRun(kx1, kx2, y, color)
                    MG_SPANS = (MG_SPANS or 0) + 1
                end
            end
        end
    end
    if profT0 then MG_DRAWN_LOOP = (MG_DRAWN_LOOP or 0) + (os.clock() - profT0) end
end

-- How far aside the loopback ghost ("<id>-ghost", the relay's -loopback echo) is drawn, so it can be judged beside the
-- player; MESHGHOST_LOOPBACK_TRAIL puts it exactly on the player. Screen position only, never the wire.
local LOOPBACK_GHOST_OFFSET_TILES_X = (os.getenv("MESHGHOST_LOOPBACK_TRAIL") and 0)
    or tonumber(MESHGHOST_LOOPBACK_OFFSET_X or "") or 2
local LOOPBACK_GHOST_OFFSET_TILES_Y = (os.getenv("MESHGHOST_LOOPBACK_TRAIL") and 0)
    or tonumber(MESHGHOST_LOOPBACK_OFFSET_Y or "") or 0

-- MESHGHOST_COMPARE_TIERS (dev): the loopback ghost drawn twice from one state, spawned two tiles right and painted
-- two left, so whatever the painted tier lacks shows in the same frame and lighting.
local COMPARE_TIERS = (MESHGHOST_COMPARE_TIERS or os.getenv("MESHGHOST_COMPARE_TIERS")) and true or false

----------------------------------------------------------------------------
-- Spawning real object events, a dev tier (tiering.budget's cap defaults to 0): a peer as an ObjectEvent plus Sprite
-- that the engine draws, animates and walks. The Sprite is copied from the player's (four ROM pointers) but needs its
-- own VRAM tiles; MovementType_None is the one movement type with no autonomous behaviour that still plays held
-- movements.
----------------------------------------------------------------------------

local MAX_SPRITES = 64
local MAP_OFFSET = 7

-- On a patched build the camera block shifts apart from the save block (genderFrames.camOffset): IWRAM moved almost,
-- not exactly, as one piece.
local GFIELDCAMERA_X_ADDR = 0x03005de0
local GFIELDCAMERA_Y_ADDR = 0x03005de4
local GTOTALCAMERAPIXELOFFSETY_ADDR = 0x03005de8
local GTOTALCAMERAPIXELOFFSETX_ADDR = 0x03005dec

local SSPRITETILEALLOCBITMAP_ADDR = 0x02021b3c
local GRESERVEDSPRITETILECOUNT_ADDR = 0x02021b3a
local GOBJECTEVENTGRAPHICSINFOPOINTERS_ADDR = 0x08505620
local TOTAL_OBJ_TILE_COUNT = 1024
local TILE_SIZE_4BPP = 32

local MOVEMENTTYPE_NONE_CB = 0x0808f3e0 + 1 -- +1 selects Thumb
local MOVEMENT_TYPE_NONE = 0x00

-- Direction ids, and the movement action ids they index (the decompilation's numbering unless a note says measured).
local DIR_ID = { south = 1, north = 2, west = 3, east = 4 }
-- Turning is walk-in-place fast, as the player turns; a face action is a static pose and snaps round unanimated.
local FACE_ACTION = { [1] = 0x21, [2] = 0x22, [3] = 0x23, [4] = 0x24 }
-- Static poses, for placing a ghost at spawn, where there is no previous direction to turn from.
local FACE_STILL_ACTION = { [1] = 0x00, [2] = 0x01, [3] = 0x02, [4] = 0x03 }
-- Bumping a wall: the player's shuffle, played with walk-in-place slow. A bumping peer reports "walking" at a position
-- that never changes.
local BUMP_ACTION = { [1] = 0x19, [2] = 0x1a, [3] = 0x1b, [4] = 0x1c }
-- Frames of walking-but-still before it counts as a bump: a just-finished step looks the same.
local BUMP_AFTER_FRAMES = 20
local WALK_ACTION = { [1] = 0x08, [2] = 0x09, [3] = 0x0a, [4] = 0x0b }
-- PLAYER_RUN, not WALK_FAST (0x15): WALK_FAST reuses the walking frames. The ghost has run frames because it borrows
-- the player's graphics.
local RUN_ACTION = { [1] = 0x35, [2] = 0x36, [3] = 0x37, [4] = 0x38 }

-- A ledge hop is one JUMP_2 action over two tiles, 0x0C + (dir - 1) in DIR_ID order (the decompilation's numbering),
-- written inline below: the main chunk is at Lua's 200-local ceiling.

local function w8(a, v) memory.write_u8(a, v & 0xff) end
local function w16(a, v) memory.write_u16_le(a, v & 0xffff) end
local function w32(a, v) memory.write_u32_le(a, v & 0xffffffff) end
-- Read guard, off unless MESHGHOST_EMERALD_READ_GUARD is set: BizHawk answers a read outside a memory domain with
-- only a console warning and a zero, so the guard reports the first one once, with a traceback naming its line.
-- Globals: the main chunk is at Lua's 200-local ceiling.
function mgReadOK(a)
    return (a >= 0x02000000 and a < 0x02040000)   -- EWRAM
        or (a >= 0x03000000 and a < 0x03008000)   -- IWRAM
        or (a >= 0x05000000 and a < 0x05000400)   -- palette RAM
        or (a >= 0x06000000 and a < 0x06018000)   -- VRAM
        or (a >= 0x07000000 and a < 0x07000400)   -- OAM
        or (a >= 0x08000000 and a < 0x0A000000)   -- cartridge
end

function mgGuard(a)
    if MG_READ_GUARD_FIRED then return end
    MG_READ_GUARD_FIRED = true
    local where = debug.traceback("", 3) or "(no traceback)"
    console.log(string.format(
        "MeshGhost READ GUARD: out-of-range read at %s (%d). Reported ONCE. Stack:%s",
        string.format("%08X", a), a, where))
    local f = io.open(SCRIPT_DIR .. "read_guard.log", "a")
    if f then
        f:write(string.format("out-of-range read at %08X (%d)%s", a, a, where), "\n")
        f:close()
    end
end

local function r8(a)
    if MESHGHOST_EMERALD_READ_GUARD and not mgReadOK(a) then mgGuard(a) return 0 end
    return memory.read_u8(a)
end
local function r16(a)
    if MESHGHOST_EMERALD_READ_GUARD and not mgReadOK(a) then mgGuard(a) return 0 end
    return memory.read_u16_le(a)
end
local function rs16(a)
    if MESHGHOST_EMERALD_READ_GUARD and not mgReadOK(a) then mgGuard(a) return 0 end
    return memory.read_s16_le(a)
end
local function r32(a)
    if MESHGHOST_EMERALD_READ_GUARD and not mgReadOK(a) then mgGuard(a) return 0 end
    return memory.read_u32_le(a)
end

local function objAddr(i) return GOBJECTEVENTS_ADDR + avatarAddrOffset + i * OBJECTEVENT_SIZE end
-- gSprites moves on a patched build as gObjectEvents does; spriteAddrOffset carries the shift.
local function sprAddr(i) return GSPRITES_ADDR + (genderFrames.spriteAddrOffset or 0) + i * SPRITE_SIZE end

local function tileIsAllocated(n)
    return (r8(SSPRITETILEALLOCBITMAP_ADDR + (n // 8)) >> (n % 8)) & 1 == 1
end

local function setTileAllocated(n, on)
    local a = SSPRITETILEALLOCBITMAP_ADDR + (n // 8)
    local v = r8(a)
    if on then v = v | (1 << (n % 8)) else v = v & ~(1 << (n % 8)) end
    w8(a, v)
end

-- First-fit search of the tile bitmap (after the decompilation's AllocSpriteTiles); nil when OBJ VRAM has no run that
-- long, a real outcome on a busy map.
local function allocSpriteTiles(tileCount)
    local i = r16(GRESERVEDSPRITETILECOUNT_ADDR)
    while true do
        while tileIsAllocated(i) do
            i = i + 1
            if i >= TOTAL_OBJ_TILE_COUNT then return nil end
        end
        local start, found = i, 1
        while found ~= tileCount do
            i = i + 1
            if i >= TOTAL_OBJ_TILE_COUNT then return nil end
            if not tileIsAllocated(i) then found = found + 1 else break end
        end
        if found == tileCount then
            for t = start, start + tileCount - 1 do setTileAllocated(t, true) end
            return start
        end
    end
end

-- ROM is 0x08000000-0x09FFFFFF; everything graphicsInfo reads, and everything it points at, is ROM data. Its offsets
-- follow the decompilation's ObjectEventGraphicsInfo, not measured field by field.
local function isRomPtr(p) return p >= 0x08000000 and p <= 0x09ffffff end

-- graphicsId can come from a peer (extras.gfx), and the pointers it yields go into a live sprite, so it is bounded to
-- a u8 (objectEvent.graphicsId) and every pointer must point into ROM, which rejects entries past the table's end.
local function graphicsInfo(graphicsId)
    if type(graphicsId) ~= "number" or graphicsId ~= math.floor(graphicsId)
        or graphicsId < 0 or graphicsId > 255 then
        return nil
    end
    -- romOffset is the Archipelago shift (0 on vanilla); tableOffset is for a build that moves this table apart from
    -- the sprite data (EX SPEEDCHOICE).
    local ptr = r32(GOBJECTEVENTGRAPHICSINFOPOINTERS_ADDR
        + (genderFrames.tableOffset or genderFrames.romOffset or 0)
        + graphicsId * 4)
    if not isRomPtr(ptr) then return nil end
    local size = r16(ptr + 0x06)
    if size == 0 then return nil end
    -- These go into a live sprite for the engine to dereference, so a bad one crashes the game: anims and images must
    -- exist; oam, subsprite tables and affine anims may be null.
    local anims, images = r32(ptr + 0x18), r32(ptr + 0x1c)
    local oam, subs, affine = r32(ptr + 0x10), r32(ptr + 0x14), r32(ptr + 0x20)
    if not isRomPtr(anims) or not isRomPtr(images) then return nil end
    if oam ~= 0 and not isRomPtr(oam) then return nil end
    if subs ~= 0 and not isRomPtr(subs) then return nil end
    if affine ~= 0 and not isRomPtr(affine) then return nil end
    return {
        ptr = ptr,
        paletteTag = r16(ptr + 0x02),
        size = size,
        tileCount = size // TILE_SIZE_4BPP,
        width = r16(ptr + 0x08),
        height = r16(ptr + 0x0a),
        paletteSlot = r8(ptr + 0x0c) & 0x0f,
        -- The struct itself, for shadowSize: bits 4-5 of +0x0C, beside paletteSlot.
        raw = ptr,
        oam = r32(ptr + 0x10),
        subspriteTables = r32(ptr + 0x14),
        anims = r32(ptr + 0x18),
        images = r32(ptr + 0x1c),
        affineAnims = r32(ptr + 0x20),
    }
end

-- Publish an animation the published graphic actually has: the graphic may be held over from a previous frame while
-- the animation is read live, and at a transition they disagree for a frame or two. Falls back to the last coherent
-- pair for this graphic, which the character was just showing.
genderFrames.lastCoherentAnim = {}
genderFrames.coherentAnim = function(gfx, animNum, animIdx)
    local info = gfx and graphicsInfo(gfx)
    if not info or info.anims == 0 or info.images == 0 then return animNum, animIdx end
    local ap = r32(info.anims + (animNum or 0) * 4)
    if isRomPtr(ap) then
        local frame = r32(ap + (animIdx or 0) * 4) & 0xffff
        if isRomPtr(r32(info.images + frame * 8)) then
            genderFrames.lastCoherentAnim[gfx] = { animNum, animIdx }
            return animNum, animIdx
        end
    end
    local prev = genderFrames.lastCoherentAnim[gfx]
    if prev then return prev[1], prev[2] end
    return 0, 0
end


-- Drawing a peer as whatever it is (a bike, a surfer, a rod): anims[animNum][animCmdIndex] gives the image index (low
-- 16 bits; hFlip is bit 22) and images[index] (8 bytes an entry) its pixels, per the decompilation's sprite.h.
-- Colours come from the live OBJ palette at the graphic's slot, wrong only when nothing on the map wears that graphic.
genderFrames.peerRunCache = {}

-- A cheap fingerprint of one live OBJ palette, memoised per frame: the run cache bakes colours in, so it is keyed on
-- what the palette held, or a decode made mid-fade or in a battle stays wrong.
genderFrames.palStamp = {}
genderFrames.palStampFrame = -1
genderFrames.paletteStamp = function(slot)
    slot = slot & 0x0f
    local fc = emu.framecount()
    if genderFrames.palStampFrame ~= fc then
        genderFrames.palStampFrame = fc
        genderFrames.palStamp = {}
    end
    local s = genderFrames.palStamp[slot]
    if s then return s end
    s = 0
    for i = 0, 15 do
        s = (s * 33 + r16(0x05000200 + slot * 32 + i * 2)) % 0x100000000
    end
    genderFrames.palStamp[slot] = s
    return s
end

-- Declared above its first use: a local declared later is a nil global to an earlier function.
local tiering

-- One frame's pixels from an images pointer, size and palette slot; characters, the surf blob and reflections share
-- it. The palette slot belongs in the cache key: a reflection is the same pixels in other colours.
genderFrames.runsFromImages = function(cacheKey, imagesPtr, width, height, imageIndex, paletteSlot)
    local stamp = genderFrames.paletteStamp(paletteSlot)
    local cached = genderFrames.peerRunCache[cacheKey]
    if cached and cached.palStamp == stamp then return cached end

    local pixels = r32(imagesPtr + imageIndex * 8)
    if not isRomPtr(pixels) then return nil end

    -- 4bpp 8x8 tiles, row of tiles by row of tiles.
    local wTiles = width // 8
    local pal = {}
    for i = 0, 15 do
        local c = r16(0x05000200 + (paletteSlot & 0x0f) * 32 + i * 2)
        pal[i] = (0xFF << 24) | (expand5to8(c & 0x1F) << 16)
            | (expand5to8((c >> 5) & 0x1F) << 8) | expand5to8((c >> 10) & 0x1F)
    end

    local runs = {}
    for py = 0, height - 1 do
        local tileRow, localY = py // 8, py % 8
        local x = 0
        while x < width do
            local tileIndex = tileRow * wTiles + (x // 8)
            local b = r8(pixels + tileIndex * 32 + localY * 4 + ((x % 8) // 2))
            local idx = (x % 2 == 0) and (b & 0x0F) or ((b >> 4) & 0x0F)
            if idx ~= 0 then
                local color = pal[idx]
                local x2 = x
                while x2 + 1 < width do
                    local ti = tileRow * wTiles + ((x2 + 1) // 8)
                    local nb = r8(pixels + ti * 32 + localY * 4 + (((x2 + 1) % 8) // 2))
                    local ni = ((x2 + 1) % 2 == 0) and (nb & 0x0F) or ((nb >> 4) & 0x0F)
                    if ni == 0 or pal[ni] ~= color then break end
                    x2 = x2 + 1
                end
                runs[#runs + 1] = { y = py, x1 = x, x2 = x2, color = color }
                x = x2 + 1
            else
                x = x + 1
            end
        end
    end
    -- Stamp the entry, or the check above never matches and every peer re-decodes every frame.
    runs.palStamp = stamp
    genderFrames.peerRunCache[cacheKey] = runs
    return runs
end

-- Declared here because the drawn tier below is its first user. gFieldEffectObjectTemplate_SurfBlob; its frames are
-- 32x32. One table, not a local per constant: the main chunk is at Lua's 200-local ceiling.
local surfBlob = {}
surfBlob.template = 0x0850cbc4
surfBlob.framePx = 32
-- The water ripple's frame is 16x16. A field, not a local, for the same ceiling.
genderFrames.rippleFramePx = 16

-- gOamMatrices: entries 0 and 1 (four s16 each) are what a moving reflection is drawn through (reflectionXScale).
genderFrames.oamMatricesAddr = 0x02021bc0

-- The surf blob for the drawn tier, which has no engine sprite to follow: one image per facing, east being west
-- mirrored (south measured; the rest follow the decompilation). The palette comes from the template's tag through
-- the engine's table, slot 0 only as a fallback: a show-mon effect at a surf start can take the slot we assumed.
genderFrames.blobPaletteSlot = 0
genderFrames.blobPalette = function()
    return hwPaletteSlotForTag(r16(surfBlob.template + 0x02))
        or genderFrames.blobPaletteSlot
end
-- The reverse of FACING, so a peer's orientation string picks the blob's animation.
genderFrames.dirOf = { south = 1, north = 2, west = 3, east = 4 }
genderFrames.blobDirImage = { [1] = 0, [2] = 1, [3] = 2, [4] = 2 }

genderFrames.runsForSurfBlob = function(facing)
    local imageIndex = genderFrames.blobDirImage[facing or 1] or 0
    local images = r32(surfBlob.template + 0x0c)
    if not isRomPtr(images) then return nil end
    local runs = genderFrames.runsFromImages(
        string.format("blob:%d", imageIndex), images,
        surfBlob.framePx, surfBlob.framePx, imageIndex, genderFrames.blobPalette())
    -- East is the west frame mirrored, which is the flag the anim command carries.
    return runs, (facing == 4)
end

-- A dark cave is window 0: a lit span per scanline in the scanline-effect buffer sent to WIN0H. Painting after the
-- PPU sees no window, so each painted row is intersected with its span, but only while gScanlineEffect targets WIN0H
-- and runs (an all-zero buffer otherwise means nothing lit). Vanilla addresses only: on a patched ROM it declines.
genderFrames.flashCheckedAt, genderFrames.flashBuf = -100, nil
genderFrames.flashSpan = function(y)
    if frameCounter ~= genderFrames.flashCheckedAt then
        genderFrames.flashCheckedAt = frameCounter
        genderFrames.flashBuf = nil
        if avatarAddrOffset == 0
            and r32(0x02039b28 + 0x08) == 0x04000040
            and r8(0x02039b28 + 0x15) ~= 0
        then
            genderFrames.flashBuf = 0x02038c28 + (r8(0x02039b28 + 0x14) & 1) * 0x3c0 * 2
        end
    end
    if not genderFrames.flashBuf then return nil end
    local row = math.floor(y)
    if row < 0 or row > 159 then return nil end
    local v = r16(genderFrames.flashBuf + row * 2)
    -- WIN0H is (left << 8) | right, and the right edge is exclusive.
    return v >> 8, (v & 0xff) - 1
end

-- The image the peer is showing: its graphic's anim table at animNum, then animCmdIndex, low half. nil when
-- unreadable, as for a peer mid-swap whose animNum belongs to the graphic it is leaving.
genderFrames.peerImageIndex = function(remote)
    local gi = graphicsInfo(remote.gfx or 0)
    if not gi or gi.anims == 0 then return nil end
    local ap = r32(gi.anims + (remote.sanim or 0) * 4)
    if not isRomPtr(ap) then return nil end
    return r32(ap + (remote.sidx or 0) * 4) & 0xffff
end

-- A moving reflection is drawn through OAM matrix 0 (1 when flipped), whose a swings around 256, so its width is
-- width * 256 / a, read live rather than reproduced. An ice reflection never turns affine on, so 1.0.
genderFrames.reflectionXScale = function(kind)
    if kind == "ice" then return 1.0 end
    local a = rs16(genderFrames.oamMatricesAddr)
    if a == 0 then return 1.0 end
    return 256.0 / math.abs(a)
end


-- Which pixels of a metatile cover a sprite: a 16-row bitmask per metatile, decoded once from VRAM (the tileset's own
-- data is usually compressed in ROM) and dropped when the layout changes. A metatile is 8 tilemap entries, four
-- bottom layer then four top, each 2x2 in reading order (the decompilation's layout).
genderFrames.coverCache = {}
genderFrames.coverLayout = nil

-- BG1/BG2/BG3 read back at priorities 1/2/3, and OBJ wins ties. Taking a character at priority 2 and a reflection
-- at 3 (the decompilation's reading), by layer type:
--   NORMAL  (0) ground BG2, top BG1: a character is hidden by the top layer, a reflection by both.
--   COVERED (1) ground BG3, top BG2: a character by nothing, a reflection by the top layer.
--   SPLIT   (2) ground BG3, top BG1: both by the top layer.
genderFrames.layerTypeOf = function(metatileId)
    if not metatileId then return nil end
    local layout = genderFrames.mapLayoutPtr()
    if not layout then return nil end
    local tileset, index
    if metatileId < 512 then
        tileset, index = r32(layout + 0x10), metatileId
    else
        tileset, index = r32(layout + 0x14), metatileId - 512
    end
    if tileset == 0 then return nil end
    local attrs = r32(tileset + 0x10)
    if attrs == 0 then return nil end
    return (r16(attrs + index * 2) >> 12) & 0x0f
end

genderFrames.coverMask = function(metatileId, who)
    local key = (who or "reflection") .. metatileId
    local cached = genderFrames.coverCache[key]
    if cached ~= nil then return cached end

    local layout = genderFrames.mapLayoutPtr()
    if not layout then genderFrames.coverCache[key] = false return false end
    local tileset, index
    if metatileId < 512 then
        tileset, index = r32(layout + 0x10), metatileId
    else
        tileset, index = r32(layout + 0x14), metatileId - 512
    end
    if tileset == 0 then genderFrames.coverCache[key] = false return false end
    local metatiles = r32(tileset + 0x0c)
    local attrs = r32(tileset + 0x10)
    if metatiles == 0 or attrs == 0 then
        genderFrames.coverCache[key] = false
        return false
    end
    local layerType = (r16(attrs + index * 2) >> 12) & 0x0f

    local rows = {}
    for i = 0, 15 do rows[i] = 0 end
    local layers
    if who == "sprite" then
        layers = (layerType == 1) and {} or { 4 }   -- COVERED hides a character not at all
    else
        layers = (layerType == 0) and { 0, 4 } or { 4 }
    end
    for _, lay in ipairs(layers) do
        for quad = 0, 3 do
            local e = r16(metatiles + (index * 8 + lay + quad) * 2)
            local tileIndex = e & 0x03ff
            local hflip, vflip = (e & 0x0400) ~= 0, (e & 0x0800) ~= 0
            local ox, oy = (quad % 2) * 8, (quad // 2) * 8
            for py = 0, 7 do
                local sy = vflip and (7 - py) or py
                local w0 = r16(0x06000000 + tileIndex * 32 + sy * 4)
                local w1 = r16(0x06000000 + tileIndex * 32 + sy * 4 + 2)
                local row = rows[oy + py]
                for px = 0, 7 do
                    local sx = hflip and (7 - px) or px
                    -- A 4bpp row is four bytes for eight pixels: pixel sx is in byte sx // 2.
                    local bi = sx // 2
                    local byte
                    if bi < 2 then byte = (w0 >> (bi * 8)) & 0xff
                    else byte = (w1 >> ((bi - 2) * 8)) & 0xff end
                    -- Two pixels per byte, low nibble first.
                    local v = (sx % 2 == 0) and (byte & 0x0f) or ((byte >> 4) & 0x0f)
                    if v ~= 0 then row = row | (1 << (ox + px)) end
                end
                rows[oy + py] = row
            end
        end
    end
    genderFrames.coverCache[key] = rows
    return rows
end

----------------------------------------------------------------------------
-- The occlusion chain (map grid -> metatile id -> gMapHeader -> tileset -> attributes) starts at two addresses that
-- patched builds move, so both are found: the grid by the player standing inside it, then the header as the word
-- pointing at a ROM layout whose width and height are the grid's minus 15 and 14 (the decompilation's margins).
genderFrames.MAP_OFFSET_W, genderFrames.MAP_OFFSET_H = 15, 14
genderFrames.EWRAM_LO, genderFrames.EWRAM_HI = 0x02000000, 0x02040000

-- gBackupMapLayout { s32 width, s32 height, u16 *map }, scanned for in IWRAM because builds move it.
genderFrames.gridAddr = function()
    if genderFrames.gridAt ~= nil then return genderFrames.gridAt end
    if genderFrames.gridNext and frameCounter < genderFrames.gridNext then return nil end
    local sb1 = session.saveBlockPtr(0x03005d8c)
    if sb1 == 0 then return nil end
    local px = memory.read_s16_le(sb1 + 0x00) + MAP_OFFSET
    local py = memory.read_s16_le(sb1 + 0x02) + MAP_OFFSET
    local function looks(a)
        local w, h, m = memory.read_s32_le(a), memory.read_s32_le(a + 0x04), r32(a + 0x08)
        return w > MAP_OFFSET * 2 and h > MAP_OFFSET * 2 and w < 1024 and h < 1024
            and m >= genderFrames.EWRAM_LO and m < genderFrames.EWRAM_HI and (m % 2) == 0
            and px >= 0 and py >= 0 and px < w and py < h
    end
    if looks(0x03005dc0) then genderFrames.gridAt = 0x03005dc0 return genderFrames.gridAt end
    local found, count = nil, 0
    for a = 0x03000000, 0x03008000 - 12, 4 do
        if looks(a) then
            count = count + 1
            if found == nil or math.abs(a - 0x03005dc0) < math.abs(found - 0x03005dc0) then
                found = a
            end
        end
    end
    if found then
        genderFrames.gridAt = found
        logFile(string.format("f=%d MAP grid at %08X (%+d), %d candidate(s)", frameCounter, found,
            found - 0x03005dc0, count))
        return found
    end
    -- Unresolved is usually this moment (a load, the title screen), not this build: retry spaced.
    genderFrames.gridNext = frameCounter + 120
    return nil
end

-- gMapHeader's mapLayout pointer, re-verified every frame: a copy elsewhere in EWRAM answers as well while current
-- and goes stale when the map changes.
genderFrames.mapLayoutPtr = function()
    -- Once a frame, not per call: this sits under attrAt, once per tile per peer per frame.
    if genderFrames.mhFrame == frameCounter then return genderFrames.mhLayout end
    genderFrames.mhFrame = frameCounter
    genderFrames.mhLayout = nil
    local grid = genderFrames.gridAddr()
    if not grid then return nil end
    local bw = memory.read_s32_le(grid) - genderFrames.MAP_OFFSET_W
    local bh = memory.read_s32_le(grid + 0x04) - genderFrames.MAP_OFFSET_H
    if bw <= 0 or bh <= 0 then return nil end
    local function layoutAt(a)
        local layout = r32(a)
        if not isRomPtr(layout) then return nil end
        if memory.read_s32_le(layout) ~= bw or memory.read_s32_le(layout + 0x04) ~= bh then
            return nil
        end
        local prim, sec = r32(layout + 0x10), r32(layout + 0x14)
        if not isRomPtr(prim) then return nil end
        if sec ~= 0 and not isRomPtr(sec) then return nil end
        return layout
    end

    if genderFrames.mhAt then
        local layout = layoutAt(genderFrames.mhAt)
        if layout then genderFrames.mhLayout = layout return layout end
        genderFrames.mhAt = nil   -- stale: this word is not tracking the live map
    end
    if genderFrames.mhNext and frameCounter < genderFrames.mhNext then return nil end
    local layout = layoutAt(0x02037318)
    if layout then
        genderFrames.mhAt, genderFrames.mhLayout = 0x02037318, layout
        return layout
    end
    local found, count = nil, 0
    for a = genderFrames.EWRAM_LO, genderFrames.EWRAM_HI - 4, 4 do
        if layoutAt(a) then
            count = count + 1
            if found == nil or math.abs(a - 0x02037318) < math.abs(found - 0x02037318) then
                found = a
            end
        end
    end
    if found then
        genderFrames.mhAt = found
        logFile(string.format("f=%d MAP header at %08X (%+d), %d candidate(s)", frameCounter,
            found, found - 0x02037318, count))
        genderFrames.mhLayout = layoutAt(found)
        return genderFrames.mhLayout
    end
    genderFrames.mhNext = frameCounter + 120
    return nil
end
----------------------------------------------------------------------------

-- Whether the map can be read on this build at all; if not, painted ghosts go without occlusion, logged once.
genderFrames.mapReadable = function()
    local grid = genderFrames.gridAddr()
    if not grid then return false end
    local width = memory.read_s32_le(grid)
    local height = memory.read_s32_le(grid + 0x04)
    local map = r32(grid + 0x08)
    -- mapLayoutPtr has already proved the layout is a ROM pointer matching this grid, with a real primary tileset.
    local layout = genderFrames.mapLayoutPtr()
    local ok = layout ~= nil and map ~= 0 and width > 0 and height > 0
        and width < 1024 and height < 1024
    if not ok and not genderFrames.mapUnreadableLogged then
        genderFrames.mapUnreadableLogged = true
        console.log("MeshGhost: this adapter cannot find the map layout on this build, so painted "
            .. "ghosts are drawn WITHOUT occlusion (they will not be hidden by scenery). "
            .. "Everything else is unaffected. Logged once.")
    end
    return ok
end

genderFrames.metatileAt = function(x, y)
    local grid = genderFrames.gridAddr()
    if not grid then return nil end
    local width = memory.read_s32_le(grid)
    local map = r32(grid + 0x08)
    if map == 0 or width <= 0 then return nil end
    local height = memory.read_s32_le(grid + 0x04)
    if x < 0 or y < 0 or x >= width or y >= height then return nil end
    return r16(map + (x + width * y) * 2) & 0x03ff
end

-- The metatile behaviours the engine draws a reflection over, and which kind: ice holds still, water ripples.
genderFrames.reflectiveBehaviour = {
    [16] = "water", [20] = "water", [22] = "water", [26] = "water",
    [32] = "ice",
    [43] = "water",
}

-- The engine's reflection scan: a region about the graphic's size from one row below the character, at its previous
-- coordinates as well as its current ones, so a reflection slides off under the bank instead of cutting out. Grid
-- coordinates; prev may be nil.
genderFrames.hasReflection = function(x, y, px, py, w, h)
    for i = 0, (h or 2) - 1 do
        for pass = 1, (px and 2 or 1) do
            local cx, cy = x, y
            if pass == 2 then cx, cy = px, py end
            for j = 0, (w or 2) - 1 do
                -- j = 0 is the character's own column; past it both sides, +j then -j.
                for k = 1, (j == 0 and 1 or 2) do
                    local dx = (k == 1) and j or -j
                    local attr = genderFrames.attrAt(cx + dx, cy + 1 + i)
                    -- The first tile with a kind wins, as the engine's scan returns at each step.
                    local kind = attr and genderFrames.reflectiveBehaviour[attr & 0xff]
                    if kind then return kind end
                end
            end
        end
    end
    return false
end

-- The metatile attributes at a grid coordinate: the grid gives a metatile id, and the tileset owning it (primary
-- below 512) holds its attributes.
genderFrames.attrAt = function(x, y)
    -- mapReadable first: a non-zero header that is not a pointer would be read through once per tile per peer per
    -- frame.
    if not genderFrames.mapReadable() then return nil end
    local grid = genderFrames.gridAddr()
    if not grid then return nil end
    local width = memory.read_s32_le(grid)
    local map = r32(grid + 0x08)
    if map == 0 or width <= 0 then return nil end
    local height = memory.read_s32_le(grid + 0x04)
    if x < 0 or y < 0 or x >= width or y >= height then return nil end
    local metatileId = r16(map + (x + width * y) * 2) & 0x03ff
    local layout = genderFrames.mapLayoutPtr()
    if not layout then return nil end
    local tileset, index
    if metatileId < 512 then
        tileset, index = r32(layout + 0x10), metatileId
    else
        tileset, index = r32(layout + 0x14), metatileId - 512
    end
    if tileset == 0 then return nil end
    local attrs = r32(tileset + 0x10)
    if attrs == 0 then return nil end
    return r16(attrs + index * 2)
end

-- The screen-to-grid origin, the inverse of the drawn tier's placement; FRAME_HEIGHT_PX - TILE because a character
-- stands on its frame's bottom tile.
genderFrames.gridBase = function()
    local ax, ox = tiering.anchorX, tiering.originXStill
    local ay, oy = tiering.anchorY, tiering.originYStill
    if not (ax and ox and ay and oy) then return nil end
    return ox + rs16(GTOTALCAMERAPIXELOFFSETX_ADDR + (genderFrames.camOffset or 0)) - (ax + MAP_OFFSET) * TILE,
        oy + rs16(GTOTALCAMERAPIXELOFFSETY_ADDR + (genderFrames.camOffset or 0)) + (FRAME_HEIGHT_PX - TILE)
            - (ay + MAP_OFFSET) * TILE
end

-- Tall grass is a field-effect sprite drawn over the character, not a BG layer (the grass metatile's top layer is
-- empty), so the painted tier draws it from the effect's own art. Templates by metatile behaviour: tall 2, long 3.
genderFrames.grassTemplate = { [2] = 0x0850caa0, [3] = 0x0850cf94 }

-- One pass of grass for a peer, over the tiles its feet overlap in rows rowFrom..rowTo: called for the row above
-- before the character is drawn and for its own row and below after, the engine's subpriority order. topLimit bounds
-- how far up it paints, so a sliver of hat stays visible at every step phase.
genderFrames.drawGrassRows = function(playerId, gbX, gbY, left, footY, rowFrom, rowTo, panelRows,
    dim, topLimit)
    local clip = nil
    if topLimit then
        clip = {}
        for y = math.floor(topLimit), math.floor(topLimit) + 3 * TILE do
            clip[y] = { { -9999, 9999 } }
        end
    end
    tiering.grassTiles = tiering.grassTiles or {}
    local st = tiering.grassTiles[playerId] or {}
    local x0 = math.floor((left - gbX) / TILE)
    local x1 = math.floor((left + FRAME_WIDTH_PX - 1 - gbX) / TILE)
    for gy = rowFrom, rowTo do
        for gx = x0, x1 do
            local key = gx .. "," .. gy
            local e = st[key]
            -- Not drawn last frame means just stepped on, when the game spawns its sprite, so the rustle restarts.
            if not e or (frameCounter - e[2]) > 1 then e = { frameCounter, frameCounter } end
            e[2] = frameCounter
            st[key] = e
            local attr = genderFrames.attrAt(gx, gy)
            local beh = attr and (attr & 0xff)
            local runs = beh and genderFrames.grassRuns(beh,
                genderFrames.grassFrameAt(beh, frameCounter - e[1]))
            if runs then
                drawRunList(runs, TILE, false, gbX + gx * TILE, gbY + gy * TILE, panelRows,
                    dim, nil, nil, clip)
            end
        end
    end
    -- Drop what this peer has walked away from, so the table cannot grow all session.
    for k, v in pairs(st) do
        if frameCounter - v[2] > 300 then st[k] = nil end
    end
    tiering.grassTiles[playerId] = st
end

-- Landing dust, painted: the drawn tier has no engine to spawn it. The spawned tier paints it only while its shadow is
-- painted rather than a sprite (shadowSpriteEnabled), since a painted shadow covers the engine's own puff.
genderFrames.dustTemplate = 0x0850cca0

genderFrames.dustRuns = function(frame)
    local images = r32(genderFrames.dustTemplate + 0x0c)
    if not isRomPtr(images) then return nil end
    -- The palette by tag, as the engine's IndexOfSpritePaletteTag does: scanning for a live dust sprite fails when
    -- nobody else is landing. 0x1004 is the decompilation's FLDEFF_PAL_TAG_GENERAL_0, not read off the template.
    local pal = hwPaletteSlotForTag(0x1004)
    if not pal then return nil end
    -- 16x8, from the template's own OAM shape (gObjectEventBaseOam_16x8).
    return genderFrames.runsFromImages(string.format("dust:%d:%d", pal, frame),
        images, TILE, TILE // 2, frame, pal)
end

-- The frame of a landing `elapsed` frames ago, walked from the template's animation commands; nil once it is over.
genderFrames.dustFrameAt = function(elapsed)
    local anims = r32(genderFrames.dustTemplate + 0x08)
    if not isRomPtr(anims) then return nil end
    local list = r32(anims)
    if not isRomPtr(list) then return nil end
    local t = elapsed
    for i = 0, 15 do
        local cmd = r32(list + i * 4)
        local img = cmd & 0xffff
        if img == 0xffff then return nil end       -- ANIMCMD_END: the puff is over
        local dur = (cmd >> 16) & 0x3f
        if dur == 0 then dur = 1 end
        if t < dur then return img end
        t = t - dur
    end
    return nil
end

-- The water trail: a ripple field effect, painted for both self-drawn tiers. One per tile stepped while surfing,
-- fixed where it was born, its frames walked from the template's own animation commands.
genderFrames.rippleTemplate = 0x0850cb08

-- The frame of a ripple born `elapsed` frames ago; nil once it is over.
genderFrames.rippleFrameAt = function(elapsed)
    local anims = r32(genderFrames.rippleTemplate + 0x08)
    if not isRomPtr(anims) then return nil end
    local list = r32(anims)
    if not isRomPtr(list) then return nil end
    local t = elapsed
    for i = 0, 15 do
        local cmd = r32(list + i * 4)
        local img = cmd & 0xffff
        if img == 0xffff then return nil end       -- ANIMCMD_END: the ripple is over
        local dur = (cmd >> 16) & 0x3f
        if dur == 0 then dur = 1 end
        if t < dur then return img end
        t = t - dur
    end
    return nil
end

genderFrames.rippleRuns = function(frame)
    local images = r32(genderFrames.rippleTemplate + 0x0c)
    if not isRomPtr(images) then return nil end
    -- The palette by tag, as for the dust.
    local pal = hwPaletteSlotForTag(r16(genderFrames.rippleTemplate + 0x02))
    if not pal then return nil end
    return genderFrames.runsFromImages(string.format("ripple:%d:%d", pal, frame),
        images, genderFrames.rippleFramePx, genderFrames.rippleFramePx, frame, pal)
end

-- Due when this peer is surfing and its drawn tile changed this frame (the reflection's previous-tile store stamps
-- it; one store per tier). `surfing` is passed in: SURFING_GFX is declared below.
genderFrames.rippleDue = function(store, playerId, surfing)
    if not surfing then return false end
    local e = store[playerId]
    return e ~= nil and e[4] == frameCounter
end

-- Frames per bounce for acro actions that repeat under a held B while reporting one id (wheelie hops 16, wheelie
-- jumps 32, the decompilation's periods): there is no air-to-ground edge to latch dust on. A ledge hop or side hop
-- has its own edge, so nil; counting a side hop strung puffs out behind the ghost.
genderFrames.hopFrames = function(act)
    if act == nil then return nil end
    if act >= 0x70 and act <= 0x77 then return 16 end
    if act >= 0x78 and act <= 0x7b then return 32 end
    return nil
end


-- Returns the newest landing's dust frame (nil once played out) and a landed-this-frame edge, so every tier
-- puffs on the same frame; the edge reads `at == frameCounter` because three tiers ask and only one advances it.
genderFrames.noteLanding = function(playerId, jumping, act)
    tiering.landed = tiering.landed or {}
    local e = tiering.landed[playerId]
    local period = jumping and genderFrames.hopFrames(act)
    if jumping then
        if not (e and e.air) then
            tiering.landed[playerId] = { air = true, airAt = frameCounter, at = (e and e.at) or nil }
        elseif period and e.airAt and frameCounter - e.airAt >= period then
            -- A bounce ended with the action unchanged (B held): still airborne, but it touched ground.
            tiering.landed[playerId] = { air = true, airAt = frameCounter, at = frameCounter }
        end
    elseif e and e.air then
        tiering.landed[playerId] = { air = false, at = frameCounter }
    end
    local cur = tiering.landed[playerId]
    local f = cur and cur.at and genderFrames.dustFrameAt(frameCounter - cur.at) or nil
    return f, (cur ~= nil and cur.at == frameCounter) or false
end

-- The grass effect's image index `elapsed` frames into its animation: the last once played out, 0 if unknown.
genderFrames.grassFrameAt = function(behaviour, elapsed)
    local tmpl = genderFrames.grassTemplate[behaviour]
    if not tmpl then return 0 end
    local anims = r32(tmpl + 0x08)
    if not isRomPtr(anims) then return 0 end
    local list = r32(anims)
    if not isRomPtr(list) then return 0 end
    local t, last = elapsed, 0
    for i = 0, 15 do
        local cmd = r32(list + i * 4)
        local img = cmd & 0xffff
        if img == 0xffff then break end            -- ANIMCMD_END
        local dur = (cmd >> 16) & 0x3f
        if dur == 0 then dur = 1 end
        last = img
        if t < dur then return img end
        t = t - dur
    end
    return last
end

genderFrames.grassRuns = function(behaviour, frame)
    local tmpl = genderFrames.grassTemplate[behaviour]
    if not tmpl then return nil end
    local images = r32(tmpl + 0x0c)
    if not isRomPtr(images) then return nil end
    -- Find a live sprite already drawing this effect and take its palette slot.
    local pal = nil
    for i = 0, 63 do
        local d = sprAddr(i)
        if (r8(d + 0x3e) & 0x01) ~= 0 and r32(d + 0x0c) == images then
            pal = (r16(d + 0x04) >> 12) & 0x0f
            break
        end
    end
    if not pal then return nil end
    frame = frame or 0
    return genderFrames.runsFromImages(string.format("grass%d:%d:%d", behaviour, pal, frame),
        images, TILE, TILE, frame, pal)
end

-- reflectiveSpans' buffers, one per call site since its result escapes; a site's result must be dead before it asks
-- again. The pool sits beside the result, never in it: `hwet`'s consumer walks the result with pairs().
genderFrames.scHwet = function()
    genderFrames.__scHwet = genderFrames.__scHwet or genderFrames.newSpanScratch()
    return genderFrames.__scHwet
end

genderFrames.scWet = function()
    genderFrames.__scWet = genderFrames.__scWet or genderFrames.newSpanScratch()
    return genderFrames.__scWet
end

genderFrames.scBlob = function()
    genderFrames.__scBlob = genderFrames.__scBlob or genderFrames.newSpanScratch()
    return genderFrames.__scBlob
end

genderFrames.scOccl = function()
    genderFrames.__scOccl = genderFrames.__scOccl or genderFrames.newSpanScratch()
    return genderFrames.__scOccl
end

genderFrames.scWwet = function()
    genderFrames.__scWwet = genderFrames.__scWwet or genderFrames.newSpanScratch()
    return genderFrames.__scWwet
end

genderFrames.scWalk = function()
    genderFrames.__scWalk = genderFrames.__scWalk or genderFrames.newSpanScratch()
    return genderFrames.__scWalk
end

genderFrames.newSpanScratch = function()
    return { map = {}, pool = {} }
end

-- Per pixel row of the box, the {x1, x2} spans the background does not cover; nil means no restriction.
-- `sc` is optional: without it this allocates per call, so a new call site is correct by default.
genderFrames.reflectiveSpans = function(left, top, width, height, who, sc)
    -- Timed here so every call site counts; no closure, which would allocate in the tier's hottest path.
    local __t0
    if MESHGHOST_EMERALD_PROFILE then
        MG_RSPANS_N = (MG_RSPANS_N or 0) + 1
        -- Per caller, so a call computed and discarded shows apart from the body's.
        MG_RSPANS_BY = MG_RSPANS_BY or {}
        local k = tostring(who)
        MG_RSPANS_BY[k] = (MG_RSPANS_BY[k] or 0) + 1
        __t0 = os.clock()
    end
    -- The grid comes from the still origin, never playerScreenY: the player's sprite position carries pos2,
    -- which is the surf bob. MAP_OFFSET is folded in, so tx and ty are the grid coordinates lookups take.
    local baseX, baseY = genderFrames.gridBase()
    if not baseX then
        if __t0 then MG_RSPANS_T = (MG_RSPANS_T or 0) + (os.clock() - __t0) end
        return nil
    end

    -- An unknown metatile covers, but a map this build cannot read restricts nothing: covering there would clip
    -- away every run and hide every ghost.
    if not genderFrames.mapReadable() then
        if __t0 then MG_RSPANS_T = (MG_RSPANS_T or 0) + (os.clock() - __t0) end
        return nil
    end
    local txMin = math.floor((left - baseX) / TILE)
    local txMax = math.floor((left + width - 1 - baseX) / TILE)
    local tyMin = math.floor((top - baseY) / TILE)
    local tyMax = math.floor((top + height - 1 - baseY) / TILE)

    -- Drop the decoded masks when the layout changes: a metatile id means something else under new tilesets.
    local layout = genderFrames.mapLayoutPtr()
    if not layout then
        if __t0 then MG_RSPANS_T = (MG_RSPANS_T or 0) + (os.clock() - __t0) end
        return nil
    end
    if genderFrames.coverLayout ~= layout then
        genderFrames.coverCache, genderFrames.coverLayout = {}, layout
    end

    local gxMin = math.floor((left - baseX) / TILE)
    local gxMax = math.floor((left + width - 1 - baseX) / TILE)
    -- Last call's rows go back to the pool and their keys are cleared: keys are absolute pixel rows, so a row
    -- left behind would read as a real answer for a row this call never looked at.
    local spans, pool
    if sc then
        spans, pool = sc.map, sc.pool
        for k, row in pairs(spans) do
            pool[#pool + 1] = row
            spans[k] = nil
        end
    else
        spans = {}
    end
    -- The metatile row is fetched once per tile row: `gy` only changes every 16 pixel rows.
    local maskGy, maskArr = nil, {}
    for py = math.floor(top), math.floor(top) + height - 1 do
        local gy = math.floor((py - baseY) / TILE)
        local inTile = py - baseY - gy * TILE
        if gy ~= maskGy then
            maskGy = gy
            local n = 0
            for gx = gxMin, gxMax do
                n = n + 1
                local id = genderFrames.metatileAt(gx, gy)
                -- `false` rather than nil keeps the array dense for the loop below.
                maskArr[n] = (id and genderFrames.coverMask(id, who)) or false
            end
        end
        local list, openFrom = nil, nil
        local nSpans = 0
        if pool and #pool > 0 then
            list = pool[#pool]
            pool[#pool] = nil
        else
            list = {}
        end
        for gx = gxMin, gxMax do
            local mask = maskArr[gx - gxMin + 1]
            -- true covers everywhere, a table is per pixel, and nil or false (off the map, undecoded) covers too:
            -- an unknown never becomes a reason to paint.
            local rowBits = 0xffff
            if type(mask) == "table" then rowBits = mask[inTile] or 0xffff end
            local tileLeft = baseX + gx * TILE
            -- Fast paths for an all-covering and an all-open row, exactly what the bit loop does for them; a
            -- partly covering tile (a bank, a ledge, a roof lip) still walks all 16 bits.
            if rowBits == 0xffff then
                if openFrom then
                    nSpans = nSpans + 1
                    local pair = list[nSpans]
                    if pair then
                        pair[1], pair[2] = openFrom, tileLeft - 1
                    else
                        list[nSpans] = { openFrom, tileLeft - 1 }
                    end
                    openFrom = nil
                end
            elseif rowBits == 0 then
                if not openFrom then openFrom = tileLeft end
            else
                for bx = 0, TILE - 1 do
                    if (rowBits >> bx) & 1 == 0 then
                        if not openFrom then openFrom = tileLeft + bx end
                    elseif openFrom then
                        -- Written into the existing pair: a row usually keeps its span count frame to frame.
                        nSpans = nSpans + 1
                        local pair = list[nSpans]
                        if pair then
                            pair[1], pair[2] = openFrom, tileLeft + bx - 1
                        else
                            list[nSpans] = { openFrom, tileLeft + bx - 1 }
                        end
                        openFrom = nil
                    end
                end
            end
        end
        if openFrom then
            nSpans = nSpans + 1
            local pair = list[nSpans]
            if pair then
                pair[1], pair[2] = openFrom, baseX + (gxMax + 1) * TILE - 1
            else
                list[nSpans] = { openFrom, baseX + (gxMax + 1) * TILE - 1 }
            end
        end
        -- Trimmed from the end: consumers walk these with ipairs, so a leftover pair would be painted.
        for i = #list, nSpans + 1, -1 do
            list[i] = nil
        end
        spans[py] = list
    end
    if __t0 then MG_RSPANS_T = (MG_RSPANS_T or 0) + (os.clock() - __t0) end
    return spans
end

-- The engine's reflection test, asked where the tier draws, with the caller's own previous-tile table. The previous
-- tile expires after one step (16 frames), or a ghost parked at the shore reflects across the bank.
genderFrames.reflectPalFor = function(store, playerId, areaId, ggx, ggy, wTiles, hTiles, palSlot)
    local lt = store[playerId]
    if lt and (lt[3] ~= areaId or frameCounter - lt[4] > 16) then lt = nil end
    local yes = genderFrames.hasReflection(ggx, ggy, lt and lt[1], lt and lt[2], wTiles, hTiles)
    local cur = store[playerId]
    -- Slots 1,2 are the tile stepped from and 5,6 the current one, rotated in place.
    if not cur then
        store[playerId] = { ggx, ggy, areaId, frameCounter, ggx, ggy }
    elseif cur[5] ~= ggx or cur[6] ~= ggy then
        local fromX, fromY = cur[5], cur[6]
        cur[1], cur[2], cur[3], cur[4], cur[5], cur[6] =
            fromX, fromY, areaId, frameCounter, ggx, ggy
    end
    -- The kind is the second value: an ice reflection is still and a water one ripples.
    return yes and genderFrames.reflectionPalette[(palSlot or 0) & 0x0f] or nil, yes or nil
end

genderFrames.reflectionPalette = {
    -- The whole table, so a graphic in an NPC slot reflects in its own colours; reflection slots map to themselves.
    [0] = 1, [1] = 1, [2] = 6, [3] = 7, [4] = 8, [5] = 9,
    [6] = 6, [7] = 7, [8] = 8, [9] = 9, [10] = 11, [11] = 11,
}


genderFrames.runsForPeerGfx = function(gfx, animNum, animIdx)
    local info = graphicsInfo(gfx)
    if not info or info.anims == 0 or info.images == 0 then return nil end

    local animPtr = r32(info.anims + (animNum or 0) * 4)
    if not isRomPtr(animPtr) then return nil end
    local cmd = r32(animPtr + (animIdx or 0) * 4)
    local imageIndex = cmd & 0xFFFF
    local hFlip = ((cmd >> 22) & 1) == 1
    -- An end or jump command is a marker, not a frame: its value is out of range for the graphic's image count.
    local frameCount = info.size > 0 and (info.width * info.height // 2) or 0
    if frameCount == 0 then return nil end
    -- A peer can report an index on a marker: walk back to the last real frame, which is what the engine shows,
    -- rather than give up and fall back to the cached walker.
    if imageIndex * frameCount >= 0x10000000 then
        local found = nil
        for i = 0, (animIdx or 0) - 1 do
            local c = r32(animPtr + i * 4) & 0xFFFF
            if c * frameCount < 0x10000000 then found = c end
        end
        if not found then return nil end
        -- Logged once per pair: a substitution firing constantly or on the wrong stride looks like a peer
        -- doing something it never did.
        if COMPARE_TIERS then
            local k = string.format("%s:%s:%s", tostring(gfx), tostring(animNum), tostring(animIdx))
            if genderFrames.walkedBackKey ~= k then
                genderFrames.walkedBackKey = k
                logFile(string.format("DRAWN WALKED BACK: gfx=%s anim=%s/%s -> image %s",
                    tostring(gfx), tostring(animNum), tostring(animIdx), tostring(found)))
            end
        end
        imageIndex = found
        hFlip = ((r32(animPtr) >> 22) & 1) == 1
    end

    local runs = genderFrames.runsFromImages(
        string.format("g%d:%d", gfx, imageIndex), info.images, info.width, info.height,
        imageIndex, info.paletteSlot)
    if not runs then return nil end
    -- The image index comes back too: a reflection is this frame in another palette, and resolving it twice
    -- lets the two halves disagree about which frame they describe.
    return runs, info, hFlip, imageIndex
end

-- Computed, never copied from a template: a copied screen position drew Crystal's first ghost off the screen.
local function spriteScreenPos(mapX, mapY, centerToCornerVecY)
    local sb1 = session.saveBlockPtr(GSAVEBLOCK1PTR_ADDR)
    local camX, camY = 0, 0
    local fcx = memory.read_s32_le(GFIELDCAMERA_X_ADDR + (genderFrames.camOffset or 0))
    local fcy = memory.read_s32_le(GFIELDCAMERA_Y_ADDR + (genderFrames.camOffset or 0))
    if fcx > 0 then camX = 1 elseif fcx < 0 then camX = -1 end
    if fcy > 0 then camY = 1 elseif fcy < 0 then camY = -1 end
    local x = (((mapX + camX) - rs16(sb1 + 0x00)) << 4) - rs16(GTOTALCAMERAPIXELOFFSETX_ADDR + (genderFrames.camOffset or 0))
    local y = (((mapY + camY) - rs16(sb1 + 0x02)) << 4) - rs16(GTOTALCAMERAPIXELOFFSETY_ADDR + (genderFrames.camOffset or 0))
    local c2cY = centerToCornerVecY
    if c2cY > 127 then c2cY = c2cY - 256 end
    return x + 8, y + 16 + c2cY
end

-- A ghost's screen position is computed once, then the engine applies only camera deltas: computed mid-scroll,
-- the sub-tile remainder stays baked in and the ghost renders off its tile for good.
local function cameraIsSettled()
    return memory.read_s32_le(GFIELDCAMERA_X_ADDR + (genderFrames.camOffset or 0)) == 0
        and memory.read_s32_le(GFIELDCAMERA_Y_ADDR + (genderFrames.camOffset or 0)) == 0
end

-- ghosts[playerId] = { objId, sprId, localId, tileStart, tileCount, mapX, mapY }
local ghosts = {}

-- Skips slots our ghosts hold, which read inactive while culled in a doorway. Downward from 15, since
-- GetObjectEventIdByLocalId scans up from 0 and the real player must stay ahead of every ghost wearing its id.
local function findFreeObjectSlot()
    local claimed = {}
    for _, g in pairs(ghosts) do claimed[g.objId] = true end
    for i = 15, 0, -1 do
        if (r8(objAddr(i) + 0x00) & 0x01) == 0 and not claimed[i] then return i end
    end
    return nil
end

-- Downward: the engine's CreateSprite takes the lowest free index.
local function findFreeSpriteSlot()
    local claimed = {}
    for _, g in pairs(ghosts) do claimed[g.sprId] = true end
    for i = MAX_SPRITES - 1, 0, -1 do
        if (r8(sprAddr(i) + 0x3e) & 0x01) == 0 and not claimed[i] then return i end
    end
    return nil
end

-- The player's local id, so an A-press on a ghost finds no script; a synthesised object's own id runs garbage.
local GHOST_LOCAL_ID = 255

-- The cross-map rebase is defined earlier and cannot close over `ghosts`; it reaches it through this field.
genderFrames.xmapGhosts = ghosts

-- Forward declarations: the code below uses these before they are defined, and an undeclared name is a nil global.
local ghostAlive
local despawnSurfBlob
local spawnSurfBlob
local flyRide = {}
local SURFING_GFX

-- Tile ranges a battle kept us from freeing (the bitmap was not ours to write), settled back in the overworld.
genderFrames.pendingTileFrees = {}
genderFrames.deferredTileFrees = {} -- swap-time frees, held a few frames; see swapGhostGraphicInPlace
-- Queued once per range: several despawn paths reach the same tiles, and queuing twice frees twice.
function queueTileFree(entry)
    for _, e in ipairs(genderFrames.deferredTileFrees) do
        if e.start == entry.start then return end
    end
    genderFrames.deferredTileFrees[#genderFrames.deferredTileFrees + 1] = entry
end

-- Set bits are not ownership: a range re-taken by another tier or the engine reads the same. A live sprite drawing
-- from the range says it is in use, and a leak is better than handing the tiles out twice. Runs only at a free.
genderFrames.rangeDrawnByLiveSprite = function(start, count, exceptSprId)
    for i = 0, MAX_SPRITES - 1 do
        if i ~= exceptSprId then
            local d = sprAddr(i)
            if (r8(d + 0x3e) & 0x01) == 1 then
                local t = r16(d + 0x04) & 0x3ff
                if t >= start and t < start + count then return true end
            end
        end
    end
    return false
end

local function freeGhostTiles(g)
    -- Never free across a state load: it rewinds the bitmap, so our ranges no longer name bits we own.
    if genderFrames.stateLoadPurge then return end
    if g.tileStart then
        for t = g.tileStart, g.tileStart + g.tileCount - 1 do setTileAllocated(t, false) end
    end
end

-- Drops the per-peer rows the rendering built for a ghost, so they leave with it. Called from the despawn_remote
-- handler, which always runs: despawnGhost returns early unless the peer holds an engine object slot.
forgetPeerRenderState = function(playerId)
    -- `tiering` is assigned further down, so it is nil until load finishes, and indexing nil is a hard error.
    if not tiering then return end
    if tiering.lastTile then tiering.lastTile[playerId] = nil end
    if tiering.hwLastTile then tiering.hwLastTile[playerId] = nil end
    -- Pruned otherwise only when the same peer is drawn again, which a departed id never is.
    if tiering.grassTiles then tiering.grassTiles[playerId] = nil end
    if tiering.landed then tiering.landed[playerId] = nil end
    if tiering.ripples then tiering.ripples[playerId] = nil end
    if tiering.puffs then tiering.puffs[playerId] = nil end
    if genderFrames.wRefl then genderFrames.wRefl[playerId] = nil end
end

-- Identity first: a map load hands our slots and tiles to the new map's NPCs. Frees exactly the range we
-- allocated, never by the sprite's own size, so it cannot free another sprite's VRAM.
local function despawnGhost(playerId)
    local g = ghosts[playerId]
    if not g then return end
    -- Never write the arrays outside the overworld: a battle reuses the sprite array, and a bridge drop
    -- mid-battle is ordinary. The engine reclaims the slot and tiles when it tears the map down.
    if not inOverworld() then
        -- Queued, not forgotten: a leaked range starves the engine's own NPCs of tiles. Settled back in the
        -- overworld, where the identity test can say whether the range is still ours.
        local q = genderFrames.pendingTileFrees
        q[#q + 1] = { objId = g.objId, tileStart = g.tileStart, tileCount = g.tileCount }
        ghosts[playerId] = nil
        forgetPeerRenderState(playerId)
        return
    end
    if ghostAlive(g) then
        despawnSurfBlob(g)
        despawnGhostShadow(g)
        -- A bird or a boat outlives its ghost unless retired here.
        flyRide.despawnBird(g)
        flyRide.despawnVehicle(g)
        w8(objAddr(g.objId) + 0x00, 0)
        local d = sprAddr(g.sprId)
        w8(d + 0x3e, (r8(d + 0x3e) & ~0x01) | 0x04) -- inUse = 0, invisible = 1
        freeGhostTiles(g)
    end
    -- Not ours any more: touch nothing, the engine reclaimed the slot and tiles at map teardown.
    ghosts[playerId] = nil
    forgetPeerRenderState(playerId)
end

despawnAllGhosts = function()
    for playerId in pairs(ghosts) do despawnGhost(playerId) end
end

-- Liveness by identity, never slot state or map: a warp gives our slots to NPCs, and a route connection changes
-- mapNum with the array intact. Only a ghost is active, not the player, and wears LOCALID_PLAYER.
ghostAlive = function(g)
    local a = objAddr(g.objId)
    if (r8(a + 0x00) & 0x01) ~= 1 then return false end          -- not active
    if (r8(a + 0x02) & 0x01) == 1 then return false end          -- became the player somehow
    if r8(a + 0x08) ~= GHOST_LOCAL_ID then return false end      -- slot reused by a real NPC
    if r8(a + 0x04) ~= g.sprId then return false end             -- no longer points at our sprite
    return (r8(sprAddr(g.sprId) + 0x3e) & 0x01) == 1             -- and that sprite still exists
end

-- Anything wearing our marker that we are not tracking is left from an earlier load or a bug. Its tiles stay:
-- their range is unknown, and the next map load reclaims them.
local function sweepOrphanGhosts()
    local mine = {}
    for _, g in pairs(ghosts) do mine[g.objId] = true end
    for i = 0, 15 do
        local a = objAddr(i)
        if not mine[i]
            and (r8(a + 0x00) & 0x01) == 1
            and (r8(a + 0x02) & 0x01) == 0
            and r8(a + 0x08) == GHOST_LOCAL_ID then
            local sprId = r8(a + 0x04)
            w8(a + 0x00, 0)
            if sprId < MAX_SPRITES then
                local d = sprAddr(sprId)
                w8(d + 0x3e, (r8(d + 0x3e) & ~0x01) | 0x04)
            end
            console.log(string.format("MeshGhost: cleared an orphaned ghost in object slot %d.", i))
        end
    end
end

-- Dev only: forces every ghost's graphicsId, to test a peer on a bike over loopback; a global, so a reload sets it.
--   Brendan: 0 normal, 1 Mach Bike, 63 Acro Bike, 2 surfing, 137 fishing
--   May:    89 normal, 90 Mach Bike, 91 Acro Bike, 92 surfing, 138 fishing
local FORCE_GHOST_GFX = tonumber(MESHGHOST_FORCE_GHOST_GFX
    or os.getenv("MESHGHOST_FORCE_GHOST_GFX") or "")

-- Opt-in for the engine tiers, off on purpose: a peer's own 32-wide graphic was seen corrupted there, so by default
-- a spawned ghost wears the local player's graphic.
local PEER_GFX_ENABLED = MESHGHOST_GHOST_PEER_GFX or os.getenv("MESHGHOST_GHOST_PEER_GFX")

-- The painted tier's own gate, on by default: it clones nothing, centres a 32-wide frame itself, and falls back to
-- the cached walker when a decode fails. On genderFrames for the 200-local ceiling.
genderFrames.peerGfxDrawn = (MESHGHOST_GHOST_PEER_GFX_DRAWN == nil) and true
    or MESHGHOST_GHOST_PEER_GFX_DRAWN

-- What a ghost should be drawn as, decided here rather than inside spawnGhost so a graphic change compares like
-- with like: forced inside the spawn, it never matched the peer's and the ghost was rebuilt every frame.
local function wantedGfx(remote)
    if FORCE_GHOST_GFX then return FORCE_GHOST_GFX end
    if PEER_GFX_ENABLED then return remote and remote.gfx or nil end
    -- A fly is the one state the gate cannot serve: a walker would fly off in a pose the game never shows. Safe,
    -- since the spawn paths refuse a graphic whose palette tag differs from the player's.
    if remote and remote.fly then return remote.gfx end
    return nil
end

-- Two tiers, so every peer stays visible: spawn object events while the map's 16 last, and draw the overflow.
--   hysteresis -- tiles a spawned ghost keeps against an unspawned peer, so a near-equal pair does not swap tiers.
--   reserve    -- object slots kept for a character of the engine's own scrolling into view.
--   castMax    -- per area_id, the most game-owned objects ever seen active: the count varies with the camera.
tiering = {
    slide = { step = 0, legs = 0, paused = 0 },
    blockedFrame = nil,
    lastLogFrame = nil,
    drawn = (MESHGHOST_EMERALD_DRAWN_OVERFLOW or os.getenv("MESHGHOST_EMERALD_DRAWN_OVERFLOW") or "1") ~= "0",
    hysteresis = 3,
    reserve = 1,
    castMax = {},
    -- A probe, off unless asked: per-frame lines comparing the player's sprite animation with each ghost's and
    -- the OAM entries both draw from. Kept out of compare mode, which would otherwise pay its file I/O.
    animTrace = (MESHGHOST_EMERALD_ANIM_TRACE
        or os.getenv("MESHGHOST_EMERALD_ANIM_TRACE")) and true or false,
    animTraceBuf = nil,

    -- A probe, off by default: 60 frames of ring before each seam event and 150 after. The global is read every
    -- frame, so it arms without a relaunch, and false disarms it (a global outlives the script that set it).
    seamTrace = (MESHGHOST_EMERALD_SEAM_TRACE
        or os.getenv("MESHGHOST_EMERALD_SEAM_TRACE")) and true or false,
    seamRing = nil,
    seamDumpUntil = nil,
    seamLastKey = nil,
    seamLastSrc = nil,
}

-- Where the game's UI is, so the drawn tier stays off the text: BG0's tilemap, empty until the game draws a panel
-- (the window registers change every frame while walking), found through BG0CNT whatever the ROM.
local gbaReg = {}
gbaReg.bg0cnt = 0x04000008
gbaReg.vram = 0x06000000

-- Rescanned every SCAN_EVERY_FRAMES frames: a panel one frame late is invisible. Rows are {x1, x2} in screen
-- pixels, per row, since the START menu and a text box cover different columns.
tiering.panelRows = {}
tiering.panelScannedAt = nil
-- The banner's window is applied to a copy of the cached rows on every call: the game animates it per frame, and
-- the throttled, debounced scan would trail its edges by frames.
tiering.applyShowMonWindow = function(rows)
    local showMon = nil
    for t = 0, 15 do
        local ta = 0x03005e00 + t * 0x28
        if r8(ta + 0x04) == 1 then
            local fn = r32(ta + 0x00)
            if fn == 0x080b8555 or fn == 0x080b88b5 then showMon = ta break end
        end
    end
    if not showMon then
        if tiering.showMonWasLive then
            -- The banner's task is gone but its rows stay in the tilemap until the game's restore step: drop the
            -- cached rows now (a rescan would still return them this frame) and ignore the tilemap for 8 frames.
            tiering.showMonWasLive = nil
            tiering.panelScannedAt = nil
            tiering.panelRows, tiering.panelPrev = {}, {}
            tiering.panelBlankUntil = frameCounter + 8
            return {}
        end
        if tiering.panelBlankUntil and frameCounter < tiering.panelBlankUntil then
            tiering.panelScannedAt = nil
            return {}
        end
        return rows
    end
    tiering.showMonWasLive = true
    -- From the restore steps on (task state 5 and up) there is no banner: the last frame resets the stored
    -- window to the full screen, which is not coverage.
    if r16(showMon + 0x08) >= 5 then
        tiering.showMonWasLive = nil
        tiering.panelScannedAt = nil
        tiering.panelRows, tiering.panelPrev = {}, {}
        tiering.panelBlankUntil = frameCounter + 8
        return {}
    end
    local wh = r16(showMon + 0x08 + 1 * 2)
    local wv = r16(showMon + 0x08 + 2 * 2)
    local x1, x2 = (wh >> 8) & 0xff, (wh & 0xff) - 1
    local y1, y2 = (wv >> 8) & 0xff, (wv & 0xff) - 1
    local out = {}
    for row, span in pairs(rows) do
        local rTop, rBot = row * 8, row * 8 + 7
        if not (rBot < y1 or rTop > y2 or x2 < x1) then
            local a, b = span[1], span[2]
            if a < x1 then a = x1 end
            if b > x2 then b = x2 end
            if b >= a then out[row] = { a, b } end
        end
    end
    return out
end

tiering.scanPanel = function()
    local SCAN_EVERY_FRAMES = 4
    if tiering.panelScannedAt and frameCounter - tiering.panelScannedAt < SCAN_EVERY_FRAMES then
        return tiering.applyShowMonWindow(tiering.panelRows)
    end
    tiering.panelScannedAt = frameCounter

    local rows = {}
    -- Dev override: a full-width panel from this row down, to exercise the clipping without a real one.
    local fake = tonumber(MESHGHOST_EMERALD_FAKE_PANEL_ROW
        or os.getenv("MESHGHOST_EMERALD_FAKE_PANEL_ROW") or "")
    if fake then
        for row = fake, 19 do rows[row] = { 0, 239 } end
        tiering.panelRows = rows
        return rows
    end

    local base = gbaReg.vram + ((memory.read_u16_le(gbaReg.bg0cnt) >> 8) & 0x1F) * 0x800
    for row = 0, 19 do
        local first, last
        for col = 0, 29 do
            if (memory.read_u16_le(base + (row * 32 + col) * 2) & 0x3FF) ~= 0 then
                first = first or col
                last = col
            end
        end
        -- Only drawn rows are stored, so no panel costs the draw path one nil lookup per run.
        if first then rows[row] = { first * 8, last * 8 + 7 } end
    end
    -- Only rows present in two consecutive scans clip: the map-name banner's mid-ride redraws flicker, a real
    -- panel is stable.
    local out = {}
    for row, span in pairs(rows) do
        if tiering.panelPrev and tiering.panelPrev[row] then out[row] = span end
    end
    -- Rows 0-4 on the left half, the banner's home, need five scans in a row: its flicker never holds that long.
    -- The START menu's spans there start past midscreen.
    tiering.bannerStreak = tiering.bannerStreak or {}
    for row = 0, 4 do
        local leftSpan = rows[row] and rows[row][1] < 120
        tiering.bannerStreak[row] = leftSpan and (tiering.bannerStreak[row] or 0) + 1 or 0
        if out[row] and out[row][1] < 120 and tiering.bannerStreak[row] < 5 then
            out[row] = nil
        end
    end
    tiering.panelPrev = rows
    tiering.panelRows = out
    return tiering.applyShowMonWindow(out)
end

console.log("MeshGhost: drawn overflow tier = " .. (tiering.drawn and "ON" or "off"))
if COMPARE_TIERS then
    console.log("MeshGhost: PROBE FLAG IN USE -- MESHGHOST_COMPARE_TIERS: the loopback ghost is "
        .. "rendered twice, spawned 2 tiles right and painted 2 tiles left. Dev only.")
end
if tiering.animTrace then
    console.log("MeshGhost: PROBE FLAG IN USE -- MESHGHOST_EMERALD_ANIM_TRACE: writing a per-frame "
        .. "player-vs-ghost animation trace to probes/animtrace.log. Dev only, and it costs a "
        .. "file write every 120 frames.")
end
if tiering.seamTrace then
    console.log("MeshGhost: PROBE FLAG IN USE -- MESHGHOST_EMERALD_SEAM_TRACE: writing a window "
        .. "around every seam crossing to probes/seamtrace.log. Dev only.")
end

-- Object slots ghosts may hold on this map now, counted from the array rather than our bookkeeping.
tiering.budget = function(localAreaId)
    local cast = 0
    for i = 0, 15 do
        local a = objAddr(i)
        if (r8(a) & 0x01) == 1 and r8(a + 0x08) ~= GHOST_LOCAL_ID then cast = cast + 1 end
    end
    local seen = tiering.castMax[localAreaId] or 0
    if cast > seen then
        seen = cast
        tiering.castMax[localAreaId] = cast
    end
    local budget = 16 - seen - tiering.reserve
    if budget < 0 then budget = 0 end
    -- Dev override: raises the cap on peers holding an object slot. Re-read every call, so a loader script flips it.
    local cap = tonumber(MESHGHOST_EMERALD_MAX_SPAWNED
        or os.getenv("MESHGHOST_EMERALD_MAX_SPAWNED") or "")
    -- Zero by default, since only the painted tier ships: it draws a peer's own graphic, where every engine tier
    -- borrows the palette slot loaded for the player, so a peer of the other gender came out as a copy of you.
    if not cap then cap = 0 end
    if cap < budget then budget = cap end
    return budget
end

-- Nearest wins, not join order: the engine's objects go where the player looks closely. Returns the player_ids
-- that hold an object slot this frame; the rest are the drawn tier's.
tiering.chooseSpawned = function(localAreaId, playerX, playerY)
    -- Quiet after a state load: the core echoes the pre-load world until our first send round-trips, and the
    -- painted tier stays live.
    if genderFrames.loadQuietUntil and frameCounter < genderFrames.loadQuietUntil then
        return {}
    end
    local budget = tiering.budget(localAreaId)
    local ranked = {}
    for playerId, remote in pairs(remotes) do
        -- A cross-map peer may stand 10 tiles past the edge, but an object past the engine's 7-tile border goes
        -- negative and a u16 write wraps it. Fails open while the self-location scan has no dimensions (0).
        local xmW, xmH = genderFrames.xmap.ourW, genderFrames.xmap.ourH
        if remote.areaId == localAreaId
            and (xmW == 0 or (remote.x >= -7 and remote.y >= -7
                and remote.x <= xmW + 6 and remote.y <= xmH + 6))
        then
            local dx, dy = remote.x - playerX, remote.y - playerY
            local d = math.sqrt(dx * dx + dy * dy)
            -- Hysteresis as a discount to whoever holds a slot, so a drifting pair cannot trade tiers each frame.
            if ghosts[playerId] then d = d - tiering.hysteresis end
            ranked[#ranked + 1] = { id = playerId, d = d }
        end
    end
    table.sort(ranked, function(a, b)
        -- player_id breaks ties: a pairs()-random order is a despawn and respawn every frame.
        if a.d == b.d then return a.id < b.id end
        return a.d < b.d
    end)
    local set = {}
    for i = 1, math.min(#ranked, budget) do set[ranked[i].id] = true end
    return set
end

local function spawnGhost(playerId, mapX, mapY, orientation, wantGfx)
    local playerObjId = r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05)
    local pObj = objAddr(playerObjId)
    local playerSprId = r8(pObj + 0x04)

    -- The player's object and the sprite it names must agree before a byte is written: it proves gSprites'
    -- address, which a shifted build would break silently.
    if rs16(sprAddr(playerSprId) + 0x2e) ~= playerObjId then
        console.log("MeshGhost: refusing to spawn -- the player's object/sprite cross-link does "
            .. "not check out, so gSprites is not where this build expects.")
        return nil
    end

    local objId = findFreeObjectSlot()
    local sprId = findFreeSpriteSlot()
    local localId = GHOST_LOCAL_ID
    if not objId or not sprId then
        -- Out of slots is a normal state: the message is throttled (console.log is a GUI append), and the refusal
        -- is recorded so syncRemoteGhosts stops asking this frame, since the arrays do not grow mid-frame.
        tiering.blockedFrame = frameCounter
        if not tiering.lastLogFrame or frameCounter - tiering.lastLogFrame >= 300 then
            tiering.lastLogFrame = frameCounter
            console.log("MeshGhost: no free slot for a ghost (objects or sprites full) -- more "
                .. "peers here than this map can hold. Further refusals are not logged for 5s.")
        end
        return nil
    end

    local sb1 = session.saveBlockPtr(GSAVEBLOCK1PTR_ADDR)
    local playerGfx = r8(pObj + 0x05)
    local elevation = r8(pObj + 0x0b) & 0x0f
    -- Dev only: puts the ghost on another elevation. A value, not a boolean: which elevation lets a character be
    -- walked past is not measured, so setting it is the experiment.
    local devElevation = tonumber(MESHGHOST_EMERALD_GHOST_ELEVATION
        or os.getenv("MESHGHOST_EMERALD_GHOST_ELEVATION") or "")
    if devElevation then elevation = devElevation & 0x0f end
    local gx, gy = mapX + MAP_OFFSET, mapY + MAP_OFFSET
    local dir = DIR_ID[orientation] or DIR_ID.south

    -- The peer's graphic when we know it: every player state is a different graphicsId.
    local playerInfo = graphicsInfo(playerGfx)
    local graphicsId = wantGfx or playerGfx
    local info = graphicsInfo(graphicsId)
    -- A ghost borrows the player's palette slot, so only a graphic with the same palette tag is safe.
    if not info or not playerInfo or info.paletteTag ~= playerInfo.paletteTag then
        graphicsId = playerGfx
        info = playerInfo
    end
    if not info then
        -- Logged, throttled: a refusal the log never mentions looks like a peer who is not there.
        if not tiering.lastLogFrame or frameCounter - tiering.lastLogFrame >= 300 then
            tiering.lastLogFrame = frameCounter
            console.log(string.format("MeshGhost: refusing to spawn -- no usable graphics info "
                .. "for id %s (table at %08X). Further refusals are not logged for 5s.",
                tostring(graphicsId), GOBJECTEVENTGRAPHICSINFOPOINTERS_ADDR
                    + (genderFrames.romOffset or 0)))
        end
        return nil
    end

    local tileCount = info.tileCount
    local tileStart = allocSpriteTiles(tileCount)
    if not tileStart then
        -- Throttled, and to the file: when OBJ VRAM runs dry this fires every frame, and console.log is a GUI append.
        if (emu.framecount() - (tiering.noTilesAt or -999)) >= 300 then
            tiering.noTilesAt = emu.framecount()
            logFile("MeshGhost: no run of free OBJ tiles for a ghost (repeats suppressed for 5s).")
        end
        return nil
    end

    -- The object event: zeroed, then the fields a template init sets, with movementType NONE so only we drive it.
    local a = objAddr(objId)
    for off = 0, OBJECTEVENT_SIZE - 1 do w8(a + off, 0) end
    w8(a + 0x00, 0x05) -- active | triggerGroundEffectsOnMove
    w8(a + 0x05, graphicsId)
    w8(a + 0x06, MOVEMENT_TYPE_NONE)
    w8(a + 0x08, localId)
    w8(a + 0x09, r8(sb1 + 0x05)) -- mapNum
    w8(a + 0x0a, r8(sb1 + 0x04)) -- mapGroup
    w8(a + 0x0b, elevation | (elevation << 4))
    w16(a + 0x0c, gx) w16(a + 0x0e, gy)
    w16(a + 0x10, gx) w16(a + 0x12, gy)
    w16(a + 0x14, gx) w16(a + 0x16, gy)
    w8(a + 0x18, dir | (dir << 4))
    w8(a + 0x20, dir)
    w8(a + 0x04, sprId)

    -- The sprite starts as a copy of the player's, for the engine-set fields we cannot invent, then takes what is
    -- drawn from the chosen graphic.
    local src, dst = sprAddr(playerSprId), sprAddr(sprId)
    for off = 0, SPRITE_SIZE - 1 do w8(dst + off, r8(src + off)) end

    -- OAM takes only shape and size (attr0 and attr1 bits 14-15) from the graphic: its whole template puts the
    -- sprite out of step with the engine's per-frame OAM building.
    local attr2 = r16(dst + 0x04)
    w16(dst + 0x04, (attr2 & 0xfc00) | (tileStart & 0x03ff))
    if info.oam ~= 0 then
        w16(dst + 0x00, (r16(dst + 0x00) & 0x3fff) | (r16(info.oam + 0x00) & 0xc000))
        w16(dst + 0x02, (r16(dst + 0x02) & 0x3fff) | (r16(info.oam + 0x02) & 0xc000))
    end

    -- The ROM pointers to the graphic's pixels and animations.
    w32(dst + 0x08, info.anims)
    w32(dst + 0x0c, info.images)
    w32(dst + 0x10, info.affineAnims)
    -- Subsprites on only for a graphic with tables, or it draws through the previous graphic's layout.
    w32(dst + 0x18, info.subspriteTables)
    -- Keep the subsprite table number: the engine picks it per frame from the elevation, which a graphic change does
    -- not alter, and forcing 0 drew one frame of scrambled pieces.
    local keepSubNum = r8(dst + 0x42) & 0x3f
    w8(dst + 0x42, 0)
    if info.subspriteTables ~= 0 then
        w8(dst + 0x42, keepSubNum | (1 << 6)) -- engine's table, mode ON
    end
    -- centerToCornerVec, from the graphic's dimensions.
    w8(dst + 0x28, (-(info.width // 2)) & 0xff)
    w8(dst + 0x29, (-(info.height // 2)) & 0xff)
    local sx, sy = spriteScreenPos(gx, gy, r8(dst + 0x29))
    w32(dst + 0x1c, MOVEMENTTYPE_NONE_CB)
    w16(dst + 0x20, sx) w16(dst + 0x22, sy)
    w16(dst + 0x24, 0) w16(dst + 0x26, 0)
    for k = 0, 7 do w16(dst + 0x2e + k * 2, 0) end
    w16(dst + 0x2e, objId)
    w8(dst + 0x2a, 0) w8(dst + 0x2b, 0)
    w8(dst + 0x3e, (r8(dst + 0x3e) | 0x03) & ~0x04)
    w8(dst + 0x3f, r8(dst + 0x3f) | 0x04)

    ghosts[playerId] = {
        objId = objId, sprId = sprId, localId = localId,
        tileStart = tileStart, tileCount = tileCount, mapX = mapX, mapY = mapY,
        gfx = graphicsId, -- what this ghost is drawn as, so a change can be detected
        swapAt = frameCounter, -- a spawn is a swap for the restart cooldown; see animRestart
    }
    -- A state is its animation and its extras. Not mid-mount: this site would spawn at the glide position, the land
    -- tile, and the jump block in syncGhost owns the mount blob at the engine-held destination.
    local rAct = remotes[playerId] and remotes[playerId].act
    local midJump = rAct and rAct >= 0x3a and rAct <= 0x3d
    -- Nor while flying: the mount pose borrows this graphic (see flyRide.apply's `g.noBlob`). Read off the peer,
    -- since the ghost's record does not exist yet.
    local rFly = remotes[playerId] and remotes[playerId].fly
    if SURFING_GFX[graphicsId] and not midJump and not rFly then
        local blob = spawnSurfBlob(ghosts[playerId], mapX, mapY)
        console.log(string.format("MeshGhost: surf blob for gfx %d -> sprite %s",
            graphicsId, tostring(blob)))
    elseif UNDERWATER_GFX[graphicsId] then
        -- Underwater has no companion sprite: the bobbing is the state (see spawnUnderwaterBobber).
        local bob = spawnUnderwaterBobber(ghosts[playerId])
        console.log(string.format("MeshGhost: underwater bobber for gfx %d -> sprite %s",
            graphicsId, tostring(bob)))
    end
    return ghosts[playerId]
end

-- The surf blob: the Pokemon under a surfing rider is a separate sprite, built from the field effect's template
-- because no blob exists to copy unless somebody is already surfing. The update callback is Thumb, hence +1.
surfBlob.updateCb = 0x08155658 + 1
surfBlob.bobMode = 1
surfBlob.subPriority = 150

-- Surfing only: underwater bobs the player's own sprite instead.
SURFING_GFX = { [2] = true, [92] = true } -- Brendan, May

-- A fly borrows the surfing graphic to sit on the bird, so the graphic alone cannot say surfing; every blob and
-- ripple consumer, on every tier, asks this instead.
function peerIsSurfing(remote)
    return remote and remote.gfx ~= nil and SURFING_GFX[remote.gfx] and not remote.fly
end

-- MESHGHOST_EMERALD_NO_BLOB, a probe: spawned ghosts get no blob, separating a ghost from its field effects.
-- Never ship it set.
spawnSurfBlob = function(g, mapX, mapY)
    if MESHGHOST_EMERALD_NO_BLOB then return nil end   -- surf blob only; see NO_BOBBER
    if COMPARE_TIERS then
        local who = debug.getinfo(2, "l")
        logFile(string.format("BLOB SPAWN from line %s at tile (%d,%d) f=%d",
            tostring(who and who.currentline), mapX, mapY, frameCounter))
    end
    local tmpl = surfBlob.template
    local oamPtr, animsPtr = r32(tmpl + 0x04), r32(tmpl + 0x08)
    local imagesPtr, affinePtr = r32(tmpl + 0x0c), r32(tmpl + 0x10)
    if oamPtr == 0 or imagesPtr == 0 then return nil end

    local sprId = findFreeSpriteSlot()
    if not sprId or sprId == g.sprId then return nil end
    -- The blob's frames are 32x32 -- 16 tiles, same as the rider's.
    local tileStart = allocSpriteTiles(16)
    if not tileStart then return nil end

    local d = sprAddr(sprId)
    for off = 0, SPRITE_SIZE - 1 do w8(d + off, 0) end
    for off = 0, 7 do w8(d + off, r8(oamPtr + off)) end
    -- The palette comes from the template's tag: the engine hardcodes 0 because it runs with its slot loaded.
    w16(d + 0x04, (r16(d + 0x04) & 0x0c00) | (tileStart & 0x03ff)
        | ((genderFrames.blobPalette() & 0x0f) << 12))
    w32(d + 0x08, animsPtr)
    w32(d + 0x0c, imagesPtr)
    w32(d + 0x10, affinePtr)
    w32(d + 0x1c, surfBlob.updateCb)

    -- Not the rider's formula: this also subtracts gFieldCamera and adds (8,8). The camera terms cancel at rest.
    local sb1 = session.saveBlockPtr(GSAVEBLOCK1PTR_ADDR)
    local dx = -rs16(GTOTALCAMERAPIXELOFFSETX_ADDR + (genderFrames.camOffset or 0)) - memory.read_s32_le(GFIELDCAMERA_X_ADDR + (genderFrames.camOffset or 0))
    local dy = -rs16(GTOTALCAMERAPIXELOFFSETY_ADDR + (genderFrames.camOffset or 0)) - memory.read_s32_le(GFIELDCAMERA_Y_ADDR + (genderFrames.camOffset or 0))
    local sx = (((mapX + MAP_OFFSET) - rs16(sb1 + 0x00)) << 4) + dx + 8
    local sy = (((mapY + MAP_OFFSET) - rs16(sb1 + 0x02)) << 4) + dy + 8
    w16(d + 0x20, sx) w16(d + 0x22, sy)
    -- centerToCornerVec, which CreateSprite would set: the hardware draws from the top-left, so without it the blob
    -- lands down-right of its rider.
    w8(d + 0x28, (-(surfBlob.framePx // 2)) & 0xff)
    w8(d + 0x29, (-(surfBlob.framePx // 2)) & 0xff)
    w8(d + 0x43, surfBlob.subPriority)
    w16(d + 0x2e, 0)                       -- data[0]: bob state, set below
    w8(d + 0x2e, surfBlob.bobMode)
    w16(d + 0x32, g.objId)                 -- data[2]: the object this blob follows, the ghost
    w16(d + 0x34, 0xffff)                  -- data[3]: velocity, seeded -1
    w16(d + 0x3a, 0xffff)                  -- data[6]: previous x, seeded -1
    w16(d + 0x3c, 0xffff)                  -- data[7]: previous y, seeded -1
    w8(d + 0x3e, 0x03)                     -- inUse | coordOffsetEnabled
    w8(d + 0x3f, 0x04)                     -- animBeginning

    -- Tell the object it owns this effect, the way the engine does.
    w8(objAddr(g.objId) + 0x1a, sprId)
    g.blobSprId, g.blobTileStart = sprId, tileStart
    g.blobSince = frameCounter -- age separates a mount's fresh blob from a dismount's old one
    return sprId
end

-- A real shadow sprite, which an overlay cannot be (under the character and its dust), driven from Lua since the
-- engine's update finds its object by localId. Indexed by shadow size, bits 4-5 of graphicsInfo +0x0C.
genderFrames.shadowTemplates =
    { [0] = 0x0850c9fc, [1] = 0x0850ca14, [2] = 0x0850ca2c, [3] = 0x0850ca44 }

-- The engine's do-nothing callback (`bx lr`): a callback of 0 reset the game, as every in-use sprite's is called
-- unchecked. Verified at spawn, since a relocated ROM keeps something else there.
genderFrames.spriteCallbackDummy = 0x08007428 + 1 -- +1 selects Thumb

-- centerToCornerVec by OAM shape*4 + size: minus half the OBJ's width and height, so a sprite's position is its
-- centre. A player graphic's shadow is always entry 4.
genderFrames.ctcVec = {
    [0] = { -4, -4 }, [1] = { -8, -8 }, [2] = { -16, -16 }, [3] = { -32, -32 },   -- square
    [4] = { -8, -4 }, [5] = { -16, -4 }, [6] = { -16, -8 }, [7] = { -32, -16 },   -- horizontal
    [8] = { -4, -8 }, [9] = { -4, -16 }, [10] = { -8, -16 }, [11] = { -16, -32 }, -- vertical
}

function spawnGhostShadow(g)
    if g.shadowSprId then return g.shadowSprId end
    local gi = g.gfx and graphicsInfo(g.gfx)
    if not gi or not gi.raw then return nil end
    local size = (r8(gi.raw + 0x0c) >> 4) & 0x03
    local tmpl = genderFrames.shadowTemplates[size]
    local oamPtr, animsPtr = r32(tmpl + 0x04), r32(tmpl + 0x08)
    local imagesPtr = r32(tmpl + 0x0c)
    if oamPtr == 0 or imagesPtr == 0 then return nil end

    -- `bx lr` or no shadow sprite: a wrong callback is a reset, not a glitch.
    if r16(genderFrames.spriteCallbackDummy - 1) ~= 0x4770 then
        if not genderFrames.shadowCbWarned then
            genderFrames.shadowCbWarned = true
            logFile("shadow sprite: SpriteCallbackDummy is not where this ROM keeps it -- "
                .. "staying on the painted shadow")
        end
        return nil
    end

    local sprId = findFreeSpriteSlot()
    if not sprId or sprId == g.sprId then return nil end
    -- The frame's byte count: a frame image is a data pointer, then a u16 size.
    local bytes = r16(imagesPtr + 4)
    local nTiles = math.max(1, bytes // 32)
    -- A shadow frame is 32, 64, 128 or 1024 bytes; anything else means the image read is wrong.
    if bytes == 0 or bytes > 1024 or bytes % 32 ~= 0 then
        logFile(string.format("shadow sprite: refusing a %d-byte frame (images=%08x)",
            bytes, imagesPtr))
        return nil
    end
    local tileStart = allocSpriteTiles(nTiles)
    if not tileStart then return nil end
    if not genderFrames.shadowSizeLogged then
        genderFrames.shadowSizeLogged = true
        logFile(string.format("shadow sprite: size=%d, %d bytes, %d tiles at %d..%d (VRAM %08x)",
            size, bytes, nTiles, tileStart, tileStart + nTiles - 1, 0x06010000 + tileStart * 32))
    end

    local d = sprAddr(sprId)
    for off = 0, SPRITE_SIZE - 1 do w8(d + off, 0) end
    for off = 0, 7 do w8(d + off, r8(oamPtr + off)) end
    w16(d + 0x04, (r16(d + 0x04) & 0x0c00) | (tileStart & 0x03ff))
    w32(d + 0x08, animsPtr)
    w32(d + 0x0c, imagesPtr)
    w32(d + 0x10, r32(tmpl + 0x10))
    -- A do-nothing callback: the engine's own would bind by localId and find the player.
    w32(d + 0x1c, genderFrames.spriteCallbackDummy)
    w8(d + 0x43, 148)         -- subpriority: under the character, above the ground
    -- centerToCornerVec from the OAM's own shape and size.
    local ctc = genderFrames.ctcVec[(((r16(d + 0x00) >> 14) & 0x03) * 4)
        + ((r16(d + 0x02) >> 14) & 0x03)] or { -8, -4 }
    w8(d + 0x28, ctc[1] & 0xff)
    w8(d + 0x29, ctc[2] & 0xff)
    w8(d + 0x3e, 0x03)        -- inUse | coordOffsetEnabled
    w8(d + 0x3f, 0x04)
    g.shadowSprId, g.shadowTileStart, g.shadowTiles = sprId, tileStart, nTiles
    g.shadowDrop = (gi.height >> 1) - (genderFrames.shadowDrop[size] or 4)
    -- The pixels, now, rather than waiting for an engine copy that will never come.
    local src = r32(imagesPtr)
    if isRomPtr(src) then
        local dst = 0x06010000 + tileStart * 32
        for off = 0, bytes - 4, 4 do w32(dst + off, r32(src + off)) end
    end
    return sprId
end

function despawnGhostShadow(g)
    if not g.shadowSprId then return end
    local d = sprAddr(g.shadowSprId)
    w8(d + 0x3e, (r8(d + 0x3e) & ~0x01) | 0x04)
    -- Never free across a state load, as in freeGhostTiles.
    if genderFrames.stateLoadPurge then
        g.shadowSprId, g.shadowTileStart, g.shadowTiles = nil, nil, nil
        return
    end
    -- Deferred: an engine sprite's queued VBlank copy outlives its despawn by a frame.
    if g.shadowTileStart then
        queueTileFree({ g = g, start = g.shadowTileStart, count = g.shadowTiles or 1,
            at = frameCounter })
    end
    g.shadowSprId, g.shadowTileStart, g.shadowTiles = nil, nil, nil
end

genderFrames.shadowSpriteEnabled = true

function updateGhostShadow(g, jumping)
    if not genderFrames.shadowSpriteEnabled then return end
    if not jumping then
        if g.shadowSprId then
            w8(sprAddr(g.shadowSprId) + 0x3e, r8(sprAddr(g.shadowSprId) + 0x3e) | 0x04)
        end
        return
    end
    if not g.shadowSprId then spawnGhostShadow(g) end
    if not g.shadowSprId then return end
    local sd, cd = sprAddr(g.shadowSprId), sprAddr(g.sprId)
    w8(sd + 0x3e, r8(sd + 0x3e) & ~0x04)                       -- visible
    -- Priority follows the character's, and lives in OAM attribute 2 (bits 10-11 of +0x04); y is pos1 plus the
    -- drop, so the shadow stays grounded while the character arcs on pos2.
    w16(sd + 0x04, (r16(sd + 0x04) & 0xf3ff) | (r16(cd + 0x04) & 0x0c00))
    w16(sd + 0x20, rs16(cd + 0x20))
    w16(sd + 0x22, rs16(cd + 0x22) + (g.shadowDrop or 12))
end

UNDERWATER_GFX = { [111] = true, [112] = true } -- Brendan, May
SPRITECB_UNDERWATERSURFBLOB_CB = 0x08155850 + 1
GDUMMYSPRITETEMPLATE = 0x082ec6ac

-- No bobber: a diver's bob is the peer's own sprite offset (`soy`), already on the wire and the authority. A sprite
-- holding another's index wrote into whatever reused that slot, and a Lua bob made two writers on one field.
function spawnUnderwaterBobber(g)
    return nil
end

despawnSurfBlob = function(g)
    if not g.blobSprId then return end
    local d = sprAddr(g.blobSprId)
    w8(d + 0x3e, (r8(d + 0x3e) & ~0x01) | 0x04) -- inUse = 0, invisible = 1
    w32(d + 0x1c, 0)
    if genderFrames.stateLoadPurge then g.blobSprId, g.blobTileStart = nil, nil return end
    -- Deferred: the blob's animation re-copies its frame every frame through the VBlank queue, so a copy queued
    -- last frame lands after this despawn, over whatever re-claimed the tiles.
    if g.blobTileStart then
        queueTileFree({ g = g, start = g.blobTileStart, count = 16, at = frameCounter })
    end
    g.blobSprId, g.blobTileStart = nil, nil
end
----------------------------------------------------------------------------
-- Fly and Briney's boat: the engine hides the player's object and draws something else. Read from the engine: the
-- invisible bit, the boat object on the player's tile, and the fly task's bird sprite.
----------------------------------------------------------------------------
-- The boat's graphic uses an NPC palette slot, not the player's, so a ghost cannot simply wear it.
flyRide.BOAT_GFX = 88

-- gTasks at vanilla's address (EX moves it; see door.tasksAddr): 16 entries of 0x28, func at +0x00 (Thumb, odd),
-- isActive at +0x04, data[] at +0x08.
flyRide.TASKS_ADDR, flyRide.TASK_SIZE = 0x03005e00, 0x28
-- Task_FlyOut / Task_FlyIn, +1 for Thumb.
flyRide.TASK_FLY_OUT, flyRide.TASK_FLY_IN = 0x080b91d5, 0x080b97d5
-- Every ROM address here shifts on a patched ROM, and an unshifted one simply never matches, silently. The show-mon
-- banner scan above does not shift its addresses: a known gap.
flyRide.rom = function(a) return a + (genderFrames.romOffset or 0) end
-- The bird is recognised by its callback, not the task's state: only the swoop carries a character.
flyRide.BIRD_SWOOP_CB = 0x080b963d
-- 64 in the bird's data[6] means carrying nobody; any other value is the carried sprite's id.
flyRide.NO_RIDER = 64

-- What the sender publishes, on the table for the 200-local ceiling:
--   flyRide.invis -- the object's invisible bit (+0x01 bit 0x20): the engine is not drawing this character.
--   flyRide.boat  -- the graphicsId of the vehicle the player is riding, or nil.
--   flyRide.fly   -- nil, 1 (in the fly cutscene, still on the ground) or 2 (carried by the bird).
--   flyRide.flyk  -- the bird's arc parameter, so a receiver's bird starts in phase.
flyRide.sample = function(objId, sprId)
    local a = objAddr(objId)
    flyRide.invis = ((r8(a + 0x01) & 0x20) ~= 0) and 1 or 0
    flyRide.boat, flyRide.fly, flyRide.flyk = nil, nil, nil

    -- The boat is found on the hidden player's tile, a fact about this frame rather than a guess from the map.
    if flyRide.invis == 1 then
        local px, py = rs16(a + 0x10), rs16(a + 0x12)
        for i = 0, 15 do
            local o = objAddr(i)
            if (r8(o + 0x00) & 0x01) ~= 0 and r8(o + 0x05) == flyRide.BOAT_GFX
                and rs16(o + 0x10) == px and rs16(o + 0x12) == py then
                flyRide.boat = flyRide.BOAT_GFX
                break
            end
        end
    end

    for t = 0, 15 do
        local ta = flyRide.TASKS_ADDR + t * flyRide.TASK_SIZE
        if r8(ta + 0x04) == 1 then
            local fn = r32(ta + 0x00)
            if fn == flyRide.rom(flyRide.TASK_FLY_OUT)
                or fn == flyRide.rom(flyRide.TASK_FLY_IN) then
                -- On the ground until the bird proves otherwise: the other states are the field-move pose.
                flyRide.fly = 1
                local birdId = r16(ta + 0x08 + 1 * 2) -- data[1], tBirdSpriteId
                if birdId < flyRide.NO_RIDER then
                    local bs = sprAddr(birdId)
                    -- Validated as a live swoop sprite: data[1] holds the Pokemon's id before the bird exists.
                    if (r8(bs + 0x3e) & 0x01) ~= 0
                        and r32(bs + 0x1c) == flyRide.rom(flyRide.BIRD_SWOOP_CB) then
                        flyRide.flyk = r16(bs + 0x32) -- data[2], the arc parameter
                        if r16(bs + 0x3a) == sprId then flyRide.fly = 2 end -- data[6], the rider
                    end
                end
                break
            end
        end
    end
end

----------------------------------------------------------------------------
-- The door a ghost opens: the engine's own door task for the tile, which retires itself. That it redraws only the
-- door's tiles and tilemap, never the map grid, a save or an object, is the decompilation's reading, unmeasured.
-- Kinds: "o" open, "c" close, "h" hold open (the task started on its last open frame), since leaving a house shows
-- the door already open. The wire carries the tile, never a pointer; no sound, as the SFX belongs to the warp.
-- Vanilla addresses, shifted per build by flyRide.rom; TASK_ANIMATE is code, which does not shift with romOffset.
----------------------------------------------------------------------------
genderFrames.door = {
    TASK_ANIMATE = 0x0808a655,
    FRAMES_OPEN = 0x08496f8c,
    FRAMES_CLOSE = 0x08496fa0,
    FRAMES_BIG_OPEN = 0x08496fb4,
    GFX_TABLE = 0x08497174,
    GFX_ENTRY = 12,
    -- A bound, not a length: the table's null `tiles` terminator stops the walk; this stops one that never finds it.
    GFX_MAX = 54,
    -- Our mark in data[15], which the door task never uses: without it a ghost door is reported as our own, painted
    -- back, and echoes around the mesh. Checked in sample() only; `start` still yields to a door of ours.
    MINE = 0x6d67,
    -- The engine's door task priority, and the last open frame of a four-frame table.
    PRIORITY = 0x50,
    LAST_OPEN_FRAME = 3,
    -- Backstop for a close that never arrives (the peer dropped mid-warp); a real one follows within ~50 frames.
    HOLD_MAX_FRAMES = 120,
}

-- Is this build's door machinery where we think it is? Proven once per ROM by the tables' shape and logged either
-- way: four 4-byte frames (u8 time 4, u16 offset at +2) then a zero, and graphics entries holding two ROM pointers.
genderFrames.door.ready = function()
    -- Not before the ROM variant is known, or vanilla's addresses would be tested; uncached until then.
    local off = genderFrames.romOffset
    if off == nil then return false end
    if genderFrames.door.readyFor == off then return genderFrames.door.readyAns end
    genderFrames.door.readyFor = off
    genderFrames.door.readyAns = false

    -- The offsets as well as the times: the time bytes alone let a build pass that then matched no door task.
    local function isFrameTable(a, o0, o1, o2, o3)
        for f = 0, 3 do
            if r8(a + f * 4) ~= 4 then return false end
        end
        if r8(a + 16) ~= 0 then return false end
        return r16(a + 2) == o0 and r16(a + 6) == o1
            and r16(a + 10) == o2 and r16(a + 14) == o3
    end
    local ok = isFrameTable(flyRide.rom(genderFrames.door.FRAMES_OPEN), 0xffff, 0, 0x100, 0x200)
        and isFrameTable(flyRide.rom(genderFrames.door.FRAMES_CLOSE), 0x200, 0x100, 0, 0xffff)
        and isFrameTable(flyRide.rom(genderFrames.door.FRAMES_BIG_OPEN), 0xffff, 0, 0x200, 0x400)
    if ok then
        -- And the graphics table: its first three entries must each carry two ROM pointers.
        local base = flyRide.rom(genderFrames.door.GFX_TABLE)
        for i = 0, 2 do
            local e = base + i * genderFrames.door.GFX_ENTRY
            local tiles, pal = r32(e + 0x04), r32(e + 0x08)
            if tiles < 0x08000000 or tiles >= 0x0a000000
                or pal < 0x08000000 or pal >= 0x0a000000 then
                ok = false
                break
            end
        end
    end

    genderFrames.door.readyAns = ok
    -- Task_AnimateDoor per build, read off each engine: the code shift is not the data shift. An unknown build gets
    -- no seed and learns its own, since a wrong code address is one the engine would call.
    genderFrames.door.fn = nil
    if ok then
        genderFrames.door.fn = ({
            [0] = 0x0808a655,
            [25608] = 0x0808acc5,
            [30000] = 0x0808aff5,
            [641912] = 0x080a30dd,
        })[off]
    end
    -- The pass is logged too: otherwise silence means both "fine" and "never asked".
    logFile(string.format("f=%d DOOR tables %s: open=%08X close=%08X big=%08X gfx=%08X off=%d",
        frameCounter, ok and "OK" or "NOT FOUND",
        flyRide.rom(genderFrames.door.FRAMES_OPEN), flyRide.rom(genderFrames.door.FRAMES_CLOSE),
        flyRide.rom(genderFrames.door.FRAMES_BIG_OPEN), flyRide.rom(genderFrames.door.GFX_TABLE),
        off))
    if not ok then
        console.log("MeshGhost: the door animation tables are not at the addresses this adapter "
            .. "knows on this build, so ghosts will not open doors here (and this client will not "
            .. "tell peers about its own). Everything else is unaffected. Logged once per ROM.")
    end
    return ok
end

-- A door task is recognised by its data, not its function pointer, which shifts unlike romOffset: a door frame
-- table pointer, then a pointer on an entry boundary of the door graphics table.
genderFrames.door.isDoorTask = function(t)
    local frames = (r16(t + 0x08) << 16) | r16(t + 0x0a)
    local kind = nil
    if frames == flyRide.rom(genderFrames.door.FRAMES_CLOSE) then
        kind = "c"
    elseif frames == flyRide.rom(genderFrames.door.FRAMES_OPEN)
        or frames == flyRide.rom(genderFrames.door.FRAMES_BIG_OPEN) then
        kind = "o"
    end
    -- And tGfx must be a real entry of the graphics table: inside it, and on an entry boundary.
    local gfx = (r16(t + 0x0c) << 16) | r16(t + 0x0e)
    local tbl, entry = flyRide.rom(genderFrames.door.GFX_TABLE), genderFrames.door.GFX_ENTRY
    local gfxOk = gfx >= tbl and gfx < tbl + genderFrames.door.GFX_MAX * entry
        and (gfx - tbl) % entry == 0
    if kind and gfxOk then return kind end

    -- Either half matching alone is past coincidence: logged once per load with both values, to say which table
    -- this build's doors do not match.
    if (kind or gfxOk) and not genderFrames.door.missLogged then
        genderFrames.door.missLogged = true
        logFile(string.format(
            "f=%d DOOR half-match: frames=%08X (%s) tGfx=%08X (%s), gfx table [%08X,%08X) off=%d",
            frameCounter, (r16(t + 0x08) << 16) | r16(t + 0x0a), kind or "unknown",
            gfx, gfxOk and "in table" or "outside",
            tbl, tbl + genderFrames.door.GFX_MAX * entry, genderFrames.romOffset or 0))
    end
    return nil
end

-- Where gTasks is on this build (EX moves its IWRAM): the known address first, else found by shape and logged.
genderFrames.door.tasksAddr = function()
    if genderFrames.door.tasksAt ~= nil then return genderFrames.door.tasksAt end
    -- A retry is spaced, per the tail of this function; nil means "ask again later", not "no".
    if genderFrames.door.nextTry and frameCounter < genderFrames.door.nextTry then return nil end
    local stride = flyRide.TASK_SIZE
    local function looksLikeTasks(a)
        local active, heads = 0, 0
        for i = 0, 15 do
            local t = a + i * stride
            local act, prev, next_ = r8(t + 0x04), r8(t + 0x05), r8(t + 0x06)
            if act > 1 then return false end
            if prev > 15 and prev ~= 0xfe then return false end
            if next_ > 15 and next_ ~= 0xff then return false end
            if act == 1 then
                local fn = r32(t + 0x00)
                if fn < 0x08000000 or fn >= 0x0a000000 or (fn & 1) == 0 then return false end
                active = active + 1
                if prev == 0xfe then heads = heads + 1 end
            end
        end
        return active >= 1 and heads == 1
    end

    if looksLikeTasks(flyRide.TASKS_ADDR) then
        genderFrames.door.tasksAt = flyRide.TASKS_ADDR
        return genderFrames.door.tasksAt
    end
    -- IWRAM, four-byte aligned, leaving room for the whole table.
    for a = 0x03000000, 0x03008000 - 16 * stride, 4 do
        if looksLikeTasks(a) then
            genderFrames.door.tasksAt = a
            logFile(string.format(
                "f=%d DOOR gTasks is NOT at %08X on this build -- found at %08X (%+d)",
                frameCounter, flyRide.TASKS_ADDR, a, a - flyRide.TASKS_ADDR))
            return a
        end
    end
    -- Nothing convincing may be this moment (a title screen, a load) rather than this build: a few attempts, ten
    -- seconds apart, never a whole-IWRAM scan every frame.
    genderFrames.door.tries = (genderFrames.door.tries or 0) + 1
    genderFrames.door.nextTry = frameCounter + 600
    if genderFrames.door.tries >= 5 then
        genderFrames.door.tasksAt = false
        logFile(string.format(
            "f=%d DOOR gTasks not found in IWRAM after %d attempts -- no doors on this build",
            frameCounter, genderFrames.door.tries))
        return false
    end
    return nil
end

genderFrames.door.sample = function()
    if not genderFrames.door.ready() then return nil end
    local base, stride = genderFrames.door.tasksAddr(), flyRide.TASK_SIZE
    if not base then return nil end
    -- Resolved eagerly and logged once, so the map grid's address does not wait for a door.
    if not genderFrames.door.mapLogged then
        genderFrames.door.mapLogged = true
        local m = genderFrames.door.mapAddr()
        logFile(string.format("f=%d DOOR map grid at %s (vanilla is 03005DC0)", frameCounter,
            m and string.format("%08X", m) or "NOT FOUND"))
    end
    for i = 0, 15 do
        local t = base + i * stride
        -- A door we painted for a peer is not news: reporting it turns one door into an endless one.
        if r8(t + 0x04) == 1 and r16(t + 0x08 + 15 * 2) ~= genderFrames.door.MINE then
            local kind = genderFrames.door.isDoorTask(t)
            if kind then
                -- Identified by its data, so its func is this build's Task_AnimateDoor; only from a door watched
                -- arriving, never one we may have stranded. The engine outranks the seed, and says so.
                if genderFrames.door.sawNone and not genderFrames.door.checked then
                    local live = r32(t + 0x00)
                    if genderFrames.door.fn == nil then
                        genderFrames.door.fn = live
                        logFile(string.format(
                            "f=%d DOOR learned Task_AnimateDoor=%08X (romOffset=%d)",
                            frameCounter, live, genderFrames.romOffset or 0))
                    elseif genderFrames.door.fn ~= live then
                        console.log(string.format(
                            "MeshGhost: the door-task address this adapter has for this build "
                                .. "(%08X) is NOT what the game just used (%08X) -- taking the "
                                .. "game's. Please report this with the ROM you are playing.",
                            genderFrames.door.fn, live))
                        genderFrames.door.fn = live
                    end
                    genderFrames.door.checked = true
                end
                return genderFrames.door.publish(kind, rs16(t + 0x14), rs16(t + 0x16))
            end
        end
    end
    -- No door task this frame: the next one to appear is watched arriving, so it may teach the code address.
    genderFrames.door.sawNone = true
    -- The hold-open is never published: leaving a house leaves no task to recognise, and the receiver sees the
    -- same moment itself, a peer arriving on a door tile (see doorTick).
    return nil
end

-- The last gate before a door goes on the wire: is that padded tile a door in this build's own table? The engine
-- asks first too, before it starts a door.
genderFrames.door.publish = function(kind, px, py)
    if px < MAP_OFFSET or py < MAP_OFFSET then return nil end
    if not genderFrames.door.gfxFor(px, py) then return nil end
    return kind, px - MAP_OFFSET, py - MAP_OFFSET
end

-- The map grid, found by shape (EX moves IWRAM, by a shift no other address predicts) and shared with occlusion.
-- A wrong answer only reads the wrong metatile: nothing is executed.
genderFrames.door.mapAddr = function() return genderFrames.gridAddr() end

-- The metatile id at a padded grid coordinate.
genderFrames.door.metatileAt = function(px, py)
    local base = genderFrames.door.mapAddr()
    if not base then return nil end
    local w, h, map = memory.read_s32_le(base), memory.read_s32_le(base + 0x04), r32(base + 0x08)
    if map == 0 or w <= 0 or h <= 0 then return nil end
    if px < 0 or py < 0 or px >= w or py >= h then return nil end
    return r16(map + (px + w * py) * 2) & 0x03ff
end

-- The door graphics entry for the metatile at a padded grid coordinate, and its size; nil if not a door here.
genderFrames.door.gfxFor = function(px, py)
    local id = genderFrames.door.metatileAt(px, py)
    if not id then return nil end
    local base = flyRide.rom(genderFrames.door.GFX_TABLE)
    for i = 0, genderFrames.door.GFX_MAX - 1 do
        local e = base + i * genderFrames.door.GFX_ENTRY
        local tiles = r32(e + 0x04)
        -- The terminator, and the guard against handing the engine a garbage pointer to copy from.
        if tiles < 0x08000000 or tiles >= 0x0a000000 then return nil end
        if r16(e + 0x00) == id then return e, r8(e + 0x03) end
    end
    return nil
end

-- Links a slot into the task list: a doubly linked chain (prev +0x05, next +0x06, 0xFE head, 0xFF tail) in priority
-- (+0x07) order, not yet read back from a live gTasks. Bounded, since pcall catches errors, not loops.
genderFrames.door.insert = function(newId)
    local base, stride = genderFrames.door.tasksAddr(), flyRide.TASK_SIZE
    if not base then return false end
    local HEAD, TAIL = 0xfe, 0xff
    local function at(i) return base + i * stride end

    -- Our own slot is still inactive, so it is not in the chain; longer than the 16-entry table means corrupt.
    local order, id = {}, nil
    for i = 0, 15 do
        if r8(at(i) + 0x04) == 1 and r8(at(i) + 0x05) == HEAD then id = i break end
    end
    while id ~= nil and id ~= TAIL do
        if #order >= 16 then return false end
        order[#order + 1] = id
        local nxt = r8(at(id) + 0x06)
        id = (nxt == TAIL) and nil or nxt
    end

    -- Insert ahead of the first entry with a higher priority value (higher sorts later), else at the end.
    local mine, prio = at(newId), r8(at(newId) + 0x07)
    local before = nil
    for _, other in ipairs(order) do
        if prio < r8(at(other) + 0x07) then before = other break end
    end

    local prev, next_
    if before ~= nil then
        prev, next_ = r8(at(before) + 0x05), before
    elseif #order > 0 then
        prev, next_ = order[#order], TAIL
    else
        prev, next_ = HEAD, TAIL
    end
    w8(mine + 0x05, prev)
    w8(mine + 0x06, next_)
    if prev ~= HEAD then w8(at(prev) + 0x06, newId) end
    if next_ ~= TAIL then w8(at(next_) + 0x05, newId) end
    return true
end

-- CreateTask + StartDoorAnimationTask for one of the three kinds at a save-block tile; true if the engine now runs it.
genderFrames.door.start = function(kind, x, y)
    -- Task_AnimateDoor, learned in sample(): nil until the local player opens a door (ready() seeds it on vanilla).
    local animate = genderFrames.door.fn
    if animate == nil then return false end
    local base, stride = genderFrames.door.tasksAddr(), flyRide.TASK_SIZE
    if not base then return false end
    local free = nil
    for i = 0, 15 do
        local t = base + i * stride
        if r8(t + 0x04) == 1 then
            -- The engine runs one door animation at a time, and it may be the player's own: a ghost yields to it.
            if genderFrames.door.isDoorTask(t) then return false end
        elseif free == nil then
            free = i
        end
    end
    if free == nil then return false end
    local gfx, size = genderFrames.door.gfxFor(x + MAP_OFFSET, y + MAP_OFFSET)
    if not gfx then
        -- Logged once: only the metatile read is left to fail, and the map grid's IWRAM address moves on EX.
        if not genderFrames.door.gfxMissLogged then
            genderFrames.door.gfxMissLogged = true
            logFile(string.format(
                "f=%d DOOR no gfx for tile %d,%d (padded %d,%d): metatile=%s "
                    .. "gBackupMapLayout@03005DC0 w=%d h=%d map=%08X",
                frameCounter, x, y, x + MAP_OFFSET, y + MAP_OFFSET,
                tostring(genderFrames.door.metatileAt(x + MAP_OFFSET, y + MAP_OFFSET)),
                memory.read_s32_le(genderFrames.door.mapAddr() or 0x03005dc0),
                memory.read_s32_le((genderFrames.door.mapAddr() or 0x03005dc0) + 0x04),
                r32((genderFrames.door.mapAddr() or 0x03005dc0) + 0x08)))
        end
        return false
    end
    local frames
    if kind == "c" then
        frames = flyRide.rom(genderFrames.door.FRAMES_CLOSE)
    elseif size == 2 then
        frames = flyRide.rom(genderFrames.door.FRAMES_BIG_OPEN)
    else
        frames = flyRide.rom(genderFrames.door.FRAMES_OPEN)
    end
    local t = base + free * stride
    w32(t + 0x00, animate)
    w8(t + 0x07, genderFrames.door.PRIORITY)
    for k = 0, 15 do w16(t + 0x08 + k * 2, 0) end
    w16(t + 0x08, (frames >> 16) & 0xffff) w16(t + 0x0a, frames & 0xffff)
    w16(t + 0x0c, (gfx >> 16) & 0xffff)    w16(t + 0x0e, gfx & 0xffff)
    -- "h" starts on the last open frame: the engine draws it and retires the task, leaving the door drawn open.
    if kind == "h" then w16(t + 0x10, genderFrames.door.LAST_OPEN_FRAME) end
    w16(t + 0x14, x + MAP_OFFSET) w16(t + 0x16, y + MAP_OFFSET)
    -- data[15] -- ours, so sample() does not report this door back to the peer it came from.
    w16(t + 0x08 + 15 * 2, genderFrames.door.MINE)
    -- isActive last, and only once linked: an active task missing from the chain is never run or freed, leaking a slot.
    if not genderFrames.door.insert(free) then return false end
    w8(t + 0x04, 1)
    return true
end

-- Once per frame, play each same-area peer's door; across a seam the tile needs rebasing, and wrong is the wrong house.
-- Once per event, not per frame: a door task lives ~20 frames and the peer reports it on every one of them.
genderFrames.doorTick = function(localAreaId)
    if not genderFrames.door.ready() then return end
    for _, r in pairs(remotes) do
        -- A peer we were watching elsewhere who arrives on our map standing on a door tile has just left a house: the
        -- moment Task_ExitDoor's state 0 draws the door open, read from tiles alone, so it works on every build.
        local arrived = r.areaId == localAreaId and r.dPrevArea ~= nil
            and r.dPrevArea ~= localAreaId
        r.dPrevArea = r.areaId
        if arrived and r.x and r.y and r.dOpenAt == nil then
            local tx, ty = math.floor(r.x + 0.5), math.floor(r.y + 0.5)
            if genderFrames.door.start("h", tx, ty) then
                r.dOpenAt, r.dOpenX, r.dOpenY = frameCounter, tx, ty
                r.dHold = true
            end
        end
        -- A hold we inferred shuts when the ghost steps off the door tile, when Task_ExitDoor's state 2 closes it.
        -- Never for a door the peer opened by entering: the ghost walks onto that tile, so this would close it early.
        if r.dHold and r.dOpenAt then
            local offTile = r.areaId ~= localAreaId
            if not offTile and r.x and r.y then
                offTile = math.floor(r.x + 0.5) ~= r.dOpenX or math.floor(r.y + 0.5) ~= r.dOpenY
            end
            if offTile then
                genderFrames.door.start("c", r.dOpenX, r.dOpenY)
                r.dOpenAt, r.dHold = nil, nil
            end
        end
        if r.dk and r.dx and r.dy and r.areaId == localAreaId then
            local key = r.dk .. ":" .. r.dx .. "," .. r.dy
            if key ~= r.dKey then
                -- The key means seen, not played: an event this client cannot play is refused once, not every frame.
                local started = genderFrames.door.start(r.dk, r.dx, r.dy)
                r.dKey = key
                if started and r.dk ~= "c" then
                    r.dOpenAt, r.dOpenX, r.dOpenY = frameCounter, r.dx, r.dy
                    -- A door the peer reported has its own close coming; it is not ours to time.
                    r.dHold = nil
                elseif r.dk == "c" then
                    r.dOpenAt, r.dHold = nil, nil
                end
            end
        end
        -- A close that never came (a peer dropping mid-warp) times out; dKey stays set, or the open would replay.
        if r.dOpenAt and frameCounter - r.dOpenAt > genderFrames.door.HOLD_MAX_FRAMES then
            if r.areaId == localAreaId then
                genderFrames.door.start("c", r.dOpenX, r.dOpenY)
            end
            r.dOpenAt, r.dHold = nil, nil
        end
    end
end

-- gFieldEffectObjectTemplate_Bird: a SpriteTemplate in the layout spawnSurfBlob reads; 32x32 frames, so 16 tiles.
flyRide.BIRD_TEMPLATE = 0x0850d4a8
flyRide.BIRD_TILES = 16
-- The decompilation's palette and subpriority for the engine's bird (CreateFlyBirdSprite); not measured on a live bird.
flyRide.BIRD_PALETTE, flyRide.BIRD_SUBPRIORITY = 0, 1

-- Hide or show a ghost: the object's invisible bit (what the peer reports) and the sprite's, so it lands this frame.
flyRide.setHidden = function(g, hidden)
    local a, d = objAddr(g.objId), sprAddr(g.sprId)
    if hidden then
        w8(a + 0x01, r8(a + 0x01) | 0x20)
        w8(d + 0x3e, r8(d + 0x3e) | 0x04)
    else
        w8(a + 0x01, r8(a + 0x01) & ~0x20)
        w8(d + 0x3e, r8(d + 0x3e) & ~0x04)
    end
end

-- Put a carried sprite back on the map: the bird drives it in screen coordinates, and the engine never recomputes an
-- object's sprite position from its map coordinates. Exact on a settled camera, which a landing gives.
flyRide.reground = function(g)
    local a, d = objAddr(g.objId), sprAddr(g.sprId)
    local sx, sy = spriteScreenPos(rs16(a + 0x10), rs16(a + 0x12), r8(d + 0x29))
    w16(d + 0x20, sx) w16(d + 0x22, sy)
    w16(d + 0x24, 0) w16(d + 0x26, 0)
    w8(d + 0x3e, r8(d + 0x3e) | 0x02)  -- coordOffsetEnabled: back on the map's clock
end

-- Builds the engine's own bird from its template (none exists unless someone is already flying) and points it at
-- SpriteCB_FlyBirdSwoopDown, which carries whichever sprite data[6] names, so the flight is the engine's.
flyRide.spawnBird = function(g, k)
    if g.birdSprId then return g.birdSprId end
    local tmpl = flyRide.rom(flyRide.BIRD_TEMPLATE)
    local oamPtr, animsPtr = r32(tmpl + 0x04), r32(tmpl + 0x08)
    local imagesPtr, affinePtr = r32(tmpl + 0x0c), r32(tmpl + 0x10)
    if oamPtr == 0 or imagesPtr == 0 then return nil end

    local sprId = findFreeSpriteSlot()
    if not sprId or sprId == g.sprId then return nil end
    local tileStart = allocSpriteTiles(flyRide.BIRD_TILES)
    if not tileStart then return nil end

    local d = sprAddr(sprId)
    for off = 0, SPRITE_SIZE - 1 do w8(d + off, 0) end
    for off = 0, 7 do w8(d + off, r8(oamPtr + off)) end
    -- tileNum, palette and priority in one field: attribute 2 at +0x04 carries all three.
    w16(d + 0x04, (tileStart & 0x03ff) | (1 << 10)
        | ((flyRide.BIRD_PALETTE & 0x0f) << 12))
    w32(d + 0x08, animsPtr)
    w32(d + 0x0c, imagesPtr)
    w32(d + 0x10, affinePtr)
    w32(d + 0x1c, flyRide.rom(flyRide.BIRD_SWOOP_CB))
    -- The engine anchors the arc at (120,0), right only for the player at screen centre. Keep its anchor, translated by
    -- where the ghost stands relative to the local player, from its object coordinates (its sprite may be stranded).
    local ga = objAddr(g.objId)
    local gsx, gsy = spriteScreenPos(rs16(ga + 0x10), rs16(ga + 0x12),
        r8(sprAddr(g.sprId) + 0x29))
    local pd = sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04))
    w16(d + 0x20, (120 + gsx - rs16(pd + 0x20)) & 0xffff)
    w16(d + 0x22, (gsy - rs16(pd + 0x22)) & 0xffff)
    -- centerToCornerVec, which a hand-built sprite must be given (-16,-16 at 32x32) so its position means its centre.
    w8(d + 0x28, (-16) & 0xff)
    w8(d + 0x29, (-16) & 0xff)
    w8(d + 0x43, flyRide.BIRD_SUBPRIORITY)
    -- Seeded from the peer's own bird: both then step by 4 a frame on the engine's clock, in phase.
    w16(d + 0x32, (k or 0) & 0xffff)          -- data[2]: the arc parameter
    -- data[6], sPlayerSpriteId: empty, as StartFlyBirdSwoopDown seeds it; the caller writes the passenger every frame.
    w16(d + 0x3a, flyRide.NO_RIDER)
    w16(d + 0x3c, 0)                          -- data[7]: sAnimCompleted
    w8(d + 0x3e, 0x01)                        -- inUse, not coordOffsetEnabled: the arc is in screen coordinates
    w8(d + 0x3f, 0x04)                        -- animBeginning
    g.birdSprId, g.birdTileStart = sprId, tileStart
    return sprId
end

flyRide.despawnBird = function(g)
    if not g.birdSprId then return end
    local d = sprAddr(g.birdSprId)
    w8(d + 0x3e, (r8(d + 0x3e) & ~0x01) | 0x04) -- inUse = 0, invisible = 1
    -- Freed through the queue: the hardware draws from these tiles for two more frames (swapGhostGraphicInPlace).
    if g.birdTileStart then
        queueTileFree({ g = g, start = g.birdTileStart, count = flyRide.BIRD_TILES,
            at = frameCounter })
    end
    g.birdSprId, g.birdTileStart = nil, nil
    -- Give the passenger back to the map, position included, not just the scroll bit.
    flyRide.reground(g)
end

-- The vehicle is its own sprite with the ghost hidden inside, built like the shadow. A boat's palette is an NPC slot,
-- loaded only where the watcher's map has that boat, so this can refuse, and the caller then hides the ghost.
flyRide.spawnVehicle = function(g, gfxId)
    if g.vehicleSprId then return g.vehicleSprId end
    local gi = graphicsInfo(gfxId)
    if not gi or not gi.raw or gi.images == 0 or gi.oam == 0 then return nil end
    local slot = hwPaletteSlotForTag(gi.paletteTag)
    if not slot then return nil end
    if r16(genderFrames.spriteCallbackDummy - 1) ~= 0x4770 then return nil end

    local sprId = findFreeSpriteSlot()
    if not sprId or sprId == g.sprId then return nil end
    local bytes = r16(gi.images + 4)
    if bytes == 0 or bytes > 2048 or bytes % 32 ~= 0 then
        logFile(string.format("vehicle sprite: refusing a %d-byte frame (gfx=%d)", bytes, gfxId))
        return nil
    end
    local nTiles = bytes // 32
    local tileStart = allocSpriteTiles(nTiles)
    if not tileStart then return nil end

    local d = sprAddr(sprId)
    for off = 0, SPRITE_SIZE - 1 do w8(d + off, 0) end
    for off = 0, 7 do w8(d + off, r8(gi.oam + off)) end
    w16(d + 0x04, (tileStart & 0x03ff) | ((slot & 0x0f) << 12))
    w32(d + 0x08, gi.anims)
    w32(d + 0x0c, gi.images)
    w32(d + 0x10, gi.affineAnims)
    w32(d + 0x1c, genderFrames.spriteCallbackDummy)
    -- The ride sets the boat's subpriority to 0 (setobjectsubpriority): in front of what it passes.
    w8(d + 0x43, 0)
    w8(d + 0x28, (-(gi.width // 2)) & 0xff)
    w8(d + 0x29, (-(gi.height // 2)) & 0xff)
    w8(d + 0x3e, 0x03)        -- inUse | coordOffsetEnabled
    w8(d + 0x3f, 0x04)
    g.vehicleSprId, g.vehicleTileStart, g.vehicleTiles = sprId, tileStart, nTiles
    g.vehicleGfx = gfxId
    -- Copy the pixels now: this sprite has a do-nothing callback and no animation driver to copy them.
    local src = r32(gi.images)
    if isRomPtr(src) then
        local dst = 0x06010000 + tileStart * 32
        for off = 0, bytes - 4, 4 do w32(dst + off, r32(src + off)) end
    end
    return sprId
end

flyRide.despawnVehicle = function(g)
    if not g.vehicleSprId then return end
    local d = sprAddr(g.vehicleSprId)
    w8(d + 0x3e, (r8(d + 0x3e) & ~0x01) | 0x04)
    if g.vehicleTileStart then
        queueTileFree({ g = g, start = g.vehicleTileStart, count = g.vehicleTiles or 16,
            at = frameCounter })
    end
    g.vehicleSprId, g.vehicleTileStart, g.vehicleTiles, g.vehicleGfx = nil, nil, nil, nil
end

-- Logs what the receiver got for a fly and what it did, one line per change, to the file. Not gated on compare mode:
-- the watching client runs the shipped config, and a session that never flies writes nothing.
flyRide.trace = function(g, remote, where)
    if not remote.fly and not g.flyTraceKey then return end
    -- Received position beside the one read back from the engine: a trace of our intent would agree with itself.
    local a = g.objId and objAddr(g.objId)
    local gx = a and (rs16(a + 0x10) - MAP_OFFSET) or -1
    local gy = a and (rs16(a + 0x12) - MAP_OFFSET) or -1
    local k = string.format("%s/%s/%s/%s/%s/%d/%d/%s", where, tostring(remote.fly),
        tostring(remote.flyk), tostring(g.birdSprId), tostring(remote.flyDone), gx, gy,
        tostring(g.gfx))
    if g.flyTraceKey == k then return end
    g.flyTraceKey = k
    logFile(string.format(
        "FLY %s fly=%s flyk=%s bird=%s done=%s gfx=%s obj=%s | peer=%s (%.2f,%.2f) area=%s "
            .. "| ghost=(%d,%d) f=%d",
        where, tostring(remote.fly), tostring(remote.flyk), tostring(g.birdSprId),
        tostring(remote.flyDone), tostring(g.gfx), tostring(g.objId), tostring(remote.gfx),
        remote.x or -1, remote.y or -1, tostring(remote.areaId), gx, gy, frameCounter))
end

-- Takes over a peer the engine no longer draws as a character (a fly, then a vehicle, then invisible); true means the
-- caller must not place, step or animate it. Flight state lives on the remote, which outlives a ghost rebuild.
flyRide.apply = function(g, remote, playerId)
    flyRide.trace(g, remote, "enter")
    -- To sit on the bird the engine borrows the surfing graphic, so suppress the surf blob both attach sites would add.
    g.noBlob = remote.fly ~= nil or nil
    if remote.fly then
        -- A fly resuming after a gap is the arrival, a new flight: the departure's latch must not refuse it a bird.
        if remote.flyGapAt then
            remote.flyGapAt = nil; remote.flyDone = nil; remote.flyLastPhase = nil
        end
        despawnSurfBlob(g)
        g.wasFlying = true
        flyRide.despawnVehicle(g)
        -- The bird is built as soon as the peer has one, carrying or not, and its passenger is written every frame: the
        -- engine's bird swoops down empty and is handed the character about twenty frames later.
        if not remote.flyDone and remote.flyk then
            if remote.flyk >= 0x80 then
                -- The peer's arc is already over (seen late): latch done whatever the phase, since an arrival is handed
                -- off partway down and reports phase 1 while its arc still runs.
                remote.flyDone = true
            elseif not g.birdSprId then
                flyRide.spawnBird(g, remote.flyk)
            end
        end
        -- The passenger is restated every frame (NO_RIDER until the hand-off); the bird retires on its own done flag.
        if g.birdSprId then
            w16(sprAddr(g.birdSprId) + 0x3a,
                (remote.fly == 2) and g.sprId or flyRide.NO_RIDER)
            if r16(sprAddr(g.birdSprId) + 0x3c) ~= 0 then
                remote.flyDone = true
                flyRide.despawnBird(g)
            end
        end
        -- The phase a flight ended on is all that tells a departure from an arrival once the wire goes quiet.
        remote.flyLastPhase = remote.fly
        if remote.fly == 2 then
            -- The callback sets sAnimCompleted past 0x80 and keeps counting (the engine's task tears the sprite down;
            -- there is none here), so done is latched: one flight per fly, then hidden, as the player is, off-screen.
            flyRide.setHidden(g, remote.flyDone == true)
            return true
        end
        -- fly == 1: on the ground; an attached bird lets go. The latch is cleared by the gap branch, never here (here
        -- it would re-arm the spawn every descent frame). Re-anchor the sprite while the scroll bit says a bird had it.
        if (r8(sprAddr(g.sprId) + 0x3e) & 0x02) == 0 then flyRide.reground(g) end
        flyRide.setHidden(g, false)
        return false
    end

    -- Fly ended on the wire. Last phase 2 (carried off, mid-warp behind a fade): stay hidden until the arrival, another
    -- area or the timeout. Last phase 1: set down. The phase tells them apart; an arrival ends latched too.
    if remote.flyLastPhase == 2 then
        remote.flyGapAt = remote.flyGapAt or frameCounter
        if frameCounter - remote.flyGapAt < 480 then
            flyRide.despawnBird(g)
            g.noBlob = true
            flyRide.setHidden(g, true)
            return true
        end
    end
    remote.flyGapAt = nil
    remote.flyLastPhase = nil
    flyRide.despawnBird(g)
    remote.flyDone = nil

    -- A landed peer is rebuilt, not repaired: a fly leaves six fields wrong and, on a same-town fly, nothing else to
    -- revisit them, so drop the ghost and let the spawn path rebuild it while the landing is behind a fade.
    if g.wasFlying then
        g.wasFlying = nil
        if playerId then
            despawnGhost(playerId)
            return true
        end
    end

    if remote.boat then
        if g.vehicleGfx and g.vehicleGfx ~= remote.boat then flyRide.despawnVehicle(g) end
        if g.vehicleSprId or flyRide.spawnVehicle(g, remote.boat) then
            -- Screen position, which both sprites already agree on, so it needs no camera arithmetic.
            local cd, vd = sprAddr(g.sprId), sprAddr(g.vehicleSprId)
            w16(vd + 0x20, rs16(cd + 0x20))
            w16(vd + 0x22, rs16(cd + 0x22))
            w16(vd + 0x04, (r16(vd + 0x04) & 0xf3ff) | (r16(cd + 0x04) & 0x0c00))
            flyRide.setHidden(g, true)
            return false
        end
        -- The vehicle cannot be drawn (see spawnVehicle): hide, since a walker sliding across water is a worse lie.
        flyRide.setHidden(g, true)
        return true
    end
    flyRide.despawnVehicle(g)

    if remote.invis then
        flyRide.setHidden(g, true)
        return true
    end
    flyRide.setHidden(g, false)
    return false
end


-- Request a movement action (the fields ObjectEventSetHeldMovement writes); the engine plays out the whole tile.
local function requestAction(g, action)
    local a = objAddr(g.objId)
    w8(a + 0x1c, action)
    w8(a + 0x00, (r8(a + 0x00) | 0x40) & ~0x80) -- heldMovementActive = 1, finished = 0
    w16(sprAddr(g.sprId) + 0x32, 0) -- data[2] = sActionFuncId
    -- Give the animation back, or a held peer's animPaused freezes the legs through the step. Under the peer's
    -- disableAnim (an ice slide) set that instead, and clear it on the next step: only enableAnim ever clears it.
    if genderFrames.syncNoAnim then
        w8(a + 0x01, (r8(a + 0x01) | 0x04) & ~0x08)
    elseif (r8(a + 0x01) & 0x04) ~= 0 or (r8(sprAddr(g.sprId) + 0x2c) & 0x40) ~= 0 then
        w8(a + 0x01, (r8(a + 0x01) & ~0x04) | 0x08)
        g.animSetFor = nil -- the engine owns it again; the mirror must re-arm when it takes over
    end
end

-- A character can face one way and move another (a muddy slope): when the peer's facing and step disagree, the ghost
-- gets that facing and the lock bit so the step cannot turn it. Global: this chunk is at Lua's 200-local ceiling.
function lockGhostFacing(g, remote, stepDir)
    local a = objAddr(g.objId)
    local want = DIR_ID[remote.orientation]
    if want and stepDir and want ~= stepDir then
        w8(a + 0x18, (r8(a + 0x18) & 0xf0) | want)
        w8(a + 0x01, r8(a + 0x01) | 0x02)
    elseif (r8(a + 0x01) & 0x02) ~= 0 then
        -- Released the moment they agree again, or the ghost would face one way for ever.
        w8(a + 0x01, r8(a + 0x01) & ~0x02)
    end
end

-- The engine sets heldMovementFinished but leaves heldMovementActive set; clearing it is the caller's job.
local MOVEMENT_ACTION_NONE = 0xff
local function clearHeldMovement(g)
    local a = objAddr(g.objId)
    w8(a + 0x1c, MOVEMENT_ACTION_NONE)
    w8(a + 0x00, r8(a + 0x00) & ~0xc0) -- heldMovementActive = 0, heldMovementFinished = 0
    local d = sprAddr(g.sprId)
    w16(d + 0x30, 0) -- data[1] = sTypeFuncId
    w16(d + 0x32, 0) -- data[2] = sActionFuncId
end

-- Ready for a new order, with a watchdog: an action that never finishes would strand the ghost, and nothing real
-- outlasts 60 frames (a step is 16, a ledge jump about 24). It logs the action it frees so the fault stays visible.
local function ghostIsIdle(g)
    local a = objAddr(g.objId)
    local b0 = r8(a + 0x00)
    local active = (b0 >> 6) & 0x01
    local finished = (b0 >> 7) & 0x01
    if active == 1 and finished == 1 then
        clearHeldMovement(g)
        g.busySince = nil
        return true
    end
    if active == 1 then
        g.busySince = g.busySince or frameCounter
        if frameCounter - g.busySince > 60 then
            logFile(string.format(
                "MeshGhost: a ghost was stuck %d frames in movement action 0x%02X -- freeing it",
                frameCounter - g.busySince, r8(a + 0x1c)))
            clearHeldMovement(g)
            g.busySince = nil
            return true
        end
        return false
    end
    g.busySince = nil
    return true
end

local function teleportGhost(g, mapX, mapY)
    local a = objAddr(g.objId)
    -- Peer coordinates can skip chooseSpawned's range gate after a load, and a u16 write wraps: refuse (not clamp)
    -- anything off the grid plus its border; the low end is -MAP_OFFSET since the write adds MAP_OFFSET.
    if type(mapX) ~= "number" or type(mapY) ~= "number"
        or mapX ~= mapX or mapY ~= mapY                       -- NaN
        or mapX < -MAP_OFFSET or mapY < -MAP_OFFSET or mapX > 1000 or mapY > 1000 then
        return
    end
    mapX, mapY = math.floor(mapX), math.floor(mapY)
    local gx, gy = mapX + MAP_OFFSET, mapY + MAP_OFFSET
    w16(a + 0x0c, gx) w16(a + 0x0e, gy)
    w16(a + 0x10, gx) w16(a + 0x12, gy)
    w16(a + 0x14, gx) w16(a + 0x16, gy)
    local d = sprAddr(g.sprId)
    local sx, sy = spriteScreenPos(gx, gy, r8(d + 0x29))
    w16(d + 0x20, sx) w16(d + 0x22, sy)
    w16(d + 0x24, 0) w16(d + 0x26, 0)
    g.mapX, g.mapY = mapX, mapY
end

-- No engine animation restart for six frames after a graphic swap: its frame copy runs mid-display just after the
-- tiles moved, and tears, where ours run between frames. Six covers the OAM pipeline's ~2 plus the swap's; longer
-- stalls the field-move pose. Globals (the 200-local ceiling). MESHGHOST_EMERALD_NO_ANIM_RESTART is a probe.
ANIM_RESTART_COOLDOWN = 6
function animRestartBlocked(g)
    return MESHGHOST_EMERALD_NO_ANIM_RESTART
        or (g and g.swapAt and frameCounter - g.swapAt < ANIM_RESTART_COOLDOWN) or false
end
function animRestart(d, g)
    if animRestartBlocked(g) then
        w8(d + 0x2c, r8(d + 0x2c) | 0x40)          -- stay paused; our loads carry the pose
        w8(d + 0x3f, r8(d + 0x3f) & ~0x14)
    else
        w8(d + 0x3f, (r8(d + 0x3f) | 0x04) & ~0x10)
    end
end

-- An animation number belongs to a graphic (each has its own table, of its own length): mirror the peer's only while
-- the ghost wears the same one. A nil graphic on either side cannot disagree.
function animBelongsToGhost(g, remote)
    return remote.gfx == nil or g.gfx == nil or remote.gfx == g.gfx
end

-- Loads a frame's pixels now, so a new graphic is never worn over the old one's for the frame before the engine's
-- VBlank copy. Under COMPARE_TIERS it logs the calling line on change: a pixel state that flips means two writers.
function loadGhostFrameNow(g, info, animNum, animIdx)
    if COMPARE_TIERS then
        local who = debug.getinfo(2, "l")
        local k = string.format("%s:%s/%s", who and who.currentline or "?",
            tostring(animNum), tostring(animIdx))
        if k ~= genderFrames.lastLoadLog then
            genderFrames.lastLoadLog = k
            logFile("FRAME LOAD from line " .. k)
        end
    end
    if not info or info.anims == 0 or info.images == 0 or not g.tileStart then return end
    -- An unresolvable frame falls back to the graphic's first: the swap has just claimed fresh tiles, so returning
    -- would leave them unwritten (grey rubbish). The peer's animation number belongs to the graphic it had.
    local function resolve(an, ai)
        local animPtr = r32(info.anims + (an or 0) * 4)
        if not isRomPtr(animPtr) then return nil end
        local frame = r32(animPtr + (ai or 0) * 4) & 0xFFFF
        local p = r32(info.images + frame * 8)
        if not isRomPtr(p) then return nil end
        return p
    end
    local src = resolve(animNum, animIdx) or resolve(0, 0)
    if not src then return end
    -- OBJ VRAM, 32 bytes per 4bpp tile; info.size copies exactly one frame.
    local dst = 0x06010000 + g.tileStart * 32
    for off = 0, info.size - 4, 4 do w32(dst + off, r32(src + off)) end
    -- 128 read+write pairs for a 32x32 frame: on a change only, never per frame.
end

-- Holds a standing peer's pose (animation, index, animPaused) instead of restarting it from command 0, plus the OAM
-- flip a held sprite never gets from AnimCmd_frame (east is the west art flipped).
function applyHeldPose(g, remote)
    if not (remote.spaused and remote.sanim and remote.sidx) then return false end
    if COMPARE_TIERS and (frameCounter - (genderFrames.poseLogAt or 0)) >= 60 then
        genderFrames.poseLogAt = frameCounter
        -- What the ghost's tiles hold in VRAM, by which rows carry ink: standing and mid-stride frames differ by row.
        local fr, lr = nil, nil
        if g.tileStart then
            for row = 0, 31 do
                local tr, ly = row // 8, row % 8
                local ink = false
                for tc = 0, 1 do
                    local t = g.tileStart + tr * 2 + tc
                    for byte = 0, 3 do
                        if r8(0x06010000 + t * 32 + ly * 4 + byte) ~= 0 then ink = true break end
                    end
                    if ink then break end
                end
                if ink then
                    if not fr then fr = row end
                    lr = row
                end
            end
        end
        local gi3 = graphicsInfo(g.gfx)
        local img = "?"
        if gi3 and gi3.anims ~= 0 then
            local ap3 = r32(gi3.anims + remote.sanim * 4)
            if isRomPtr(ap3) then img = tostring(r32(ap3 + remote.sidx * 4) & 0xffff) end
        end
        local dd2 = sprAddr(g.sprId)
        logFile(string.format(
            "GHOSTPOSE f=%d want=%s/%s img=%s | ghost anim=%d/%d paused=%s tileStart=%s "
            .. "artRows=%s..%s oamTile=%d",
            frameCounter, tostring(remote.sanim), tostring(remote.sidx), img,
            r8(dd2 + 0x2a), r8(dd2 + 0x2b), tostring((r8(dd2 + 0x2c) & 0x40) ~= 0),
            tostring(g.tileStart), tostring(fr), tostring(lr),
            r16(dd2 + 0x04) & 0x3ff))
    end
    -- A pose from another graphic's table displays a frame that does not exist (animBelongsToGhost).
    if not animBelongsToGhost(g, remote) then return false end
    local d = sprAddr(g.sprId)
    local settled = r8(d + 0x2a) == remote.sanim and r8(d + 0x2b) == remote.sidx
        and (r8(d + 0x2c) & 0x40) ~= 0
    if settled and (g.heldCopiedAt or 0) + 3 < frameCounter then
        return true                      -- already held exactly here; writing again restarts it
    end
    w8(d + 0x2a, remote.sanim)
    w8(d + 0x2b, remote.sidx)
    w8(d + 0x2c, r8(d + 0x2c) | 0x40)
    -- Clear animBeginning and animEnded too: with them set the engine runs the animation once more before honouring
    -- animPaused, and copies command 0's picture into the tiles.
    w8(d + 0x3f, r8(d + 0x3f) & ~0x14)
    -- The OAM bit only, never the struct's hFlip: that is a base the animation command's flip is combined with.
    local hgi = graphicsInfo(g.gfx)
    if hgi and hgi.anims ~= 0 then
        local hap = r32(hgi.anims + remote.sanim * 4)
        if isRomPtr(hap) then
            local hfl = ((r32(hap + remote.sidx * 4) >> 22) & 1) == 1
            w16(d + 0x02, hfl and (r16(d + 0x02) | 0x1000) or (r16(d + 0x02) & 0xefff))
        end
    end
    -- The pixels last, re-asserted for three frames: the engine's sprite update between our ticks can undo one copy.
    loadGhostFrameNow(g, hgi, remote.sanim, remote.sidx)
    if not settled then g.heldCopiedAt = frameCounter end
    g.animSetFor = remote.sanim
    return true
end

-- The OAM entries the hardware draws for the ghost's and the player's tiles (128 entries, 8 bytes apart), for the
-- animation trace: struct fields only feed these, and in the fishing work they agreed while OAM x moved 8px and back.
function oamEntryFor(ghostTile, playerTile)
    local gout, pout = "-", "-"
    for i = 0, 127 do
        local a0 = r16(0x07000000 + i * 8)
        if (a0 & 0x0300) ~= 0x0200 then -- skip disabled (bit 9 set without affine)
            local a2 = r16(0x07000000 + i * 8 + 4)
            local t = a2 & 0x3ff
            local a1 = r16(0x07000000 + i * 8 + 2)
            local e = string.format("x=%d y=%d sh=%d sz=%d",
                a1 & 0x1ff, a0 & 0xff, (a0 >> 14) & 3, (a1 >> 14) & 3)
            if ghostTile and t == ghostTile then gout = e end
            if playerTile and t == playerTile then pout = e end
        end
    end
    return "gOAM[" .. gout .. "] pOAM[" .. pout .. "]"
end

-- The fishing offset follows the frame displayed, computed from the ghost's own animation command: the player's
-- offset over the wire belongs to a frame the lagging ghost is not showing yet. One rule, shared by both tiers.
function fishingFrameShift(anims, animNum, idx, facingWest)
    if not anims or anims == 0 then return 0, 0 end
    local animPtr = r32(anims + animNum * 4)
    if animPtr == 0 then return 0, 0 end
    local t = r16(animPtr + idx * 4)
    -- ANIMCMD_END (-1) means the index sits one past the last frame; the game steps back one.
    if t == 0xffff and idx > 0 then t = r16(animPtr + (idx - 1) * 4) end
    if t == 1 or t == 2 or t == 3 then
        if facingWest then return -8, 0 end
        return 8, 0
    elseif t == 5 then
        return 0, -8
    elseif t == 10 or t == 11 then
        return 0, 8
    end
    return 0, 0
end

function alignFishingGhost(g)
    local d = sprAddr(g.sprId)
    local x2, y2 = fishingFrameShift(r32(d + 0x08), r8(d + 0x2a), r8(d + 0x2b),
        (r8(objAddr(g.objId) + 0x18) & 0x0f) == 3)
    w16(d + 0x24, x2 & 0xffff)
    w16(d + 0x26, y2 & 0xffff)
end

-- The fishing graphics, 137 Brendan and 138 May (May's unmeasured).
function isFishingGfx(gfx) return gfx == 137 or gfx == 138 end

-- Every action that leaves the ground, in-place hops included: 0x0C-0x0F JUMP_2, 0x42-0x45 JUMP (the Acro side hop),
-- 0x46-0x4D JUMP_IN_PLACE, 0x70-0x7B Acro wheelie hops.
function isJumpAction(act)
    return act ~= nil and ((act >= 0x0c and act <= 0x0f)
        or (act >= 0x42 and act <= 0x4d)
        or (act >= 0x70 and act <= 0x7b))
end

-- Mach and Acro bikes, both genders: Brendan 1/63, May 90/91.
function isBikeGfx(gfx)
    return gfx == 1 or gfx == 63 or gfx == 90 or gfx == 91
end

-- Changes a ghost's graphic in place: a rebuild re-creates the object, sprite slot, tile range and every settled field
-- in one frame, which is the visible glitch. Returns false, for the caller to rebuild, when it cannot do the whole job.
function swapGhostGraphicInPlace(g, graphicsId, sanim, sox, soy, sidx, spaused, wireX, wireY)
    local info = graphicsInfo(graphicsId)
    if not info or not ghostAlive(g) then return false end
    -- Allocate before freeing: nothing runs between these writes, and a failed allocation must
    -- leave the sprite pointing at a range it still owns.
    local tileStart = allocSpriteTiles(info.tileCount)
    if not tileStart then return false end
    -- Free the old range later: hardware OAM lags the struct by two frames, and a range reclaimed now draws whatever is
    -- loaded next. Queued with its ghost, and freed only while that ghost is still itself.
    if g.tileStart then
        queueTileFree({ g = g, start = g.tileStart, count = g.tileCount, at = frameCounter })
    end

    w8(objAddr(g.objId) + 0x05, graphicsId)

    local d = sprAddr(g.sprId)
    w16(d + 0x04, (r16(d + 0x04) & 0xfc00) | (tileStart & 0x03ff))
    if info.oam ~= 0 then
        -- Shape and size only: the rest of a template OAM puts a live sprite out of step with the engine (spawnGhost).
        w16(d + 0x00, (r16(d + 0x00) & 0x3fff) | (r16(info.oam + 0x00) & 0xc000))
        w16(d + 0x02, (r16(d + 0x02) & 0x3fff) | (r16(info.oam + 0x02) & 0xc000))
    end
    w32(d + 0x08, info.anims)
    w32(d + 0x0c, info.images)
    w32(d + 0x10, info.affineAnims)
    w32(d + 0x18, info.subspriteTables)
    -- Keep the engine's subsprite table number; forcing 0 scrambles one frame at every change (spawnGhost).
    local keepSubNum = r8(d + 0x42) & 0x3f
    w8(d + 0x42, 0)
    if info.subspriteTables ~= 0 then w8(d + 0x42, keepSubNum | (1 << 6)) end
    w8(d + 0x28, (-(info.width // 2)) & 0xff)
    w8(d + 0x29, (-(info.height // 2)) & 0xff)
    -- Start the new animation and put its frame in the tiles now, ahead of the engine's VBlank copy.
    w8(d + 0x2a, sanim or 0)
    w8(d + 0x2b, 0)
    -- Arrive paused with the frame already in VRAM, never with animBeginning, whose restart copy runs mid-frame and
    -- tears. The wire mirror drives the pose from here, and requestAction's enableAnim un-pauses a stepping ghost.
    w8(d + 0x2c, r8(d + 0x2c) | 0x40)
    w8(d + 0x3f, r8(d + 0x3f) & ~0x14)
    -- The sprite offset in the same batch as the shape: a 32-wide fishing frame sits on its tile only with its offset.
    g.gfx, g.tileStart, g.tileCount = graphicsId, tileStart, info.tileCount
    g.swapAt = frameCounter -- opens the animation-restart cooldown; see animRestart
    if isFishingGfx(graphicsId) then
        alignFishingGhost(g)
    else
        if sox then w16(d + 0x24, sox & 0xffff) end
        if soy then w16(d + 0x26, soy & 0xffff) end
    end
    g.animSetFor = nil -- a new graphic always re-issues its animation, whatever the number was
    -- The peer's frame index, not 0: a held sprite is paused, so nothing would repaint a wrong frame.
    loadGhostFrameNow(g, info, sanim or 0, sidx or 0)
    w8(sprAddr(g.sprId) + 0x2b, sidx or 0)

    -- And the companion sprite the state owns: entering water comes through this swap rather than spawnGhost, so the
    -- blob is made here, and dropped on leaving (it follows the object in its data[2]); never while flying (g.noBlob).
    if SURFING_GFX[graphicsId] and not g.noBlob then
        if not g.blobSprId then
            -- At the wire tile, the jump's destination, as the engine spawns its blob at tDestX/tDestY. Not during a
            -- mount jump: the wire and the ghost both still name the land tile, so syncGhost's mount block spawns it.
            if not (g.jsActive and not g.jsDismount) then
                local a = objAddr(g.objId)
                spawnSurfBlob(g, wireX or (rs16(a + 0x10) - MAP_OFFSET),
                    wireY or (rs16(a + 0x12) - MAP_OFFSET))
            end
        end
    elseif UNDERWATER_GFX[graphicsId] then
        -- Diving is a warp, so the spawn path usually makes the bobber; a peer spawned as a walker comes through here.
        if not g.blobSprId then spawnUnderwaterBobber(g) end
    else
        despawnSurfBlob(g)
    end
    return true
end

-- One remote, one frame. Spawn if missing, step it if it moved one tile, teleport if it jumped,
-- and turn it on the spot otherwise.
local function syncGhost(playerId, remote)
    -- The peer's disableAnim for requestAction, on a table rather than a new local (the 200-local ceiling).
    genderFrames.syncNoAnim = remote.noanim
    local targetX = math.floor(remote.x + 0.5)
    local targetY = math.floor(remote.y + 0.5)
    if playerId:match("%-ghost$") then
        targetX = targetX + LOOPBACK_GHOST_OFFSET_TILES_X
        targetY = targetY + LOOPBACK_GHOST_OFFSET_TILES_Y
    end

    -- No ghost for a peer carried away and still in the warp gap (a cross-town fly changes its area before the arrival
    -- starts), unless it is flying again: the arrival's own fly frames are what end the gap.
    if remote.flyLastPhase == 2 and remote.flyGapAt and not remote.fly
        and frameCounter - remote.flyGapAt < 480 and not ghosts[playerId] then
        return
    end
    -- Nor for a peer the engine is not drawing, for a watcher that never saw the departure: its invisible bit covers
    -- the warp landing until the arrival starts (cleared in FlyInFieldEffect_BirdSwoopDown).
    if remote.invis and not ghosts[playerId] then return end

    local g = ghosts[playerId]
    if g and not ghostAlive(g) then
        -- The engine cleared (map load) or culled the ghost, tiles and blob with it: drop the record, free nothing.
        -- Logged, at most once a second, so a ghost that vanishes and comes back has a line to match.
        if not tiering.lastReclaimFrame or frameCounter - tiering.lastReclaimFrame > 60 then
            tiering.lastReclaimFrame = frameCounter
            -- logFile, not console.log: a console line is a GUI append, and reclaims cluster at seams and doors.
            logFile(string.format(
                "MeshGhost: the engine reclaimed %s's ghost slot (%s) -- respawning.",
                tostring(playerId), inOverworld() and "cull or map load" or "not the overworld"))
        end
        ghosts[playerId] = nil
        g = nil
        -- Sweep now: a partly reclaimed object is orphaned as of this line, and the replacement spawns next.
        sweepOrphanGhosts()
    end
    if not g then
        -- A peer already found the object array full this frame, and it cannot empty mid-frame: skip the re-scan.
        if tiering.blockedFrame == frameCounter then return end
        -- Placement is only exact on a settled camera; a frame's wait is free. Spawn only within +/-8 x and +/-7 y of
        -- the player, inside the 15x10 screen: the engine culls anything outside, looping spawn, cull, respawn.
        local pvX = rs16(objAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05)) + 0x10) - MAP_OFFSET
        local pvY = rs16(objAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05)) + 0x12) - MAP_OFFSET
        if math.abs(targetX - pvX) > 8 or math.abs(targetY - pvY) > 7 then return end
        if cameraIsSettled() then
            local wantNow = wantedGfx(remote)
            spawnGhost(playerId, targetX, targetY, remote.orientation, wantNow)
            -- Every path that gives a ghost a graphic gives it that graphic's state: a respawn never saw the swap.
            local ng = ghosts[playerId]
            if ng then
                local d = sprAddr(ng.sprId)
                -- A standing peer is held, not restarted.
                if not applyHeldPose(ng, remote) and remote.sanim then
                    w8(d + 0x2a, remote.sanim)
                    animRestart(d, ng)
                end
                -- After the animation write, so the offset is computed from the frame the ghost will show.
                if isFishingGfx(wantNow) then
                    alignFishingGhost(ng)
                else
                    if remote.sox then w16(d + 0x24, remote.sox & 0xffff) end
                    if remote.soy then w16(d + 0x26, remote.soy & 0xffff) end
                end
                -- The graphic spawnGhost actually chose: wantNow is nil when the peer's graphic is not adopted, and nil
                -- info would leave the fresh tiles unwritten.
                loadGhostFrameNow(ng, graphicsInfo(ng.gfx), remote.sanim, remote.sidx)
            end
        end
        return
    end

    -- Is this peer still a character? On a boat or in a fly the engine is drawing something else, so stop here.
    if flyRide.apply(g, remote, playerId) then return end

    -- Mirror the peer's animation where nothing else drives it: our movement actions animate the walking graphic (0,
    -- 89), not a rod, bike or surfboard, and under disableAnim (an ice slide) the engine would hold the wrong frame.
    local engineDrivesAnim = (remote.gfx == nil or remote.gfx == 0 or remote.gfx == 89)
        and not remote.noanim
    -- Only once the ghost wears that graphic (the peer's is held six frames on the way out, its offset is not). A
    -- walker with no held movement running is mirrored too (movementActionId keeps the last action's number).
    if PEER_GFX_ENABLED and remote.sanim and g.gfx == remote.gfx
        and (not engineDrivesAnim
            or (remote.spaused and (r8(objAddr(g.objId)) & 0x40) == 0))
        -- On a bike the peer's number wins even while moving: the action's own animation (8) runs to its end and holds
        -- while the player rides on 4. The number only, so the engine still advances the frames.
        and (remote.anim ~= "walking" and remote.anim ~= "running" or isBikeGfx(remote.gfx))
        -- Not while the peer is moving (pspeed above 0; older peers send none), unless a bike rider is sending a
        -- movement action, not a face one; bikeSpeed cannot tell, since it stays 0 on the Acro.
        and (remote.pspeed == nil or remote.pspeed == 0
            or (isBikeGfx(remote.gfx) and remote.act and remote.act > 0x03 and remote.act ~= 0xff))
        -- The bike escape covers jumps too: a held B is one repeating action, so the peer's animation number is the
        -- only writer that can turn a ghost mid-hop.
        and (ghostIsIdle(g)
            or (isBikeGfx(remote.gfx) and remote.act and remote.act > 0x03
                and remote.act ~= 0xff)) then
        local d = sprAddr(g.sprId)
        -- Set the animation, never re-set it: animSetFor is what we last set (the engine moves the live value), and it
        -- re-arms whenever the engine has paused the sprite, as it does at every plain standing graphic.
        if (r8(d + 0x2c) & 0x40) ~= 0 then g.animSetFor = nil end

        if COMPARE_TIERS and genderFrames.lastSp ~= tostring(remote.spaused) then
            genderFrames.lastSp = tostring(remote.spaused)
            logFile("WIRE spaused -> " .. genderFrames.lastSp .. " (act=" .. tostring(remote.act) .. ")")
        end
        -- The field-move pose (gfx 3/93) joins the bikes: it keeps one animation and steps only its index (0/0-0/4 in
        -- 16 frames) from the game's field-move task, which a ghost lacks. Surfing and fishing keep their paths.
        if (isBikeGfx(remote.gfx) or remote.gfx == 3 or remote.gfx == 93)
            and not remote.spaused then
            -- Number and pixels on a change only (a restart resets the cycle; a copy per frame is costly). While the
            -- peer's jump differs from the ghost's action, stand aside, or it hops one way wearing another's art.
            local agrees = not isJumpAction(remote.act)
                or r8(objAddr(g.objId) + 0x1c) == remote.act
            -- Mirror the pair, not just the number (the field-move pose steps only its index). The index only while
            -- restarts are blocked: outside the cooldown the engine owns it.
            local pairKey = (remote.sanim or 0) * 256 + (remote.sidx or 0)
            if agrees and animBelongsToGhost(g, remote) and g.animPairFor ~= pairKey then
                g.animPairFor = pairKey
                w8(d + 0x2a, remote.sanim)
                if animRestartBlocked(g) then w8(d + 0x2b, remote.sidx or 0) end
                loadGhostFrameNow(g, graphicsInfo(g.gfx), remote.sanim, remote.sidx or 0)
            end
            -- And un-pause it: the engine pauses a sprite whenever its object settles, freezing the legs between steps.
            if (r8(d + 0x2c) & 0x40) ~= 0 then
                w8(objAddr(g.objId) + 0x01, r8(objAddr(g.objId) + 0x01) | 0x08)
            end
        elseif remote.spaused and remote.sidx then
            -- The held pose, through the helper the spawn path shares.
            if COMPARE_TIERS then
                logFile(string.format("HELD LOAD: g.gfx=%s live=%d sanim=%s sidx=%s tileStart=%s"
                    .. " oamTile=%d", tostring(g.gfx), r8(objAddr(g.objId) + 0x05),
                    tostring(remote.sanim), tostring(remote.sidx), tostring(g.tileStart),
                    r16(sprAddr(g.sprId) + 0x04) & 0x3ff))
            end
            applyHeldPose(g, remote)
        elseif g.animSetFor ~= remote.sanim and animBelongsToGhost(g, remote) then
            w8(d + 0x2a, remote.sanim)
            animRestart(d, g)
            -- And let the engine play it: enableAnim (TryEnableObjectEventAnim) un-pauses the sprite. Not inside the
            -- swap cooldown, where un-pausing lets the engine's mid-frame copies back; animSetFor stays nil to retry.
            if not animRestartBlocked(g) then
                w8(objAddr(g.objId) + 0x01, r8(objAddr(g.objId) + 0x01) | 0x08)
                g.animSetFor = remote.sanim
            end
        end

        -- And the sprite offset the fishing task applies (8,0 keeps a 32-wide frame on its tile), which a ghost lacks.
        if isFishingGfx(g.gfx) then
            -- The BuildOamBuffer hook owns this when active: written here, between frames, the engine advances the
            -- animation before building OAM, and image and offset change on different frames.
            if not tiering.fishAlignActive then alignFishingGhost(g) end
        elseif g.blobSprId then
            -- A surf blob drives its rider's pos2 (the bob), so the peer's offset is not written over it.
        else
            if remote.sox then w16(d + 0x24, remote.sox & 0xffff) end
            if remote.soy then w16(d + 0x26, remote.soy & 0xffff) end
        end
    end

    -- Underwater the bob is a position, not an animation, so it applies while moving too (the game drives it with a
    -- dummy sprite we do not reproduce), unless a surf blob owns the field.
    if g.gfx and UNDERWATER_GFX[g.gfx] and not g.blobSprId and remote.soy then
        local dw = sprAddr(g.sprId)
        w16(dw + 0x26, remote.soy & 0xffff)
        if remote.sox then w16(dw + 0x24, remote.sox & 0xffff) end
    end

    -- Slide counter, per second: frames mid-step, how many changed animCmdIndex, and how many were spent paused. A
    -- moving sprite that is paused is sliding, which no position reading can see.
    if tiering.slide then
        local gd = sprAddr(g.sprId)
        local idx = r8(gd + 0x2b)
        if not ghostIsIdle(g) then
            tiering.slide.step = tiering.slide.step + 1
            if g.lastIdx ~= nil and g.lastIdx ~= idx then
                tiering.slide.legs = tiering.slide.legs + 1
            end
            if (r8(gd + 0x2c) & 0x40) ~= 0 then
                tiering.slide.paused = tiering.slide.paused + 1
            end
        end
        g.lastIdx = idx
    end

    -- Animation-alignment trace (probe, MESHGHOST_EMERALD_ANIM_TRACE): the player's and the ghost's animation state and
    -- real OAM entries on one line, buffered to a file, since per-frame console output or io.open changes the reading.
    if tiering.animTrace then
        local pd = sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04))
        local gd = sprAddr(g.sprId)
        tiering.animTraceBuf = tiering.animTraceBuf or {}
        do
            tiering.animTraceBuf[#tiering.animTraceBuf + 1] = string.format(
                "f=%d P.gfx=%s P.anim=%d/%d P.2c=%02x P.fl=%02x P.pos2=%d,%d | R.gfx=%s R.sanim=%s/%s R.anim=%s R.act=%s R.sox=%s | G.gfx=%s G.anim=%d/%d G.2c=%02x G.fl=%02x G.pos2=%d,%d G.setFor=%s | idle=%s | G.pos1=%d,%d G.crd=%d,%d R.xy=%.3f,%.3f objdir=%d act=%d | %s",
                frameCounter, tostring(localGraphicsId()),
                r8(pd + 0x2a), r8(pd + 0x2b), r8(pd + 0x2c), r8(pd + 0x3f), rs16(pd + 0x24), rs16(pd + 0x26),
                tostring(remote.gfx), tostring(remote.sanim), tostring(remote.sidx),
                tostring(remote.anim), tostring(remote.act), tostring(remote.sox),
                tostring(g.gfx), r8(gd + 0x2a), r8(gd + 0x2b), r8(gd + 0x2c), r8(gd + 0x3f),
                rs16(gd + 0x24), rs16(gd + 0x26), tostring(g.animSetFor),
                tostring(ghostIsIdle(g)),
                rs16(gd + 0x20), rs16(gd + 0x22),
                rs16(objAddr(g.objId) + 0x10) - MAP_OFFSET,
                rs16(objAddr(g.objId) + 0x12) - MAP_OFFSET,
                remote.x, remote.y,
                r8(objAddr(g.objId) + 0x18) & 0x0f,
                r8(objAddr(g.objId) + 0x1c),
                oamEntryFor(g.tileStart, r16(pd + 0x04) & 0x3ff))
        end
        if #tiering.animTraceBuf >= 120 then
            local tf = io.open(SCRIPT_DIR .. "probes/animtrace.log", "a")
            if tf then
                tf:write(table.concat(tiering.animTraceBuf, string.char(10)) .. string.char(10))
                tf:close()
            end
            tiering.animTraceBuf = {}
        end
    end
    -- Park the blob once a dismount is on the wire, every frame, before the busy guard. Mount and dismount share action
    -- ids; order tells them apart: a mount makes its blob after the jump starts, a dismount's exists before it.
    local inJs = remote.act and remote.act >= 0x3a and remote.act <= 0x3d
    if inJs and not g.jsActive then
        g.jsActive, g.jsDismount = true, g.blobSprId ~= nil
    elseif not inJs then
        -- The jump ended: hand a mount's inert blob to the engine, as PlayerAvatarTransition_Surfing does.
        if g.jsActive and not g.jsDismount and g.blobSprId then
            local bd = sprAddr(g.blobSprId)
            w8(bd + 0x2e, (r8(bd + 0x2e) & 0xf0) | 1) -- surfBlob.bobMode
        end
        g.jsActive, g.jsDismount = nil, nil
    end
    -- A mount's blob is born once the engine holds the ghost's jump: InitJump writes the destination into its coords.
    if inJs and not g.jsDismount and not g.blobSprId and g.gfx and SURFING_GFX[g.gfx]
        and not g.noBlob then
        local ja = objAddr(g.objId)
        local heldAct = r8(ja + 0x1c)
        if heldAct >= 0x3a and heldAct <= 0x3d then
            local bid = spawnSurfBlob(g, rs16(ja + 0x10) - MAP_OFFSET, rs16(ja + 0x12) - MAP_OFFSET)
            -- Re-place it from the rider's sprite: spawnSurfBlob's screen math is exact only on a resting camera, and a
            -- mount jump moves it. The engine seats a blob at rider + (0, +8); the arc in pos2 is not copied.
            if bid then
                -- Plus the jump's one-tile step: the rider's sprite is still on the land tile at the accept frame
                -- (JUMP_SPECIAL_DOWN..RIGHT, 0x3A..0x3D).
                local dxs = { [0x3a] = 0, [0x3b] = 0, [0x3c] = -TILE, [0x3d] = TILE }
                local dys = { [0x3a] = TILE, [0x3b] = -TILE, [0x3c] = 0, [0x3d] = 0 }
                local gs2, bd2 = sprAddr(g.sprId), sprAddr(bid)
                w16(bd2 + 0x20, (rs16(gs2 + 0x20) + (dxs[heldAct] or 0)) & 0xffff)
                w16(bd2 + 0x22, (rs16(gs2 + 0x22) + (dys[heldAct] or 0) + 8) & 0xffff)
            end
        end
    end
    if inJs and g.blobSprId then
        local bd = sprAddr(g.blobSprId)
        if g.jsDismount then
            w8(bd + 0x2e, (r8(bd + 0x2e) & 0xf0) | 2) -- BOB_JUST_MON: park in the water
        else
            -- A mount's blob stays inert (bob state none) until the rider lands on it, waiting in the water.
            w8(bd + 0x2e, r8(bd + 0x2e) & 0xf0)    -- BOB_NONE: wait at the destination
        end
    end
    -- Never interrupt a half-played step, except for a pending non-fishing graphic change: the engine owns pos2
    -- mid-step, so a rod swapped then draws 8px off, but bike and walker frames carry no offset.
    if not ghostIsIdle(g) then
        local pending = wantedGfx(remote)
        if not (pending and g.gfx and pending ~= g.gfx
            and not isFishingGfx(pending) and not isFishingGfx(g.gfx)) then
            return
        end
    end

    -- The peer changed what they are (a bike, surfing, a rod): patched in place where possible, so nothing is missing,
    -- doubled or wearing the old pixels.
    local wantNow = wantedGfx(remote)
    -- A graphic change ends in a settle: a static zero-motion step, so the engine sets the pose itself.
    if COMPARE_TIERS and remote.gfx ~= g.gfxWireSeen then
        g.gfxWireSeen = remote.gfx
        logFile(string.format("f=%d GFX on wire -> %s (ghost wears %s, idle=%s)",
            frameCounter, tostring(remote.gfx), tostring(g.gfx), tostring(ghostIsIdle(g))))
    end
    if wantNow and g.gfx and wantNow ~= g.gfx then
        if COMPARE_TIERS then logFile(string.format("f=%d emu=%d SWAP %s -> %s", frameCounter, emu.framecount(), tostring(g.gfx), tostring(wantNow))) end
        -- No settle for the field-move pose: a 16-frame transient, and the settle's step would keep the ghost busy past
        -- the mirror that drives its frames.
        if not (wantNow == 3 or wantNow == 93) then
            g.needsSettle = true
            g.settleStatic = true
        end
        g.frameFor = nil
    end
    if wantNow and g.gfx and wantNow ~= g.gfx
        and swapGhostGraphicInPlace(g, wantNow, remote.sanim, remote.sox or 0, remote.soy or 0,
            remote.sidx, remote.spaused,
            -- targetX/Y, not raw wire: the loopback ghost's blob is born at its own destination.
            targetX, targetY)
    then
        -- No offset write: the swap set it with the shape, and the wire value is the player's newer frame's.
        return
    end

    -- When the swap cannot patch, rebuild the sprite, as the engine does for the player's own change.
    local want = wantedGfx(remote)
    if want and g.gfx and want ~= g.gfx and cameraIsSettled() then
        local a = objAddr(g.objId)
        local atX, atY = rs16(a + 0x10) - MAP_OFFSET, rs16(a + 0x12) - MAP_OFFSET
        despawnGhost(playerId)
        spawnGhost(playerId, atX, atY, remote.orientation, want)
        -- Fill the new sprite's tiles with the frame now, so no frame shows the old graphic's pixels.
        local ng = ghosts[playerId]
        if ng then loadGhostFrameNow(ng, graphicsInfo(want), remote.sanim, remote.sidx) end
        -- Sweep in the same frame: despawnGhost leaves an object it cannot prove is ours active beside the new one.
        sweepOrphanGhosts()
        -- And the peer's sprite offset in the same frame, since this path returns before the mirror.
        if ng then
            local nd = sprAddr(ng.sprId)
            if remote.sanim then
                w8(nd + 0x2a, remote.sanim)
                animRestart(nd, ng)
                -- A rebuilt ghost is paused like a swapped one; let the engine play it.
                if not animRestartBlocked(ng) then
                    w8(objAddr(ng.objId) + 0x01, r8(objAddr(ng.objId) + 0x01) | 0x08)
                    ng.animSetFor = remote.sanim
                end
            end
            if isFishingGfx(ng.gfx) then
                alignFishingGhost(ng)
            else
                if remote.sox then w16(nd + 0x24, remote.sox & 0xffff) end
                if remote.soy then w16(nd + 0x26, remote.soy & 0xffff) end
            end
        end
        return
    end


    -- Actions positions cannot recover (a ledge hop, the bunny hop, the Acro family: one arc, or on the spot) are the
    -- peer's movementActionId performed verbatim, latched on its value so a hold is not restarted. In-place ones are
    -- held; a travelling one must not stop the step logic, which keeps the ghost following. First, release our side-hop
    -- facing lock once the peer leaves the side-hop range (SetObjectEventDirection refuses while it is set);
    -- lockGhostFacing shares the bit and runs after, so it can re-assert it.
    if g.sideHopLock and not (remote.act and remote.act >= 0x42 and remote.act <= 0x45) then
        local sa = objAddr(g.objId)
        w8(sa + 0x01, r8(sa + 0x01) & ~0x02)
        g.sideHopLock = nil
    end

    local inPlace = remote.act and (
        (remote.act >= 0x46 and remote.act <= 0x4d)
        or (remote.act >= 0x64 and remote.act <= 0x73)
        or (remote.act >= 0x7c and remote.act <= 0x7f))
    -- Travelling actions. The ledge jump 0x0C..0x0F, the surf jump 0x3A..0x3D and the side hop 0x42..0x45 are performed
    -- verbatim: each covers ground in one arc no step reproduces, and the engine then gives the ghost the landing. The
    -- Acro hop (0x74..0x7B) and wheelie-move (0x80..0x8B) families become animation-only below.
    local travels = remote.act and (
        (remote.act >= 0x0c and remote.act <= 0x0f)
        or (remote.act >= 0x3a and remote.act <= 0x3d)
        or (remote.act >= 0x42 and remote.act <= 0x45)
        or (remote.act >= 0x74 and remote.act <= 0x7b)
        or (remote.act >= 0x80 and remote.act <= 0x8b))
    -- Compare mode: one line per change of the peer's action, with what the ghost is doing at that moment.
    if COMPARE_TIERS and g.lastAct ~= remote.act then
        g.lastAct = remote.act
        -- The sent graphic beside the received one: only both together say which end is wrong.
        logFile(string.format("ACT sending gfx=%s | peer=%s -> ghost act=%d idle=%s inPlace=%s "
            .. "travels=%s gfx=%s pos2=%d,%d",
            string.format("%s (confirmed=%s objId=%d raw=%d sent=%s pending=%s ticks=%s)",
                tostring(localGraphicsId()), tostring(avatarAddrConfirmed),
                r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05),
                r8(GOBJECTEVENTS_ADDR + avatarAddrOffset
                    + r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05) * OBJECTEVENT_SIZE + 0x05),
                tostring(genderFrames.sentGfx), tostring(genderFrames.pendingGfx),
                tostring(genderFrames.pendingTicks)),
            tostring(remote.act), r8(objAddr(g.objId) + 0x1c), tostring(ghostIsIdle(g)),
            tostring(inPlace and true or false), tostring(travels and true or false),
            tostring(remote.gfx), rs16(sprAddr(g.sprId) + 0x24), rs16(sprAddr(g.sprId) + 0x26)))
    end
    -- A travelling action moves the ghost itself, so issuing it and stepping too moves it twice. The Acro families are
    -- used for their animation only: the step below asks for the same family (base = act & 0xFC, four ids in DIR order)
    -- in the direction the ghost needs.
    local acroBase = nil
    if travels and remote.act >= 0x74 then acroBase = remote.act & 0xfc end
    if acroBase then travels = false end

    -- A pose holds until released: once the peer moves on, let go, or the ghost never goes idle and stops following.
    if not (inPlace or travels) then
        if g.jumped then clearHeldMovement(g) end
        g.jumped = nil
    end
    -- Clear the latch once idle so a repeated hop re-fires; a held pose never goes idle, so it still issues once.
    if inPlace and g.jumped == remote.act and ghostIsIdle(g) then g.jumped = nil end
    -- Pose only at the target tile: this branch returns without stepping, so a pose must not cost a tile still owed.
    if inPlace and not travels
        and (targetX ~= rs16(objAddr(g.objId) + 0x10) - MAP_OFFSET
            or targetY ~= rs16(objAddr(g.objId) + 0x12) - MAP_OFFSET)
    then
        inPlace = false
    end
    -- Latch an action only once the ghost was idle to take it: an order given mid-arc is dropped, so it is re-sent each
    -- frame until it lands.
    -- Wait out a pending graphic swap: the engine picks the action's animation for the graphic worn at that instant,
    -- and the field-move graphic has no surf-jump animation. Gated on a pending swap, not on the graphics differing:
    -- with peer graphics off a ghost wears the local graphic, so differing is the normal state.
    local swapPending = (function()
        local w = wantedGfx(remote)
        return w ~= nil and g.gfx ~= nil and w ~= g.gfx
    end)()
    if (inPlace or travels) and g.jumped ~= remote.act and not swapPending then
        if ghostIsIdle(g) then
            g.jumped = remote.act
            g.needsSettle = nil
            -- A side hop keeps its facing: set facingDirectionLocked before the jump; the standing-on-target branch
            -- releases it. objAddr directly: `a` is declared further down, and reading it here would be a nil global.
            if remote.act >= 0x42 and remote.act <= 0x45 then
                local ja = objAddr(g.objId)
                w8(ja + 0x01, r8(ja + 0x01) | 0x02)
                g.sideHopLock = true
            end
            -- A dismount parks the blob in the water before the jump, as the game's own blob does. A mount's blob is
            -- created moments before its jump, a dismount's has lived the whole surf. No restore: the walker graphic's
            -- swap despawns it.
            if remote.act >= 0x3a and remote.act <= 0x3d and g.blobSprId
                and g.blobSince and frameCounter - g.blobSince > 30 then
                local bd = sprAddr(g.blobSprId)
                w8(bd + 0x2e, (r8(bd + 0x2e) & 0xf0) | 2) -- BOB_JUST_MON
            end
            requestAction(g, remote.act)
        end
        return
    end

    local dir = DIR_ID[remote.orientation] or DIR_ID.south

    -- Trust the engine's coordinates: it owns the object mid-step, and a cancelled step would desync our record.
    local a = objAddr(g.objId)
    local curX = rs16(a + 0x10) - MAP_OFFSET
    local curY = rs16(a + 0x12) - MAP_OFFSET
    local dx, dy = targetX - curX, targetY - curY

    -- Hop trace: which branch decided, every 15 frames. Its own flag: four lines a second per peer is costly.
    if (MESHGHOST_EMERALD_HOP_TRACE or os.getenv("MESHGHOST_EMERALD_HOP_TRACE")) and frameCounter % 15 == 0 then
        logFile(string.format("HOP act=%s inPlace=%s travels=%s latch=%s d=%d,%d idle=%s "
            .. "ghostAct=%d held=%02X orient=%s gFace=%d",
            tostring(remote.act), tostring(inPlace and true or false),
            tostring(travels and true or false), tostring(g.jumped), dx, dy,
            tostring(ghostIsIdle(g)), r8(a + 0x1c), r8(a + 0x00),
            tostring(remote.orientation), r8(a + 0x18) & 0x0f)
            .. string.format(" | peer=%.2f,%.2f ghost=%d,%d | gfx ghost=%s peer=%s want=%s",
                remote.x, remote.y, curX, curY, tostring(g.gfx), tostring(remote.gfx),
                tostring(wantedGfx(remote))))
    end
    -- At the target tile, re-issue the peer's own jump whenever the ghost comes free: the id carries the direction, so
    -- it is the turn and the hop in one, in step with the peer's bounces and never interrupting one mid-arc.
    if isJumpAction(remote.act) and dx == 0 and dy == 0 then
        if ghostIsIdle(g) then
            g.jumped = remote.act
            requestAction(g, remote.act)
        end
        return
    end
    if inPlace and dx == 0 and dy == 0 then return end

    if dx == 0 and dy == 0 then
        -- Nowhere left to go: drop the facing lock a side hop leaves set, or a turn on the spot is never adopted.
        if (r8(a + 0x01) & 0x02) ~= 0 then w8(a + 0x01, r8(a + 0x01) & ~0x02) end
        -- A rider turns with the static face action: FACE_ACTION is walk-in-place, which is how only a walker turns.
        if (r8(a + 0x18) & 0x0f) ~= dir then
            requestAction(g, (isBikeGfx(remote.gfx) and FACE_STILL_ACTION or FACE_ACTION)[dir])
            g.stillSince = nil
            return
        end
        -- Facing is right and the peer has not moved; if it still reports movement, it is walking into something.
        local moving = (remote.anim == "walking" or remote.anim == "running")
        if not moving then
            g.stillSince = nil
            -- Settle after a run or a ride: the engine leaves the object on its last moving frame, and facing the way
            -- it already faces is how the game itself settles a character.
            if g.needsSettle then
                g.needsSettle = nil
                g.frameFor = nil
                -- The static pose on a bike, and after any graphic change.
                if COMPARE_TIERS and g.settleStatic then logFile(string.format("f=%d SETTLE fires", frameCounter)) end
                requestAction(g, ((g.settleStatic or isBikeGfx(remote.gfx))
                    and FACE_STILL_ACTION or FACE_ACTION)[dir])
                g.settleStatic = nil
                -- Hand the settle the peer's animation number (no animBeginning), so through the settle the engine
                -- advances a standing animation rather than the pedal cycle.
                if remote.sanim and animBelongsToGhost(g, remote) then
                    w8(sprAddr(g.sprId) + 0x2a, remote.sanim)
                end
            end
            -- Copy the frame the peer displays into the ghost's tiles: a standing object advances no animation, so
            -- nothing else copies its image. Only on a change (a copy is 128 read+write pairs), and only once
            -- movementActionId is NONE, or the engine's next catch-up step copies a moving frame over it.
            if r8(a + 0x1c) ~= MOVEMENT_ACTION_NONE then
                g.frameFor = nil
            elseif remote.sanim and g.gfx and animBelongsToGhost(g, remote) then
                local key = remote.sanim * 8 + (remote.sidx or 0)
                if g.frameFor ~= key then
                    g.frameFor = key
                    loadGhostFrameNow(g, graphicsInfo(g.gfx), remote.sanim, remote.sidx)
                end
            end
            return
        end
        g.stillSince = g.stillSince or frameCounter
        -- No bump on a bike: BUMP_ACTION is a walker's shuffle against a wall. What a blocked rider does is unmeasured.
        if frameCounter - g.stillSince >= BUMP_AFTER_FRAMES and not isBikeGfx(remote.gfx) then
            requestAction(g, BUMP_ACTION[dir])
        end
        return
    end
    g.stillSince = nil

    -- The peer's speed class as the game's own step: FAST -> WALK_FAST 0x15, FASTER/FASTEST -> WALK_FASTER 0x2D.
    local base = nil
    if remote.pspeed == 2 then base = 0x15
    elseif remote.pspeed == 3 or remote.pspeed == 4 then base = 0x2d end
    -- Forced movement (a muddy slope) reads bikeSpeed 0, so fall back to the peer's action. It is transient, so only
    -- where the speed field says standing.
    if not base and remote.act then
        if remote.act >= 0x2d and remote.act <= 0x30 then base = 0x2d
        elseif remote.act >= 0x15 and remote.act <= 0x18 then base = 0x15
        -- The Acro Bike rides with the ride-water-current actions and leaves bikeSpeed (the Mach Bike's) at 0.
        elseif remote.act >= 0x29 and remote.act <= 0x2c then base = 0x29 end
    end

    if math.abs(dx) + math.abs(dy) == 1 then
        local stepDir
        if dx == 1 then stepDir = DIR_ID.east
        elseif dx == -1 then stepDir = DIR_ID.west
        elseif dy == 1 then stepDir = DIR_ID.south
        else stepDir = DIR_ID.north end
        -- Speed from the peer's movementActionId, direction from the tile delta (the peer's action may be a turn or
        -- NONE mid-step). Bases WALK_NORMAL 0x08, WALK_FAST 0x15, WALK_FASTER 0x2D, four ids each in DIR_ID order.
        local running = (remote.anim == "running")
        -- Remember the peer's last riding family, so a ghost a step behind rides the tile it owes rather than walking
        -- it. Only the wheelie moves (0x80..0x8B) are a riding style; a hop (0x74..0x7B) happened once.
        if acroBase and acroBase >= 0x80 then g.lastAcroBase = acroBase end
        -- The peer's live action beats the remembered family, which is dropped once the peer rides some other way.
        if base then
            g.lastAcroBase = nil
        elseif not acroBase and isBikeGfx(remote.gfx) then
            acroBase = g.lastAcroBase
        end
        if acroBase then
            requestAction(g, acroBase + (stepDir - 1))
        elseif base then
            requestAction(g, base + (stepDir - 1))
        else
            requestAction(g, (running and RUN_ACTION or WALK_ACTION)[stepDir])
        end
        -- A run or a ride needs a settle: a walk's last frame is the standing frame, a run's and a bike's are not. A
        -- riding peer reports its pose as walking, hence the bike test.
        g.needsSettle = (running or isBikeGfx(remote.gfx)) or nil
        -- The engine owns the tiles again for the step, so re-arm the settled-frame copy.
        g.frameFor = nil
        lockGhostFacing(g, remote, stepDir)
    elseif frameCounter - (genderFrames.xmap.rebasedAt or -99) <= 3 then
        -- A seam crossing is mid-flight: the engine rebases objects a frame after the map key flips, ours on the flip,
        -- so for a beat the ghost reads a map-height out. Coast until both land, or the teleport moves it twice.
        return
    else
        -- More than a tile out. A short gap is walked, not placed: at Mach Bike top speed the ghost trails about two
        -- tiles and one-tile steps cannot close that, so placing it would snap. A long gap is a warp and is placed.
        local far = math.abs(dx) + math.abs(dy)
        if far <= 3 then
            -- Dominant axis first, so a near-diagonal approach does not zig-zag.
            local sd
            if math.abs(dx) >= math.abs(dy) then
                sd = dx > 0 and DIR_ID.east or DIR_ID.west
            else
                sd = dy > 0 and DIR_ID.south or DIR_ID.north
            end
            requestAction(g, (acroBase and (acroBase + (sd - 1)))
                or (base and (base + (sd - 1)))
                or ((remote.anim == "running") and RUN_ACTION or WALK_ACTION)[sd])
            lockGhostFacing(g, remote, sd)
            return
        end
        -- Too far to walk: place it, once the camera has settled, as for a spawn.
        if not cameraIsSettled() then return end
        teleportGhost(g, targetX, targetY)
        if (r8(a + 0x18) & 0x0f) ~= dir then requestAction(g, FACE_ACTION[dir]) end
    end
end

-- The engine binds a jump shadow by localId and a ghost wears LOCALID_PLAYER, so the shadow under a jumping ghost is
-- ours. Rather than approximate it, learn the game's own shadow sprite while the local player hops (in use, 16x8, near
-- the player, mid-jump) and draw that; the ellipse is only the fallback.
-- A global: this chunk is at Lua's 200-local ceiling.
function learnShadowArt()
    if genderFrames.shadowArt ~= nil then return end
    local pObj = objAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05))
    local act = r8(pObj + 0x1c)
    if act < 0x0c or act > 0x0f then return end
    local ps = sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04))
    local px = rs16(ps + 0x20)
    for i = 0, 63 do
        local d = sprAddr(i)
        if (r8(d + 0x3e) & 0x01) == 1
            and ((r16(d + 0x00) >> 14) & 3) == 1 and ((r16(d + 0x02) >> 14) & 3) == 0
            and math.abs(rs16(d + 0x20) - px) < 40 then
            local images = r32(d + 0x0c)
            if isRomPtr(images) then
                local pixels = r32(images)
                if isRomPtr(pixels) then
                    local slot = (r16(d + 0x04) >> 12) & 0x0f
                    local pal = {}
                    for k = 0, 15 do
                        local c = r16(0x05000200 + slot * 32 + k * 2)
                        pal[k] = (0xFF << 24) | (expand5to8(c & 0x1F) << 16)
                            | (expand5to8((c >> 5) & 0x1F) << 8) | expand5to8((c >> 10) & 0x1F)
                    end
                    -- 16x8: two 8x8 4bpp tiles side by side, built into runs like every other decoded frame.
                    local runs = {}
                    for y = 0, 7 do
                        local x = 0
                        while x < 16 do
                            local b = r8(pixels + (x // 8) * 32 + y * 4 + ((x % 8) // 2))
                            local idx = (x % 2 == 0) and (b & 0x0F) or ((b >> 4) & 0x0F)
                            if idx ~= 0 then
                                local x2 = x
                                while x2 + 1 < 16 do
                                    local nb = r8(pixels + ((x2 + 1) // 8) * 32 + y * 4
                                        + (((x2 + 1) % 8) // 2))
                                    local ni = ((x2 + 1) % 2 == 0) and (nb & 0x0F)
                                        or ((nb >> 4) & 0x0F)
                                    if ni ~= idx then break end
                                    x2 = x2 + 1
                                end
                                runs[#runs + 1] = { y = y, x1 = x, x2 = x2, color = pal[idx] }
                                x = x2 + 1
                            else
                                x = x + 1
                            end
                        end
                    end
                    if #runs > 0 then
                        genderFrames.shadowArt = runs
                        console.log("MeshGhost: learned the game's own jump shadow ("
                            .. #runs .. " runs) -- ghosts now use it instead of an ellipse.")
                    end
                end
            end
            return
        end
    end
end

-- Shadow drop by the graphic's shadow size (graphicsInfo +0x0C bits 4-5). Only size 1 is measured; 0, 2 and 3 follow
-- the decompilation. A field: this chunk is at Lua's 200-local ceiling.
genderFrames.shadowDrop = { [0] = 4, [1] = 4, [2] = 4, [3] = 16 }

-- The shadow's top from the graphic: the frame's top plus its height, less the size's drop, less the shadow sprite's
-- 4px half-height.
function shadowTopFor(info, frameTopY)
    local size = 0
    if info and info.raw then size = (r8(info.raw + 0x0c) >> 4) & 0x03 end
    local h = (info and info.height) or FRAME_HEIGHT_PX
    return frameTopY + h - (genderFrames.shadowDrop[size] or 4) - 4
end

function drawOneShadow(sx, sy, dim)
    local left, top = sx - 8, sy
    if genderFrames.shadowArt then
        drawRunList(genderFrames.shadowArt, 16, false, left, top, nil, dim)
    else
        -- Until a shadow has been seen to learn from: the measured ink extent, 16x5 at rows 3..7.
        gui.drawEllipse(left, top + 3, 16, 5, 0x00000000, 0xFF000000)
    end
end

local function drawGhostShadows()
    learnShadowArt()
    for playerId, g in pairs(ghosts) do
        local remote = remotes[playerId]
        if ghostAlive(g) and not (remote and isJumpAction(remote.act)) then
            updateGhostShadow(g, false)
            -- Painted dust only when the shadow is not a real sprite: the engine raises its own landing dust for a
            -- ghost, placed by coordinates rather than localId. noteLanding still latches the landing either way.
            local f = genderFrames.noteLanding(playerId, false, remote and remote.act)
            if f and not genderFrames.shadowSpriteEnabled then
                local d = sprAddr(g.sprId)
                local runs = genderFrames.dustRuns(f)
                if runs then
                    drawRunList(runs, TILE, false,
                        rs16(d + 0x20) + rs16(GSPRITECOORDOFFSETX_ADDR + (genderFrames.spriteAddrOffset or 0)) - 8,
                        rs16(d + 0x22) + rs16(GSPRITECOORDOFFSETY_ADDR + (genderFrames.spriteAddrOffset or 0)) + 8, nil, 1)
                end
            end
        end
        if remote and isJumpAction(remote.act) and ghostAlive(g) then
            local d = sprAddr(g.sprId)
            local sx = rs16(d + 0x20) + rs16(GSPRITECOORDOFFSETX_ADDR + (genderFrames.spriteAddrOffset or 0))
            -- Without pos2 (+0x24/+0x26), which carries the jump arc: the shadow stays on the ground the ghost left.
            local sy = rs16(d + 0x22) + rs16(GSPRITECOORDOFFSETY_ADDR + (genderFrames.spriteAddrOffset or 0))
            updateGhostShadow(g, true)
            if not genderFrames.shadowSpriteEnabled then
                local size = 0
                local gi = g.gfx and graphicsInfo(g.gfx)
                if gi and gi.raw then size = (r8(gi.raw + 0x0c) >> 4) & 0x03 end
                local h = (gi and gi.height) or FRAME_HEIGHT_PX
                drawOneShadow(sx, sy + (h >> 1) - (genderFrames.shadowDrop[size] or 4) - 4, 1)
            end
            genderFrames.noteLanding(playerId, true, remote.act)
        end
    end
end

-- Walk-through ghosts: a non-zero currentElevation (low nibble of +0x0B) that differs from the player's, rewritten
-- every frame since, by the decompilation, the engine resets it from the tile on each move. The high nibble, which draw
-- order uses, is left alone.
local function freeGhostCollision()
    if tiering.devNoCollision == nil then
        tiering.devNoCollision = (MESHGHOST_EMERALD_NO_COLLISION
            or os.getenv("MESHGHOST_EMERALD_NO_COLLISION")) and true or false
        if tiering.devNoCollision then
            console.log("MeshGhost: PROBE FLAG IN USE -- MESHGHOST_EMERALD_NO_COLLISION: ghosts "
                .. "are walk-through (elevation made incompatible with the player's). Dev only.")
        end
    end
    -- The room's ghost_collision policy turns it on too; nil (no policy yet, or an older core) is not "disabled".
    -- Turning it off needs no restore: the engine rewrites currentElevation on the ghost's next step.
    tiering.noCollision = tiering.devNoCollision or (session.noCollisionPolicy == true)
    if not avatarAddrConfirmed then return end

    local pObj = r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05)
    if pObj > 15 then return end
    local pe = r8(objAddr(pObj) + 0x0b) & 0x0f
    -- Non-zero and never equal to the player's, whatever the player is standing on.
    local want = (pe == 3) and 4 or 3

    for _, g in pairs(ghosts) do
        if ghostAlive(g) then
            local a = objAddr(g.objId)
            local cur = r8(a + 0x0b)
            if tiering.noCollision and (cur & 0x0f) ~= want then
                w8(a + 0x0b, (cur & 0xf0) | want)
            end
            -- Shipped, whatever the flag: hold hasShadow (+0x02 bit 6) set, so a ghost's jump never spawns the engine's
            -- shadow, which binds to the player, stops itself within a frame and flashes stale tiles. Re-applied every
            -- frame because the landing effects clear it (the decompilation's reading, unmeasured).
            w8(a + 0x02, r8(a + 0x02) | 0x40)
        end
    end
end

-- spawnSet names the peers entitled to an object slot this frame (tiering.chooseSpawned); a peer that loses its place
-- goes to the drawn tier in the same frame.
local function syncRemoteGhosts(localAreaId, spawnSet)
    for playerId in pairs(ghosts) do
        local remote = remotes[playerId]
        -- Gone, elsewhere, or demoted to the drawn tier; area_id is compared by equality only.
        if not remote or remote.areaId ~= localAreaId or not spawnSet[playerId] then
            if COMPARE_TIERS then
                logFile(string.format("f=%d DESPAWN %s: remote=%s areaId=%s vs local=%s inSet=%s",
                    frameCounter, tostring(playerId), tostring(remote ~= nil),
                    tostring(remote and remote.areaId), tostring(localAreaId),
                    tostring(spawnSet[playerId] ~= nil)))
            end
            despawnGhost(playerId)
        end
    end
    for playerId, remote in pairs(remotes) do
        if remote.areaId == localAreaId and spawnSet[playerId] then
            syncGhost(playerId, remote)
        end
    end
    -- Name any object or sprite slot two peers share (one ghost blinking between two places); once a second.
    if not tiering.lastSlotAudit or frameCounter - tiering.lastSlotAudit >= 60 then
        tiering.lastSlotAudit = frameCounter
        local seenObj, seenSpr = {}, {}
        for playerId, g in pairs(ghosts) do
            if seenObj[g.objId] then
                console.log(string.format(
                    "MeshGhost: BUG -- %s and %s both hold object slot %d; one ghost will blink "
                    .. "between two places until this is fixed.", tostring(seenObj[g.objId]),
                    tostring(playerId), g.objId))
            elseif seenSpr[g.sprId] then
                console.log(string.format(
                    "MeshGhost: BUG -- %s and %s both hold sprite slot %d.",
                    tostring(seenSpr[g.sprId]), tostring(playerId), g.sprId))
            end
            seenObj[g.objId] = playerId
            seenSpr[g.sprId] = playerId
        end
    end
    freeGhostCollision()
end

-- The frame's screen anchor, shared by both non-engine tiers: its calibration is stateful, so there is one copy, and it
-- runs with the drawn tier off. Once per frame, cached: the calibration counts still frames, and a second call in a
-- frame would refresh it mid-step. A global: this chunk is at Lua's 200-local ceiling.
function anchorFrame(localAreaId, playerScreenX, playerScreenY, playerMapX, playerMapY)
    -- Apply a seam's shift to the tile-valued anchor before anything reads it. The origin and the Still pair are screen
    -- positions, continuous across a seam, so they stay.
    local shift = genderFrames.xmapAnchorShift
    if shift then
        genderFrames.xmapAnchorShift = nil
        if tiering.anchorX then tiering.anchorX = tiering.anchorX + shift.dx end
        if tiering.anchorY then tiering.anchorY = tiering.anchorY + shift.dy end
        tiering.anchorArea = shift.key
        tiering.anchorAt, tiering.anchorCache = nil, nil
    end
    if tiering.anchorAt == frameCounter and tiering.anchorCache then
        local c = tiering.anchorCache
        return c[1], c[2], c[3], c[4]
    end
    local sb1 = session.saveBlockPtr(GSAVEBLOCK1PTR_ADDR)
    local camPixX = rs16(GTOTALCAMERAPIXELOFFSETX_ADDR + (genderFrames.camOffset or 0))
    local camPixY = rs16(GTOTALCAMERAPIXELOFFSETY_ADDR + (genderFrames.camOffset or 0))
    if sb1 ~= 0 then
        local camX, camY = camPixX, camPixY
        -- Calibrate only after four frames on one tile: moving in the positive direction, the tile counter flips to the
        -- destination as a step begins, a tile ahead of the picture.
        local tx, ty = rs16(sb1 + 0x00), rs16(sb1 + 0x02)
        if tiering.lastTileX ~= tx or tiering.lastTileY ~= ty then
            tiering.lastTileX, tiering.lastTileY, tiering.tileStill = tx, ty, 0
        else
            tiering.tileStill = (tiering.tileStill or 0) + 1
        end
        local settled = (tiering.tileStill or 0) >= 4
        local fresh = tiering.anchorX == nil or tiering.anchorArea ~= localAreaId
        -- The Still origin drops pos2 (the surf bob) and the graphic's centring (-8 for the 16-wide walker, -16 for a
        -- 32-wide frame), so the tile grid stays fixed whatever the player rides.
        local pspr = sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04))
        -- The paint origin adds the centring back, so it means where a walker-sized frame sits; otherwise every ghost
        -- slides 8px when the local player mounts a bike. A 32-wide peer gets its own correction.
        local ctcX = memory.read_s8(pspr + 0x28) + (FRAME_WIDTH_PX // 2)
        local ctcY = memory.read_s8(pspr + 0x29) + (FRAME_HEIGHT_PX // 2)
        if fresh or (settled and camX % 16 == 0) then
            tiering.anchorX, tiering.originX = tx + camX / 16, playerScreenX - ctcX
            tiering.originXStill = playerScreenX - rs16(pspr + 0x24)
                - memory.read_s8(pspr + 0x28) - (FRAME_WIDTH_PX // 2)
        end
        if fresh or (settled and camY % 16 == 0) then
            tiering.anchorY, tiering.originY = ty + camY / 16, playerScreenY - ctcY
            tiering.originYStill = playerScreenY - rs16(pspr + 0x26)
                - memory.read_s8(pspr + 0x29) - (FRAME_HEIGHT_PX // 2)
        end
        tiering.anchorArea = localAreaId
        playerMapX = tiering.anchorX - camX / 16
        playerMapY = tiering.anchorY - camY / 16
    end
    tiering.anchorAt = frameCounter
    tiering.anchorCache = { camPixX, camPixY, playerMapX, playerMapY }
    return camPixX, camPixY, playerMapX, playerMapY
end

-- ================= Tier two: hardware sprites the PPU draws =================
--
-- A peer with no object slot gets a real hardware sprite in gMain's OAM buffer, entries 64..119: the engine's layout
-- pass stops at gOamLimit (64 on the overworld), yet all 128 entries go to the hardware every VBlank. The PPU gives it
-- background priority and the live palette; it has no collision, engine animation or walking, and it loses overlap ties
-- to the engine's own sprites. On the table, not in locals: this chunk is at Lua's 200-local ceiling.
tiering.hw = {
    -- Off by default, a dev tool ("1" turns it on): it borrows the live palette, so it cannot show a peer of the other
    -- gender. Read at file load, so a loader script sets it before the adapter.
    on = (MESHGHOST_EMERALD_HW_OVERFLOW or os.getenv("MESHGHOST_EMERALD_HW_OVERFLOW") or "0") == "1",
    base = 0x030022f8 + 64 * 8, -- gMain.oamBuffer[64]; gMain 0x030022c0 + 0x038
    slots = 56,                 -- entries 64..119. 120..127 is margin: 125 is the game's own.
    -- Pools back to front, because a raw OAM entry's depth is its number (lower draws in front): reflection, ripple,
    -- blob, shadow, the character, dust. Twelve ripples: one per tile, an 80-frame life and a tile every 8 frames
    -- surfing is ten live at once. Each pool logs when it runs out.
    dustFirst = 0, dustLast = 3,        -- in front of everything of ours
    bodyFirst = 4, bodyLast = 29,
    shadowFirst = 30, shadowLast = 33,
    blobFirst = 34, blobLast = 37,
    rippleFirst = 38, rippleLast = 49,
    reflFirst = 50, reflLast = 55,      -- behind everything of ours
    fxTiles = {},               -- "shadow:<size>" / "dust:<frame>" -> { start, tiles }
    puffs = {},                 -- live dust-trail puffs: { at, bx, by, slot }
    ripples = {},               -- live water-trail ripples: { at, bx, by, slot }
    -- gDummyOamData, the engine's hidden encoding (off screen, 8x8, priority 3): a released slot looks never used.
    d0 = 0x00a0, d1 = 0x0130, d2 = 0x0c00,
    -- Compare-mode nudge in tiles from the spawned ghost (+2,0 from the player): -6,0 puts the hardware copy two tiles
    -- left of the painted one (-2,0), all three tiers in the player's row.
    cmpDX = tonumber(MESHGHOST_EMERALD_HW_COMPARE_DX or "") or -6,
    cmpDY = tonumber(MESHGHOST_EMERALD_HW_COMPARE_DY or "") or 0,
    byPeer = {},   -- player_id -> { slot, tileStart, tileCount, gfx, animNum, animIdx }
    slotUsed = {}, -- slot -> player_id
    area = nil,    -- the area those tile allocations belong to
    placed = 0,    -- how many were actually written last frame, for the status line
}

-- Release is not optional: nothing in the engine's per-frame path clears entries 64..127, so a stale one stays on
-- screen. freeTiles is false on a map change: ResetSpriteData has already freed every range, and clearing bits we no
-- longer own would free somebody else's sprite.
function hwRelease(playerId, freeTiles)
    local rec = tiering.hw.byPeer[playerId]
    if not rec then return end
    local a = tiering.hw.base + rec.slot * 8
    -- +0/+2/+4 only. The engine's affine-matrix pass owns +6 on all 128 entries every frame.
    w16(a + 0, tiering.hw.d0)
    w16(a + 2, tiering.hw.d1)
    w16(a + 4, tiering.hw.d2)
    if freeTiles ~= false and rec.tileStart then
        -- Deferred: the hardware still shows the old tile number for a couple of frames after a release, so an
        -- immediate free lets the next allocation overwrite tiles on screen. Freed only while the stamped area stands.
        queueTileFree({ hwArea = tiering.hw.area, start = rec.tileStart,
            count = rec.tileCount, at = frameCounter })
    end
    -- The shadow and dust entries go back with the body; their tiles are shared by every peer on this tier, and only
    -- the area change below frees them.
    for which, slot in pairs(rec.fx or {}) do
        hwFxHide(rec, which)
        tiering.hw.slotUsed[slot] = nil
    end
    tiering.hw.slotUsed[rec.slot] = nil
    tiering.hw.byPeer[playerId] = nil
end

function hwReleaseAll(freeTiles)
    for playerId in pairs(tiering.hw.byPeer) do hwRelease(playerId, freeTiles) end
    -- On a map change ResetSpriteData has freed every range already, so the records are dropped without clearing.
    if freeTiles ~= false then
        for _, t in pairs(tiering.hw.fxTiles) do
            if t.start and not genderFrames.rangeDrawnByLiveSprite(t.start, t.tiles, nil) then
                for i = t.start, t.start + t.tiles - 1 do setTileAllocated(i, false) end
            end
        end
    end
    tiering.hw.fxTiles = {}
    -- Blank each puff's entry too: the engine never touches 64..127, so a freed slot left unblanked stays on screen.
    for _, puff in ipairs(tiering.hw.puffs) do
        if puff.slot then
            local a = tiering.hw.base + puff.slot * 8
            w16(a + 0, tiering.hw.d0)
            w16(a + 2, tiering.hw.d1)
            w16(a + 4, tiering.hw.d2)
            tiering.hw.slotUsed[puff.slot] = nil
        end
    end
    tiering.hw.puffs = {}
    tiering.hw.ripples = {}
    tiering.hw.area = nil
    tiering.hw.placed = 0
end

-- Claims a body slot and an OBJ tile range from the game's own allocation bitmap. nil when no run is long enough, which
-- hands the peer to the painted tier. A global, for the 200-local ceiling.
function hwAcquire(playerId, info)
    local slot
    for i = tiering.hw.bodyFirst, tiering.hw.bodyLast do
        if not tiering.hw.slotUsed[i] then slot = i break end
    end
    if not slot then return nil end
    local tileStart = allocSpriteTiles(info.tileCount)
    if not tileStart then return nil end
    local rec = {
        slot = slot, tileStart = tileStart, tileCount = info.tileCount,
        gfx = nil, animNum = nil, animIdx = nil,
    }
    tiering.hw.slotUsed[slot] = playerId
    tiering.hw.byPeer[playerId] = rec
    -- One line per acquire (spawns and graphic changes only), so the tiles held after a state load can be read.
    logFile(string.format("hw acquire: %s slot=%d tiles=%d..%d f=%d emu=%d",
        tostring(playerId), slot, tileStart, tileStart + info.tileCount - 1,
        frameCounter, emu.framecount()))
    return rec
end

-- This tier's entries sit at 64+, so at equal priority they lose to every engine sprite. Underwater and in fog the
-- engine covers the screen with semi-transparent sprites at lower entries, which then draw over ours; a higher priority
-- shows the ghost but turns that sheet opaque over its rectangle, so the tier stands down there instead.
-- MESHGHOST_EMERALD_HW_PRIORITY (a probe, never shipped set) overrides the priority and suppresses the stand-down.
function hwSpritePriority()
    return tonumber(MESHGHOST_EMERALD_HW_PRIORITY or "") or 2
end

-- Is the engine covering the screen with semi-transparent sprites (objMode 1: fog, the underwater haze)? Asked of the
-- screen, not the place. attr0 only, every 8th frame, latched. Four or more means covered: incidental ones come one or
-- two at a time, and a cover is twelve or more.
genderFrames.semiTransparentScanAt, genderFrames.semiTransparentCover = -100, false
genderFrames.screenCoveredBySemiTransparentSprites = function()
    if frameCounter - genderFrames.semiTransparentScanAt < 8 then
        return genderFrames.semiTransparentCover
    end
    genderFrames.semiTransparentScanAt = frameCounter
    local n = 0
    for e = 0, 63 do
        if (r16(0x07000000 + e * 8) & 0x0c00) == 0x0400 then
            n = n + 1
            if n >= 4 then break end
        end
    end
    genderFrames.semiTransparentCover = n >= 4
    return genderFrames.semiTransparentCover
end

-- The engine's own tag lookup: the palette slot whose sSpritePaletteTags entry (0x03000CF0, 16 halfwords) is tag.
function hwPaletteSlotForTag(tag)
    for i = 0, 15 do
        if r16(0x03000cf0 + i * 2) == tag then return i end
    end
    return nil
end

-- Loads one frame of a field effect into OBJ VRAM once and returns its first tile; one shared range per effect frame
-- serves every peer. A failure is cached too and retried after 300 frames: a failed allocation walks the whole bitmap,
-- and failing is the normal case on a busy map.
function hwFxTiles(key, imagesPtr, frameIdx)
    local rec = tiering.hw.fxTiles[key]
    if rec then
        if rec.start then return rec.start end
        if frameCounter - rec.failedAt < 300 then return nil end
    end
    local e = imagesPtr + frameIdx * 8
    local src, bytes = r32(e), r16(e + 4)
    -- A wrong SpriteFrameImage read would turn the copy below into a write over somebody else's tiles.
    if not isRomPtr(src) or bytes == 0 or bytes > 1024 or bytes % 32 ~= 0 then return nil end
    local nTiles = bytes // 32
    local start = allocSpriteTiles(nTiles)
    if not start then
        tiering.hw.fxTiles[key] = { start = false, failedAt = frameCounter }
        return nil
    end
    local dst = 0x06010000 + start * 32
    for off = 0, bytes - 4, 4 do w32(dst + off, r32(src + off)) end
    tiering.hw.fxTiles[key] = { start = start, tiles = nTiles }
    return start
end

-- An entry from the pool that puts this effect at its depth, held while the peer is on this tier: a slot that changes
-- number changes depth.
function hwFxSlot(playerId, rec, which)
    rec.fx = rec.fx or {}
    if rec.fx[which] then return rec.fx[which] end
    -- Dust is per puff, from its own pool in hwPuffTick.
    local first, last = tiering.hw.shadowFirst, tiering.hw.shadowLast
    if which == "blob" then
        first, last = tiering.hw.blobFirst, tiering.hw.blobLast
    elseif which == "refl" then
        first, last = tiering.hw.reflFirst, tiering.hw.reflLast
    end
    for i = first, last do
        if not tiering.hw.slotUsed[i] then
            tiering.hw.slotUsed[i] = playerId
            rec.fx[which] = i
            return i
        end
    end
    return nil
end

function hwFxHide(rec, which)
    local slot = rec.fx and rec.fx[which]
    if not slot then return end
    local a = tiering.hw.base + slot * 8
    w16(a + 0, tiering.hw.d0)
    w16(a + 2, tiering.hw.d1)
    w16(a + 4, tiering.hw.d2)
end

-- A surfing peer's blob and reflection, one OAM entry each. The blob is the field effect's own template, its tiles
-- shared by every peer, seated at the rider plus (0, +8). The reflection reuses the body's tiles at priority 3 with the
-- reflection palette, through OAM matrix 0 (1 when mirrored), so the engine's own shimmer drives it; when that matrix
-- holds no vertical flip, the plain flip bit instead.
function hwDrawSurf(playerId, rec, remote, info, sx, sy, arcY, hFlip)
    if peerIsSurfing(remote) then
        -- Park the blob through a surf jump, like the game's: a dismount holds its pre-jump spot, a mount parks at the
        -- destination (one tile along the jump). Sticky once set: the action ends a beat before the graphic flips.
        local jumping = remote.act and remote.act >= 0x3a and remote.act <= 0x3d
        if jumping and not rec.blobParkHold then
            if rec.blobPark then
                rec.blobParkHold, rec.blobParkKind = true, "dismount"
            else
                local jdx = ({ [0x3c] = -TILE, [0x3d] = TILE })[remote.act] or 0
                local jdy = ({ [0x3a] = TILE, [0x3b] = -TILE })[remote.act] or 0
                rec.blobPark = { sx + jdx - rs16(GSPRITECOORDOFFSETX_ADDR + (genderFrames.spriteAddrOffset or 0)),
                    sy - arcY + jdy + 8 - rs16(GSPRITECOORDOFFSETY_ADDR + (genderFrames.spriteAddrOffset or 0)) }
                rec.blobParkHold, rec.blobParkKind = true, "mount"
                if COMPARE_TIERS then
                    logFile(string.format(
                        "HW MOUNT PARK at (%d,%d) act=%02X sx=%d sy=%d arc=%d f=%d",
                        rec.blobPark[1], rec.blobPark[2], remote.act, sx, sy, arcY,
                        frameCounter))
                end
            end
        end
        -- A mount's park ends with its jump, when body and blob share the tile; a dismount's lasts until the graphic.
        if not jumping and rec.blobParkHold and rec.blobParkKind == "mount" then
            rec.blobParkHold, rec.blobParkKind = nil, nil
        end
        local bx, by = sx, sy + 8
        if rec.blobParkHold and rec.blobPark then
            bx = rec.blobPark[1] + rs16(GSPRITECOORDOFFSETX_ADDR + (genderFrames.spriteAddrOffset or 0))
            by = rec.blobPark[2] + rs16(GSPRITECOORDOFFSETY_ADDR + (genderFrames.spriteAddrOffset or 0))
        elseif not jumping then
            rec.blobPark = { bx - rs16(GSPRITECOORDOFFSETX_ADDR + (genderFrames.spriteAddrOffset or 0)),
                by - rs16(GSPRITECOORDOFFSETY_ADDR + (genderFrames.spriteAddrOffset or 0)) }
        end
        local facing = genderFrames.dirOf[remote.orientation] or 1
        local imageIndex = genderFrames.blobDirImage[facing] or 0
        local imgs = r32(surfBlob.template + 0x0c)
        local bpal = hwPaletteSlotForTag(r16(surfBlob.template + 0x02))
            or genderFrames.blobPaletteSlot
        local bstart = isRomPtr(imgs) and hwFxTiles("blob:" .. imageIndex, imgs, imageIndex)
        local bslot = bstart and hwFxSlot(playerId, rec, "blob")
        if bslot then
            local o = r32(surfBlob.template + 0x04)
            local a = tiering.hw.base + bslot * 8
            w16(a + 0, (r16(o + 0x00) & 0xff00) | (by & 0xff))
            w16(a + 2, (r16(o + 0x02) & 0xfe00) | (bx & 0x1ff) | (facing == 4 and 0x1000 or 0))
            w16(a + 4, (bstart & 0x3ff) | (hwSpritePriority() << 10) | ((bpal & 0x0f) << 12))
        else
            hwFxHide(rec, "blob")
        end
    else
        rec.blobPark, rec.blobParkHold, rec.blobParkKind = nil, nil, nil
        hwFxHide(rec, "blob")
    end

    -- A reflection for any peer on reflective ground, asked at the tile this tier draws on, with its own previous-tile
    -- store: in compare mode the copies stand on different ground.
    local rpal, rkind
    local gbX, gbY = genderFrames.gridBase()
    if gbX then
        -- The painted tier's formula: the frame's left edge, and the tile below its middle.
        tiering.hwLastTile = tiering.hwLastTile or {}
        local hgx = math.floor((sx - gbX) / TILE)
        local hgy = math.floor((sy - arcY + TILE - gbY) / TILE)
        rpal, rkind = genderFrames.reflectPalFor(tiering.hwLastTile, playerId, remote.areaId,
            hgx, hgy,
            ((info.width or FRAME_WIDTH_PX) + 8) >> 4,
            ((info.height or FRAME_HEIGHT_PX) + 8) >> 4,
            info.paletteSlot)
        -- Published for the painted tier's log later this frame: both tiers ask the same function, so a difference
        -- between them is in these inputs.
        if COMPARE_TIERS then
            -- What the painted tier's mask says at this tier's tile, so mask and hardware answer about the same ground.
            local hry = sy + (info.height or FRAME_HEIGHT_PX) - 2 - 2 * arcY
            local hwet = genderFrames.reflectiveSpans(sx, hry,
                info.width or FRAME_WIDTH_PX, info.height or FRAME_HEIGHT_PX, "reflection", genderFrames.scHwet())
            local lo, hi = nil, nil
            if hwet then
                for y2, l in pairs(hwet) do
                    if #l > 0 then
                        if not lo or y2 < lo then lo = y2 end
                        if not hi or y2 > hi then hi = y2 end
                    end
                end
            end
            -- The art rows in VRAM, against the painted tier's ROM decode (16x32, 4bpp, tiles in reading order).
            local firstRow, lastRow = nil, nil
            if rec.tileStart then
                for row = 0, 31 do
                    local tr, ly = row // 8, row % 8
                    local ink = false
                    for tc = 0, 1 do
                        local t = rec.tileStart + tr * 2 + tc
                        for byte = 0, 3 do
                            if r8(0x06010000 + t * 32 + ly * 4 + byte) ~= 0 then
                                ink = true
                                break
                            end
                        end
                        if ink then break end
                    end
                    if ink then
                        if not firstRow then firstRow = row end
                        lastRow = row
                    end
                end
            end
            tiering.hwReflDbg = string.format("hwArtRows=%s..%s ",
                tostring(firstRow), tostring(lastRow)) .. string.format(
                "tile=%d,%d wh=%d,%d pal=%s reflBox=%d..%d maskOpens=%s..%s", hgx, hgy,
                ((info.width or FRAME_WIDTH_PX) + 8) >> 4,
                ((info.height or FRAME_HEIGHT_PX) + 8) >> 4, tostring(rpal),
                math.floor(hry), math.floor(hry) + (info.height or FRAME_HEIGHT_PX) - 1,
                tostring(lo), tostring(hi))
        end
    end
    -- A ripple per tile stepped, from the tile store above, about the tile this tier drew on.
    if genderFrames.rippleDue(tiering.hwLastTile or {}, playerId,
        peerIsSurfing(remote)) then
        local w = info.width or FRAME_WIDTH_PX
        local h = info.height or FRAME_HEIGHT_PX
        tiering.hw.ripples[#tiering.hw.ripples + 1] = {
            at = frameCounter,
            bx = sx + (w >> 1) - 8 - rs16(GSPRITECOORDOFFSETX_ADDR + (genderFrames.spriteAddrOffset or 0)),
            by = sy - arcY + h - 10 - rs16(GSPRITECOORDOFFSETY_ADDR + (genderFrames.spriteAddrOffset or 0)),
        }
    end

    local rslot = rpal and rec.tileStart and hwFxSlot(playerId, rec, "refl")
    if not rslot then
        hwFxHide(rec, "refl")
        return
    end
    -- Height minus 2 below the body, mirrored about the bob: sy carries the bob once, so it comes off twice.
    local ry = sy + (info.height or FRAME_HEIGHT_PX) - 2 - 2 * arcY
    local t0, t1 = 0x8000, 0x8000
    if info.oam ~= 0 then t0, t1 = r16(info.oam + 0x00), r16(info.oam + 0x02) end
    local a = tiering.hw.base + rslot * 8
    -- gOamMatrices entry: a +0, b +2, c +4, d +6 (d holds the vertical flip). Ice uses the plain flip: no shimmer.
    local m = hFlip and 1 or 0
    if rkind ~= "ice" and rs16(genderFrames.oamMatricesAddr + m * 8 + 6) < -128 then
        -- ST_OAM_AFFINE_NORMAL: attr0 bits 8-9 = 01, attr1 bits 9-13 = the matrix, which carries both flips.
        w16(a + 0, (t0 & 0xfc00) | 0x0100 | (ry & 0xff))
        w16(a + 2, (t1 & 0xc000) | (m << 9) | (sx & 0x1ff))
    else
        w16(a + 0, (t0 & 0xff00) | (ry & 0xff))
        w16(a + 2, (t1 & 0xc000) | (hFlip and 0x1000 or 0) | 0x2000 | (sx & 0x1ff))
    end
    w16(a + 4, (rec.tileStart & 0x3ff) | (3 << 10) | ((rpal & 0x0f) << 12))
    -- Published for the painted tier's comparison log later this frame.
    if COMPARE_TIERS then tiering.hwBodyY, tiering.hwReflY = sy, ry end
end

-- sx, sy are the body entry's top-left this frame and arcY the hop it carries: both effects belong on the ground the
-- peer left, so the arc comes back off.
function hwDrawFx(playerId, rec, remote, info, sx, sy, arcY, hFlip)
    local w, h = info.width or FRAME_WIDTH_PX, info.height or FRAME_HEIGHT_PX
    local groundY = sy - arcY
    local jumping = isJumpAction(remote.act) or false

    hwDrawSurf(playerId, rec, remote, info, sx, sy, arcY, hFlip)

    local size = 1
    if info.raw and info.raw ~= 0 then size = (r8(info.raw + 0x0c) >> 4) & 0x03 end
    local tmpl = genderFrames.shadowTemplates[size]
    local start = jumping and tmpl and hwFxTiles("shadow:" .. size, r32(tmpl + 0x0c), 0)
    local slot = start and hwFxSlot(playerId, rec, "shadow")
    if slot then
        local o = r32(tmpl + 0x04)
        -- shadowTopFor's arithmetic: the graphic's height, less the size's drop, less the shadow's 4px half-height.
        local hy = groundY + h - (genderFrames.shadowDrop[size] or 4) - 4
        local hx = sx + (w >> 1) - 8
        local a = tiering.hw.base + slot * 8
        w16(a + 0, (r16(o + 0x00) & 0xff00) | (hy & 0xff))
        w16(a + 2, (r16(o + 0x02) & 0xfe00) | (hx & 0x1ff))
        w16(a + 4, (start & 0x3ff) | (hwSpritePriority() << 10))
    else
        hwFxHide(rec, "shadow")
    end

    -- The same landing latch the other tiers read, so all three puff on the same frame; the puff stays where the ground
    -- was and hwPuffTick plays it out there.
    local _, landedNow = genderFrames.noteLanding(playerId, jumping, remote.act)
    if landedNow then
        tiering.hw.puffs[#tiering.hw.puffs + 1] = {
            at = frameCounter,
            bx = sx + (w >> 1) - 8 - rs16(GSPRITECOORDOFFSETX_ADDR + (genderFrames.spriteAddrOffset or 0)),
            by = groundY + h - 8 - rs16(GSPRITECOORDOFFSETY_ADDR + (genderFrames.spriteAddrOffset or 0)),
        }
    end
end

-- Play out every live puff at its recorded spot, camera-anchored. One dust slot per live puff, not per peer: a 24-frame
-- puff against a 16-frame bounce overlaps. Too many drops the oldest, which has the least left to show.
function hwPuffTick()
    local puffs = tiering.hw.puffs
    if #puffs == 0 then return end
    local offX, offY = rs16(GSPRITECOORDOFFSETX_ADDR + (genderFrames.spriteAddrOffset or 0)), rs16(GSPRITECOORDOFFSETY_ADDR + (genderFrames.spriteAddrOffset or 0))
    local imgs = r32(genderFrames.dustTemplate + 0x0c)
    local pal = hwPaletteSlotForTag(0x1004)
    local o = r32(genderFrames.dustTemplate + 0x04)
    for pi = #puffs, 1, -1 do
        local puff = puffs[pi]
        local f = genderFrames.dustFrameAt(frameCounter - puff.at)
        local start = f and pal and isRomPtr(imgs) and hwFxTiles("dust:" .. f, imgs, f)
        if not start then
            if puff.slot then
                local a = tiering.hw.base + puff.slot * 8
                w16(a + 0, tiering.hw.d0) w16(a + 2, tiering.hw.d1) w16(a + 4, tiering.hw.d2)
                tiering.hw.slotUsed[puff.slot] = nil
            end
            table.remove(puffs, pi)
        else
            if not puff.slot then
                for i = tiering.hw.dustFirst, tiering.hw.dustLast do
                    if not tiering.hw.slotUsed[i] then
                        tiering.hw.slotUsed[i] = "puff"
                        puff.slot = i
                        break
                    end
                end
            end
            if not puff.slot then
                table.remove(puffs, pi) -- pool exhausted: iteration is newest-first, this is oldest
            else
                local a = tiering.hw.base + puff.slot * 8
                local dx, dy = puff.bx + offX, puff.by + offY
                if dx + 16 <= 0 or dx >= 240 or dy + 8 <= 0 or dy >= 160 then
                    w16(a + 0, tiering.hw.d0) w16(a + 2, tiering.hw.d1) w16(a + 4, tiering.hw.d2)
                else
                    w16(a + 0, (r16(o + 0x00) & 0xff00) | (dy & 0xff))
                    w16(a + 2, (r16(o + 0x02) & 0xfe00) | (dx & 0x1ff))
                    w16(a + 4, (start & 0x3ff) | (hwSpritePriority() << 10) | (pal << 12))
                end
            end
        end
    end
end

-- Play out every live ripple where it was dropped, one slot per live ripple: an 80-frame life against a tile every 8
-- frames is ten alive. Too many drops the oldest and says so: a ceiling must never read as full coverage.
function hwRippleTick()
    local list = tiering.hw.ripples
    if #list == 0 then return end
    local offX, offY = rs16(GSPRITECOORDOFFSETX_ADDR + (genderFrames.spriteAddrOffset or 0)), rs16(GSPRITECOORDOFFSETY_ADDR + (genderFrames.spriteAddrOffset or 0))
    local imgs = r32(genderFrames.rippleTemplate + 0x0c)
    local pal = hwPaletteSlotForTag(r16(genderFrames.rippleTemplate + 0x02))
    local o = r32(genderFrames.rippleTemplate + 0x04)
    for ri = #list, 1, -1 do
        local rip = list[ri]
        local f = genderFrames.rippleFrameAt(frameCounter - rip.at)
        local start = f and pal and isRomPtr(imgs) and hwFxTiles("ripple:" .. f, imgs, f)
        if not start then
            if rip.slot then
                local a = tiering.hw.base + rip.slot * 8
                w16(a + 0, tiering.hw.d0) w16(a + 2, tiering.hw.d1) w16(a + 4, tiering.hw.d2)
                tiering.hw.slotUsed[rip.slot] = nil
            end
            table.remove(list, ri)
        else
            if not rip.slot then
                for i = tiering.hw.rippleFirst, tiering.hw.rippleLast do
                    if not tiering.hw.slotUsed[i] then
                        tiering.hw.slotUsed[i] = "ripple"
                        rip.slot = i
                        break
                    end
                end
            end
            if not rip.slot then
                -- Iteration is newest-first, so this is the oldest live ripple.
                if not tiering.hw.rippleDropAt
                    or frameCounter - tiering.hw.rippleDropAt >= 300 then
                    tiering.hw.rippleDropAt = frameCounter
                    console.log(string.format(
                        "MeshGhost: hardware ripple pool full (%d slots); dropping the oldest of "
                        .. "%d live ripples.",
                        tiering.hw.rippleLast - tiering.hw.rippleFirst + 1, #list))
                end
                table.remove(list, ri)
            else
                local a = tiering.hw.base + rip.slot * 8
                local dx, dy = rip.bx + offX, rip.by + offY
                if dx + genderFrames.rippleFramePx <= 0 or dx >= 240
                    or dy + genderFrames.rippleFramePx <= 0 or dy >= 160 then
                    -- Off screen gives the slot back, not just the pixels: a trail's oldest leave the screen first.
                    w16(a + 0, tiering.hw.d0) w16(a + 2, tiering.hw.d1) w16(a + 4, tiering.hw.d2)
                    tiering.hw.slotUsed[rip.slot] = nil
                    rip.slot = nil
                else
                    w16(a + 0, (r16(o + 0x00) & 0xff00) | (dy & 0xff))
                    w16(a + 2, (r16(o + 0x02) & 0xfe00) | (dx & 0x1ff))
                    w16(a + 4, (start & 0x3ff) | (hwSpritePriority() << 10) | (pal << 12))
                end
            end
        end
    end
end

-- How many more peers this tier can take now. OBJ tiles, not entries, are the binding limit, found at acquire time.
tiering.hwBudget = function()
    if not tiering.hw.on then return 0 end
    local free = 0
    for i = 0, tiering.hw.slots - 1 do if not tiering.hw.slotUsed[i] then free = free + 1 end end
    return free
end

-- The ladder's middle rung: the nearest peers the engine could not take, as far as this tier has room. Same ranking and
-- hysteresis as chooseSpawned: without the band near-equal peers swap tiers, and here a swap costs a VRAM copy.
tiering.chooseHardware = function(localAreaId, playerX, playerY, spawnSet)
    local set = {}
    if not tiering.hw.on then return set end
    -- Same post-load quiet as chooseSpawned, same reason, same measurement.
    if genderFrames.loadQuietUntil and frameCounter < genderFrames.loadQuietUntil then
        return set
    end
    -- Under a semi-transparent screen cover this tier cannot draw cleanly (hwSpritePriority), so its peers go to the
    -- painted tier. Asked of the screen, not the place: fog and sandstorm do it on dry land.
    if not MESHGHOST_EMERALD_HW_PRIORITY
        and genderFrames.screenCoveredBySemiTransparentSprites() then
        -- Release and free: weather is not a map change, so the tile bitmap is still ours to free.
        if next(tiering.hw.byPeer) then hwReleaseAll(true) end
        return set
    end
    local ranked = {}
    for playerId, remote in pairs(remotes) do
        -- In compare mode the loopback ghost may hold every tier; others land here when the engine had no room.
        local alsoSpawned = COMPARE_TIERS and playerId:match("%-ghost$") ~= nil
        -- A peer the engine stopped drawing (invisible, the boat, the bird) is not ranked, as on the painted tier.
        if remote.areaId == localAreaId
            and not (remote.invis or remote.boat or remote.fly == 2)
            and (alsoSpawned or not (spawnSet and spawnSet[playerId]))
        then
            local dx, dy = remote.x - playerX, remote.y - playerY
            local d = math.sqrt(dx * dx + dy * dy)
            if tiering.hw.byPeer[playerId] then d = d - tiering.hysteresis end
            ranked[#ranked + 1] = { id = playerId, d = d }
        end
    end
    table.sort(ranked, function(a, b)
        if a.d == b.d then return a.id < b.id end
        return a.d < b.d
    end)
    -- Peers that already hold a slot keep it; the free-slot count is what the newcomers share.
    local room = tiering.hwBudget()
    for i = 1, #ranked do
        local id = ranked[i].id
        if tiering.hw.byPeer[id] then
            set[id] = true
        elseif room > 0 then
            set[id] = true
            room = room - 1
        end
    end
    return set
end

-- Write this frame's entries. Runs after the spawned tier and before the painted one, so the painted
-- tier can be told to skip whoever landed here.
function renderHardwareGhosts(localAreaId, playerMapX, playerMapY, hwSet)
    tiering.hw.placed = 0
    -- Every early return leaves OAM clean: a puff outlives its bounce.
    if not tiering.hw.on or avatarAddrOffset ~= 0 then
        if #tiering.hw.puffs > 0 then hwReleaseAll(true) end
        return
    end
    if not next(hwSet) and (not tiering.hw.lastEmpty
        or frameCounter - tiering.hw.lastEmpty > 300) then
        tiering.hw.lastEmpty = frameCounter
        logFile("hw tier: on, but no peer was assigned to it this frame")
    end
    -- Vanilla only (the avatarAddrOffset test above): gMain's address is from our build of the decomp, and an
    -- Archipelago ROM relocates it.

    -- A map change runs ResetSpriteData, which frees every tile range for the new map's NPCs, so the records are
    -- dropped without clearing bits we no longer own.
    if tiering.hw.area ~= localAreaId then
        -- A seam is not a warp: a connection keeps every sprite and the tile bitmap, only a warp runs ResetSpriteData.
        -- So free on a seam and forget on a warp, stamping the area first so the deferred frees carry the area that now
        -- stands. A recent rebase, or a spawned ghost alive across the change, means a seam.
        local survivor = false
        for _, g in pairs(ghosts) do
            if ghostAlive(g) then survivor = true break end
        end
        -- The signal that needs nothing armed: a warp fades out of CB2_Overworld, and a seam never leaves it.
        local stayedInOverworld = tiering.lastNonOverworldAt == nil
            or (frameCounter - tiering.lastNonOverworldAt) > 30
        local seam = tiering.hw.area ~= nil
            and ((frameCounter - (genderFrames.xmap.rebasedAt or -999)) <= 10 or survivor
                or stayedInOverworld)
        logFile(string.format("hw area change %s -> %s: seam=%s (rebase %s frames ago, survivor=%s, stayedInOverworld=%s) records=%d",
            tostring(tiering.hw.area), tostring(localAreaId), tostring(seam),
            genderFrames.xmap.rebasedAt and tostring(frameCounter - genderFrames.xmap.rebasedAt) or "never",
            tostring(survivor), tostring(stayedInOverworld),
            (function() local n = 0 for _ in pairs(tiering.hw.byPeer) do n = n + 1 end return n end)()))
        if seam then
            -- Frees pending from before the crossing carry the old area: restamp them, since the bitmap survived.
            for _, e in ipairs(genderFrames.deferredTileFrees) do
                if e.hwArea == tiering.hw.area then e.hwArea = localAreaId end
            end
            tiering.hw.area = localAreaId
            hwReleaseAll(true)
            -- hwReleaseAll blanks the area; left blank, next frame takes the warp branch and forgets the re-acquired.
            tiering.hw.area = localAreaId
        else
            hwReleaseAll(false)
            tiering.hw.area = localAreaId
        end
    end

    for playerId in pairs(tiering.hw.byPeer) do
        if not hwSet[playerId] or not remotes[playerId] then hwRelease(playerId, true) end
    end

    -- The dust trail outlives the bounce that made it, so it is ticked here rather than inside
    -- any one peer's placement -- a peer who leaves the tier mid-puff still gets the tail of it.
    hwPuffTick()
    hwRippleTick()

    local playerScreenX, playerScreenY = playerScreenPos()
    local camPixX, camPixY, pmX, pmY = anchorFrame(localAreaId, playerScreenX, playerScreenY,
        playerMapX, playerMapY)
    playerMapX, playerMapY = pmX, pmY

    for playerId in pairs(hwSet) do
        local remote = remotes[playerId]
        local info = remote and graphicsInfo(remote.gfx or 0)
        if info then
            local rec = tiering.hw.byPeer[playerId]
            -- A graphic change is a different tile count (walker 8, bike or surf 16): release and re-acquire.
            if rec and rec.gfx ~= nil and rec.gfx ~= remote.gfx then
                hwRelease(playerId, true)
                rec = nil
            end
            if not rec then rec = hwAcquire(playerId, info) end
            -- Why nothing appeared, to the file every 5 seconds: a tier that renders nobody looks switched off.
            if not rec and (not tiering.hw.lastWhy
                or frameCounter - tiering.hw.lastWhy > 300) then
                tiering.hw.lastWhy = frameCounter
                logFile(string.format(
                    "hw tier: no slot/tiles for %s (free slots=%d, wanted %d tiles, gfx=%s)",
                    tostring(playerId), tiering.hwBudget(), info.tileCount, tostring(remote.gfx)))
            end
            if rec then
                -- Where on screen: the painted tier's origin + delta + camera form, already the top-left in pixels.
                local glideX = remote.gX or remote.x
                local glideY = remote.gY or remote.y
                -- Compare mode pins this copy to the spawned ghost's sprite, so position leaves the comparison and only
                -- the renderer differs: the glide trails by genderFrames.drawnDelay by design.
                local cmpPin = COMPARE_TIERS and playerId:match("%-ghost$") and ghosts[playerId]
                if cmpPin then
                    local gs = sprAddr(cmpPin.sprId)
                    local px = rs16(gs + 0x20) + rs16(gs + 0x24) + memory.read_s8(gs + 0x28)
                        + rs16(GSPRITECOORDOFFSETX_ADDR + (genderFrames.spriteAddrOffset or 0))
                    local py = rs16(gs + 0x22) + rs16(gs + 0x26) + memory.read_s8(gs + 0x29)
                        + rs16(GSPRITECOORDOFFSETY_ADDR + (genderFrames.spriteAddrOffset or 0))
                    local a = tiering.hw.base + rec.slot * 8
                    local sx = px + (tiering.hw.cmpDX or 0) * TILE
                    local sy = py + (tiering.hw.cmpDY or 0) * TILE
                    local t0, t1 = 0x8000, 0x8000
                    if info.oam ~= 0 then t0, t1 = r16(info.oam + 0x00), r16(info.oam + 0x02) end
                    local flip = 0
                    local aptr = r32(info.anims + (remote.sanim or 0) * 4)
                    if isRomPtr(aptr)
                        and ((r32(aptr + (remote.sidx or 0) * 4) >> 22) & 1) == 1 then
                        flip = 0x1000
                    end
                    local an, ai = remote.sanim or 0, remote.sidx or 0
                    if rec.gfx ~= remote.gfx or rec.animNum ~= an or rec.animIdx ~= ai then
                        loadGhostFrameNow(rec, info, an, ai)
                        if COMPARE_TIERS then
                            logFile(string.format(
                                "HW LOAD gfx=%s an=%s/%s tiles=%s..%s f=%d emu=%d",
                                tostring(remote.gfx), tostring(an), tostring(ai),
                                tostring(rec.tileStart),
                                tostring(rec.tileStart and rec.tileStart + rec.tileCount - 1),
                                frameCounter, emu.framecount()))
                        end
                        rec.gfx, rec.animNum, rec.animIdx = remote.gfx, an, ai
                    end
                    w16(a + 0, (t0 & 0xff00) | (sy & 0xff))
                    w16(a + 2, (t1 & 0xfe00) | (sx & 0x1ff) | flip)
                    w16(a + 4, (rec.tileStart & 0x3ff) | (hwSpritePriority() << 10)
                        | ((info.paletteSlot or 0) << 12))
                    -- sy carries the pinned sprite's pos2, so the hop arc comes back off for the two ground effects.
                    hwDrawFx(playerId, rec, remote, info, sx, sy, rs16(gs + 0x26), flip ~= 0)
                    tiering.hw.placed = tiering.hw.placed + 1
                    if COMPARE_TIERS then tiering.hwLastX, tiering.hwLastY = sx, sy end
                    goto hwNextPeer
                end
                -- The loopback ghost stands beside the player, not on them, so it can be judged and walked anywhere.
                if playerId:match("%-ghost$") then
                    if COMPARE_TIERS then
                        -- Three-way compare: the hardware copy sits tiering.hw.cmpDX/cmpDY tiles from the spawned one,
                        -- and a loader script can move it without a restart.
                        glideX = glideX + LOOPBACK_GHOST_OFFSET_TILES_X + (tiering.hw.cmpDX or 0)
                        glideY = glideY + LOOPBACK_GHOST_OFFSET_TILES_Y + (tiering.hw.cmpDY or 0)
                    else
                        glideX = glideX + LOOPBACK_GHOST_OFFSET_TILES_X
                        glideY = glideY + LOOPBACK_GHOST_OFFSET_TILES_Y
                    end
                end
                local sx = (tiering.originX or playerScreenX)
                    + (glideX - (tiering.anchorX or playerMapX)) * TILE + camPixX
                local sy = (tiering.originY or playerScreenY)
                    + (glideY - (tiering.anchorY or playerMapY)) * TILE + camPixY
                sx, sy = math.floor(sx + 0.5), math.floor(sy + 0.5)
                -- The peer's own hop: soy is its sprite pos2.y (the surf bob and the jump arc), taken verbatim, since
                -- this tier draws the peer's own frame from its own template.
                local arc = remote.soy or 0
                sy = sy + arc

                -- Off screen gets the hidden entry, not a wrapped one: x is 9 bits and y 8, so a far peer reappears.
                local a = tiering.hw.base + rec.slot * 8
                if sx + (info.width or FRAME_WIDTH_PX) <= 0 or sx >= 240
                    or sy + (info.height or FRAME_HEIGHT_PX) <= 0 or sy >= 160 then
                    w16(a + 0, tiering.hw.d0)
                    w16(a + 2, tiering.hw.d1)
                    w16(a + 4, tiering.hw.d2)
                    hwFxHide(rec, "shadow")
                    hwFxHide(rec, "dust")
                else
                    -- The graphic's own OAM template carries the right shape and size, as in spawnSurfBlob.
                    local t0, t1 = 0x8000, 0x8000 -- 16x32, the walker's shape/size, as the fallback
                    if info.oam ~= 0 then t0, t1 = r16(info.oam + 0x00), r16(info.oam + 0x02) end

                    -- The pixels, only on a change: a frame copy is cheap once and ruinous per frame.
                    local an, ai = remote.sanim or 0, remote.sidx or 0
                    if rec.gfx ~= remote.gfx or rec.animNum ~= an or rec.animIdx ~= ai then
                        loadGhostFrameNow(rec, info, an, ai)
                        if COMPARE_TIERS then
                            logFile(string.format(
                                "HW LOAD gfx=%s an=%s/%s tiles=%s..%s f=%d emu=%d",
                                tostring(remote.gfx), tostring(an), tostring(ai),
                                tostring(rec.tileStart),
                                tostring(rec.tileStart and rec.tileStart + rec.tileCount - 1),
                                frameCounter, emu.framecount()))
                        end
                        rec.gfx, rec.animNum, rec.animIdx = remote.gfx, an, ai
                    end

                    -- Facing is in the animation command: east is the west frames flipped, bit 22 of the command word.
                    -- Bit 12 of attr1 is hFlip for a non-affine entry, which an overworld character always is.
                    local flip = 0
                    local aptr = r32(info.anims + an * 4)
                    if isRomPtr(aptr) and ((r32(aptr + ai * 4) >> 22) & 1) == 1 then
                        flip = 0x1000
                    end
                    w16(a + 0, (t0 & 0xff00) | (sy & 0xff))
                    w16(a + 2, (t1 & 0xfe00) | (sx & 0x1ff) | flip)
                    -- Priority 2 is the engine's own for overworld characters; the palette slot is the graphic's own.
                    w16(a + 4, (rec.tileStart & 0x3ff) | (hwSpritePriority() << 10)
                        | ((info.paletteSlot or 0) << 12))
                    -- The arc is in sy now, so it comes back off for the two ground effects.
                    hwDrawFx(playerId, rec, remote, info, sx, sy, arc, flip ~= 0)
                    tiering.hw.placed = tiering.hw.placed + 1
                    -- Published for the three-way compare log in drawRemotes, so a lag can be pinned on one tier.
                    if COMPARE_TIERS then
                        tiering.hwLastX, tiering.hwLastY = sx, sy
                        -- The formula's four inputs, so a drift can be attributed.
                        tiering.hwDbg = string.format("gX=%.3f anch=%s orig=%s cam=%d",
                            glideX, tostring(tiering.anchorX), tostring(tiering.originX), camPixX)
                    end
                end
            end
        end
        ::hwNextPeer::
    end
end

-- A painted ghost against the player: the one standing lower draws in front, by 16px bands of the bottom edge, as the
-- game sorts on one elevation (the peer's elevation is not on the wire). On genderFrames: 200-local ceiling.
genderFrames.sortBand = function(bottomY)
    return (math.floor(bottomY + 8) & 0xFF) >> 4
end

-- The player's opaque pixels in screen coordinates, one span list per row, from its current graphic and
-- frame so a bike or a rod masks with its own shape. Cached per frame: the decode is the expensive half.
-- Returns rows, top, bottom, left, right; the box lets a caller reject a non-overlapping ghost for free.
genderFrames.playerMask = function()
    if genderFrames.pmAt == frameCounter then
        return genderFrames.pmRows, genderFrames.pmT, genderFrames.pmB, genderFrames.pmL, genderFrames.pmR
    end
    -- Cleared up front: an early return must not leave the previous frame's bottom behind.
    genderFrames.pmAt, genderFrames.pmRows, genderFrames.pmFrameBottom = frameCounter, nil, nil
    local gfx = localGraphicsId()
    if not gfx then return nil end
    local pd = sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04))
    -- The animation sampled inside BuildOamBuffer when fresh (the frame this overlay lands on); the live read
    -- is the next frame's. Both are kept so the trace can say whether they disagreed.
    local liveNum, liveIdx = r8(pd + 0x2a), r8(pd + 0x2b)
    local useNum, useIdx = liveNum, liveIdx
    if genderFrames.pmSnapAt and (frameCounter - genderFrames.pmSnapAt) <= 1 then
        useNum, useIdx = genderFrames.pmSnapNum, genderFrames.pmSnapIdx
    end
    genderFrames.pmLive, genderFrames.pmUsed = liveNum .. "/" .. liveIdx, useNum .. "/" .. useIdx
    -- The PPU draws OAM attribute 1's flip, runsForPeerGfx reports the anim command's: both are logged.
    genderFrames.pmOamFlip = (r16(pd + 0x02) & 0x1000) ~= 0
    -- The third return is the flip: east is the west art mirrored, so the mask mirrors as drawRunList does.
    local ok, runs, pinfoRet, pflip = pcall(genderFrames.runsForPeerGfx, gfx, useNum, useIdx)
    if not ok or not runs or #runs == 0 then return nil end
    local px, py = playerScreenPos()
    if not px then return nil end
    -- The frame's bottom, not the ink's, to compare like with a peer's frame bottom: the art has empty rows
    -- under the feet, and an ink bottom puts two characters a tile apart in one band.
    local pinfo = pinfoRet or graphicsInfo(gfx)
    local pw = (pinfo and pinfo.width) or FRAME_WIDTH_PX
    genderFrames.pmFrameBottom = py + ((pinfo and pinfo.height) or FRAME_HEIGHT_PX)
    local rows, t, b, l, r = {}, nil, nil, nil, nil
    for i = 1, #runs do
        local run = runs[i]
        local y = math.floor(py + run.y)
        local list = rows[y]
        if not list then list = {} rows[y] = list end
        local rx1, rx2 = run.x1, run.x2
        if pflip then rx1, rx2 = pw - 1 - run.x2, pw - 1 - run.x1 end
        local x1, x2 = px + rx1, px + rx2
        list[#list + 1] = { x1, x2 }
        if t == nil or y < t then t = y end
        if b == nil or y > b then b = y end
        if l == nil or x1 < l then l = x1 end
        if r == nil or x2 > r then r = x2 end
    end
    genderFrames.pmCmdFlip = pflip and true or false
    genderFrames.pmRows, genderFrames.pmT, genderFrames.pmB, genderFrames.pmL, genderFrames.pmR =
        rows, t, b, l, r
    return rows, t, b, l, r
end

-- Cuts the player's pixels out of one peer's keep-span mask, or returns the mask untouched. keepSpans is
-- strict in drawRunList (a missing row paints nothing), so every row the ghost covers gets a span list.
genderFrames.maskBehindPlayer = function(occl, left, top, width, height)
    -- MESHGHOST_EMERALD_NO_SORT (dev): return the caller's mask, to run with the draw-order work subtracted.
    if MESHGHOST_EMERALD_NO_SORT then return occl end
    local rows, pt, pb, pl, pr = genderFrames.playerMask()
    -- Why it decided, with the numbers it decided from: once a second, and every frame the two animation
    -- reads or the two flips disagree, since a transition-only fault is never on a round frame.
    if MESHGHOST_EMERALD_SORT_TRACE
        and (frameCounter % 60 == 0 or genderFrames.pmLive ~= genderFrames.pmUsed
             or genderFrames.pmCmdFlip ~= genderFrames.pmOamFlip) then
        logFile(string.format(
            "SORT f=%d ghost=%s,%s %sx%s bottom=%s band=%s | player=%s box=%s,%s..%s,%s bottom=%s band=%s",
            frameCounter, tostring(left), tostring(top), tostring(width), tostring(height),
            tostring(top and height and (top + height)),
            tostring(top and height and genderFrames.sortBand(top + height)),
            rows and "mask" or "NO-MASK", tostring(pl), tostring(pt), tostring(pr), tostring(pb),
            tostring(genderFrames.pmFrameBottom),
            tostring(genderFrames.pmFrameBottom
                and genderFrames.sortBand(genderFrames.pmFrameBottom))
            .. " anim live=" .. tostring(genderFrames.pmLive)
            .. " used=" .. tostring(genderFrames.pmUsed)
            .. " flip cmd=" .. tostring(genderFrames.pmCmdFlip)
            .. " oam=" .. tostring(genderFrames.pmOamFlip)))
    end
    if not rows then return occl end
    -- No overlap, the common case: four compares.
    if math.floor(top + height - 1) < pt or math.floor(top) > pb
        or left + width - 1 < pl or left > pr then return occl end
    -- Both bottoms through the engine's banding; the ghost is in front only when strictly lower. A tie puts it
    -- behind: vanilla never puts two characters on one tile, ghosts are walk-through, and a ghost may never
    -- hide the player.
    if genderFrames.sortBand(top + height)
        > genderFrames.sortBand(genderFrames.pmFrameBottom or (pb + 1)) then return occl end
    -- Integer rows: drawRunList looks spans up by math.floor(y) and `top` is a float off the glide, so a
    -- float key would answer nil, and a nil row paints nothing.
    local out = {}
    local yTop, yBot = math.floor(top), math.floor(top + height - 1)
    for y = yTop, yBot do
        local base = occl and occl[y]
        if occl and not base then
            out[y] = nil          -- already fully occluded by scenery: leave it that way
        else
            local pieces = base or { { left, left + width - 1 } }
            local cut = rows[y]
            if not cut then
                out[y] = pieces
            else
                local acc = pieces
                for c = 1, #cut do
                    local cx1, cx2 = cut[c][1], cut[c][2]
                    local next_ = {}
                    for s = 1, #acc do
                        local sx1, sx2 = acc[s][1], acc[s][2]
                        if cx2 < sx1 or cx1 > sx2 then
                            next_[#next_ + 1] = { sx1, sx2 }
                        else
                            if sx1 < cx1 then next_[#next_ + 1] = { sx1, cx1 - 1 } end
                            if sx2 > cx2 then next_[#next_ + 1] = { cx2 + 1, sx2 } end
                        end
                    end
                    acc = next_
                end
                out[y] = acc
            end
        end
    end
    -- What the mask emitted: an empty row where the player has no pixels is the ghost eaten, not sorted.
    if MESHGHOST_EMERALD_SORT_TRACE and frameCounter % 60 == 0 then
        local nEmpty, firstEmpty, nFull = 0, nil, 0
        for y = yTop, yBot do
            local sp = out[y]
            if not sp or #sp == 0 then
                nEmpty = nEmpty + 1
                if not firstEmpty then firstEmpty = y end
            else
                nFull = nFull + 1
            end
        end
        -- And three sample rows' spans beside the ghost's x range: a span outside the sprite counts as kept.
        local function sp(y)
            local l = out[y]
            if not l or #l == 0 then return "-" end
            local parts = {}
            for i = 1, #l do parts[i] = l[i][1] .. ".." .. l[i][2] end
            return table.concat(parts, ",")
        end
        logFile(string.format("SORTMASK f=%d rows=%d..%d kept=%d empty=%d firstEmpty=%s occl=%s "
            .. "inkRows=%d..%d ghostX=%d..%d | r%d=%s r%d=%s r%d=%s",
            frameCounter, yTop, yBot, nFull, nEmpty, tostring(firstEmpty),
            occl and "yes" or "no", pt or -1, pb or -1,
            math.floor(left), math.floor(left + width - 1),
            yTop, sp(yTop), yTop + 16, sp(yTop + 16), yBot, sp(yBot)))
    end
    return out
end

-- skipSpawned names the peers another tier already draws (spawned or hardware), which a flat copy would cover;
-- compareOnly paints only the loopback ghost.
local function drawRemotes(localAreaId, playerMapX, playerMapY, skipSpawned, compareOnly)
    -- GBA display size; declared in here because the main chunk is at Lua's 200-local ceiling.
    local SCREEN_WIDTH_PX, SCREEN_HEIGHT_PX = 240, 160
    -- The painted compare copy's column, in tiles from the player: settable so two copies can be compared on
    -- one tile (-4 lines it up with the hardware copy).
    local COMPARE_DRAWN_OFFSET_TILES_X =
        tonumber(MESHGHOST_EMERALD_DRAWN_COMPARE_DX or "") or -2
    -- The engine hides its own player through a door transition; with no player there is nobody for a ghost
    -- to stand beside. Only a backstop (below): the scene fade does the visible work.
    local playerSprite = sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04))
    local playerHidden = (r8(playerSprite + 0x3e) & 0x04) ~= 0

    -- The scene's lighting, since the cached runs are cartridge colours: fit live = a*rom + b over the player's
    -- live OBJ palette against its ROM palette, which covers fades to black and to white (a ratio sees only
    -- black). 32 reads a frame, nothing per peer. The additive term lives on genderFrames, not tiering:
    -- drawRunList is defined above `local tiering`.
    local dim = 1
    do
        local ps = sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04))
        local slot = (r16(ps + 0x04) >> 12) & 0xF
        local romPal = GOBJECTEVENTPAL_BRENDAN_ADDR + (genderFrames.romOffset or 0)
        local sb2 = session.saveBlockPtr(GSAVEBLOCK2PTR_ADDR)
        if sb2 ~= 0 and r8(sb2 + 0x08) == 1 then
            romPal = GOBJECTEVENTPAL_MAY_ADDR + (genderFrames.romOffset or 0)
        end
        local sx, sy, sxx, sxy, syy = 0, 0, 0, 0, 0
        local xs, ys = {}, {}
        for i = 0, 15 do
            local c = r16(0x05000200 + slot * 32 + i * 2)
            local o = r16(romPal + i * 2)
            for s = 0, 10, 5 do
                local x, y = (o >> s) & 0x1F, (c >> s) & 0x1F
                local k = #xs + 1
                xs[k], ys[k] = x, y
                sx, sy = sx + x, sy + y
            end
        end
        local nPts = #xs
        local mx, my = sx / nPts, sy / nPts
        for i = 1, nPts do
            local dx, dy = xs[i] - mx, ys[i] - my
            sxx, sxy, syy = sxx + dx * dx, sxy + dx * dy, syy + dy * dy
        end
        local a, b
        if syy < 1e-6 then
            -- Every live colour is one: the fade reached its target, and the ghost is that flat colour too.
            a, b = 0, my
        elseif sxx > 1e-6 and sxy * sxy > 0.9 * sxx * syy then
            a = sxy / sxx
            b = my - a * mx
        end
        -- No fit: the slot is not holding this palette (mid-load, or reused), so trust the cartridge.
        if not a then
            a, b = 1, 0
        end
        if a > 1 then a = 1 elseif a < 0 then a = 0 end
        -- 0..31 palette units up to the 0..255 the run colours are cached in.
        b = b * (255 / 31)
        if b > 255 then b = 255 elseif b < 0 then b = 0 end
        dim, genderFrames.tintAdd = a, b
    end
    -- The backstop needs both: a dark cave is dim with the player visible, a door's first frames hidden but bright.
    if playerHidden and dim < 0.15 then
        tiering.painted = 0
        return
    end

    local playerScreenX, playerScreenY = playerScreenPos()
    local __panelT0 = MESHGHOST_EMERALD_PROFILE and os.clock() or nil
    local panelRows = tiering.scanPanel()
    if __panelT0 then MG_PANEL_T = (MG_PANEL_T or 0) + (os.clock() - __panelT0) end

    -- Anchored on the engine's camera offset, not an estimate of the player, who never moves on screen: the
    -- position is C - camPix/16, with the tile counter only calibrating C when aligned (it leads moving
    -- right or down). The same anchor the hardware tier places against.
    local camPixX, camPixY, pmX, pmY = anchorFrame(localAreaId, playerScreenX, playerScreenY,
        playerMapX, playerMapY)
    playerMapX, playerMapY = pmX, pmY

    -- Counted, not inferred: assigned to this tier and painted this frame differ by the off-screen cull.
    local painted = 0
    for playerId, remote in pairs(remotes) do
        -- Only the loopback ghost may be in both tiers, in compare mode. Cached per peer; false caches too.
        local isLoopback = remote.__lb
        if isLoopback == nil then
            isLoopback = playerId:match("%-ghost$") ~= nil
            remote.__lb = isLoopback
        end
        local wanted
        if compareOnly then
            wanted = isLoopback
        else
            wanted = (COMPARE_TIERS and isLoopback) or not (skipSpawned and skipSpawned[playerId])
        end
        -- The engine has stopped drawing this character (a script hide, a boat ride, a Fly), so neither do we.
        -- The boat and the bird are engine sprites only the spawned tier can show.
        if remote.invis or remote.boat or remote.fly == 2 then wanted = false end
        if remote.areaId == localAreaId and wanted then
            -- The core's continuous position, unrounded; the glide paces tile to tile at the game's frame counts.
            local glideX, glideY = glideRemote(remote, remote.x, remote.y)
            -- Placed from one camera counter: gSpriteCoordOffset and gTotalCameraPixelOffset are written at
            -- different points in the frame, so the origin is captured with the anchor rather than read per frame.
            -- Compare mode pins the painted copy to the spawned sprite, mirrored: the engine's step scheduler
            -- cannot be matched from packet timing, and pinned, what differs is rendering alone.
            local screenX, screenY
            local pinned = COMPARE_TIERS and ghosts[playerId]
            -- Height off the ground, negative up (a hop, the surf bob), kept apart so the shadow and dust sit on
            -- the ground: a pinned copy reads the spawned sprite's, any other peer the wire's soy.
            local arc = 0
            if pinned then
                local gs = sprAddr(pinned.sprId)
                arc = rs16(gs + 0x26)
                -- A fishing sprite's pos2 aligns its own frame, not the wire's: take only the true anchor, and the
                -- paint below adds the shift for the frame it draws.
                local pinnedAlignX = rs16(gs + 0x24)
                if isFishingGfx(pinned.gfx) then pinnedAlignX, arc = 0, 0 end
                screenX = rs16(gs + 0x20) + pinnedAlignX + memory.read_s8(gs + 0x28)
                    + rs16(GSPRITECOORDOFFSETX_ADDR + (genderFrames.spriteAddrOffset or 0))
                    + (COMPARE_DRAWN_OFFSET_TILES_X - LOOPBACK_GHOST_OFFSET_TILES_X) * TILE
                screenY = rs16(gs + 0x22) + arc + memory.read_s8(gs + 0x29)
                    + rs16(GSPRITECOORDOFFSETY_ADDR + (genderFrames.spriteAddrOffset or 0))
            end

            local unpinnedX = (tiering.originX or playerScreenX)
                + (glideX - (tiering.anchorX or playerMapX)) * TILE + camPixX
            local unpinnedY = (tiering.originY or playerScreenY)
                + (glideY - (tiering.anchorY or playerMapY)) * TILE + camPixY
            if not pinned then
                -- Except while fishing: a rod's pos2 is alignment, which fishingFrameShift adds for the painted frame.
                arc = (not isFishingGfx(remote.gfx)) and (remote.soy or 0) or 0
                screenX, screenY = unpinnedX, unpinnedY + arc
            end
            -- A pinned position already carries the mirror; the loopback nudge would apply it twice.
            if isLoopback and not pinned then
                screenX = screenX + (COMPARE_TIERS and COMPARE_DRAWN_OFFSET_TILES_X
                    or LOOPBACK_GHOST_OFFSET_TILES_X) * TILE
                screenY = screenY + LOOPBACK_GHOST_OFFSET_TILES_Y * TILE
            end

            -- The seam trace's painted position, stamped before the cull so off screen reads apart from unpainted.
            if tiering.seamTrace or MESHGHOST_EMERALD_SEAM_TRACE then
                remote.dbgScreenX, remote.dbgScreenY, remote.dbgScreenAt = screenX, screenY, frameCounter
            end

            -- Off-screen peers cost nothing, animation included, so the tier scales with what is visible.
            if screenX + FRAME_WIDTH_PX > 0 and screenX < SCREEN_WIDTH_PX
                and screenY + FRAME_HEIGHT_PX > 0 and screenY < SCREEN_HEIGHT_PX then
                -- Facing: from motion, then the delayed wire facing (glideRemote's ring) for a still peer, then the
                -- live one before the ring fills. Never the live one while moving: it turns early.
                local dirInfo = DIRECTION_ANIM[remote.gFacing or remote.gOrient or remote.orientation]
                    or DIRECTION_ANIM.south
                local frameIndex, pose
                -- Moving comes from the glide, not the anim tag: a forced move (cutscene, scripted walk) reads idle.
                local gliding = remote.gMoved
                -- The no-animate freeze is latched to the glide, not the wire flag, holding the frame from when it
                -- began: this copy is still sliding after the peer has stopped and gone idle.
                if remote.noanim then
                    remote.noanimImg = genderFrames.peerImageIndex(remote) or remote.noanimImg
                elseif not gliding then
                    remote.noanimImg = nil
                end
                if remote.noanim or remote.noanimImg then
                    -- A movement that does not animate (an ice slide): the peer's own frame, which shares this
                    -- tier's index space, rather than one derived from distance.
                    pose = "walk"
                    frameIndex = remote.noanimImg or dirInfo.idle
                    remote.lastAnim = remote.anim
                    remote.lastOrientation = remote.orientation
                    -- None of the frozen distance was walked; reset it so the next step starts its own cycle.
                    remote.gDist = 0
                elseif remote.anim == "walking" or remote.anim == "running" or gliding then
                    pose = (remote.anim == "running") and "run" or "walk"
                    -- By distance, not time: a pose every half tile, so one tile is always two poses and a ghost
                    -- catching up animates faster rather than longer.
                    if remote.lastOrientation ~= remote.orientation then
                        remote.gDist = 0
                        remote.lastOrientation = remote.orientation
                    end
                    remote.lastAnim = remote.anim
                    frameIndex = dirInfo.steps[
                        (math.floor((remote.gDist or 0) * 2) % #dirInfo.steps) + 1]
                else
                    -- A turn in place plays one stride of the new direction, the engine's turn animation being one
                    -- pose hold; it arrives as idle because the game reports runningState 1 for it.
                    if remote.lastOrientation ~= remote.orientation then
                        remote.turnUntil = frameCounter + WALK_POSE_DURATIONS[1]
                    end
                    remote.animTimer = 0
                    remote.animStepIndex = 1
                    remote.lastAnim = remote.anim
                    remote.lastOrientation = remote.orientation
                    pose = "walk" -- idle frames (0-2) only exist in the walk/Normal pic table
                    if remote.turnUntil and frameCounter < remote.turnUntil then
                        frameIndex = dirInfo.steps[1]
                    else
                        frameIndex = dirInfo.idle
                    end
                end

                -- Compare mode: both renderers of one peer, per frame, to a buffered file flushed once a second.
                local g = ghosts[playerId]
                if COMPARE_TIERS and g and tiering.moveLog then
                    local gs = sprAddr(g.sprId)
                    tiering.moveLog[#tiering.moveLog + 1] = string.format(
                        "f=%d spawned=%d,%d drawn=%.2f,%.2f peer=%.2f,%.2f glide=%.3f,%.3f "
                            .. "player=%.3f,%.3f step=%s",
                        frameCounter,
                        rs16(gs + 0x20) + rs16(gs + 0x24) + memory.read_s8(gs + 0x28)
                            + rs16(GSPRITECOORDOFFSETX_ADDR + (genderFrames.spriteAddrOffset or 0)),
                        rs16(gs + 0x22) + rs16(gs + 0x26) + memory.read_s8(gs + 0x29)
                            + rs16(GSPRITECOORDOFFSETY_ADDR + (genderFrames.spriteAddrOffset or 0)),
                        screenX, screenY, remote.x, remote.y,
                        remote.gX or -1, remote.gY or -1, playerMapX, playerMapY,
                        tostring(remote.gStepping))
                    -- And the frame chosen with the gDist it came from: a cycle that never advanced reads apart from
                    -- one that picked the same frame twice.
                    tiering.moveLog[#tiering.moveLog] = tiering.moveLog[#tiering.moveLog]
                        .. string.format(" | pose=%s frame=%s gDist=%.3f gMoved=%s gfx=%s "
                            .. "sanim=%s/%s hw=%s,%s",
                            tostring(pose), tostring(frameIndex), remote.gDist or -1,
                            tostring(remote.gMoved), tostring(remote.gfx),
                            tostring(remote.sanim), tostring(remote.sidx),
                            tostring(tiering.hwLastX), tostring(tiering.hwLastY))
                        .. " | " .. tostring(tiering.hwDbg)
                end
                -- The shadow first, since paint order is depth on this tier; the arc comes off so it stays on the
                -- ground, centred on the graphic's own width (a bike or a rod is 32 wide).
                if isJumpAction(remote.act) then
                    local sgi = remote.gfx and graphicsInfo(remote.gfx) or nil
                    local halfW = (sgi and sgi.width or FRAME_WIDTH_PX) >> 1
                    -- Not screenX + cx: cx is the peer-graphic branch's, and here it would read a nil global.
                    drawOneShadow(screenX + halfW,
                        shadowTopFor(sgi, screenY - arc), dim)
                end

                -- A peer wearing its own graphic (bike, surf, rod) draws from it; the walker (0) keeps the cached path.
                local drew = false
                -- The peer's last moving animation, re-used while this tier is still crossing a tile the peer has
                -- finished: the moving number differs per graphic, so it is remembered rather than tabled.
                if (remote.anim == "walking" or remote.anim == "running") and remote.sanim then
                    remote.lastMoveAnim = remote.sanim
                end
                -- Compare mode: every wire graphic change, which tells a peer sent as the walker from one that failed
                -- to decode.
                if COMPARE_TIERS and remote.gfxWas ~= remote.gfx then
                    logFile(string.format("WIRE gfx %s -> %s (anim=%s sanim=%s/%s act=%s)",
                        tostring(remote.gfxWas), tostring(remote.gfx), tostring(remote.anim),
                        tostring(remote.sanim), tostring(remote.sidx), tostring(remote.act)))
                    remote.gfxWas = remote.gfx
                end
                -- The phase counts from the step's start: a tile always begins at index 0 of the ride cycle.
                if remote.gMoved and not remote.gMovedPrev then remote.gDistBase = remote.gDist end
                remote.gMovedPrev = remote.gMoved
                -- While the glide moves, distance drives the whole step's frame; hops and jumps (jump in place,
                -- wheelie hop and jump) keep the peer's own animation.
                local drawAnim, drawIdx = remote.sanim, remote.sidx
                if remote.gMoved and remote.lastMoveAnim
                    and not (remote.act and ((remote.act >= 0x46 and remote.act <= 0x4d)
                        or (remote.act >= 0x70 and remote.act <= 0x7b)))
                then
                    drawAnim = remote.lastMoveAnim
                    drawIdx = math.floor(((remote.gDist or 0) - (remote.gDistBase or 0)) * 2) % 4
                end
                if genderFrames.peerGfxDrawn and remote.gfx and remote.gfx ~= 0 and remote.sanim then
                    -- A pinned copy takes the spawned sprite's live animation too, or it strobes at wire rate.
                    if pinned then
                        local ps2 = sprAddr(pinned.sprId)
                        drawAnim, drawIdx = r8(ps2 + 0x2a), r8(ps2 + 0x2b)
                    end
                    local runs, info, gfxFlip, imgIdx =
                        genderFrames.runsForPeerGfx(remote.gfx, drawAnim, drawIdx)
                    -- A substituted frame that fails retries the peer's own before the walker (a dismount).
                    if not runs and drawAnim ~= remote.sanim then
                        runs, info, gfxFlip, imgIdx =
                            genderFrames.runsForPeerGfx(remote.gfx, remote.sanim, remote.sidx)
                    end
                    if runs and info then
                        -- A wide frame is centred as the engine does (centerToCorner = -(width >> 1)); a pinned
                        -- position already carries the spawned sprite's.
                        local cx, cy = 0, 0
                        if not pinned then
                            cx = (FRAME_WIDTH_PX >> 1) - (info.width >> 1)
                            cy = (FRAME_HEIGHT_PX >> 1) - (info.height >> 1)
                        end
                        -- The fishing shift for the frame painted: image and alignment from one wire sample.
                        if isFishingGfx(remote.gfx) and remote.sanim and remote.sidx then
                            local fx2, fy2 = fishingFrameShift(info.anims, remote.sanim,
                                remote.sidx, remote.orientation == "west")
                            cx, cy = cx + fx2, cy + fy2
                        end

                        -- Paint order is depth: the reflection, then the blob, then the rider, the engine's subpriority
                        -- order. The reflection is the same frame in the mapped palette, upside down, height-2 lower,
                        -- for any peer on reflective ground.
                        do
                            -- Rider and blob bob together and the reflection takes the bob negated, so its gap is the
                            -- offset minus twice the bob. The position above already carries the bob.
                            local bob = arc

                            -- The engine's own ground test, asked where the ghost is drawn rather than where the peer
                            -- is: off reflective ground the engine creates no reflection at all.
                            local gbX, gbY = genderFrames.gridBase()
                            local rpal, rkind2
                            if gbX then
                                local ggx = math.floor((screenX - gbX) / TILE)
                                local ggy = math.floor((screenY - bob + TILE - gbY) / TILE)
                                tiering.lastTile = tiering.lastTile or {}
                                rpal, rkind2 = genderFrames.reflectPalFor(tiering.lastTile, playerId,
                                    remote.areaId, ggx, ggy,
                                    (info.width + 8) >> 4, (info.height + 8) >> 4,
                                    info.paletteSlot)
                            end
                            local rruns = rpal and genderFrames.runsFromImages(
                                string.format("r%d:%d:%d", remote.gfx, imgIdx, rpal),
                                info.images, info.width, info.height, imgIdx, rpal)
                            local rtop = screenY + cy + info.height - 2 - 2 * bob
                            if COMPARE_TIERS then
                                local ck = string.format("%d:%d:%s:%s", math.floor(screenY + cy),
                                    math.floor(rtop), tostring(tiering.hwBodyY),
                                    tostring(tiering.hwReflY))
                                if genderFrames.reflCmpKey ~= ck then
                                    genderFrames.reflCmpKey = ck
                                    logFile(string.format(
                                        "REFL CMP painted body=%d refl=%d | hw body=%s refl=%s "
                                        .. "| h=%d bob=%d arc=%d cy=%d",
                                        math.floor(screenY + cy), math.floor(rtop),
                                        tostring(tiering.hwBodyY), tostring(tiering.hwReflY),
                                        info.height, bob, arc, cy))
                                end
                            end
                            -- Only over water: the engine has OAM priority, we ask the map, once per reflection.
                            local wet = rruns and genderFrames.reflectiveSpans(
                                screenX + cx, rtop, info.width, info.height, "reflection", genderFrames.scWet())
                            if rruns then
                                drawRunList(rruns, info.width, gfxFlip, screenX + cx, rtop,
                                    panelRows, dim, info.height,
                                    genderFrames.reflectionXScale(rkind2), wet)
                            end
                            -- The water trail, between the reflection and the rider: a ripple per tile this tier drew
                            -- the peer stepping onto (reflectPalFor's previous-tile stamp), born where the character
                            -- was and anchored on gSpriteCoordOffset so it stays on its water through a scroll.
                            tiering.ripples = tiering.ripples or {}
                            local rlist = tiering.ripples[playerId]
                            if not rlist then rlist = {} tiering.ripples[playerId] = rlist end
                            if genderFrames.rippleDue(tiering.lastTile, playerId,
                                peerIsSurfing(remote)) then
                                rlist[#rlist + 1] = { at = frameCounter,
                                    bx = screenX + cx + (info.width >> 1) - 8
                                        - rs16(GSPRITECOORDOFFSETX_ADDR + (genderFrames.spriteAddrOffset or 0)),
                                    by = screenY + cy - arc + info.height - 10
                                        - rs16(GSPRITECOORDOFFSETY_ADDR + (genderFrames.spriteAddrOffset or 0)) }
                            end
                            for pi = #rlist, 1, -1 do
                                local rip = rlist[pi]
                                local rf = genderFrames.rippleFrameAt(frameCounter - rip.at)
                                local rruns2 = rf and genderFrames.rippleRuns(rf)
                                if not rruns2 then
                                    table.remove(rlist, pi)
                                else
                                    drawRunList(rruns2, genderFrames.rippleFramePx, false,
                                        rip.bx + rs16(GSPRITECOORDOFFSETX_ADDR + (genderFrames.spriteAddrOffset or 0)),
                                        rip.by + rs16(GSPRITECOORDOFFSETY_ADDR + (genderFrames.spriteAddrOffset or 0)),
                                        panelRows, dim)
                                end
                            end

                            -- The surf blob, surfing only: eight pixels below the rider, same centre.
                            local bruns, bflip
                            if not peerIsSurfing(remote) then
                                remote.blobParkPx, remote.blobParkHold, remote.blobParkKind =
                                    nil, nil, nil
                            end
                            if peerIsSurfing(remote) then
                                bruns, bflip = genderFrames.runsForSurfBlob(
                                    genderFrames.dirOf[remote.orientation] or 1)
                            end
                            if bruns then
                                -- Parked through a JUMP_SPECIAL, mirroring the game's BOB_JUST_MON; the hardware
                                -- tier's twin carries the reasoning.
                                local bjumping = remote.act
                                    and remote.act >= 0x3a and remote.act <= 0x3d
                                if bjumping and not remote.blobParkHold then
                                    if remote.blobParkPx then
                                        remote.blobParkHold, remote.blobParkKind =
                                            true, "dismount"
                                    else
                                        local jdx = ({ [0x3c] = -TILE,
                                            [0x3d] = TILE })[remote.act] or 0
                                        local jdy = ({ [0x3a] = TILE,
                                            [0x3b] = -TILE })[remote.act] or 0
                                        remote.blobParkPx = {
                                            screenX + cx + jdx
                                                - rs16(GSPRITECOORDOFFSETX_ADDR + (genderFrames.spriteAddrOffset or 0)),
                                            screenY + cy + jdy + 8 - (arc or 0)
                                                - rs16(GSPRITECOORDOFFSETY_ADDR + (genderFrames.spriteAddrOffset or 0)) }
                                        remote.blobParkHold, remote.blobParkKind =
                                            true, "mount"
                                    end
                                end
                                -- Mount parks end with the jump; the hardware twin says why.
                                if not bjumping and remote.blobParkHold
                                    and remote.blobParkKind == "mount" then
                                    remote.blobParkHold, remote.blobParkKind = nil, nil
                                end
                                local pbx, pby = screenX + cx, screenY + cy + 8
                                if remote.blobParkHold and remote.blobParkPx then
                                    pbx = remote.blobParkPx[1] + rs16(GSPRITECOORDOFFSETX_ADDR + (genderFrames.spriteAddrOffset or 0))
                                    pby = remote.blobParkPx[2] + rs16(GSPRITECOORDOFFSETY_ADDR + (genderFrames.spriteAddrOffset or 0))
                                elseif not bjumping then
                                    remote.blobParkPx = {
                                        pbx - rs16(GSPRITECOORDOFFSETX_ADDR + (genderFrames.spriteAddrOffset or 0)),
                                        pby - rs16(GSPRITECOORDOFFSETY_ADDR + (genderFrames.spriteAddrOffset or 0)) }
                                end
                                drawRunList(bruns, surfBlob.framePx, bflip, pbx,
                                    pby, panelRows, dim, nil, nil,
                                    genderFrames.reflectiveSpans(pbx, pby,
                                        surfBlob.framePx, surfBlob.framePx, "sprite", genderFrames.scBlob()))
                            end
                        end

                        -- Hidden by roofs and tree tops like a spawned ghost: the reflection's mask, asked for a
                        -- priority-2 sprite.
                        local occl = genderFrames.reflectiveSpans(screenX + cx, screenY + cy,
                            info.width, info.height, "sprite", genderFrames.scOccl())
                        -- Compare mode, on change: pixels of the frame's top 8 rows that survive occlusion, and the
                        -- metatile over them, which tells the mask eating a hat from something upstream.
                        if COMPARE_TIERS then
                            local topKept = -1
                            if occl then
                                topKept = 0
                                for py = math.floor(screenY + cy), math.floor(screenY + cy) + 7 do
                                    for _, s in ipairs(occl[py] or {}) do
                                        topKept = topKept + s[2] - s[1] + 1
                                    end
                                end
                            end
                            local gbX, gbY = genderFrames.gridBase()
                            local mid = "?"
                            if gbX then
                                mid = tostring(genderFrames.metatileAt(
                                    math.floor((screenX + cx + 8 - gbX) / TILE),
                                    math.floor((screenY + cy - gbY) / TILE)))
                            end
                            local info2 = graphicsInfo(remote.gfx)
                            local cmdRaw = 0
                            if info2 and info2.anims ~= 0 then
                                local ap = r32(info2.anims + (drawAnim or 0) * 4)
                                if isRomPtr(ap) then cmdRaw = r32(ap + (drawIdx or 0) * 4) end
                            end
                            local minRy, nRuns = 99, 0
                            if runs then
                                for _, rr in ipairs(runs) do
                                    nRuns = nRuns + 1
                                    if rr.y < minRy then minRy = rr.y end
                                end
                            end
                            local k = string.format("%s:%d:%s:%s:%s:%d", tostring(playerId), topKept,
                                mid, tostring(drawAnim), tostring(drawIdx), minRy)
                            if genderFrames.hatLogKey ~= k then
                                genderFrames.hatLogKey = k
                                logFile(string.format(
                                    "f=%d emu=%d HAT %s topKept=%d y=%d anim=%s/%s minRy=%d panels=%s clipped=%d",
                                    frameCounter, emu.framecount(), tostring(playerId), topKept,
                                    math.floor(screenY + cy), tostring(drawAnim),
                                    tostring(drawIdx), minRy,
                                    (function() local c = 0 local rws = {}
                                        if panelRows then for rw in pairs(panelRows) do c = c + 1 rws[#rws+1] = rw end end
                                        table.sort(rws)
                                        return c .. ":" .. table.concat(rws, ",") end)(),
                                    genderFrames.clippedRuns or 0))
                            end
                        end
                        -- A paint can run and keep no span: zero survivors around the body's paint logs the frame
                        -- with the panel scanner's rows, on the emulator's frame clock.
                        local spansBefore = MG_SPANS or 0
                        -- maskBehindPlayer returns occl untouched unless this peer overlaps the player from higher up.
                        drawRunList(runs, info.width, gfxFlip, screenX + cx, screenY + cy,
                            panelRows, dim, nil, nil,
                            genderFrames.maskBehindPlayer(occl, screenX + cx, screenY + cy,
                                info.width, info.height))
                        if COMPARE_TIERS and playerId:match("%-ghost$")
                            and (MG_SPANS or 0) == spansBefore and #runs > 0 then
                            local pr = {}
                            if panelRows then
                                for rw, sp in pairs(panelRows) do
                                    pr[#pr + 1] = string.format("%d:%d-%d", rw, sp[1], sp[2])
                                end
                            end
                            table.sort(pr)
                            logFile(string.format(
                                "BODY INVISIBLE f=%d emu=%d runs=%d y=%d panels=[%s]",
                                frameCounter, emu.framecount(), #runs,
                                math.floor(screenY + cy), table.concat(pr, " ")))
                        end
                        drew = true
                        MG_BODY_PAINTED = true -- gap detector: the BODY, not a reflection/shadow
                    end
                end
                if not drew then
                    -- Compare mode, throttled: a fallback to the walker for a peer with a graphic is a silent dismount
                    -- on screen, so name its state.
                    if COMPARE_TIERS and remote.gfx and remote.gfx ~= 0
                        and (not remote.fellBackAt or frameCounter - remote.fellBackAt >= 30)
                    then
                        remote.fellBackAt = frameCounter
                        logFile(string.format(
                            "DRAWN FELL BACK TO THE WALKER: gfx=%s sanim=%s/%s anim=%s act=%s "
                            .. "gMoved=%s lastMove=%s orient=%s",
                            tostring(remote.gfx), tostring(remote.sanim), tostring(remote.sidx),
                            tostring(remote.anim), tostring(remote.act), tostring(remote.gMoved),
                            tostring(remote.lastMoveAnim), tostring(remote.orientation)))
                    end
                    -- The walker's reflection first, as the peer-graphic path does it with the walker's own frame.
                    local wgi = graphicsInfo(remote.gfx or 0)
                    local wgbX, wgbY = genderFrames.gridBase()
                    if wgbX and wgi then
                        tiering.lastTile = tiering.lastTile or {}
                        local wpal, wkind = genderFrames.reflectPalFor(tiering.lastTile, playerId,
                            remote.areaId,
                            math.floor((screenX - wgbX) / TILE),
                            math.floor((screenY - arc + TILE - wgbY) / TILE),
                            (FRAME_WIDTH_PX + 8) >> 4, (FRAME_HEIGHT_PX + 8) >> 4,
                            wgi.paletteSlot)
                        local wruns = wpal and genderFrames.walkerReflectRuns(
                            remote.gender, pose, frameIndex, wpal)
                        local wtop = screenY + FRAME_HEIGHT_PX - 2 - 2 * arc
                        -- The water clip, only with a reflection: indoors it would be thrown away for every peer.
                        local wwet
                        if wruns then
                            wwet = genderFrames.reflectiveSpans(screenX, wtop,
                                FRAME_WIDTH_PX, FRAME_HEIGHT_PX, "reflection", genderFrames.scWwet())
                        end
                        -- MESHGHOST_EMERALD_REFL_TRACE: what the ground test decided and where, which tells a gate that
                        -- said no from a decode that returned nothing.
                        if MESHGHOST_EMERALD_REFL_TRACE or os.getenv("MESHGHOST_EMERALD_REFL_TRACE") then
                            local wk = string.format("%s:%s:%s:%s:%d,%d", tostring(playerId),
                                tostring(wpal), tostring(wruns ~= nil),
                                tostring(wwet and next(wwet) ~= nil),
                                math.floor((screenX - wgbX) / TILE),
                                math.floor((screenY - arc + TILE - wgbY) / TILE))
                            -- Per peer, on change and every two seconds (the steady state): one shared key would
                            -- fire for every peer every frame.
                            genderFrames.wRefl = genderFrames.wRefl or {}
                            local wr = genderFrames.wRefl[playerId]
                            if not wr then wr = { key = nil, at = 0 }; genderFrames.wRefl[playerId] = wr end
                            if wr.key ~= wk or (frameCounter - wr.at) >= 120 then
                                wr.key = wk
                                wr.at = frameCounter
                                logFile(string.format(
                                    "WALKER REFL %s pal=%s kind=%s runs=%s tile=%d,%d gfx=%s pose=%s/%s"
                                    .. " | painted body=%d refl=%d | hw body=%s refl=%s arc=%d"
                                    .. " | wetRows=%d wetPx=%d | wh=%d,%d | HW %s",
                                    tostring(playerId), tostring(wpal), tostring(wkind),
                                    wruns and #wruns or -1,
                                    math.floor((screenX - wgbX) / TILE),
                                    math.floor((screenY - arc + TILE - wgbY) / TILE),
                                    tostring(remote.gfx),
                                    -- This tier's own frame against the image the peer's animation resolves to:
                                    -- two frames of one cycle put their art on different rows, a reflection row.
                                    tostring(pose) .. "/" .. tostring(frameIndex)
                                        .. " peerAnim=" .. tostring(remote.sanim)
                                        .. "/" .. tostring(remote.sidx)
                                        .. " peerImg=" .. (function()
                                            local gi2 = graphicsInfo(remote.gfx or 0)
                                            if not gi2 or gi2.anims == 0 then return "?" end
                                            local ap = r32(gi2.anims + (remote.sanim or 0) * 4)
                                            if not isRomPtr(ap) then return "?" end
                                            return tostring(r32(ap + (remote.sidx or 0) * 4)
                                                & 0xffff)
                                        end)(), "",
                                    math.floor(screenY), math.floor(wtop),
                                    tostring(tiering.hwBodyY), tostring(tiering.hwReflY), arc,
                                    (function()
                                        if not wwet then return -1 end
                                        local n2 = 0
                                        for _ in pairs(wwet) do n2 = n2 + 1 end
                                        return n2
                                    end)(),
                                    (function()
                                        if not wwet then return -1 end
                                        local px = 0
                                        for _, l in pairs(wwet) do
                                            for _, sp in ipairs(l) do
                                                px = px + sp[2] - sp[1] + 1
                                            end
                                        end
                                        return px
                                    end)(),
                                    (FRAME_WIDTH_PX + 8) >> 4, (FRAME_HEIGHT_PX + 8) >> 4,
                                    tostring(tiering.hwReflDbg))
                                    .. (function()
                                        -- Which rows survive, not how many: a reflection is flipped, so the bottom rows
                                        -- carry the hat.
                                        if not wwet then return " | wetRange=nil" end
                                        local lo, hi = nil, nil
                                        for y2, l in pairs(wwet) do
                                            if #l > 0 then
                                                if not lo or y2 < lo then lo = y2 end
                                                if not hi or y2 > hi then hi = y2 end
                                            end
                                        end
                                        -- And where the frame's own ink is, in the same box.
                                        local ilo, ihi = nil, nil
                                        if wruns then
                                            for _, rr in ipairs(wruns) do
                                                local yy = wtop + (FRAME_HEIGHT_PX - rr.y)
                                                if not ilo or yy < ilo then ilo = yy end
                                                if not ihi or yy > ihi then ihi = yy end
                                            end
                                        end
                                        -- Per grid row of the box: the metatile id, its layerType, and the rows
                                        -- the mask calls open.
                                        local tiles = {}
                                        local gbx2, gby2 = genderFrames.gridBase()
                                        if gbx2 then
                                            local gx2 = math.floor((screenX - gbx2) / TILE)
                                            local gy0 = math.floor((wtop - gby2) / TILE)
                                            local gy1 = math.floor(
                                                (wtop + FRAME_HEIGHT_PX - 1 - gby2) / TILE)
                                            for gy2 = gy0, gy1 do
                                                local id2 = genderFrames.metatileAt(gx2, gy2)
                                                local m2 = id2
                                                    and genderFrames.coverMask(id2, "reflection")
                                                local openRows = 0
                                                if type(m2) == "table" then
                                                    for rr = 0, 15 do
                                                        if (m2[rr] or 0xffff) ~= 0xffff then
                                                            openRows = openRows + 1
                                                        end
                                                    end
                                                end
                                                tiles[#tiles + 1] = string.format(
                                                    "gy%d id=%s lt=%s open=%d/16", gy2,
                                                    tostring(id2),
                                                    tostring(genderFrames.layerTypeOf
                                                        and genderFrames.layerTypeOf(id2)),
                                                    openRows)
                                            end
                                        end
                                        -- Pixels that land, run by run: ink and water can share a row and no column.
                                        local painted = 0
                                        if wruns and wwet then
                                            for _, rr in ipairs(wruns) do
                                                local yy = wtop + (FRAME_HEIGHT_PX - rr.y)
                                                local l = wwet[yy]
                                                if l then
                                                    local ax1 = screenX + rr.x1
                                                    local ax2 = screenX + rr.x2
                                                    if dirInfo.hFlip then
                                                        ax1 = screenX + FRAME_WIDTH_PX - 1 - rr.x2
                                                        ax2 = screenX + FRAME_WIDTH_PX - 1 - rr.x1
                                                    end
                                                    for _, sp in ipairs(l) do
                                                        local lo2 = math.max(ax1, sp[1])
                                                        local hi2 = math.min(ax2, sp[2])
                                                        if hi2 >= lo2 then
                                                            painted = painted + hi2 - lo2 + 1
                                                        end
                                                    end
                                                end
                                            end
                                        end
                                        return string.format(
                                            " | paintedPx=" .. painted ..
                                            " | wetRange=%s..%s inkRange=%s..%s box=%d..%d | %s",
                                            tostring(lo), tostring(hi), tostring(ilo),
                                            tostring(ihi), math.floor(wtop),
                                            math.floor(wtop) + FRAME_HEIGHT_PX - 1,
                                            table.concat(tiles, " ; "))
                                    end)())
                            end
                        end
                        if wruns then
                            drawRunList(wruns, FRAME_WIDTH_PX, dirInfo.hFlip, screenX, wtop,
                                panelRows, dim, FRAME_HEIGHT_PX,
                                genderFrames.reflectionXScale(wkind), wwet)
                        end
                    end

                    -- The walker fallback needs the player sort too: a peer with no gfx on the wire paints here. The
                    -- MG_SPANS delta tells a paint that drew from one that drew nothing.
                    local __sp0 = MG_SPANS or 0
                    drawSpriteFrame(remote.gender, pose, frameIndex, dirInfo.hFlip, screenX,
                        screenY, panelRows, dim,
                        genderFrames.maskBehindPlayer(
                            genderFrames.reflectiveSpans(screenX, screenY,
                                FRAME_WIDTH_PX, FRAME_HEIGHT_PX, "sprite", genderFrames.scWalk()),
                            screenX, screenY, FRAME_WIDTH_PX, FRAME_HEIGHT_PX))
                    if MESHGHOST_EMERALD_SORT_TRACE and frameCounter % 60 == 0 then
                        logFile(string.format("SORTPAINT f=%d walker at=%s,%s spans=%d pose=%s frame=%s dim=%s",
                            frameCounter, tostring(screenX), tostring(screenY),
                            (MG_SPANS or 0) - __sp0, tostring(pose), tostring(frameIndex),
                            tostring(dim)))
                    end
                    MG_BODY_PAINTED = true -- gap detector: the walker-fallback body counts too
                end
                -- Grass over the character, as the engine's grass sprite sits above its object, on both draw paths.
                do
                    -- On the tile grid, not on the ghost: grass belongs to a tile and the character walks through it.
                    local gbX2, gbY2 = genderFrames.gridBase()
                    if gbX2 then
                        local footY = screenY + FRAME_HEIGHT_PX - TILE
                        local onX = math.floor((screenX + (FRAME_WIDTH_PX >> 1) - gbX2) / TILE)
                        local onY = math.floor((footY + (TILE >> 1) - gbY2) / TILE)
                        tiering.grassTiles = tiering.grassTiles or {}
                        local seen = tiering.grassTiles[playerId] or {}
                        -- Every tile the foot box overlaps, one row, all in front: mid-step that is two side by side,
                        -- and grass never rises above the feet.
                        local r0 = math.floor((footY - gbY2) / TILE)
                        local r1 = math.floor((footY + TILE - 1 - gbY2) / TILE)
                        genderFrames.drawGrassRows(playerId, gbX2, gbY2, screenX, footY,
                            r0, r1, panelRows, dim, footY)
                        -- Landing dust, after the grass so it is not buried.
                        do
                            -- A trail, not a follower: each landing's puff stays on its tile, anchored on
                            -- gSpriteCoordOffset like drawGhostShadows' effects, and centred on the graphic's width.
                            local _, landedNow = genderFrames.noteLanding(playerId,
                                isJumpAction(remote.act) or false, remote.act)
                            local offX = rs16(GSPRITECOORDOFFSETX_ADDR + (genderFrames.spriteAddrOffset or 0))
                            local offY = rs16(GSPRITECOORDOFFSETY_ADDR + (genderFrames.spriteAddrOffset or 0))
                            tiering.puffs = tiering.puffs or {}
                            local plist = tiering.puffs[playerId]
                            if not plist then plist = {} tiering.puffs[playerId] = plist end
                            if landedNow then
                                local pgi = remote.gfx and remote.gfx ~= 0
                                    and graphicsInfo(remote.gfx) or nil
                                local halfW = ((pgi and pgi.width) or FRAME_WIDTH_PX) >> 1
                                -- The arc comes off: dust is on the ground, and a pinned copy carries the hop in pos2.
                                local fullH = (pgi and pgi.height) or FRAME_HEIGHT_PX
                                plist[#plist + 1] = { at = frameCounter,
                                    bx = screenX + halfW - 8 - offX,
                                    by = screenY - arc + fullH - 8 - offY }
                            end
                            for pi = #plist, 1, -1 do
                                local puff = plist[pi]
                                local pf = genderFrames.dustFrameAt(frameCounter - puff.at)
                                local druns = pf and genderFrames.dustRuns(pf)
                                if druns then
                                    drawRunList(druns, TILE, false, puff.bx + offX,
                                        puff.by + offY, panelRows, dim)
                                elseif not pf then
                                    table.remove(plist, pi)
                                end
                            end
                        end


                    end
                end
                painted = painted + 1
            end
        end
        -- A peer in another area is not drawn (area_id compares by equality only), which is not despawning it.
    end
    tiering.painted = painted

    -- Flush the comparison samples once a second: the writes cost, not the reads.
    if COMPARE_TIERS then
        tiering.moveLog = tiering.moveLog or {}
        if #tiering.moveLog >= 60 then
            local f = io.open(SCRIPT_DIR .. "probes/tier_compare.log", "a")
            if f then
                local NL = string.char(10)
                f:write(table.concat(tiering.moveLog, NL), NL)
                f:close()
            end
            tiering.moveLog = {}
        end
    end
end

----------------------------------------------------------------------------
-- Main loop. The adapter always drives: once per emulator frame, connect if needed, send local
-- state, drain what the core pushed back, then redraw every known remote.
----------------------------------------------------------------------------

if not memory.usememorydomain("System Bus") then
    console.log("ERROR: 'System Bus' memory domain not found on this core.")
    console.log("Domains available: " .. memory.getmemorydomainlist())
    return
end

console.log("MeshGhost Emerald adapter running.")
console.log("Decoding Brendan/May sprite frames...")
loadGenderFrames()
tryDetectAvatarAddrOffset() -- may miss during the intro; the main loop retries every frame
if BRIDGE_PORT_OVERRIDE then
    console.log(string.format("Bridge target %s:%d (MESHGHOST_BRIDGE_PORT is set, so no port walk).",
        BRIDGE_HOST, BRIDGE_PORT_OVERRIDE))
else
    console.log(string.format("Bridge: walking %s:%d-%d for a core that will have us. Two copies "
        .. "on one machine each find their own.", BRIDGE_HOST, BRIDGE_BASE_PORT,
        BRIDGE_BASE_PORT + BRIDGE_PORT_COUNT - 1))
end

local localGender = nil -- resolved lazily, first frame a save is loaded (see readLocalGender)

-- A savestate load replaces the world under us, and the tell is the emulator's frame count jumping instead of
-- advancing by one. The response is to forget, never to clean up: release the hardware tier without freeing,
-- drop every ghost record and discard the queued tile frees, since all of them name a bitmap the engine no
-- longer has. A global, because the main chunk is at Lua's 200-local ceiling.
function detectStateLoad()
    local fc = emu.framecount()
    local last = genderFrames.lastEmuFrame
    genderFrames.lastEmuFrame = fc
    if last == nil or fc == last + 1 then return end
    -- A small forward jump is a dropped tick; a big one, or any backwards step, is a different world.
    if fc > last and fc <= last + 10 then return end
    logFile(string.format("state load detected: emu frame %d -> %d; dropping every ghost, "
        .. "hardware entry and tile claim rather than freeing them", last, fc))
    pcall(hwReleaseAll, false)
    -- Sweep our whole OAM range blind: the load restores save-time entries our records never claimed, and nothing
    -- of the engine's clears them. Only behind the hardware tier's own gates, since the slot machine and the
    -- confetti effect use the range outside them.
    if tiering.hw.on and avatarAddrOffset == 0 and inOverworld() then
        pcall(function()
            for slot = 0, tiering.hw.slots - 1 do
                local a = tiering.hw.base + slot * 8
                w16(a + 0, tiering.hw.d0)
                w16(a + 2, tiering.hw.d1)
                w16(a + 4, tiering.hw.d2)
            end
        end)
    else
        logFile("state load: OAM range sweep SKIPPED -- the hardware tier is off, the avatar "
            .. "address is unconfirmed, or the game is not in the overworld, so slots 64..119 "
            .. "are not ours to clear (the slot machine and the confetti effect own them)")
    end
    -- The purge deactivates the restored orphans but frees no tiles: that bitmap is the restored session's.
    genderFrames.stateLoadPurge = true
    pcall(despawnAllGhosts)
    genderFrames.stateLoadPurge = nil
    genderFrames.pendingTileFrees = {}
    genderFrames.deferredTileFrees = {}
    tiering.hw.fxTiles, tiering.hw.puffs, tiering.hw.ripples = {}, {}, {}
    tiering.hw.area = nil
    -- And the orphan surf blobs, which have no object event for any sweep to find: a state saved mid-surf restores
    -- that session's ghost blob, still following its object. Kill every blob not following the player. Only in
    -- the overworld on a confirmed build, where "the player's object" means what it says.
    if avatarAddrOffset == 0 and inOverworld() then
    pcall(function()
        local playerObj = r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05)
        local playerSpr = r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04)
        for sid = 0, 63 do
            local d = sprAddr(sid)
            local cb = r32(d + 0x1c)
            -- Blobs only, by their followed object id; the player's own underwater bobber is the engine's.
            local foreign = (cb == surfBlob.updateCb and r16(d + 0x32) ~= playerObj)
            if (r8(d + 0x3e) & 0x01) == 1 and foreign then
                w8(d + 0x3e, (r8(d + 0x3e) & ~0x01) | 0x04)
                w32(d + 0x1c, 0)
                logFile(string.format("state load: killed orphan blob/bobber sprite %d "
                    .. "(followed obj %d)", sid, r16(d + 0x32)))
            end
        end
    end)
    end
    -- No spawned or hardware ghost until the wire has echoed a post-load state; see chooseSpawned.
    genderFrames.loadQuietUntil = frameCounter + 12
end

local function runFrame()
    frameCounter = frameCounter + 1
    detectStateLoad()
    -- Swap-time tile frees, six frames late: three times the two-frame OAM lag (see swapGhostGraphicInPlace).
    do
        local q = genderFrames.deferredTileFrees
        local keep = nil
        for i = 1, #q do
            local e = q[i]
            if frameCounter - e.at >= 6 then
                local stillOurs
                if e.hwArea ~= nil then
                    stillOurs = tiering.hw.area == e.hwArea       -- hardware-tier range
                else
                    stillOurs = ghostAlive(e.g)                   -- spawned-tier range
                end
                -- Never free a range not allocated, or one a live sprite draws: a second free clears bits the engine
                -- has since given away, and several despawn paths can queue the same range.
                local drawn = genderFrames.rangeDrawnByLiveSprite(e.start, e.count, e.g and e.g.sprId)
                if stillOurs and inOverworld() and tileIsAllocated(e.start) and not drawn then
                    for t = e.start, e.start + e.count - 1 do setTileAllocated(t, false) end
                else
                    -- A skipped free is a leak by another name, so say why.
                    local why = (not stillOurs) and "notOurs" or (not inOverworld()) and "notOverworld"
                        or (not tileIsAllocated(e.start)) and "alreadyFree" or "drawnByLive"
                    logFile(string.format("tile free SKIPPED %s: %s start=%d count=%d hwArea=%s area=%s",
                        why, e.hwArea ~= nil and "hw" or "spawned", e.start, e.count,
                        tostring(e.hwArea), tostring(tiering.hw.area)))
                end
                -- Not ours any more (world rebuilt, ghost gone): dropped, never freed.
            else
                keep = keep or {}
                keep[#keep + 1] = e
            end
        end
        genderFrames.deferredTileFrees = keep or {}
    end
    -- Clear only what will be repainted: a map transition returns nil state for a frame or two, and clearing
    -- then blinks every ghost; a title-screen exit still clears. One state read per frame: getLocalState
    -- advances the map-change tracker, so a second call would eat the transition edge.
    local frameState = getLocalState()
    if not (session.live and frameState == nil) then
        gui.clearGraphics()
        tiering.overlayCleared = true   -- for the gap detector at the frame's end
    end
    -- Cross-map upkeep: the gMapGroups self-location (one 128KB chunk a frame until found), the
    -- connection table on map change, and the per-frame re-translation of every peer.
    genderFrames.xmapTick()

    if not avatarAddrConfirmed then
        tryDetectAvatarAddrOffset()
    end

    -- A connection that never answers our hello is more likely another program on our port than a core.
    if connected and not ready and helloSentAtFrame
        and frameCounter - helloSentAtFrame > HELLO_ANSWER_FRAMES then
        markPortBusy(currentPort, "never answered our hello, so it is not a core we can use")
        resetBridge()
    end

    if not connected then
        -- While the relay is down, wait: a core that cannot reach it is still a good core, and walking on would
        -- mark every port busy and spawn fresh cores.
        if frameCounter < relayDown.until_ then
            return
        end
        -- Every 30 frames: each probe is a blocking 50ms connect. On relayDown for the 200-local ceiling.
        if frameCounter < (relayDown.nextConnect or 0) then
            return
        end
        relayDown.nextConnect = frameCounter + 30
        if coreChild and coreSpawnFrame and coreSpawnFrame.port and not coreSpawnFrame.busy
            and coreStillRunning() then
            -- Our own child is alive: wait on its port, or two instances chase each other's spawns.
            tryPort(coreSpawnFrame.port)
        else
            connectBridge()
        end
        -- Spawn only after a full sweep found nothing, so a running core is always used and never doubled.
        if not connected then
            -- On the port the sweep just found empty (firstFreePort).
            startCore(firstFreePort)
        end
        if connected then
            console.log(string.format("MeshGhost: bridge connected on %s:%d.", BRIDGE_HOST, currentPort))
            helloSentAtFrame = frameCounter
            -- The first message on a fresh connection (bridge.Hello), declaring the game for the core.
            -- render_all_areas: this adapter knows which maps are connected and hides what it cannot translate, so
            -- the core delivers everything and keeps no area judgment. min_protocol_version is raised only by hand.
            sendLine(string.format('{"type":"hello","payload":{"game_id":%s,"game_version":%s,"min_protocol_version":2,"render_all_areas":true}}', jsonString(GAME_ID), jsonString(ADAPTER_VERSION)))
            -- A fresh connection is a fresh core: every remote the last one told us about may be stale, its despawn
            -- lost in the outage, and nothing else would clear it.
            remotes = {}
            despawnAllGhosts()
        end
    end

    -- The orphan sweep writes gObjectEvents and gSprites, so only with the avatar address confirmed and in the
    -- overworld; every second, and at once on re-entering it, since a battle can leave an object of ours that
    -- outlived its record.
    local nowOverworld = inOverworld()
    -- A warp passes through frames outside CB2_Overworld and a seam crossing never does: renderHardwareGhosts
    -- reads this later in the same frame.
    if not nowOverworld then tiering.lastNonOverworldAt = frameCounter end
    if avatarAddrConfirmed and nowOverworld and not tiering.wasOverworld
        and #genderFrames.pendingTileFrees > 0 then
        -- Back in the overworld: free what a battle stopped us freeing if the range is still ours, else forget it.
        for i = 1, #genderFrames.pendingTileFrees do
            local p = genderFrames.pendingTileFrees[i]
            -- The slot's marker is not identity for the range: a warp rebuilds everything, so no live sprite may
            -- draw it either.
            if p.tileStart and r8(objAddr(p.objId) + 0x08) == GHOST_LOCAL_ID
                and not genderFrames.rangeDrawnByLiveSprite(p.tileStart, p.tileCount, nil) then
                for t = p.tileStart, p.tileStart + p.tileCount - 1 do setTileAllocated(t, false) end
            end
            genderFrames.pendingTileFrees[i] = nil
        end
    end
    if avatarAddrConfirmed and nowOverworld
        and (frameCounter % 60 == 0 or not tiering.wasOverworld) then
        sweepOrphanGhosts()
    end
    tiering.wasOverworld = nowOverworld

    -- Every 5s, to the log file only: which link in the chain is quiet (connected against ready, a peer known
    -- against a ghost drawn).
    if frameCounter % 300 == 0 then
        local nRemotes, nGhosts, nDrawn = 0, 0, 0
        for _ in pairs(remotes) do nRemotes = nRemotes + 1 end
        for _ in pairs(ghosts) do nGhosts = nGhosts + 1 end
        -- The painted count, whenever anything paints: the tier itself, or compare mode's loopback ghost.
        if tiering.drawn or COMPARE_TIERS then nDrawn = tiering.painted or 0 end
        local nClipped = genderFrames.clippedRuns or 0
        genderFrames.clippedRuns = 0
        logFile(string.format(
            -- budget is the object slots this map has left: without it, ghosts=0 can mean none wanted or none free.
            "status: frame=%d connected=%s ready=%s port=%s remotes=%d ghosts=%d budget=%s hw=%d drawn=%d "
                .. "clipped=%d overworld=%s inGame=%s slide=%d/%d paused=%d",
            frameCounter, tostring(connected), tostring(ready), tostring(currentPort),
            nRemotes, nGhosts,
            tostring((function()
                local ok, b = pcall(tiering.budget, genderFrames.xmapLocalKey())
                return ok and b or "?"
            end)()),
            tiering.hw.placed or 0,
            nDrawn, nClipped, tostring(inOverworld()), tostring(session.live),
            (tiering.slide or {}).legs or 0, (tiering.slide or {}).step or 0,
            (tiering.slide or {}).paused or 0))
        tiering.slide = { step = 0, legs = 0, paused = 0 }
        -- Peers known and none rendered on any tier: both area ids tell a peer elsewhere from one declined here.
        if nRemotes > 0 and nGhosts == 0 and nDrawn == 0 then
            -- A fresh read: the smoothed area id is not in scope here.
            local b = session.saveBlockPtr(GSAVEBLOCK1PTR_ADDR)
            local localArea = b ~= 0
                and (memory.read_s8(b + 0x04) .. ":" .. memory.read_s8(b + 0x05)) or "nil"
            for playerId, r in pairs(remotes) do
                logFile(string.format("  unrendered %s: area=%s local=%s at=(%s,%s)",
                    tostring(playerId), tostring(r.areaId), localArea,
                    tostring(r.x), tostring(r.y)))
            end
        end
        -- Collision follows the object's coordinates, drawing the sprite's position: both, beside the player's pair.
        local sb1 = session.saveBlockPtr(GSAVEBLOCK1PTR_ADDR)
        if sb1 ~= 0 then
            local pObjId = r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05)
            local pa, ps = objAddr(pObjId), sprAddr(r8(objAddr(pObjId) + 0x04))
            logFile(string.format(
                "  player: pos=(%d,%d) coords=(%d,%d) sprite=(%d,%d) camOff=(%d,%d)",
                rs16(sb1 + 0x00), rs16(sb1 + 0x02), rs16(pa + 0x10), rs16(pa + 0x12),
                rs16(ps + 0x20), rs16(ps + 0x22),
                rs16(GTOTALCAMERAPIXELOFFSETX_ADDR + (genderFrames.camOffset or 0)), rs16(GTOTALCAMERAPIXELOFFSETY_ADDR + (genderFrames.camOffset or 0))))
            for playerId, g in pairs(ghosts) do
                local ga, gs = objAddr(g.objId), sprAddr(g.sprId)
                logFile(string.format(
                    "  ghost %s: obj=%d spr=%d coords=(%d,%d) sprite=(%d,%d) held=%d/%d anim=%d "
                        .. "action=%d peerAnim=%s",
                    tostring(playerId), g.objId, g.sprId, rs16(ga + 0x10), rs16(ga + 0x12),
                    rs16(gs + 0x20), rs16(gs + 0x22),
                    (r8(ga + 0x00) >> 6) & 1, (r8(ga + 0x00) >> 7) & 1, r8(gs + 0x2a),
                    r8(ga + 0x1c), tostring(remotes[playerId] and remotes[playerId].anim)))
                logFile(string.format("         gfx: ghost drawn as %s, peer reports %s",
                    tostring(g.gfx), tostring(remotes[playerId] and remotes[playerId].gfx)))
                -- Ghost against player, field by field: the player's sprite is the control that renders.
                local ps = sprAddr(r8(pa + 0x04))
                local function spr(tag, a)
                    logFile(string.format(
                        "         %s oam=%04X %04X %04X %04X flags=%02X %02X sub=%02X c2c=%d,%d "
                            .. "anim=%d/%d img=%08X anims=%08X",
                        tag, r16(a + 0x00), r16(a + 0x02), r16(a + 0x04), r16(a + 0x06),
                        r8(a + 0x3e), r8(a + 0x3f), r8(a + 0x42), r8(a + 0x28), r8(a + 0x29),
                        r8(a + 0x2a), r8(a + 0x2b), r32(a + 0x0c), r32(a + 0x08)))
                end
                spr("ghost ", gs)
                spr("player", ps)
                if g.blobSprId then spr("blob  ", sprAddr(g.blobSprId)) end
            end
        end
    end

    if connected then
        local state = frameState
        -- The session ended (title screen, soft reset): drop the bridge, since going quiet is not enough (see
        -- session). Cleared first, so the drop runs once per edge even if resetBridge throws.
        if session.ended then
            session.ended = false
            console.log("MeshGhost: left the game (title screen) -- dropping the bridge so peers "
                .. "stop seeing this ghost.")
            -- The next session may be another save with the other gender; readLocalGender runs only while nil.
            localGender = nil
            resetBridge()
        end
        local smoothX, smoothY, smoothAreaId
        if state then
            -- Only in the overworld: a non-null save block alone does not mean a gender has been chosen.
            if not localGender and inOverworld() then
                localGender = readLocalGender()
                if localGender then
                    console.log("MeshGhost: local gender = " .. localGender)
                end
            end
            -- The engine's own step speed, sprite data[4], mapped to frames per tile: the one source covering every
            -- gait, since anim names two and bikeSpeed reads standing on the Acro Bike.
            local mspd = rs16(sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04)) + 0x36)
            if mspd < 0 or mspd > 4 then mspd = nil end
            local stepFrames = mspd and ({ [0] = 16, [1] = 8, [2] = 6, [3] = 4, [4] = 2 })[mspd]
            genderFrames.sendMspd = mspd
            smoothX, smoothY = smoothPosition(state.x, state.y, state.areaId, state.anim, stepFrames)
            smoothAreaId = state.areaId
            if DIAG_STEP_CURVE and inRealGlide and diag.stepCurveLogs < DIAG_STEP_CURVE_MAX_LOGS then
                local realX, realY = playerScreenPos()
                local deltaX = diag.prevRealX and (realX - diag.prevRealX) or 0
                local deltaY = diag.prevRealY and (realY - diag.prevRealY) or 0
                diag.prevRealX, diag.prevRealY = realX, realY
                diag.stepCurveLogs = diag.stepCurveLogs + 1
                console.log(string.format(
                    "MeshGhost DIAG CURVE: frame=%d smoothX=%.4f smoothY=%.4f realScreenX=%d realScreenY=%d realDX=%d realDY=%d",
                    frameCounter, smoothX, smoothY, realX, realY, deltaX, deltaY))
            end
            -- Not until bridge_ready: a connected socket is not yet a core that accepted us.
            if ready then
                if MESHGHOST_EMERALD_PROFILE then tiering.profT = os.clock() end
                -- On the table rather than in locals: this chunk is at Lua's 200-local ceiling.
                genderFrames.sendGfx = localGraphicsId()
                flyRide.sample(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05),
                    r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04))
                -- The door the engine has open now, if any.
                genderFrames.dk, genderFrames.dx, genderFrames.dy = genderFrames.door.sample()
                genderFrames.sendAnim, genderFrames.sendIdx = genderFrames.coherentAnim(
                    genderFrames.sendGfx,
                    r8(sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04)) + 0x2a),
                    r8(sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04)) + 0x2b))
                sendLine(encodeLocalState(state.areaId, smoothX, smoothY, state.orientation,
                    state.anim, localGender or "male", genderFrames.sendGfx,
                    genderFrames.sendAnim, genderFrames.sendIdx,
                    -- movementActionId: what the engine is making this character do; no position recovers a ledge hop.
                    r8(GOBJECTEVENTS_ADDR + avatarAddrOffset
                        + r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05) * OBJECTEVENT_SIZE
                        + 0x1c),
                    -- pos2, the offset the game's tasks move a character by (a ghost has no task): localGraphicsId's
                    -- pair, so a held-back graphic keeps its own offset.
                    genderFrames.sendSox or 0, genderFrames.sendSoy or 0,
                    -- animPaused: an idle character's sprite is paused, so a ghost holds a frame.
                    ((r8(sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04)) + 0x2c) & 0x40)
                        ~= 0) and 1 or 0,
                    -- gPlayerAvatar.bikeSpeed: a stable field, where movementActionId is transient at the send rate.
                    r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x0b),
                    -- disableAnim: this character may not animate, which outranks a movement (see encodeLocalState).
                    ((r8(GOBJECTEVENTS_ADDR + avatarAddrOffset
                        + r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05) * OBJECTEVENT_SIZE
                        + 0x01) & 0x04) ~= 0) and 1 or 0,
                    -- The engine stopped drawing this character: invisible, a vehicle on its tile, a Fly's halves.
                    flyRide.invis, flyRide.boat, flyRide.fly, flyRide.flyk,
                    -- The door, absent from the packet when there is none (encodeLocalState says why).
                    genderFrames.dk, genderFrames.dx, genderFrames.dy, genderFrames.sendMspd))
                if tiering.profT then
                    local pr = tiering.prof or {}
                    pr.send = (pr.send or 0) + (os.clock() - tiering.profT)
                    tiering.prof = pr
                end
            end
        elseif ready then
            sendLine(ENCODED_NO_SEND)
        end

        if connected then
            if MESHGHOST_EMERALD_PROFILE then tiering.profT = os.clock() end
            drainBridge()
            if MESHGHOST_EMERALD_PROFILE then
                local pr = tiering.prof or {}
                pr.drain = (pr.drain or 0) + (os.clock() - tiering.profT)
                tiering.prof = pr
            end
        end

        -- The smoothed self-position just sent anchors the remotes; the rare nil-state frame skips drawing rather
        -- than read a raw position that disagrees with it.
        if connected and inOverworld() and smoothX then
            -- One render path on both builds: spawnGhost refuses to write unless the player's own object/sprite
            -- cross-link resolves through gSprites, so a build that moved it gets a logged refusal.
            -- The door first: it is background scenery and belongs to no tier, so a peer no tier could take keeps it.
            genderFrames.doorTick(smoothAreaId)
            -- TIER ONE: real object events, as many as the map can spare (nearest peers win).
            if MESHGHOST_EMERALD_PROFILE then tiering.profT = os.clock() end
            local spawnSet = tiering.chooseSpawned(smoothAreaId, smoothX, smoothY)
            syncRemoteGhosts(smoothAreaId, spawnSet)
            if MESHGHOST_EMERALD_PROFILE then
                local pr = tiering.prof or {}
                pr.sync = (pr.sync or 0) + (os.clock() - tiering.profT)
                tiering.profT = os.clock()
            end
            -- Spawned ghosts need this whether or not the painted tier is on, so it lives outside drawRemotes.
            drawGhostShadows()
            if MESHGHOST_EMERALD_PROFILE and tiering.prof then
                tiering.prof.shadows = (tiering.prof.shadows or 0) + (os.clock() - tiering.profT)
                tiering.profT = os.clock()
            end
            -- TIER TWO: hardware sprites the PPU draws, for peers the engine had no room for: cheaper than painting,
            -- with real background priority and a live palette. Flag-gated.
            local hwSet = tiering.chooseHardware(smoothAreaId, smoothX, smoothY, spawnSet)
            renderHardwareGhosts(smoothAreaId, smoothX, smoothY, hwSet)
            -- The painted tier skips both tiers' peers; a fresh set, since mutating spawnSet would corrupt the
            -- next frame's tiering.
            local drawnSkip = spawnSet
            if next(hwSet) then
                drawnSkip = {}
                for id in pairs(spawnSet) do drawnSkip[id] = true end
                for id in pairs(hwSet) do drawnSkip[id] = true end
            end
            -- TIER THREE: everyone else, painted over the finished frame so no peer is absent. Flag-gated; it clips
            -- against tiering.scanPanel's rows rather than paint over a text box.
            if tiering.drawn then
                drawRemotes(smoothAreaId, smoothX, smoothY, drawnSkip)
            elseif COMPARE_TIERS then
                -- Compare mode with the overflow tier off: the loopback ghost, and only it.
                drawRemotes(smoothAreaId, smoothX, smoothY, drawnSkip, true)
            end
            if MESHGHOST_EMERALD_PROFILE and tiering.prof then
                tiering.prof.draw = (tiering.prof.draw or 0) + (os.clock() - tiering.profT)
            end
        end
    end
end

-- lastLogged starts nil, not 0: 0 would swallow every error in the first 300 frames, where connecting and
-- detection happen. consecutive tells a blip from a subsystem that has been failing for thousands of frames.
-- One table rather than two locals: the main chunk is at Lua's 200-local ceiling.
local frameErrors = { lastLogged = nil, consecutive = 0 }

-- The seam trace: a window around every crossing, one line per frame with, for each peer, the connection
-- table, the wire, the translation, the glide and the painted position, the five things that must agree.
-- conns comes first: xmapBuild stamps connsFor before reading, so a mid-load read can latch an empty table.
-- Defined here because every local it reads is declared after the xmap block; on tiering for the 200-local
-- ceiling.
tiering.seamTraceTick = function()
    local xm = genderFrames.xmap
    local key = genderFrames.xmapLocalKey()
    local sb1 = session.saveBlockPtr(GSAVEBLOCK1PTR_ADDR)
    if sb1 == 0 then return end
    local nconn = 0
    for _ in pairs(xm.conns or {}) do nconn = nconn + 1 end
    -- Either end of a crossing opens the window: our map key changing, or a peer's wire area. Not named
    -- `event`, which is BizHawk's API table.
    local seamEvent = nil
    if tiering.seamLastKey and key and tiering.seamLastKey ~= key then
        seamEvent = "LOCAL " .. tostring(tiering.seamLastKey) .. "->" .. tostring(key)
    end
    if key then tiering.seamLastKey = key end
    tiering.seamLastSrc = tiering.seamLastSrc or {}
    local parts = {}
    for id, r in pairs(remotes) do
        local prev = tiering.seamLastSrc[id]
        if prev and r.srcAreaId and prev ~= r.srcAreaId then
            seamEvent = (seamEvent and (seamEvent .. " + ") or "")
                .. "PEER " .. id .. " " .. tostring(prev) .. "->" .. tostring(r.srcAreaId)
        end
        tiering.seamLastSrc[id] = r.srcAreaId
        -- What was painted this frame, or NOT-PAINTED: culled, off screen or never reached is a finding.
        local scr = (r.dbgScreenAt == frameCounter)
            and string.format("%.1f,%.1f", r.dbgScreenX or 0, r.dbgScreenY or 0) or "NOT-PAINTED"
        parts[#parts + 1] = string.format(
            "%s src=%s s=%s,%s xy=%s,%s g=%s,%s scr=%s step=%s dist=%s anim=%s",
            id, tostring(r.srcAreaId), tostring(r.sx), tostring(r.sy),
            tostring(r.x), tostring(r.y), tostring(r.gX), tostring(r.gY),
            scr, tostring(r.gStepping), tostring(r.gDist), tostring(r.anim))
    end
    -- The port first: both emulators in a two-instance rig share this script's folder, and so this log.
    local line = string.format(
        "p%s f=%d key=%s tile=%d,%d sent=%s@%s,%s camPix=%d,%d conns=%d@%s our=%s,%s "
            .. "anchor=%s,%s origin=%s,%s anchorArea=%s | %s%s",
        tostring(currentPort), frameCounter, tostring(key),
        rs16(sb1 + 0x00), rs16(sb1 + 0x02),
        tostring(genderFrames.sentArea), tostring(genderFrames.sentX),
        tostring(genderFrames.sentY),
        rs16(GTOTALCAMERAPIXELOFFSETX_ADDR + (genderFrames.camOffset or 0)),
        rs16(GTOTALCAMERAPIXELOFFSETY_ADDR + (genderFrames.camOffset or 0)),
        nconn, tostring(xm.connsFor), tostring(xm.ourW), tostring(xm.ourH),
        tostring(tiering.anchorX), tostring(tiering.anchorY),
        tostring(tiering.originX), tostring(tiering.originY),
        tostring(tiering.anchorArea),
        (#parts > 0) and table.concat(parts, " || ") or "no-peers",
        seamEvent and ("   <<< " .. seamEvent) or "")
    tiering.seamRing = tiering.seamRing or {}
    local ring = tiering.seamRing
    ring[#ring + 1] = line
    -- 60 frames of lead-in kept at all times, 150 of tail once a crossing opens the window.
    if seamEvent and not tiering.seamDumpUntil then tiering.seamDumpUntil = frameCounter + 150 end
    if not tiering.seamDumpUntil then
        while #ring > 60 do table.remove(ring, 1) end
    elseif frameCounter >= tiering.seamDumpUntil then
        local tf = io.open(SCRIPT_DIR .. "probes/seamtrace.log", "a")
        if tf then
            tf:write(table.concat(ring, string.char(10)) .. string.char(10))
            tf:close()
        end
        tiering.seamRing, tiering.seamDumpUntil = {}, nil
    end
end

local function guardedFrame()
    -- MESHGHOST_EMERALD_PROFILE (dev): the Lua side of the frame, averaged every 300 frames. A small number while
    -- the fps is low puts the cost in the emulator core or another script.
    local t0
    if MESHGHOST_EMERALD_PROFILE then t0 = os.clock() end
    flushLogPeriodically()
    -- pcall-wrapped so one malformed remote or odd memory read skips a frame instead of stopping the adapter.
    local ok, err = pcall(runFrame)
    -- The gap itself, every frame it lasts: cleared, a live compare ghost, and no body painted.
    if COMPARE_TIERS and tiering.overlayCleared then
        local ghostRemote = nil
        for id, rr in pairs(remotes) do
            if id:match("%-ghost$") then ghostRemote = rr break end
        end
        -- The body specifically: a frame where only the reflection painted is still a gap.
        if ghostRemote and not MG_BODY_PAINTED then
            local g2 = nil
            for id in pairs(remotes) do
                if id:match("%-ghost$") then g2 = ghosts[id] break end
            end
            logFile(string.format(
                "DRAWN GAP f=%d gfx=%s sanim=%s/%s act=%s spawnedAlive=%s hwPlaced=%s",
                frameCounter, tostring(ghostRemote.gfx), tostring(ghostRemote.sanim),
                tostring(ghostRemote.sidx), tostring(ghostRemote.act),
                tostring(g2 and ghostAlive(g2) or false), tostring(tiering.hw.placed)))
        end
    end
    -- After runFrame, so the line has this frame's painted position; the global is read live so the dev loader
    -- can arm it, and pcall'd so an instrument can never take the adapter down.
    if tiering.seamTrace or MESHGHOST_EMERALD_SEAM_TRACE then pcall(tiering.seamTraceTick) end
    MG_DRAWN_CALLS, MG_BODY_PAINTED, tiering.overlayCleared = 0, nil, nil
    if t0 then
        local dt = os.clock() - t0
        frameErrors.profSum = (frameErrors.profSum or 0) + dt
        frameErrors.profN = (frameErrors.profN or 0) + 1
        if dt > (frameErrors.profMax or 0) then frameErrors.profMax = dt end
        if frameErrors.profN >= 300 then
            -- Per section, accumulated inside runFrame; to the log file too, since only a person at the emulator
            -- reads the console.
            local p = tiering.prof or {}
            local profLine = string.format(
                "MeshGhost PROFILE: lua avg %.3f ms, worst %.1f ms | send %.3f drain %.3f sync %.3f shadows %.3f draw %.3f (ms avg)",
                frameErrors.profSum / frameErrors.profN * 1000, (frameErrors.profMax or 0) * 1000,
                (p.send or 0) / frameErrors.profN * 1000, (p.drain or 0) / frameErrors.profN * 1000,
                (p.sync or 0) / frameErrors.profN * 1000, (p.shadows or 0) / frameErrors.profN * 1000,
                (p.draw or 0) / frameErrors.profN * 1000)
                .. string.format(" | passes/frame %.1f runs/frame %.0f loop %.2f ms "
                    .. "(setup %.2f ms) spans/frame %.0f",
                    (MG_DRAWN_PASSES or 0) / frameErrors.profN,
                    (MG_DRAWN_RUNS or 0) / frameErrors.profN,
                    (MG_DRAWN_LOOP or 0) / frameErrors.profN * 1000,
                    ((p.draw or 0) - (MG_DRAWN_LOOP or 0)) / frameErrors.profN * 1000,
                    ((MG_SPANS or 0) - (MG_SPANS_AT or 0)) / frameErrors.profN)
                .. string.format(" | occl %.2f ms/%.0f",
                    (MG_RSPANS_T or 0) / frameErrors.profN * 1000,
                    (MG_RSPANS_N or 0) / frameErrors.profN)
                .. (function()
                    local out = {}
                    for k, v in pairs(MG_RSPANS_BY or {}) do
                        out[#out + 1] = string.format("%s=%.1f", k, v / frameErrors.profN)
                    end
                    table.sort(out)
                    return " occlBy[" .. table.concat(out, " ") .. "]"
                end)()
                .. string.format(" panel %.2f ms runsFor %.2f ms/%.0f",
                    (MG_PANEL_T or 0) / frameErrors.profN * 1000,
                    (MG_RF_T or 0) / frameErrors.profN * 1000,
                    (MG_RF_N or 0) / frameErrors.profN)
            console.log(profLine)
            logFile(profLine)
            frameErrors.profSum, frameErrors.profN, frameErrors.profMax = 0, 0, 0
            -- MG_SPANS is marked, not zeroed: the paint site diffs it around a paint, and a reset reads as nothing.
            MG_DRAWN_PASSES, MG_DRAWN_RUNS, MG_DRAWN_LOOP = 0, 0, 0
            MG_RSPANS_T, MG_RSPANS_N, MG_PANEL_T = 0, 0, 0
            MG_RF_T, MG_RF_N = 0, 0
            MG_RSPANS_BY = {}
            MG_SPANS_AT = MG_SPANS or 0
            tiering.prof = {}
        end
    end
    if ok then
        frameErrors.consecutive = 0
        return
    end
    frameErrors.consecutive = frameErrors.consecutive + 1
    -- Rate-limited after the first, which always logs.
    if not frameErrors.lastLogged or frameCounter - frameErrors.lastLogged > 300 then
        console.log(string.format("MeshGhost: frame error (continuing, %d in a row): %s",
            frameErrors.consecutive, tostring(err)))
        -- To the file too: the console is invisible to log greps.
        logFile(string.format("FRAME ERROR (%d in a row): %s",
            frameErrors.consecutive, tostring(err)))
        frameErrors.lastLogged = frameCounter
    end
end

-- The fishing alignment runs from an execute hook at BuildOamBuffer, where animations are final and OAM is not
-- yet built: the point the game's own alignment runs at. From between frames it is a frame out of phase with
-- the image, an 8px flick. Vanilla only, since an Archipelago ROM moves code; unregistered first, because
-- under the dev loader the previous load's hook survives.
if MESHGHOST_FISH_ALIGN_HOOK then
    pcall(event.unregisterbyid, MESHGHOST_FISH_ALIGN_HOOK)
    MESHGHOST_FISH_ALIGN_HOOK = nil
end
tiering.fishAlignActive = false
-- MESHGHOST_EMERALD_NO_FISH_HOOK (dev): skip the hook, to price it; an execute breakpoint can slow the emulator
-- core where no Lua timer sees.
if avatarAddrOffset == 0 and not MESHGHOST_EMERALD_NO_FISH_HOOK then
    -- On tiering, not locals: the main chunk is at Lua's 200-local ceiling.
    tiering.hookOk, tiering.hookId = pcall(event.onmemoryexecute, function()
        local aok = pcall(function()
            for _, g in pairs(ghosts) do
                if g.gfx and isFishingGfx(g.gfx) then alignFishingGhost(g) end
            end
        end)
        if not aok then tiering.fishAlignActive = false end
        -- The player's animation, sampled in phase with the picture for the draw-order mask; the stamp says fresh.
        pcall(function()
            local pd = sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04))
            genderFrames.pmSnapNum, genderFrames.pmSnapIdx, genderFrames.pmSnapAt =
                r8(pd + 0x2a), r8(pd + 0x2b), frameCounter
        end)
    end, 0x08006A0C, "meshghost_fish_align")
    if tiering.hookOk and tiering.hookId then
        MESHGHOST_FISH_ALIGN_HOOK = tiering.hookId
        tiering.fishAlignActive = true
    else
        console.log("MeshGhost: BuildOamBuffer hook unavailable ("
            .. tostring(tiering.hookId) .. "); fishing alignment stays at the frame boundary.")
    end
end

-- Under dev-scripts/bizhawk-dev-loader.lua (never shipped) the loader takes the per-frame function instead of
-- this file taking the frame loop, so the adapter reloads live; a player sets neither global.
MESHGHOST_DEV_TICK = guardedFrame
MESHGHOST_DEV_UNLOAD = function()
    -- Releases the bridge socket (a core serves one adapter), the ghosts (game objects nothing else clears) and
    -- the log file. The hardware area is remembered first: hwReleaseAll clears it, and every range it queued
    -- would then read as not ours.
    local hwAreaAtUnload = tiering.hw.area
    pcall(resetBridge)
    pcall(hwReleaseAll, true)
    -- Flush the deferred frees now, as their service point dies with this script: ownership still checked.
    pcall(function()
        for _, e in ipairs(genderFrames.deferredTileFrees or {}) do
            local stillOurs
            if e.hwArea ~= nil then stillOurs = (e.hwArea == hwAreaAtUnload) or (tiering.hw.area == e.hwArea)
            else stillOurs = ghostAlive(e.g) end
            if stillOurs and inOverworld() and tileIsAllocated(e.start)
                    and not genderFrames.rangeDrawnByLiveSprite(e.start, e.count, e.g and e.g.sprId) then
                for t = e.start, e.start + e.count - 1 do setTileAllocated(t, false) end
            end
        end
        genderFrames.deferredTileFrees = {}
    end)
    if MESHGHOST_FISH_ALIGN_HOOK then
        pcall(event.unregisterbyid, MESHGHOST_FISH_ALIGN_HOOK)
        MESHGHOST_FISH_ALIGN_HOOK = nil
    end
    -- Restore console.log, which this script wraps, or each reload wraps the previous wrapper.
    if rawConsoleLog then console.log = rawConsoleLog end
    if logfile then
        logfile:close()
        logfile = nil
    end
end

if not MESHGHOST_DEV_LOADER then
    while true do
        guardedFrame()
        emu.frameadvance()
    end
end
