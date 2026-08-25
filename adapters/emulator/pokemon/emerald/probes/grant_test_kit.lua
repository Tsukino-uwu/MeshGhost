-- MeshGhost — Emerald test-kit granter (DEVELOPMENT TOOL, never shipped)
--
-- WRITES THE SAVE BLOCK. Read this line twice.
--
-- `CLAUDE.md`: *nothing that ships writes a save or game state, ever* — and the exception, which
-- this is: **dev-only test tooling MAY cheat, a probe and never an adapter**, because a test save
-- is expendable (user, 2026-08-18). Cheating to reach a state is explicitly permitted as of
-- 2026-08-19, see `agent_docs/playing.md`. So: this is a probe, it is never loaded by the adapter,
-- it is not packaged, and it should be pointed at a save nobody minds losing.
--
-- WHY IT EXISTS
-- Emerald's ghost work needs the states a fresh save cannot reach: surfing, both bikes, fishing,
-- Fly. A peer's own state (`graphicsId`) is a known open item and none of it can be watched until
-- somebody can actually do those things. Requested 2026-08-19: every HM and badge, Master Balls,
-- the Super Rod, the Go-Goggles, and Repel kept running.
--
-- EVERY ADDRESS AND ID BELOW IS CITED. Nothing here is from memory (`CLAUDE.md`'s hard rule), and
-- pokeemerald is a facts-only source that may never be copied from (`agent_docs/licensing.md`):
-- these are struct offsets and constant values read from it, with independent Lua written around
-- them.
--
--   SaveBlock1 layout           include/global.h -- the /*0xNNN*/ offset comments on struct
--                               SaveBlock1: bagPocket_Items 0x560, bagPocket_KeyItems 0x5D8,
--                               bagPocket_PokeBalls 0x650, bagPocket_TMHM 0x690, flags 0x1270,
--                               vars 0x139C
--   struct ItemSlot             include/global.h:590 -- { u16 itemId; u16 quantity; }
--   quantity is ENCRYPTED       src/item.c:26-34 -- Get/SetBagItemQuantity XOR the stored value
--                               with gSaveBlock2Ptr->encryptionKey. PC items are not encrypted;
--                               bag pockets are. Miss this and every count reads as garbage.
--   encryptionKey               include/global.h:532 -- SaveBlock2 + 0xAC
--   badge flags                 include/constants/flags.h:1348,1359-1366 -- SYSTEM_FLAGS = 0x860,
--                               FLAG_BADGE01_GET = SYSTEM_FLAGS + 0x7 .. BADGE08 = + 0xE
--   item ids                    include/constants/items.h -- MASTER_BALL 1, MACH_BIKE 259,
--                               SUPER_ROD 264, ACRO_BIKE 272, GO_GOGGLES 279, HM01..HM08 339..346
--   pockets                     src/data/items.h -- Master Ball POCKET_POKE_BALLS, Super Rod (and
--                               the bikes/goggles) POCKET_KEY_ITEMS, HM01 POCKET_TM_HM
--   repel counter               include/constants/vars.h:4,51 -- VARS_START 0x4000,
--                               VAR_REPEL_STEP_COUNT 0x4021, so vars[0x21]
--
-- The two save-block POINTERS are the adapter's own, already measured and in use:
-- gSaveBlock1Ptr 0x03005d8c, gSaveBlock2Ptr 0x03005d90.

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
-- Nothing is granted into the general Items pocket: Repel is handled by its step counter below,
-- and no other consumable is needed to reach a surf/bike/fish/Fly state. An id here would have to
-- be cited like every other, and an uncited "probably right" number is how a wrong one ships.

local log = console.log

local function sb1() return memory.read_u32_le(SAVEBLOCK1PTR) end
local function sb2() return memory.read_u32_le(SAVEBLOCK2PTR) end

-- The bag stores quantity XOR the save's encryption key (src/item.c:31-34). Only the low 16 bits
-- of the key matter for a u16 field.
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
    -- Repel: the counter is steps remaining and the game decrements it as you walk, so "keep it
    -- enabled" means topping it up rather than setting it once. Checked twice a second, written
    -- only when it has actually run down, so this is not a write every frame.
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
