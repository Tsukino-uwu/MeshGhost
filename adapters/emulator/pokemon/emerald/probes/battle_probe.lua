-- Prints gMain.callback2 whenever it changes, to see whether it tells a battle from the overworld. Reads only.
-- callback2 holds the Thumb form of the pointer, so each address is tested with and without bit 0.

local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
-- CB2_Overworld on the Archipelago base patch, which recompiles it to a new address.
local CB2_OVERWORLD_ARCHIPELAGO_ADDR = 0x080867f1

if not memory.usememorydomain("System Bus") then
    console.log("ERROR: 'System Bus' memory domain not found on this core.")
    console.log("Domains available: " .. memory.getmemorydomainlist())
    return
end

console.log("MeshGhost battle probe running. Reading gMain.callback2 @ 0x030022C4.")
console.log(string.format("CB2_Overworld reference address: 0x%08X (or 0x%08X with the Thumb bit)",
    CB2_OVERWORLD_ADDR, CB2_OVERWORLD_ADDR + 1))
console.log(string.format("Archipelago-recompiled reference address: 0x%08X (or 0x%08X with the Thumb bit)",
    CB2_OVERWORLD_ARCHIPELAGO_ADDR, CB2_OVERWORLD_ARCHIPELAGO_ADDR + 1))
console.log("Only prints when callback2 changes -- walk around, open menus, talk to an NPC,")
console.log("and start a battle; watch which actions cause a new line to print.")

local lastCallback2 = nil

while true do
    local callback2 = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if callback2 ~= lastCallback2 then
        local isOverworld = (callback2 == CB2_OVERWORLD_ADDR or callback2 == CB2_OVERWORLD_ADDR + 1
            or callback2 == CB2_OVERWORLD_ARCHIPELAGO_ADDR or callback2 == CB2_OVERWORLD_ARCHIPELAGO_ADDR + 1)
        console.log(string.format("callback2=0x%08X  looksLikeOverworld=%s", callback2, tostring(isOverworld)))
        lastCallback2 = callback2
    end
    emu.frameadvance()
end
