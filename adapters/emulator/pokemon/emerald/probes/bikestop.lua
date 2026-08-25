-- MeshGhost -- ride, then STOP, on the bike (DEV TOOL, never shipped)
--
-- WHY. A ghost on the bike looks wrong the moment it stops: the user, 2026-08-20 -- it sits
-- *"tiled a bit to the side visually when idle"* and wears *"the animation/pose that is supposed
-- to happen while actively moving"*. The interesting frames are therefore the ones just after a
-- stop, and a stop is over in a few frames -- too short to catch by hand while also reading a log.
-- So the ride is scripted: a fixed distance, then a long still spell, repeatedly, with the anim
-- trace running underneath.
--
-- Lenient by design, like every probe here: fixed phases with a countdown, nothing to time.
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local GPLAYERAVATAR_ADDR = 0x02037590

local PHASES = {
    { name = "ride right",  frames = 90,  keys = function() return { Right = true } end },
    { name = "STOP -- watch the ghost settle", frames = 150, keys = function() return {} end },
    { name = "ride left",   frames = 90,  keys = function() return { Left = true } end },
    { name = "STOP -- watch the ghost settle", frames = 150, keys = function() return {} end },
    -- UP AND DOWN TOO, at the user's prompt 2026-08-20: the side-on frames of the Acro Bike hide
    -- the difference between standing on it and rolling on it, so a left/right-only ride can pass
    -- while the pose is still wrong in the two views that show it.
    { name = "ride up",     frames = 90,  keys = function() return { Up = true } end },
    { name = "STOP -- watch the ghost settle", frames = 150, keys = function() return {} end },
    { name = "ride down",   frames = 90,  keys = function() return { Down = true } end },
    { name = "STOP -- watch the ghost settle", frames = 150, keys = function() return {} end },
}

local n, said = 0, {}
local function say(s) console.log("bikestop: " .. s) end

local function tick()
    local cb = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if (cb ~= CB2_OVERWORLD_ADDR and cb ~= CB2_OVERWORLD_ADDR + 1)
        or memory.read_u8(GPLAYERAVATAR_ADDR + 0x06) ~= 0
    then
        joypad.set({})
        return
    end
    n = n + 1
    local t, i = n, 1
    while i <= #PHASES and t > PHASES[i].frames do t = t - PHASES[i].frames i = i + 1 end
    if i > #PHASES then n = 0 said = {} return end
    if not said[i] then said[i] = true say("phase " .. i .. ": " .. PHASES[i].name) end
    joypad.set(PHASES[i].keys(t))
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function() joypad.set({}) say("unloaded, keys released") end
else
    while true do tick() emu.frameadvance() end
end
