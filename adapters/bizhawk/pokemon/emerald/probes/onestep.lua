-- MeshGhost -- ONE tile at a time, on the bike (DEV TOOL, never shipped)
--
-- WHY. The user, 2026-08-20: *"when moving a single tile, its 'over animating', the characther is
-- not supposed to wiggle from just 1 step, only when constantly biking in 1 direction"*, and only
-- on the spawned tier. A sustained ride hides it -- the wiggle is a whole walk cycle spent on one
-- tile, so it only shows when the tile is the whole journey. Four single steps, one per facing,
-- with a long still spell after each.
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
