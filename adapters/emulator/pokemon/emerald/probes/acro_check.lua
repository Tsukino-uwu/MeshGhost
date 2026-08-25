-- MeshGhost -- is the Acro Bike actually in the bag and registered? (DEV TOOL, never shipped)
--
-- WHY. `use_acro` registers ITEM_ACRO_BIKE to SELECT and presses it, and twice in a row the player
-- stayed on foot with no menu on screen. "The press did nothing" has three different causes -- the
-- item is not in the bag, the registration did not take, or the pad is not reaching the game --
-- and guessing between them is what this project has a rule against. So: read all three.
--
-- Offsets are grant_test_kit.lua's, already cited there: SaveBlock1 bagPocket_KeyItems 0x5D8,
-- registeredItem 0x496, struct ItemSlot { u16 itemId; u16 quantity; }, ITEM_ACRO_BIKE 272.
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local KEYITEMS_OFF = 0x5d8
local KEYITEMS_COUNT = 30
local ITEM_ACRO_BIKE = 272

-- The Lua console is not readable from outside the emulator, so every line also goes to a
-- file next to this probe. A backslash inside a Lua pattern is an escape, hence string.char.
local BSLASH = string.char(92)
local logPath = ("%s/acro_check.log"):format(
    (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/" .. BSLASH .. "][^/" .. BSLASH .. "]*$") or "."))
local logFile = io.open(logPath, "a")

local n, said = 0, false
local function say(s)
    console.log("acro_check: " .. s)
    if logFile then logFile:write(s .. string.char(10)) logFile:flush() end
end

local function tick()
    n = n + 1
    if said or n < 30 then return end
    local sb1 = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
    if sb1 == 0 then return end
    said = true

    local found = {}
    for i = 0, KEYITEMS_COUNT - 1 do
        local id = memory.read_u16_le(sb1 + KEYITEMS_OFF + i * 4)
        if id ~= 0 then found[#found + 1] = tostring(id) end
    end
    say("registeredItem = " .. memory.read_u16_le(sb1 + 0x496)
        .. " (ACRO_BIKE is " .. ITEM_ACRO_BIKE .. ")")
    say("key items = " .. table.concat(found, ","))
    local objId = memory.read_u8(GPLAYERAVATAR_ADDR + 0x05)
    say("avatar flags = " .. string.format("%02X", memory.read_u8(GPLAYERAVATAR_ADDR))
        .. " objId = " .. objId
        .. " graphicsId = " .. memory.read_u8(GOBJECTEVENTS_ADDR + objId * 0x24 + 0x05))
end

if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
