-- Is the Acro Bike in the bag, is it registered to SELECT, and is the player on it? Logs all three, once (dev tool,
-- never shipped). SaveBlock1 offsets as in grant_test_kit.lua; a key-item slot is a u16 id then a u16 quantity.
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local KEYITEMS_OFF = 0x5d8
local KEYITEMS_COUNT = 30
local ITEM_ACRO_BIKE = 272

-- Also logged beside the probe: the Lua console cannot be read from outside the emulator. A backslash in a Lua
-- pattern is an escape, hence string.char.
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
