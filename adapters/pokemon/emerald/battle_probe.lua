-- Battle-detection probe. Not a phase deliverable -- a throwaway diagnostic to confirm,
-- on screen, whether gMain.callback2 reliably distinguishes "in battle" from "in the
-- overworld" before wiring any gating logic into phase4_multiplayer.lua. Never writes memory.
--
-- Address source: pret/pokeemerald, built locally 2026-08-11 from a checkout matching ROM
-- SHA1 F3AE088181BF583E55DAF962A92BB46F4F1D07B7 (`make compare` -> "pokeemerald.gba: OK"),
-- same build cited by every other address in this project (see agent_docs/verified.md).
--
-- gMain = 0x030022C0 (pokeemerald.map/.sym, size 0x43C matches struct Main's full layout).
-- callback2 field is at +0x004 (include/main.h L11: "/*0x004*/ MainCallback callback2;"),
-- so its address is 0x030022C4. It is a u32 GBA function pointer, re-read fresh every frame
-- (never cached), since it changes constantly as the game's top-level state machine runs.
--
-- CB2_Overworld = 0x08085E5C (pokeemerald.map/.sym), the callback set for ordinary field
-- play (src/overworld.c L1484). CB2_InitBattle is set by every battle-start path found in the
-- src tree, e.g. src/battle_setup.c L369, L940, src/battle_main.c L1955 -- not looked up here
-- since this probe only needs to show callback2 LEAVING CB2_Overworld, not the specific
-- battle callback it moves to.
--
-- NOT YET CONFIRMED: whether the live value includes the Thumb bit (GBA Thumb function
-- pointers are conventionally stored with the low bit set, i.e. 0x08085E5D not 0x08085E5C,
-- to signal Thumb-mode execution to BX) -- that is exactly what this probe is for. Printing
-- the raw hex value lets it be compared by eye against both possibilities rather than
-- guessing which one the check should use.

local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c

if not memory.usememorydomain("System Bus") then
    console.log("ERROR: 'System Bus' memory domain not found on this core.")
    console.log("Domains available: " .. memory.getmemorydomainlist())
    return
end

console.log("MeshGhost battle probe running. Reading gMain.callback2 @ 0x030022C4.")
console.log(string.format("CB2_Overworld reference address: 0x%08X (or 0x%08X with the Thumb bit)",
    CB2_OVERWORLD_ADDR, CB2_OVERWORLD_ADDR + 1))
console.log("Only prints when callback2 changes -- walk around, open menus, talk to an NPC,")
console.log("and start a battle; watch which actions cause a new line to print.")

local lastCallback2 = nil

while true do
    local callback2 = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if callback2 ~= lastCallback2 then
        local isOverworld = (callback2 == CB2_OVERWORLD_ADDR or callback2 == CB2_OVERWORLD_ADDR + 1)
        console.log(string.format("callback2=0x%08X  looksLikeOverworld=%s", callback2, tostring(isOverworld)))
        lastCallback2 = callback2
    end
    emu.frameadvance()
end
