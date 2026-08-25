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
-- Thumb bit: resolved. Rather than pin this down from this probe's own printed hex (never
-- actually forced live here), the shipped adapter (meshghost_emerald.lua:127) simply checks
-- both possibilities -- callback2 == CB2_OVERWORLD_ADDR or callback2 == CB2_OVERWORLD_ADDR + 1
-- -- since either reading correctly identifies "not in battle" and getting it wrong the other
-- way (rejecting a real overworld read) was the only failure mode worth guarding against.

local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
-- Archipelago-recompiled equivalent of CB2_Overworld -- watched live 2026-08-14 via this exact
-- probe against a real .apemerald-patched ROM: 0x080867F1 held steady standing idle, through
-- walking, a route change, and survived a full door-transition round trip (entering AND
-- leaving a house showed the same 0x08086965 -> 0x0813873D -> 0x08086995 warp/fade sequence
-- both directions before settling back to 0x080867F1) -- the same shape vanilla's own
-- CB2_Overworld shows around a warp. See meshghost_emerald.lua's inOverworld() for why this
-- address should hold for every Archipelago Emerald player on the same base-patch version, not
-- just the one seed this was watched on (agent_docs/risks.md's Archipelago-coexistence entry).
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
