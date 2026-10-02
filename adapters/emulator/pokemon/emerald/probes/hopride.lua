-- Hops on the Acro Bike with B held throughout: long runs one way with reversals of varying length mixed in, then
-- the sideways jump in each direction.
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local GPLAYERAVATAR_ADDR = 0x02037590

-- Uneven on purpose: equal legs put every reversal on the same phase of the hop cycle. The first leg is B alone,
-- since B with a direction from a standstill is the sideways jump, not a hop.
local LEGS = {
    { key = nil,     frames = 120 },
    { key = "Right", frames = 150 }, { key = "Left",  frames = 40 },
    { key = "Right", frames = 90 },  { key = "Left",  frames = 25 },
    { key = "Left",  frames = 150 }, { key = "Right", frames = 40 },
    { key = "Left",  frames = 70 },  { key = "Right", frames = 15 },
    { key = "Up",    frames = 90 },  { key = "Down",  frames = 30 },
    { key = "Down",  frames = 90 },  { key = "Up",    frames = 20 },
    -- The sideways jump: `noB` stops the hop first, since the pair pressed mid-hop steers the hop instead.
    { key = nil, noB = true, frames = 45 }, { key = "Up",    frames = 25 },
    { key = nil, noB = true, frames = 45 }, { key = "Down",  frames = 25 },
    { key = nil, noB = true, frames = 45 }, { key = "Left",  frames = 25 },
    { key = nil, noB = true, frames = 45 }, { key = "Right", frames = 25 },
}

local n, said = 0, {}
local function tick()
    local cb = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if (cb ~= CB2_OVERWORLD_ADDR and cb ~= CB2_OVERWORLD_ADDR + 1)
        or memory.read_u8(GPLAYERAVATAR_ADDR + 0x06) ~= 0
    then joypad.set({}) return end
    n = n + 1
    local t, i = n, 1
    while i <= #LEGS and t > LEGS[i].frames do t = t - LEGS[i].frames i = i + 1 end
    if i > #LEGS then n = 0 said = {} return end
    if not said[i] then said[i] = true console.log("hopride: leg " .. i .. " " .. LEGS[i].key) end
    -- B held the whole time keeps the hop going across the reversals.
    if LEGS[i].noB then joypad.set({})
    elseif LEGS[i].key then joypad.set({ B = true, [LEGS[i].key] = true })
    else joypad.set({ B = true }) end
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function() joypad.set({}) end
else while true do tick() emu.frameadvance() end end
