-- Read-only, prints on change: the Archipelago gObjectEvents/gPlayerAvatar addresses that avatar_scan,
-- avatar_hexdump and avatar_array found. If they are right these fields track walking, dashing and turning;
-- the vanilla addresses read frozen garbage on that ROM.

local GOBJECTEVENTS_ARCHIPELAGO_ADDR = 0x020375d4
local GPLAYERAVATAR_ARCHIPELAGO_ADDR = 0x02037814
local OBJECTEVENT_SIZE = 0x24

if not memory.usememorydomain("System Bus") then
    console.log("ERROR: 'System Bus' memory domain not found on this core.")
    console.log("Domains available: " .. memory.getmemorydomainlist())
    return
end

console.log("MeshGhost avatar-verify probe running (Archipelago-relocated addresses).")
console.log(string.format("gObjectEvents=0x%08X  gPlayerAvatar=0x%08X", GOBJECTEVENTS_ARCHIPELAGO_ADDR, GPLAYERAVATAR_ARCHIPELAGO_ADDR))
console.log("Only prints when something changes -- walk around, dash, turn, and watch whether")
console.log("these now track real state instead of sitting frozen like the vanilla addresses did.")

local lastLine = nil

while true do
    local flags = memory.read_u8(GPLAYERAVATAR_ARCHIPELAGO_ADDR + 0x00)
    local runningState = memory.read_u8(GPLAYERAVATAR_ARCHIPELAGO_ADDR + 0x02)
    local spriteId = memory.read_u8(GPLAYERAVATAR_ARCHIPELAGO_ADDR + 0x04)
    local objectEventId = memory.read_u8(GPLAYERAVATAR_ARCHIPELAGO_ADDR + 0x05)
    local gender = memory.read_u8(GPLAYERAVATAR_ARCHIPELAGO_ADDR + 0x07)
    local dashing = (flags & 0x80) ~= 0

    local objEventAddr = GOBJECTEVENTS_ARCHIPELAGO_ADDR + (objectEventId * OBJECTEVENT_SIZE)
    local facingRaw = memory.read_u16_le(objEventAddr + 0x18)
    local facingDirection = facingRaw & 0xF

    local line = string.format(
        "flags=0x%02X  dash=%s  runningState=%d  spriteId=%d  objectEventId=%d  gender=%d  facingDirection=%d",
        flags, tostring(dashing), runningState, spriteId, objectEventId, gender, facingDirection)
    if line ~= lastLine then
        console.log(line)
        lastLine = line
    end
    emu.frameadvance()
end
