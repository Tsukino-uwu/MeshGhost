-- MeshGhost — Emerald: find gTotalCameraPixelOffset on a build that moved IWRAM (PROBE)
--
-- READ-ONLY. Reads game memory, writes none, presses nothing, draws nothing.
--
-- THE QUESTION. EX SPEEDCHOICE 0.4.0 has every other anchor measured and still renders no peers:
-- its player's tile and sprite read correctly and steadily, but camOff reads garbage that changes
-- every frame -- (-1,513), then (4879,257), then (-1030,-1286). The painted tier positions peers
-- against that pair, so every one of them lands off-screen.
--
-- THE TEST, and it needs no known address. The local player is drawn at the centre of its own
-- screen, and the adapter's own arithmetic says how: sprite.x + cameraOffsetX = screen x. Vanilla
-- reads sprite (168,112) with camOff (-48,0) and lands on (120,112); SPEEDCHOICE reads (24,144)
-- with (96,-32) and lands on the same place. So on any build the true offsets are
--
--     wantX = 120 - sprite.x        wantY = 112 - sprite.y
--
-- Scan IWRAM for that exact s16 pair, laid out as vanilla lays it out: Y first, X four bytes later
-- (gTotalCameraPixelOffsetY 0x03005DE8, gTotalCameraPixelOffsetX 0x03005DEC).
--
-- THEN IT WALKS, because a pair of numbers that happens to match once is not an address. The
-- player moves and the candidate must keep satisfying sprite + offset = centre at every step.
-- Straight lines only, out and back on one axis, per the user's constraint for this savestate.
--
-- WHAT IT CANNOT SEE: whether the pair it finds is gTotalCameraPixelOffset rather than something
-- that tracks it. Two survivors are reported as AMBIGUOUS rather than resolved by preferring the
-- lower address.

local IWRAM_START, IWRAM_END = 0x03000000, 0x03008000
local GOBJECTEVENTS_ADDR = 0x02037350
local GPLAYERAVATAR_ADDR = 0x02037590
local GSPRITES_ADDR = 0x02020630
local SHIFTS = { { 0, 0 }, { 0x284, 0 }, { 0xA4, 0x4 }, { 0xC80, 0x20 } } -- {objects, sprites}
local OBJECTEVENT_SIZE, SPRITE_SIZE = 0x24, 0x44
local CENTRE_X, CENTRE_Y = 120, 112
local STEP_FRAMES, LEG = 22, 3

local SCRIPT_DIR = (function()
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
    end
    return "."
end)()

local function say(line)
    console.log(line)
    local f = io.open(SCRIPT_DIR .. "/camoffset_find_probe.log", "a")
    if f then f:write(line, "\n") f:close() end
end

local objShift, sprShift

local function detect()
    for _, pair in ipairs(SHIFTS) do
        local a = GOBJECTEVENTS_ADDR + pair[1]
        local x = memory.read_s16_le(a + 0x10)
        local y = memory.read_s16_le(a + 0x12)
        if x > 0 and y > 0 and x < 400 and y < 400 then return pair[1], pair[2] end
    end
end

local function playerSprite()
    local pObjId = memory.read_u8(GPLAYERAVATAR_ADDR + objShift + 0x05)
    local pa = GOBJECTEVENTS_ADDR + objShift + pObjId * OBJECTEVENT_SIZE
    local sid = memory.read_u8(pa + 0x04)
    local sa = GSPRITES_ADDR + sprShift + sid * SPRITE_SIZE
    return memory.read_s16_le(sa + 0x20), memory.read_s16_le(sa + 0x22)
end

local function scan(wantY, wantX)
    local out = {}
    -- the Y slot is the anchor; X sits four bytes later, as in vanilla
    for a = IWRAM_START, IWRAM_END - 8, 2 do
        if memory.read_s16_le(a) == wantY and memory.read_s16_le(a + 4) == wantX then
            out[#out + 1] = a
        end
    end
    return out
end

local frame, stepIndex, pressing, cands, finished = 0, 0, nil, nil, false
local PLAN = {}
for _ = 1, LEG do PLAN[#PLAN + 1] = "Down" end
for _ = 1, LEG do PLAN[#PLAN + 1] = "Up" end

local function tick()
    if finished then return end
    frame = frame + 1
    if frame < 30 then return end

    if not cands then
        objShift, sprShift = detect()
        if not objShift then
            if frame % 120 == 0 then say("waiting: no plausible gObjectEvents base") end
            return
        end
        local sx, sy = playerSprite()
        say("=== gTotalCameraPixelOffset SEARCH " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===")
        say(string.format("  objects +0x%X, sprites +0x%X, player sprite (%d,%d)",
            objShift, sprShift, sx, sy))
        say(string.format("  so the offsets must be X=%d Y=%d (sprite + offset = screen centre %d,%d)",
            CENTRE_X - sx, CENTRE_Y - sy, CENTRE_X, CENTRE_Y))
        cands = scan(CENTRE_Y - sy, CENTRE_X - sx)
        say(string.format("  IWRAM slots holding that pair (Y at +0, X at +4): %d", #cands))
        for _, a in ipairs(cands) do
            say(string.format("    Y %08X = %d, X %08X = %d", a, memory.read_s16_le(a),
                a + 4, memory.read_s16_le(a + 4)))
        end
        if #cands == 0 then
            say("  UNRESOLVED: no pair matched. Either the layout differs, or the player is not")
            say("  centred right now (mid-step, or the camera is clamped at a map edge).")
            finished = true
        end
        return
    end

    local phase = (frame - 30) % STEP_FRAMES
    if phase == 0 then
        if stepIndex > 0 then
            local sx, sy = playerSprite()
            local wantY, wantX = CENTRE_Y - sy, CENTRE_X - sx
            local kept = {}
            for _, a in ipairs(cands) do
                if memory.read_s16_le(a) == wantY and memory.read_s16_le(a + 4) == wantX then
                    kept[#kept + 1] = a
                end
            end
            say(string.format("    after step %d (%s): %d of %d still centre the player",
                stepIndex, PLAN[stepIndex], #kept, #cands))
            cands = kept
        end
        stepIndex = stepIndex + 1
        if stepIndex > #PLAN or #cands == 0 then
            finished = true
            joypad.set({ Up = false, Down = false })
            if #cands == 1 then
                local a = cands[1]
                say(string.format("  RESOLVED: gTotalCameraPixelOffsetY = %08X, X = %08X", a, a + 4))
                say(string.format("  vanilla Y 0x03005DE8 -> shift %+d (0x%X)",
                    a - 0x03005DE8, math.abs(a - 0x03005DE8)))
            elseif #cands == 0 then
                say("  UNRESOLVED: nothing kept centring the player once it moved.")
            else
                say("  AMBIGUOUS: " .. #cands .. " survived. NOT choosing one.")
                for _, a in ipairs(cands) do say(string.format("    %08X", a)) end
            end
            return
        end
        pressing = PLAN[stepIndex]
    end
    if pressing and phase < STEP_FRAMES - 6 then
        joypad.set({ [pressing] = true })
    else
        joypad.set({ Up = false, Down = false })
    end
end

MESHGHOST_DEV_UNLOAD = function()
    joypad.set({ Up = false, Down = false })
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
else
    while true do tick() emu.frameadvance() end
end
