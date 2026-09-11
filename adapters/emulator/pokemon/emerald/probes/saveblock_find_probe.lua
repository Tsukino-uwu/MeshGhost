-- MeshGhost — Emerald: find gSaveBlock1Ptr on a build that moved IWRAM (PROBE)
--
-- READ-ONLY. Reads game memory, writes none, presses nothing, draws nothing.
--
-- THE QUESTION. EX SPEEDCHOICE 0.4.0 relocated IWRAM: 0x03005D8C reads FDFDFFFF, which is not a
-- pointer, so the adapter cannot read the player's tile or the map it is on -- `inGame=false`,
-- `local=nil`, nothing sent and nothing drawn. `romvariant_probe.lua` reported this anchor
-- UNRESOLVED and said why: its search needs gObjectEvents resolved first, and at the time it was
-- not. It is now (+0xC80, by objevents_walk_probe.lua), which makes the search possible.
--
-- THE TEST. gSaveBlock1Ptr is a POINTER IN IWRAM to a struct in EWRAM whose first four bytes are
-- the player's x and y as s16 -- and a map object's coordinates are that same tile plus the map
-- border offset of 7. So: walk every word-aligned IWRAM slot, keep the ones holding a plausible
-- EWRAM address, and of those keep the ones where the target's x/y are exactly the player object's
-- minus 7. Both axes, which a coincidence rarely manages.
--
-- THEN IT WALKS. A match is a candidate until it MOVES with the player: the probe steps one axis
-- and requires every surviving candidate to follow. That is the same discipline gsprites_scan_probe
-- uses, and it is what separates the real pointer from a stale copy of it -- Emerald keeps more
-- than one save block in memory.
--
-- The user's constraint is respected (2026-09-11): straight lines only, out and back on one axis,
-- never turning a corner.

local IWRAM_START, IWRAM_END = 0x03000000, 0x03008000
local EWRAM_START, EWRAM_END = 0x02000000, 0x02040000
local GOBJECTEVENTS_ADDR = 0x02037350
local SHIFTS = { 0, 0x284, 0xA4, 0xC80 }
local OBJECTEVENT_SIZE = 0x24
local MAP_OFFSET = 7
local STEP_FRAMES = 22
local LEG = 3

local SCRIPT_DIR = (function()
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
    end
    return "."
end)()

local function say(line)
    console.log(line)
    local f = io.open(SCRIPT_DIR .. "/saveblock_find_probe.log", "a")
    if f then f:write(line, "\n") f:close() end
end

local objBase
local function findObjBase()
    for _, sh in ipairs(SHIFTS) do
        local a = GOBJECTEVENTS_ADDR + sh
        local x = memory.read_s16_le(a + 0x10)
        local y = memory.read_s16_le(a + 0x12)
        if x > 0 and y > 0 and x < 400 and y < 400 then return a, sh end
    end
end

local function playerTile()
    local x = memory.read_s16_le(objBase + 0x10) - MAP_OFFSET
    local y = memory.read_s16_le(objBase + 0x12) - MAP_OFFSET
    return x, y
end

local function scan(wantX, wantY)
    local out = {}
    for a = IWRAM_START, IWRAM_END - 4, 4 do
        local ptr = memory.read_u32_le(a)
        if ptr >= EWRAM_START and ptr < EWRAM_END - 4 then
            if memory.read_s16_le(ptr) == wantX and memory.read_s16_le(ptr + 2) == wantY then
                out[#out + 1] = a
            end
        end
    end
    return out
end

local frame, stepIndex, pressing, cands, finished = 0, 0, nil, nil, false
local PLAN = {}
for _ = 1, LEG do PLAN[#PLAN + 1] = "Right" end
for _ = 1, LEG do PLAN[#PLAN + 1] = "Left" end

local function tick()
    if finished then return end
    frame = frame + 1
    if frame < 30 then return end

    if not objBase then
        local b, sh = findObjBase()
        if not b then
            if frame % 120 == 0 then say("waiting: no plausible gObjectEvents base (be in the overworld)") end
            return
        end
        objBase = b
        local px, py = playerTile()
        say("=== gSaveBlock1Ptr SEARCH " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===")
        say(string.format("  gObjectEvents +0x%X, player tile (%d,%d)", sh, px, py))
        cands = scan(px, py)
        say(string.format("  IWRAM slots whose target holds exactly that tile: %d", #cands))
        for _, a in ipairs(cands) do
            say(string.format("    %08X -> %08X", a, memory.read_u32_le(a)))
        end
        if #cands == 0 then
            say("  UNRESOLVED: nothing matched. No conclusion.")
            finished = true
            return
        end
        say("  STAGE 2: walking one axis; a real pointer's target must follow.")
        return
    end

    local phase = (frame - 30) % STEP_FRAMES
    if phase == 0 then
        if stepIndex > 0 then
            local px, py = playerTile()
            local kept = {}
            for _, a in ipairs(cands) do
                local ptr = memory.read_u32_le(a)
                if ptr >= EWRAM_START and ptr < EWRAM_END - 4
                    and memory.read_s16_le(ptr) == px and memory.read_s16_le(ptr + 2) == py then
                    kept[#kept + 1] = a
                end
            end
            say(string.format("    after step %d (%s) at tile (%d,%d): %d of %d still agree",
                stepIndex, PLAN[stepIndex], px, py, #kept, #cands))
            cands = kept
        end
        stepIndex = stepIndex + 1
        if stepIndex > #PLAN or #cands == 0 then
            finished = true
            joypad.set({ Right = false, Left = false })
            if #cands == 1 then
                say(string.format("  RESOLVED: gSaveBlock1Ptr = %08X (vanilla 0x03005D8C, shift %+d)",
                    cands[1], cands[1] - 0x03005D8C))
            elseif #cands == 0 then
                say("  UNRESOLVED: every candidate stopped agreeing once the player moved.")
            else
                say("  AMBIGUOUS: " .. #cands .. " still agree -- Emerald keeps more than one save "
                    .. "block, so this is expected to need a longer walk. NOT choosing one.")
                for _, a in ipairs(cands) do say(string.format("    %08X", a)) end
            end
            return
        end
        pressing = PLAN[stepIndex]
    end
    if pressing and phase < STEP_FRAMES - 6 then
        joypad.set({ [pressing] = true })
    else
        joypad.set({ Right = false, Left = false })
    end
end

MESHGHOST_DEV_UNLOAD = function()
    joypad.set({ Right = false, Left = false })
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
else
    while true do tick() emu.frameadvance() end
end
