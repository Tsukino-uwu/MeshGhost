-- Read-only: which of two save-block pointer candidates is gSaveBlock1Ptr? Both point at the same struct, but in
-- vanilla gSaveBlock2Ptr (the gender lives there) sits at +4, so the candidate followed by a different EWRAM
-- pointer is the real pair. It prints the words either side rather than a verdict, as IWRAM is full of pointers.

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
                -- a pointer into EWRAM: its first two halfwords tell SaveBlock1 (x,y) from SaveBlock2 (name bytes)
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
