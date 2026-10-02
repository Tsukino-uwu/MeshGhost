-- Read-only, prints once (reload for another snapshot): raw EWRAM around avatar_scan_probe.lua's two candidates,
-- where the repeating 0x24-byte object stride shows the gObjectEvents boundary and gPlayerAvatar.

local DUMP_START = 0x02037200
local DUMP_END = 0x02037800 -- 0x600 bytes, comfortably covers both candidates plus margin
local BYTES_PER_LINE = 16

if not memory.usememorydomain("System Bus") then
    console.log("ERROR: 'System Bus' memory domain not found on this core.")
    console.log("Domains available: " .. memory.getmemorydomainlist())
    return
end

console.log(string.format("=== EWRAM hex dump 0x%08X - 0x%08X ===", DUMP_START, DUMP_END - 1))
console.log("Candidates from avatar_scan_probe.lua: 0x020375EC, 0x020375F4 (marked with * below)")
console.log("Vanilla reference: gObjectEvents=0x02037350 (0x24-byte stride x16), gPlayerAvatar=0x02037590")
console.log("")

for addr = DUMP_START, DUMP_END - 1, BYTES_PER_LINE do
    local bytes = {}
    local marker = " "
    for i = 0, BYTES_PER_LINE - 1 do
        local b = memory.read_u8(addr + i)
        bytes[#bytes + 1] = string.format("%02X", b)
        if (addr + i) == 0x020375EC or (addr + i) == 0x020375F4 then
            marker = "*"
        end
    end
    console.log(string.format("%s0x%08X: %s", marker, addr, table.concat(bytes, " ")))
end

console.log("=== end dump ===")
