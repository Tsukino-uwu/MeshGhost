-- MeshGhost — Emerald: which gObjectEvents candidate is the real one? (PROBE)
--
-- READ-ONLY. Reads game memory, writes none, presses nothing, draws nothing.
--
-- THE QUESTION. `romvariant_probe.lua` resolves anchors by structural search and, on SPEEDCHOICE
-- 1.2.2, left gObjectEvents AMBIGUOUS with six survivors -- correctly, because it never picks one
-- of several. This probe decides between them using a fact that probe did not have: on this build
-- gSaveBlock1Ptr WORKS, so the player's true tile is known independently.
--
-- THE TEST. A map object's x/y (struct ObjectEvent +0x10/+0x12) is the save-block tile plus the
-- map border offset of 7. So the real gObjectEvents is the candidate whose player slot agrees with
-- the save block on BOTH axes. A wrong array agreeing by luck on one axis is plausible; agreeing
-- on both, at a position the player can then be walked to change, is not.
--
-- It also prints the DELTA each candidate would need, so a near-miss (a different border constant,
-- a different struct size) is visible as a small consistent number rather than being reported as a
-- failure.
--
-- WHAT IT CANNOT SEE: whether the array it picks is gObjectEvents rather than some other array of
-- the same shape holding the same numbers. The confirmation for that is movement -- walk, re-run,
-- and the agreement must hold. It says so in its own output rather than implying certainty.

local CANDIDATES = {
    0x02024B7C, 0x020286F0, 0x02028738, 0x0202875C, 0x020287A4, 0x020373F4,
}
local OBJECTEVENT_SIZE = 0x24
local MAP_OFFSET = 7

local SCRIPT_DIR = (function()
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
    end
    return "."
end)()

local function say(line)
    console.log(line)
    local f = io.open(SCRIPT_DIR .. "/objevents_pick_probe.log", "a")
    if f then f:write(line, "\n") f:close() end
end

local done = false

local function tick()
    if done then return end
    done = true

    local sb1 = memory.read_u32_le(0x03005d8c)
    if sb1 < 0x02000000 or sb1 >= 0x02040000 then
        say("gSaveBlock1Ptr is not EWRAM (" .. string.format("%08X", sb1)
            .. ") -- this probe needs it and cannot run on this build.")
        return
    end
    local px = memory.read_s16_le(sb1)
    local py = memory.read_s16_le(sb1 + 2)
    local wantX, wantY = px + MAP_OFFSET, py + MAP_OFFSET

    say("=== gObjectEvents CANDIDATES " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===")
    say(string.format("  game code %s%s%s%s, save-block tile (%d,%d) -> expecting object coords (%d,%d)",
        string.char(memory.read_u8(0x080000AC)), string.char(memory.read_u8(0x080000AD)),
        string.char(memory.read_u8(0x080000AE)), string.char(memory.read_u8(0x080000AF)),
        px, py, wantX, wantY))

    for _, base in ipairs(CANDIDATES) do
        -- Slot 0 is the player on every build measured so far; slots 1..3 are printed too because
        -- one candidate in the earlier search had the player at index 1.
        local best
        for slot = 0, 3 do
            local a = base + slot * OBJECTEVENT_SIZE
            local x = memory.read_s16_le(a + 0x10)
            local y = memory.read_s16_le(a + 0x12)
            local dx, dy = x - wantX, y - wantY
            local line = string.format("      slot %d: coords=(%d,%d) delta=(%+d,%+d)%s",
                slot, x, y, dx, dy, (dx == 0 and dy == 0) and "   <== MATCHES" or "")
            if dx == 0 and dy == 0 then best = slot end
            say(line)
        end
        say(string.format("  %08X : %s", base,
            best and ("player looks like slot " .. best) or "no slot agrees"))
    end
    say("  A match here is a CANDIDATE, not a confirmation: walk a few tiles and re-run, and the")
    say("  agreement must survive. An array of the right shape can hold the right numbers once.")
end

MESHGHOST_DEV_UNLOAD = function() end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
else
    while true do tick() emu.frameadvance() end
end
