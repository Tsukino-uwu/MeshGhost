-- Grants a test kit by writing SaveBlock1, which an in-game save then keeps: 8 badges, HM01-08, both bikes, the
-- Super Rod, the Go-Goggles, 20 Master Balls, and a Repel kept running (dev tool: a probe, never loaded by the
-- adapter or packaged). Point it at a save nobody minds changing.

local SAVEBLOCK1PTR = 0x03005d8c
local SAVEBLOCK2PTR = 0x03005d90

local POCKET_KEYITEMS  = 0x5D8
local POCKET_POKEBALLS = 0x650
local POCKET_TMHM      = 0x690
local FLAGS            = 0x1270
local VARS             = 0x139C

local SYSTEM_FLAGS = 0x860
local BADGE01 = SYSTEM_FLAGS + 0x7

local REPEL_VAR_INDEX = 0x4021 - 0x4000
local REPEL_TOPUP = 250 -- steps; topped back up below whenever it runs low

-- What to grant, per pocket. Quantities are what a tester wants, not what a shop allows.
local KEY_ITEMS = {
    { 259, 1 },  -- MACH BIKE
    { 272, 1 },  -- ACRO BIKE
    { 264, 1 },  -- SUPER ROD
    { 279, 1 },  -- GO-GOGGLES
}
local BALLS = { { 1, 20 } }               -- MASTER BALL
local TMHM = {}
for i = 0, 7 do TMHM[#TMHM + 1] = { 339 + i, 1 } end  -- HM01..HM08
-- Nothing goes in the Items pocket: Repel is its step counter, below.

local log = console.log

local function sb1() return memory.read_u32_le(SAVEBLOCK1PTR) end
local function sb2() return memory.read_u32_le(SAVEBLOCK2PTR) end

-- The bag stores quantity XOR the save's encryption key, whose low 16 bits are all a u16 field uses.
local function encKey16()
    local base = sb2()
    if base == 0 then return nil end
    return memory.read_u32_le(base + 0xAC) & 0xFFFF
end

local function writePocket(offset, entries, key)
    local base = sb1()
    for i, e in ipairs(entries) do
        local slot = base + offset + (i - 1) * 4
        memory.write_u16_le(slot, e[1])
        memory.write_u16_le(slot + 2, e[2] ~ key)
    end
end

local function setFlag(id)
    local a = sb1() + FLAGS + (id // 8)
    memory.write_u8(a, memory.read_u8(a) | (1 << (id % 8)))
end

local function grant()
    local key = encKey16()
    if not key then return false end

    for i = 0, 7 do setFlag(BADGE01 + i) end
    writePocket(POCKET_KEYITEMS, KEY_ITEMS, key)
    writePocket(POCKET_POKEBALLS, BALLS, key)
    writePocket(POCKET_TMHM, TMHM, key)

    log("GRANT: 8 badges, HM01-08, both bikes, Super Rod, Go-Goggles, 20 Master Balls.")
    log("GRANT: HMs are in the TM/HM pocket -- a Pokemon still has to LEARN Surf/Fly to use them.")
    return true
end

local granted = false
local frames = 0

MESHGHOST_DEV_TICK = function()
    frames = frames + 1
    if not granted then
        if frames % 30 == 0 and sb1() ~= 0 then granted = grant() end
        return
    end
    -- The repel counter is steps left and the game counts it down, so it is topped up when low, not set once.
    if frames % 30 == 0 then
        local base = sb1()
        if base ~= 0 then
            local a = base + VARS + REPEL_VAR_INDEX * 2
            if memory.read_u16_le(a) < 40 then memory.write_u16_le(a, REPEL_TOPUP) end
        end
    end
end

MESHGHOST_DEV_UNLOAD = function()
    log("GRANT: probe unloaded -- repel will now run down normally.")
end
