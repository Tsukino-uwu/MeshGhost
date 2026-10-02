-- Steps one tile at a time on the bike, one per facing, with a long still spell after each: a sustained ride hides a
-- walk cycle spent on a single tile.
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local GPLAYERAVATAR_ADDR = 0x02037590
local STEPS = { "Right", "Left", "Up", "Down" }
local n = 0
local function tick()
    local cb = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if (cb ~= CB2_OVERWORLD_ADDR and cb ~= CB2_OVERWORLD_ADDR + 1)
        or memory.read_u8(GPLAYERAVATAR_ADDR + 0x06) ~= 0
    then joypad.set({}) return end
    n = n + 1
    local cycle = 150                       -- one step, then five seconds of standing still
    local i = math.floor(n / cycle) % #STEPS + 1
    local t = n % cycle
    if t < 12 then joypad.set({ [STEPS[i]] = true })
    elseif t == 12 then joypad.set({}) console.log("onestep: one tile " .. STEPS[i]) end
end
if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick MESHGHOST_DEV_UNLOAD = function() joypad.set({}) end
else while true do tick() emu.frameadvance() end end
