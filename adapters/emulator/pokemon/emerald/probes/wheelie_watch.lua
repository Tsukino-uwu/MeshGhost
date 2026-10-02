-- MeshGhost -- what the engine does with a wheelie, frame by frame (dev tool, holds the pad, never shipped).
-- Drives B through fixed phases on the Acro Bike; logs the player's object, its sprite and gPlayerAvatar raw per frame.
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local GSPRITES_ADDR = 0x02020630
local OBJECTEVENT_SIZE = 0x24
local SPRITE_SIZE = 0x44
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c

local function r8(a) return memory.read_u8(a) end
local function rs16(a) return memory.read_s16_le(a) end

-- Built rather than written: a backslash in this pattern is easily lost to a scripted edit, and the load then fails.
local BSLASH = string.char(92)
local logPath = ("%s/wheelie_watch_%s.log"):format(
    (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/" .. BSLASH .. "][^/" .. BSLASH .. "]*$") or "."),
    os.date("%Y%m%d_%H%M%S"))
local logFile = io.open(logPath, "a")
local function say(s)
    console.log("wheelie: " .. s)
    if logFile then logFile:write(s .. string.char(10)) logFile:flush() end
end
local function line(s)
    if logFile then logFile:write(s .. string.char(10)) logFile:flush() end
end

-- B held, not tapped: a tap pops a wheelie and nothing else.
local PHASES = {
    -- No keys: joypad.set replaces the whole pad, and this is the window use_acro needs to press SELECT.
    { name = "stand still (baseline, pad left alone)", frames = 180, keys = nil },
    { name = "hold B -- standing wheelie",    frames = 300, keys = function() return { B = true } end },
    { name = "release -- end the wheelie",    frames = 180, keys = function() return {} end },
    { name = "hold B + Right -- moving wheelie", frames = 300, keys = function() return { B = true, Right = true } end },
    { name = "release -- settle",             frames = 180, keys = function() return {} end },
    -- Every direction: the ghost hung on its families' +1 and +3 members, and facing south only produces +0.
    { name = "face north",                    frames = 40,  keys = function() return { Up = true } end },
    { name = "hold B facing north",           frames = 240, keys = function() return { B = true } end },
    { name = "release",                       frames = 90,  keys = function() return {} end },
    { name = "face east",                     frames = 40,  keys = function() return { Right = true } end },
    { name = "hold B facing east",            frames = 240, keys = function() return { B = true } end },
    { name = "release",                       frames = 90,  keys = function() return {} end },
    { name = "face west",                     frames = 40,  keys = function() return { Left = true } end },
    { name = "hold B facing west",            frames = 240, keys = function() return { B = true } end },
    { name = "release",                       frames = 90,  keys = function() return {} end },
    -- A direction pressed with B from a standstill is the sideways jump, its own move.
    { name = "Up+B together from a standstill", frames = 180, keys = function() return { Up = true, B = true } end },
    { name = "release",                       frames = 90,  keys = function() return {} end },
}

local n, said, done, lastAct, waited = 0, {}, false, nil, false

local function tick()
    if done then return end
    local cb = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if (cb ~= CB2_OVERWORLD_ADDR and cb ~= CB2_OVERWORLD_ADDR + 1)
        or r8(GPLAYERAVATAR_ADDR + 0x06) ~= 0
    then
        joypad.set({})
        return
    end

    -- Waits for the Acro Bike's graphicsId (63 Brendan, 91 May), so a bike never mounted cannot log a walk.
    local pObjId = r8(GPLAYERAVATAR_ADDR + 0x05)
    if pObjId > 15 then return end
    local gfx = r8(GOBJECTEVENTS_ADDR + pObjId * OBJECTEVENT_SIZE + 0x05)
    if gfx ~= 63 and gfx ~= 91 then
        if not waited then waited = true say("waiting for the Acro Bike (graphicsId " .. gfx .. ")") end
        return
    end
    if waited then waited = false say("on the Acro Bike -- starting") end

    n = n + 1
    local t, i = n, 1
    while i <= #PHASES and t > PHASES[i].frames do t = t - PHASES[i].frames i = i + 1 end
    if i > #PHASES then
        joypad.set({})
        done = true
        say("done -- " .. logPath)
        return
    end
    if not said[i] then
        said[i] = true
        say(string.format("phase %d/%d: %s (%d frames)", i, #PHASES, PHASES[i].name, PHASES[i].frames))
        line(string.format("# phase %d %s", i, PHASES[i].name))
    end
    if PHASES[i].keys then joypad.set(PHASES[i].keys(t)) end

    local objId = r8(GPLAYERAVATAR_ADDR + 0x05)
    if objId > 15 then return end
    local o = GOBJECTEVENTS_ADDR + objId * OBJECTEVENT_SIZE
    local s = GSPRITES_ADDR + r8(o + 0x04) * SPRITE_SIZE
    local b0 = r8(o + 0x00)

    local av = {}
    for k = 0, 15 do av[#av + 1] = string.format("%02X", r8(GPLAYERAVATAR_ADDR + k)) end

    line(string.format(
        "f=%4d ph=%d act=%02X active=%d finished=%d dir=%02X b1=%02X "
        .. "anim=%d/%d ended=%d data1=%d data2=%d pos2=%d,%d avatar=%s",
        n, i, r8(o + 0x1c), (b0 >> 6) & 1, (b0 >> 7) & 1, r8(o + 0x18), r8(o + 0x01),
        r8(s + 0x2a), r8(s + 0x2b), (r8(s + 0x2c) >> 6) & 1,
        rs16(s + 0x30), rs16(s + 0x32), rs16(s + 0x24), rs16(s + 0x26),
        table.concat(av, " ")))

    if lastAct ~= r8(o + 0x1c) then
        lastAct = r8(o + 0x1c)
        -- The whole object on each action change: cheaper than a second live run when an unprinted byte differs.
        local d = {}
        for k = 0, OBJECTEVENT_SIZE - 1 do d[#d + 1] = string.format("%02X", r8(o + k)) end
        line(string.format("  OBJ act=%02X | %s", lastAct, table.concat(d, " ")))
        say(string.format("action -> 0x%02X (active=%d finished=%d)",
            lastAct, (b0 >> 6) & 1, (b0 >> 7) & 1))
    end
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function() joypad.set({}) say("unloaded, keys released") end
else
    while true do tick() emu.frameadvance() end
end
