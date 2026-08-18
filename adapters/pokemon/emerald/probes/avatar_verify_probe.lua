-- Dev-only final verification for the Archipelago gObjectEvents/gPlayerAvatar relocation found
-- via avatar_scan_probe.lua + avatar_hexdump_probe.lua + avatar_array_probe.lua. Read-only,
-- never writes memory.
--
-- Found this session (2026-08-14), on a real Archipelago-patched ROM/seed:
--   gObjectEvents = 0x020375D4 (confirmed index 0 -- slot -1 breaks the pattern completely,
--     slots 0-3 show real sequential localId 0xFF/1/2/3 for player + 3 NPCs, all mapNum=9/
--     mapGroup=0 matching the already-known Littleroot Town location)
--   gPlayerAvatar = 0x02037814 (gObjectEvents + 0x240, same relationship vanilla uses --
--     struct PlayerAvatar per pokeemerald's include/global.fieldmap.h: flags@0x00,
--     transitionFlags@0x01, runningState@0x02, tileTransitionState@0x03, spriteId@0x04,
--     objectEventId@0x05, preventStep@0x06, gender@0x07)
--
-- This probe is the decisive test: the ORIGINAL vanilla-address reads at this exact struct
-- shape came back frozen garbage (0xFF/255/15, verified.md 2026-08-11 and reproduced 2026-08-14)
-- -- if these NEW addresses are right, the same fields should now track real, responsive state
-- as you move and dash, not sit frozen. Same "print only on change" idiom as phase1_probe.lua.

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
