-- Exercises the Acro Bike: hop in place, then hop while moving, in fixed phases with a countdown (dev tool, never
-- shipped).
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local GPLAYERAVATAR_ADDR = 0x02037590

local n, phase, said = 0, nil, {}
local function say(s) console.log("acro_hop: " .. s) end

local PHASES = {
    -- Held, not tapped: a tap of B pops a wheelie and never hops.
    { name = "hop in place (B held)", frames = 300, keys = function() return { B = true } end },
    { name = "hop while moving right", frames = 300, keys = function() return { B = true, Right = true } end },
    { name = "hop while moving left", frames = 300, keys = function() return { B = true, Left = true } end },
}

local function tick()
    n = n + 1
    local cb = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if (cb ~= CB2_OVERWORLD_ADDR and cb ~= CB2_OVERWORLD_ADDR + 1)
        or memory.read_u8(GPLAYERAVATAR_ADDR + 0x06) ~= 0
    then
        joypad.set({})
        return
    end
    local t, i = n, 1
    while i <= #PHASES and t > PHASES[i].frames do t = t - PHASES[i].frames i = i + 1 end
    if i > #PHASES then n = 0 return end
    if not said[i] then said[i] = true say("phase " .. i .. ": " .. PHASES[i].name) end
    joypad.set(PHASES[i].keys(t))
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function() joypad.set({}) say("unloaded, keys released") end
else
    while true do tick() emu.frameadvance() end
end
