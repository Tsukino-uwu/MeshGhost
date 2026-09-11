-- MeshGhost — Emerald: which of two save-block pointer candidates is gSaveBlock1Ptr? (PROBE)
--
-- READ-ONLY. Reads game memory, writes none, presses nothing, draws nothing.
--
-- THE QUESTION. `saveblock_find_probe.lua` left EX SPEEDCHOICE with two IWRAM slots that both hold
-- the player's save block and both tracked it through six steps -- 0x03004CAC and 0x03005158,
-- pointing at the SAME struct. For reading a tile either would do, but the adapter also reads
-- gSaveBlock2Ptr (the player's gender lives there), and in vanilla the two sit ADJACENT:
-- gSaveBlock1Ptr 0x03005D8C, gSaveBlock2Ptr 0x03005D90. So the candidate with a second, DIFFERENT
-- EWRAM pointer immediately after it is the one in the real pair.
--
-- It prints the words either side of both candidates rather than just the verdict, because "the
-- next word is also a pointer" is weak on its own -- IWRAM is full of pointers - and a person
-- reading the dump can see whether the neighbourhood looks like the vanilla one.

local CANDIDATES = { 0x03004CAC, 0x03005158 }

local SCRIPT_DIR = (function()
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
    end
    return "."
end)()

local function say(line)
    console.log(line)
    local f = io.open(SCRIPT_DIR .. "/saveblock_pair_probe.log", "a")
    if f then f:write(line, "\n") f:close() end
end

local done = false

local function tick()
    if done then return end
    done = true
    say("=== SAVE BLOCK PAIR " .. os.date("%H:%M:%S") .. " ===")
    say("  vanilla for reference: gSaveBlock1Ptr 0x03005D8C, gSaveBlock2Ptr 0x03005D90 (adjacent)")
    for _, c in ipairs(CANDIDATES) do
        say(string.format("  candidate %08X:", c))
        for d = -8, 12, 4 do
            local a = c + d
            local v = memory.read_u32_le(a)
            local tag = ""
            if v >= 0x02000000 and v < 0x02040000 then
                -- a pointer into EWRAM: say what the first two halfwords there look like, which is
                -- how SaveBlock1 (x,y) and SaveBlock2 (name bytes) tell themselves apart
                tag = string.format("  -> EWRAM, first words %04X %04X",
                    memory.read_u16_le(v), memory.read_u16_le(v + 2))
            end
            say(string.format("    %+3d  %08X = %08X%s", d, a, v, tag))
        end
    end
    say("  The pair is the candidate followed by a DIFFERENT EWRAM pointer at +4.")
end

MESHGHOST_DEV_UNLOAD = function() end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
else
    while true do tick() emu.frameadvance() end
end
