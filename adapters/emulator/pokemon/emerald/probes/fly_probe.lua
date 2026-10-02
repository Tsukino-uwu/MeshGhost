-- What a fly does, frame by frame, on the flyer and on a watcher at once (dev tool, never shipped). It reads the
-- game, never the adapter, and each line has the active tasks, the player, any bird, and each ghost's same fields:
-- a ghost that does not follow is either not told to fly or told and not moving, and only the pair tells which.
-- Driven, it loads savestate MESHGHOST_FLY_SLOT (default 5: a same-town fly; 6: a different town), taps A and logs
-- LOG_FRAMES; it must be the only input-driving script loaded.

local SLOT = tonumber(MESHGHOST_FLY_SLOT or os.getenv("MESHGHOST_FLY_SLOT") or "") or 5
local SETTLE_FRAMES = 60      -- let the adapter settle before yanking the state
local TAP_FRAMES = 120        -- press A, leniently, for two seconds
local LOG_FRAMES = 600        -- ten seconds: the whole departure and then some

local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
local GTASKS_ADDR = 0x03005e00
local TASK_SIZE = 0x28
local GHOST_LOCAL_ID = 255
-- gSaveBlock1Ptr, for the local map: two instances exchange ghosts only while their area ids match.
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local function localArea()
    local b = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
    if b == 0 then return "?:?" end
    return string.format("%d:%d", memory.read_s8(b + 0x04), memory.read_s8(b + 0x05))
end

-- Beside this script, never an absolute path: the repo is public.
local BS = string.char(92)
local DIR = debug.getinfo(1, "S").source:sub(2)
    :match("^(.*)[/" .. BS .. "][^/" .. BS .. "]*$") or "."
-- One file per role: a driven run and an observed run are the two halves of one measurement.
local out = io.open(DIR .. (MESHGHOST_FLY_OBSERVE and "/fly_probe_watch.log"
    or "/fly_probe.log"), "w")
-- Buffered and flushed in batches: a per-line flush costs frames on the emulator's own thread.
if out then out:setvbuf("full", 1 << 16) end
local nLines = 0
local function log(s)
    if not out then return end
    out:write(s, "\n")
    nLines = nLines + 1
    if nLines % 120 == 0 then out:flush() end
end

local function r8(a) return memory.read_u8(a) end
local function r16(a) return memory.read_u16_le(a) end
local function rs16(a) return memory.read_s16_le(a) end
local function r32(a) return memory.read_u32_le(a) end
local function objAddr(i) return GOBJECTEVENTS_ADDR + i * OBJECTEVENT_SIZE end
local function sprAddr(i) return GSPRITES_ADDR + i * SPRITE_SIZE end

-- One character's state in one field; the sprite's screen position moves during a fly while the map coords stand.
local function describe(tag, objId)
    if objId == nil or objId >= 16 then return tag .. "=none" end
    local a = objAddr(objId)
    if (r8(a + 0x00) & 0x01) == 0 then return tag .. "=inactive" end
    local sprId = r8(a + 0x04)
    local d = sprAddr(sprId)
    return string.format(
        "%s obj=%d spr=%d gfx=%d inv=%d inanim=%d shadow=%d act=%02X coords=(%d,%d) "
            .. "spr=(%d,%d) pos2=(%d,%d) coordOff=%d sprInv=%d anim=%d/%d",
        tag, objId, sprId, r8(a + 0x05),
        (r8(a + 0x01) >> 5) & 1,        -- invisible
        (r8(a + 0x01) >> 4) & 1,        -- inanimate
        (r8(a + 0x02) >> 6) & 1,        -- hasShadow
        r8(a + 0x1c),                   -- movementActionId
        rs16(a + 0x10), rs16(a + 0x12),
        rs16(d + 0x20), rs16(d + 0x22),
        rs16(d + 0x24), rs16(d + 0x26),
        (r8(d + 0x3e) >> 1) & 1,        -- coordOffsetEnabled
        (r8(d + 0x3e) >> 2) & 1,        -- invisible
        r8(d + 0x2a), r8(d + 0x2b))
        -- The tiles and shape it is drawn from: a broken sprite can have every struct field right.
        .. string.format(" | oam=%04X %04X %04X tile=%d pal=%d shape=%d size=%d sub=%02X",
            r16(d + 0x00), r16(d + 0x02), r16(d + 0x04),
            r16(d + 0x04) & 0x3ff, (r16(d + 0x04) >> 12) & 0x0f,
            (r16(d + 0x00) >> 14) & 0x03, (r16(d + 0x02) >> 14) & 0x03, r8(d + 0x42))
end

-- Every active task with its function pointer: a fly running under an address we do not know is a different bug.
local function tasks()
    local parts = {}
    for t = 0, 15 do
        local ta = GTASKS_ADDR + t * TASK_SIZE
        if r8(ta + 0x04) == 1 then
            parts[#parts + 1] = string.format("t%d:%08X st=%d d1=%d d2=%d",
                t, r32(ta + 0x00), r16(ta + 0x08), r16(ta + 0x0a), r16(ta + 0x0c))
        end
    end
    return table.concat(parts, " ; ")
end

