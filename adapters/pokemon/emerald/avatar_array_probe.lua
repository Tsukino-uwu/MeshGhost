-- Dev-only follow-up to avatar_scan_probe.lua + avatar_hexdump_probe.lua. The player's own
-- ObjectEvent entry was confirmed at 0x020375D4 on this Archipelago-patched ROM (struct fields
-- matched field-by-field against pokeemerald's real layout: isPlayer bit set, trackedByCamera
-- bit set, localId=0xFF=LOCALID_PLAYER, mapNum=9/mapGroup=0 matching the already-known
-- Littleroot Town location). This probe scans a wide window of OBJECT_EVENTS_COUNT-sized
-- (0x24-byte) slots around that known-good entry, decoding each one's active/isPlayer bits and
-- localId/mapNum/mapGroup, so the real 16-slot gObjectEvents array's start address (and
-- whatever sits immediately after it, where gPlayerAvatar lives in vanilla) can be read off
-- directly. Read-only, never writes memory. Prints once and exits.

local KNOWN_ENTRY_ADDR = 0x020375D4
local ENTRY_SIZE = 0x24
local SLOTS_BEFORE = 20
local SLOTS_AFTER = 20

if not memory.usememorydomain("System Bus") then
    console.log("ERROR: 'System Bus' memory domain not found on this core.")
    console.log("Domains available: " .. memory.getmemorydomainlist())
    return
end

console.log("=== gObjectEvents array-boundary probe ===")
console.log(string.format("Known-good player entry: 0x%08X (confirmed via hex dump field match)", KNOWN_ENTRY_ADDR))
console.log("Scanning slots before/after at the 0x24 (36-byte) ObjectEvent stride.")
console.log("")
console.log("offset  address     active isPlayer trackedByCam localId mapNum mapGroup")

for i = -SLOTS_BEFORE, SLOTS_AFTER do
    local addr = KNOWN_ENTRY_ADDR + i * ENTRY_SIZE
    local flags0 = memory.read_u8(addr + 0x00)
    local flags1 = memory.read_u8(addr + 0x01)
    local flags2 = memory.read_u8(addr + 0x02)
    local localId = memory.read_u8(addr + 0x08)
    local mapNum = memory.read_u8(addr + 0x09)
    local mapGroup = memory.read_u8(addr + 0x0A)

    local active = flags0 & 0x1
    local trackedByCamera = (flags1 >> 7) & 0x1
    local isPlayer = flags2 & 0x1

    local marker = (addr == KNOWN_ENTRY_ADDR) and "*" or " "
    console.log(string.format("%s%+3d    0x%08X  %d      %d        %d             0x%02X    %3d    %3d",
        marker, i, addr, active, isPlayer, trackedByCamera, localId, mapNum, mapGroup))
end

console.log("")
console.log("Look for where 'active' stops looking like real data (garbage/inconsistent values) --")
console.log("that's the array boundary. Whatever sits right after the LAST real-looking slot is")
console.log("the gPlayerAvatar candidate (same relationship as vanilla: gPlayerAvatar immediately")
console.log("follows gObjectEvents[15]).")
console.log("=== end ===")
