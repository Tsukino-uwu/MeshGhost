-- Read-only: finds where gObjectEvents/gPlayerAvatar moved to in EWRAM on an Archipelago ROM. They are runtime
-- structs with nothing to byte-search for in the ROM file, so this tests against known-direction motion: one
-- full EWRAM snapshot per held direction, keeping only addresses whose low nibble reads facingDirection's value
-- (1 down, 3 left, 2 up, 4 right) at every step in order, which needs a real transition to survive.
-- Follow the prompts, and stand still for the whole test: change facing only with brief taps when told.

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

-- Prints a countdown once a second (at 60fps).
local function waitFramesWithCountdown(n)
    local wholeSeconds = math.floor(n / 60)
    local leftoverFrames = n - (wholeSeconds * 60)
    for s = wholeSeconds, 1, -1 do
        console.log(string.format("  %d...", s))
        waitFrames(60)
    end
    waitFrames(leftoverFrames)
end

-- Spread across `frames` frames so a 256K-read burst does not stall the emulator.
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

-- nil: the first phase checks all of EWRAM.
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
