-- Dev-only diagnostic to find gObjectEvents/gPlayerAvatar's new EWRAM location on an
-- Archipelago-patched ROM. Read-only, never writes memory.
--
-- WHY THIS EXISTS: playerScreenPos() (meshghost_emerald.lua) and this project's own facing
-- decode both depend on gObjectEvents (0x02037350 vanilla) and gPlayerAvatar (0x02037590
-- vanilla, immediately after gObjectEvents -- 16 * 0x24 = 0x240 bytes later, same
-- pokeemerald.map/.sym build cited in phase1_probe.lua's header). Both already confirmed
-- reading frozen garbage under Archipelago (agent_docs/verified.md, 2026-08-11, reproduced on a
-- second seed 2026-08-14). Unlike the sprite/palette ROM data (fixed content, found by
-- byte-searching the ROM FILE directly -- see meshghost_emerald.lua's
-- SPRITE_ADDR_ARCHIPELAGO_SHIFT), gObjectEvents/gPlayerAvatar are RUNTIME EWRAM structs with no
-- fixed content to search for in the ROM file -- so this uses the same live "known-direction
-- motion" methodology Phase 1 originally used to find these addresses on vanilla in the first
-- place (agent_docs/pitfalls.md's "memory probing methodology"), automated into a full-EWRAM
-- scan instead of checking one hand-picked address.
--
-- METHOD (v2 -- rewritten after v1's continuous background scan failed): struct ObjectEvent's
-- facingDirection field (pokeemerald: include/global.fieldmap.h, "+0x18 facingDirection u16:4
-- (low 4 bits)") only ever holds DIR_SOUTH=1 (down), DIR_NORTH=2 (up), DIR_WEST=3 (left), or
-- DIR_EAST=4 (right) (constants/global.h). v1 tried a continuous background scan keeping any
-- byte that never left the 1-4 range, then a stability-duration filter on top of that -- both
-- failed for the same underlying reason: EWRAM is mostly quiescent during any idle stretch, so
-- huge numbers of unrelated bytes look "stable" or "always in range" simultaneously, and
-- neither filter meaningfully narrows the ~22000-candidate pool. This version is scripted
-- instead of open-ended: it tells you exactly when to press each direction, takes one full
-- EWRAM snapshot during each hold, and keeps only addresses that hit the EXACT expected value
-- at EVERY one of the four steps, in order -- 1 during down, then 3 during left, then 2 during
-- up, then 4 during right. Since a candidate can't be 1 and 3 at once, surviving from one phase
-- to the next already requires a real value transition, not just a plausible snapshot.
--
-- HOW TO USE: just follow the on-screen prompts. Stand still (no tile movement) for the whole
-- test -- only change facing via brief directional taps when told to.

local EWRAM_BASE = 0x02000000
local EWRAM_SIZE = 0x00040000 -- 256KB
local SNAPSHOT_FRAMES = 180 -- ~3s to capture a full EWRAM snapshot, spread out to avoid a stutter
local COUNTDOWN_FRAMES = 300 -- ~5s to get ready before each capture
local REACT_FRAMES = 240 -- ~4s to actually press and settle into holding the direction, after the prompt

if not memory.usememorydomain("System Bus") then
    console.log("ERROR: 'System Bus' memory domain not found on this core.")
    console.log("Domains available: " .. memory.getmemorydomainlist())
    return
end

console.log("=== MeshGhost avatar-scan probe (scripted snapshot-diff) ===")
console.log("Read-only, never writes memory. Stand still (no tile movement) for the whole test.")
console.log(string.format("Vanilla reference: gObjectEvents=0x%08X, gPlayerAvatar=0x%08X (0x240 after)",
    0x02037350, 0x02037590))

local function waitFrames(n)
    for _ = 1, n do
        emu.frameadvance()
    end
end

-- Same wait, but prints a countdown once per second (assuming 60fps) so you can see it coming
-- instead of guessing at the timing.
local function waitFramesWithCountdown(n)
    local wholeSeconds = math.floor(n / 60)
    local leftoverFrames = n - (wholeSeconds * 60)
    for s = wholeSeconds, 1, -1 do
        console.log(string.format("  %d...", s))
        waitFrames(60)
    end
    waitFrames(leftoverFrames)
end

-- Captures every byte in EWRAM into a plain Lua array (0-indexed by offset), spread across
-- `frames` frames so this doesn't stall the emulator for a full 256K-read burst in one go.
local function takeSnapshot(frames)
    local snap = {}
    local bytesPerFrame = math.ceil(EWRAM_SIZE / frames)
    local cursor = 0
    for _ = 1, frames do
        for _ = 1, bytesPerFrame do
            if cursor >= EWRAM_SIZE then break end
            snap[cursor] = memory.read_u8(EWRAM_BASE + cursor)
            cursor = cursor + 1
        end
        emu.frameadvance()
    end
    while cursor < EWRAM_SIZE do
        snap[cursor] = memory.read_u8(EWRAM_BASE + cursor)
        cursor = cursor + 1
    end
    return snap
end

local function countSurvivors(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local PHASES = {
    { label = "DOWN",  expected = 1 },
    { label = "LEFT",  expected = 3 },
    { label = "UP",    expected = 2 },
    { label = "RIGHT", expected = 4 },
}

console.log("Get ready. Do not touch any direction buttons yet.")
waitFramesWithCountdown(COUNTDOWN_FRAMES)

-- survivors == nil means "phase 1, check all of EWRAM"; afterward it's the shrinking set of
-- offsets that matched every prior phase.
local survivors = nil

for _, phase in ipairs(PHASES) do
    console.log(string.format(">>> Press and HOLD %s now. Keep holding through the capture.", phase.label))
    waitFramesWithCountdown(REACT_FRAMES)
    console.log("Capturing now (keep holding, don't release yet)...")
    local snap = takeSnapshot(SNAPSHOT_FRAMES)

    local matched = {}
    if survivors == nil then
        for offset = 0, EWRAM_SIZE - 1 do
            if (snap[offset] & 0xF) == phase.expected then
                matched[offset] = true
            end
        end
    else
        for offset in pairs(survivors) do
            if (snap[offset] & 0xF) == phase.expected then
                matched[offset] = true
            end
        end
    end
    survivors = matched

    console.log(string.format("Capture done. %d candidates match every step so far. You can release %s.",
        countSurvivors(survivors), phase.label))
    waitFrames(120)
end

console.log("=== Final candidates: matched down(1) -> left(3) -> up(2) -> right(4), in order ===")
local finalList = {}
for offset in pairs(survivors) do
    table.insert(finalList, offset)
end
table.sort(finalList)
if #finalList == 0 then
    console.log("  (none survived -- see the header comment for what to try differently)")
else
    for _, offset in ipairs(finalList) do
        console.log(string.format("  0x%08X", EWRAM_BASE + offset))
    end
    console.log("If this is ObjectEvent.facingDirection (+0x18 within a 0x24-byte entry), the")
    console.log("entry's own base address is (candidate - 0x18), and gObjectEvents[0] is that")
    console.log("minus (objEventId * 0x24) -- objEventId itself is unconfirmed on this ROM too.")
end
console.log(string.format("Vanilla reference: gObjectEvents=0x%08X, gPlayerAvatar=0x%08X (0x240 after)",
    0x02037350, 0x02037590))
console.log("Done. This probe does not loop -- reload it to run again.")