-- Any non-object sprite running a callback (the bird is one), by callback, so a wrong constant shows as an address.
local function loose(skip)
    local parts = {}
    for s = 0, 63 do
        local d = sprAddr(s)
        if (r8(d + 0x3e) & 0x01) ~= 0 and not skip[s] then
            local cb = r32(d + 0x1c)
            -- data[2] is the fly arc parameter, data[6] the passenger, data[7] the done flag.
            parts[#parts + 1] = string.format("s%d:cb=%08X xy=(%d,%d) d2=%d d6=%d d7=%d",
                s, cb, rs16(d + 0x20), rs16(d + 0x22),
                r16(d + 0x32), r16(d + 0x3a), r16(d + 0x3c))
        end
    end
    if #parts == 0 then return "none" end
    return table.concat(parts, " ; ")
end

-- A ghost wears LOCALID_PLAYER like the player, so the player's own object id from gPlayerAvatar tells them apart.
local function ghostObjIds(playerObjId)
    local ids = {}
    for i = 0, 15 do
        local a = objAddr(i)
        if i ~= playerObjId and (r8(a + 0x00) & 0x01) ~= 0
            and r8(a + 0x08) == GHOST_LOCAL_ID then
            ids[#ids + 1] = i
        end
    end
    return ids
end

-- Observer mode, for the instance watching a flying peer: log only, never a state load or the controller (two
-- scripts pressing A at each other prove nothing). Set MESHGHOST_FLY_OBSERVE there and drive the other instance.
local OBSERVE = MESHGHOST_FLY_OBSERVE or os.getenv("MESHGHOST_FLY_OBSERVE")

local phase, n, logged = OBSERVE and "log" or "settle", 0, 0

-- Screenshots every fourth frame while any sprite runs the fly-swoop callback and for six seconds after: struct
-- fields can agree while the screen is wrong. They see real sprites, never the painted overlay, and a backgrounded
-- window captures the same.
local shotUntil, shots = nil, 0
local SHOT_CAP = 150
local function birdOnScreen()
    for si = 0, 63 do
        local d = sprAddr(si)
        if (r8(d + 0x3e) & 0x01) ~= 0 and r32(d + 0x1c) == 0x080B963D then return true end
    end
    return false
end
local function maybeShoot()
    if birdOnScreen() then shotUntil = n + 360 end
    if shotUntil and n <= shotUntil and shots < SHOT_CAP and n % 4 == 0 then
        shots = shots + 1
        pcall(function()
            client.screenshot(string.format("%s/flyshot_%s_%06d.png",
                DIR, OBSERVE and "w" or "d", emu.framecount()))
        end)
    end
end

local function tick()
    n = n + 1
    if OBSERVE then
        -- Never stops or touches the controller: the other instance's fly cannot be predicted. It may be placed
        -- once (after a relaunch it sits on a title screen): MESHGHOST_FLY_OBSERVE_LOAD_SLOT loads one state, once,
        -- and never again on a script reload.
        local slot = tonumber(MESHGHOST_FLY_OBSERVE_LOAD_SLOT
            or os.getenv("MESHGHOST_FLY_OBSERVE_LOAD_SLOT") or "")
        if slot and n == SETTLE_FRAMES then
            pcall(function() savestate.loadslot(slot) end)
            console.log("fly_probe: OBSERVE -- placed from slot " .. slot .. ", now watching.")
        end
        if n == 1 then
            console.log("fly_probe: OBSERVE mode -- logging only, no input.")
            log("=== fly_probe OBSERVE emuframe=" .. emu.framecount() .. " ===")
        end
        if slot and n < SETTLE_FRAMES then return end
        phase = "log"
    end
    if phase == "settle" then
        if n < SETTLE_FRAMES then return end
        pcall(function() savestate.loadslot(SLOT) end)
        console.log("fly_probe: loaded slot " .. SLOT .. " -- tapping A, then logging.")
        log(string.format("=== fly_probe slot=%d emuframe=%d ===", SLOT, emu.framecount()))
        phase, n = "tap", 0
        return
    end
    if phase == "tap" then
        -- Tapped, not held: the game reads a new press.
        joypad.set({ A = (n % 20) < 10 })
        if n >= TAP_FRAMES then
            console.log("fly_probe: logging " .. LOG_FRAMES .. " frames.")
            phase, n = "log", 0
        end
        -- Log through the tap too -- the field-move pose starts here, before the bird exists.
    end
    if phase == "done" then return end

    local pObj = r8(GPLAYERAVATAR_ADDR + 0x05)
    local pSpr = (pObj < 16) and r8(objAddr(pObj) + 0x04) or 255
    local gs = ghostObjIds(pObj)
    local parts = { describe("PLAYER", pObj) }
    local skip = { [pSpr] = true }
    for _, gObj in ipairs(gs) do
        parts[#parts + 1] = describe("GHOST" .. gObj, gObj)
        skip[r8(objAddr(gObj) + 0x04)] = true
    end
    log(string.format("f=%d area=%s | %s | TASKS %s | LOOSE %s",
        emu.framecount(), localArea(),
        table.concat(parts, " | "),
        tasks(),
        loose(skip)))
    logged = logged + 1
    maybeShoot()

    if not OBSERVE and phase == "log" and n >= LOG_FRAMES then
        phase = "done"
        if out then out:flush() end
        console.log("fly_probe: done -- " .. logged .. " frames in probes/fly_probe.log")
    end
end

MESHGHOST_DEV_TICK = tick
if not MESHGHOST_DEV_LOADER then
    while true do tick() emu.frameadvance() end
end
