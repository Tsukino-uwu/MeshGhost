-- MeshGhost — Pokémon Emerald: pick gObjectEvents by walking, for a build whose save block is lost (dev tool,
-- read-only, holds the D-pad, never shipped). Walks LEG tiles out and back on each axis, never turning a corner, so
-- start where straight lines are clear; a candidate slot that moves exactly one tile per step on the right axis wins.
-- Two winners are reported as ambiguous, never resolved by preferring one.

local CANDIDATES = { -- the six survivors on EX SPEEDCHOICE 0.4.0
    0x02025790, 0x02029308, 0x02029350, 0x02029374, 0x020293BC, 0x02037FD0,
}
local OBJECTEVENT_SIZE = 0x24
local SLOTS = 4          -- the player is slot 0 on five candidates and slot 1 on one of them
local STEP_FRAMES = 22   -- one tile at walking pace, with margin
local LEG = 4            -- tiles out, then the same back

local SCRIPT_DIR = (function()
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
    end
    return "."
end)()

local function say(line)
    console.log(line)
    local f = io.open(SCRIPT_DIR .. "/objevents_walk_probe.log", "a")
    if f then f:write(line, "\n") f:close() end
end

local function sample()
    local out = {}
    for ci, base in ipairs(CANDIDATES) do
        out[ci] = {}
        for slot = 0, SLOTS - 1 do
            local a = base + slot * OBJECTEVENT_SIZE
            out[ci][slot] = {
                memory.read_s16_le(a + 0x10),
                memory.read_s16_le(a + 0x12),
            }
        end
    end
    return out
end

local PLAN = {}
for _ = 1, LEG do PLAN[#PLAN + 1] = "Right" end
for _ = 1, LEG do PLAN[#PLAN + 1] = "Left" end
for _ = 1, LEG do PLAN[#PLAN + 1] = "Down" end
for _ = 1, LEG do PLAN[#PLAN + 1] = "Up" end

local frame, stepIndex, pressing = 0, 0, nil
local before, legStart
local score = {}          -- [candidate][slot] = agreements
local checked = 0
local finished = false

for ci = 1, #CANDIDATES do
    score[ci] = {}
    for slot = 0, SLOTS - 1 do score[ci][slot] = 0 end
end

local function judgeStep(dir, a, b)
    local wantX = (dir == "Right" and 1) or (dir == "Left" and -1) or 0
    local wantY = (dir == "Down" and 1) or (dir == "Up" and -1) or 0
    checked = checked + 1
    for ci = 1, #CANDIDATES do
        for slot = 0, SLOTS - 1 do
            local dx = b[ci][slot][1] - a[ci][slot][1]
            local dy = b[ci][slot][2] - a[ci][slot][2]
            if dx == wantX and dy == wantY then
                score[ci][slot] = score[ci][slot] + 1
            end
        end
    end
end

local function report()
    say("=== gObjectEvents BY WALKING " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===")
    say(string.format("  %d steps judged (%d per axis, out and back on each)", checked, LEG))
    local winners = {}
    for ci, base in ipairs(CANDIDATES) do
        for slot = 0, SLOTS - 1 do
            local n = score[ci][slot]
            if n > 0 then
                say(string.format("  %08X slot %d : tracked %d/%d steps%s",
                    base, slot, n, checked, (n == checked) and "   <== EVERY STEP" or ""))
            end
            if n == checked and checked > 0 then
                winners[#winners + 1] = { base = base, slot = slot }
            end
        end
    end
    if #winners == 1 then
        say(string.format("  RESOLVED: gObjectEvents = %08X, player at slot %d",
            winners[1].base, winners[1].slot))
        say(string.format("  shift vs vanilla 0x02037350 = %+d (0x%X)",
            winners[1].base - 0x02037350, winners[1].base - 0x02037350))
    elseif #winners == 0 then
        say("  UNRESOLVED: nothing tracked every step. If the player did not actually move "
            .. "(a wall, an NPC, a menu), that is the reason -- stand somewhere open and re-run.")
    else
        say("  AMBIGUOUS: " .. #winners .. " candidates tracked every step. NOT choosing one. "
            .. "A longer walk, or a different starting tile, separates copies from the original.")
    end
end

local function tick()
    if finished then return end
    frame = frame + 1

    -- settle before the first step so the first sample is not taken mid-animation
    if frame < 30 then return end

    local phase = (frame - 30) % STEP_FRAMES
    if phase == 0 then
        if stepIndex > 0 then
            judgeStep(PLAN[stepIndex], before, sample())
        end
        stepIndex = stepIndex + 1
        if stepIndex > #PLAN then
            finished = true
            joypad.set({ Right = false, Left = false, Up = false, Down = false })
            report()
            return
        end
        before = sample()
        pressing = PLAN[stepIndex]
    end
    -- hold the direction for most of the step, release before sampling
    if pressing and phase < STEP_FRAMES - 6 then
        joypad.set({ [pressing] = true })
    else
        joypad.set({ Right = false, Left = false, Up = false, Down = false })
    end
end

MESHGHOST_DEV_UNLOAD = function()
    joypad.set({ Right = false, Left = false, Up = false, Down = false })
    console.log("MeshGhost DEV: objevents_walk_probe unloaded; D-pad released.")
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
else
    while true do tick() emu.frameadvance() end
end
