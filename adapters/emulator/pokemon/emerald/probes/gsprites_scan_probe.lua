-- MeshGhost — Emerald: find gSprites' EWRAM base on any build, from gObjectEvents alone (dev tool, drives the D-pad).
-- A runtime array cannot be byte-searched in the ROM file. Stand in the overworld with room to walk; it walks back.

local EWRAM_BASE = 0x02000000
local EWRAM_SIZE = 0x00040000

local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local CB2_OVERWORLD_ARCHIPELAGO_ADDR = 0x080867f1

local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local AVATAR_ADDR_ARCHIPELAGO_SHIFT = 0x284
local OBJECTEVENT_SIZE = 0x24
local MAP_GROUPS_COUNT = 34

local SPRITE_SIZE = 0x44
local MAX_SPRITES = 64
local ARRAY_SIZE = SPRITE_SIZE * MAX_SPRITES

-- Only for the report's "re-derived it" line: nothing in the search is seeded with it.
local GSPRITES_VANILLA = 0x02020630

local READS_PER_FRAME = 6000

local logf = io.open((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]*$") or ".")
    .. "/gsprites_scan_probe.log", "a")
local function log(msg)
    console.log(msg)
    if logf then logf:write(os.date("%Y-%m-%d %H:%M:%S "), msg, "\n"); logf:flush() end
end

if not memory.usememorydomain("System Bus") then
    log("ERROR: 'System Bus' memory domain not found on this core.")
    return
end

local function r8(a) return memory.read_u8(a) end
local function r16(a) return memory.read_u16_le(a) end
local function rs16(a) return memory.read_s16_le(a) end

-- The adapter's playerObjEventExistsAt: an object event with isPlayer set, localId 0xFF and a real map group.
local function playerObjEventExistsAt(base)
    for i = 0, 15 do
        local a = base + i * OBJECTEVENT_SIZE
        -- isPlayer is bit 0 of +0x02, not the active byte: the wrong byte finds the player only mid-step.
        if (r8(a + 0x02) & 0x01) == 1
            and r8(a + 0x08) == 0xff and r8(a + 0x0a) < MAP_GROUPS_COUNT then
            return true
        end
    end
    return false
end

local avatarOffset = nil
local objBase, avatarBase

local function activeObjects()
    local list = {}
    for i = 0, 15 do
        local a = objBase + i * OBJECTEVENT_SIZE
        if (r8(a + 0x00) & 0x01) == 1 then
            list[#list + 1] = { id = i, spriteId = r8(a + 0x04), addr = a }
        end
    end
    return list
end

local phase = "detect"
local frames = 0

-- Stage 1: a base is kept only if every active object event's sprite names it back in data[0], with inUse set.
local primary, others = nil, nil
local scanCursor, candidates = 0, nil
local filterList = nil

-- Stage 2: the player walks both axes, and a base's sprite must track it at 16 px a tile, at rest, every step.
local playerObjAddr, playerObjId
-- Several tries per direction: a blocked step is a fair "did not move" sample, and the verdict rules only after
-- real movement on both axes.
local SEQ = { "Left", "Up", "Left", "Up", "Left", "Up",
              "Right", "Down", "Right", "Down", "Right", "Down" }
local seqIndex, stepFrames, samples = 1, 0, {}

local HOLD_FRAMES = 34   -- one tile is ~16 frames; this covers a turn-in-place plus a step
local SETTLE_FRAMES = 40 -- released, standing still, camera at rest before sampling

local function fail(msg)
    log("RESULT: NOT MEASURED -- " .. msg)
    phase = "done"
end

-- A wild encounter, a warp or a menu reuses the sprite slots, and a sample taken after one is no evidence either way.
local function stillOverworld()
    local cb2 = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    -- 0x080864D4 is SPEEDCHOICE 1.2.2's CB2_Overworld. A reading that is not a code pointer means gMain moved on this
    -- build (EX SPEEDCHOICE): the test is unavailable, not failed, so the live player object event decides.
    if cb2 >= 0x08000000 and cb2 < 0x0A000000
        and cb2 ~= CB2_OVERWORLD_ADDR and cb2 ~= CB2_OVERWORLD_ADDR + 1
        and cb2 ~= CB2_OVERWORLD_ARCHIPELAGO_ADDR
        and cb2 ~= CB2_OVERWORLD_ARCHIPELAGO_ADDR + 1
        and cb2 ~= 0x080864d4 and cb2 ~= 0x080864d5 then
        return false
    end
    if not playerObjEventExistsAt(objBase) then return false end
    if r8(avatarBase + 0x05) ~= playerObjId then return false end
    local sprId = r8(avatarBase + 0x04)
    for _, b in ipairs(filterList) do
        if rs16(b + sprId * SPRITE_SIZE + 0x2e) ~= playerObjId then return false end
    end
    return true
end

local function sampleNow()
    local s = { objX = rs16(playerObjAddr + 0x10), objY = rs16(playerObjAddr + 0x12),
                sprId = r8(avatarBase + 0x04), cand = {} }
    for _, b in ipairs(filterList) do
        local a = b + s.sprId * SPRITE_SIZE
        s.cand[b] = { x = rs16(a + 0x20), y = rs16(a + 0x22) }
    end
    samples[#samples + 1] = s
    return s
end

MESHGHOST_DEV_TICK = function()
    frames = frames + 1

    if phase == "detect" then
        if frames % 30 ~= 0 then return end
        if playerObjEventExistsAt(GOBJECTEVENTS_ADDR) then
            avatarOffset = 0
        elseif playerObjEventExistsAt(GOBJECTEVENTS_ADDR + AVATAR_ADDR_ARCHIPELAGO_SHIFT) then
            avatarOffset = AVATAR_ADDR_ARCHIPELAGO_SHIFT
        -- SPEEDCHOICE 1.2.2
        elseif playerObjEventExistsAt(GOBJECTEVENTS_ADDR + 0xA4) then
            avatarOffset = 0xA4
        -- EX SPEEDCHOICE 0.4.0
        elseif playerObjEventExistsAt(GOBJECTEVENTS_ADDR + 0xC80) then
            avatarOffset = 0xC80
        else
            if frames % 300 == 0 then
                log("waiting: no player object event at either known gObjectEvents base "
                    .. "(be in the overworld)")
            end
            return
        end
        objBase = GOBJECTEVENTS_ADDR + avatarOffset
        avatarBase = GPLAYERAVATAR_ADDR + avatarOffset
        playerObjId = r8(avatarBase + 0x05)
        playerObjAddr = objBase + playerObjId * OBJECTEVENT_SIZE
        log("=== MeshGhost gSprites scan probe ===")
        log(string.format("gObjectEvents=0x%08X gPlayerAvatar=0x%08X (offset 0x%X, detected)",
            objBase, avatarBase, avatarOffset))

        local objs = activeObjects()
        local usable = {}
        for _, o in ipairs(objs) do
            if o.spriteId < MAX_SPRITES then usable[#usable + 1] = o end
        end
        if #usable == 0 then fail("no usable active object events"); return end
        log(string.format("%d active object events; using %d as constraints:", #objs, #usable))
        for _, o in ipairs(usable) do
            log(string.format("   objectEvent[%d].spriteId = %d", o.id, o.spriteId))
        end
        -- The primary is the constraint that filters hardest in one pass: the largest id, since
        -- data[0] == 0 is the commonest value in EWRAM and the player is usually id 0.
        table.sort(usable, function(a, b) return a.id > b.id end)
        primary = usable[1]
        others = {}
        for i = 2, #usable do others[#others + 1] = usable[i] end
        candidates = {}
        scanCursor = 0
        phase = "scan"
        log(string.format("scanning EWRAM for sprite[%d].data[0] == %d ...",
            primary.spriteId, primary.id))
        return
    end

    if phase == "scan" then
        -- The field read is at B + spriteId*0x44 + 0x2E, so addresses are walked and converted back to a base.
        local delta = primary.spriteId * SPRITE_SIZE + 0x2e
        local limit = EWRAM_SIZE - ARRAY_SIZE
        local n = 0
        while scanCursor <= limit and n < READS_PER_FRAME do
            if r16(EWRAM_BASE + scanCursor + delta) == primary.id then
                candidates[#candidates + 1] = EWRAM_BASE + scanCursor
            end
            scanCursor = scanCursor + 4
            n = n + 1
        end
        if scanCursor > limit then
            log(string.format("scan done: %d bases match the primary cross-link", #candidates))
            filterList = candidates
            phase = "filter"
        end
        return
    end

    if phase == "filter" then
        local kept = {}
        for _, b in ipairs(filterList) do
            local ok = (r8(b + primary.spriteId * SPRITE_SIZE + 0x3e) & 0x01) == 1
            if ok then
                for _, o in ipairs(others) do
                    local a = b + o.spriteId * SPRITE_SIZE
                    if rs16(a + 0x2e) ~= o.id or (r8(a + 0x3e) & 0x01) ~= 1 then
                        ok = false
                        break
                    end
                end
            end
            if ok then kept[#kept + 1] = b end
        end
        filterList = kept
        log(string.format("after every cross-link + inUse constraint: %d base(s)", #kept))
        for _, b in ipairs(kept) do log(string.format("   candidate 0x%08X", b)) end
        if #kept == 0 then
            fail("no base satisfies the object/sprite cross-links; the struct assumptions or the "
                .. "map state are wrong")
            return
        end
        log("STAGE 2: walking the player to see which candidate actually tracks it.")
        sampleNow()
        seqIndex, stepFrames = 1, 0
        phase = "walk"
        return
    end

    if phase == "walk" then
        stepFrames = stepFrames + 1
        if stepFrames <= HOLD_FRAMES then
            -- No controller index: BizHawk's GBA core silently ignores joypad.set(t, 1).
            joypad.set({ [SEQ[seqIndex]] = true })
            return
        end
        if stepFrames < HOLD_FRAMES + SETTLE_FRAMES then return end
        if not stillOverworld() then
            -- Every sample so far was taken while this check passed, so end the walk here rather than discard the run.
            log("the game left the overworld (a wild encounter, a warp or a menu) -- ending the "
                .. "walk here and judging on the " .. #samples .. " samples taken before it.")
            phase = "verdict"
            return
        end
        local s = sampleNow()
        log(string.format("  step %2d (%-5s): player obj coords = (%d,%d), spriteId=%d",
            seqIndex, SEQ[seqIndex], s.objX, s.objY, s.sprId))
        stepFrames = 0
        seqIndex = seqIndex + 1
        if seqIndex > #SEQ then phase = "verdict" end
        return
    end

    if phase == "verdict" then
        phase = "done"
        local movedX, movedY = 0, 0
        for i = 2, #samples do
            if samples[i].objX ~= samples[i - 1].objX then movedX = movedX + 1 end
            if samples[i].objY ~= samples[i - 1].objY then movedY = movedY + 1 end
        end
        log(string.format("the player actually moved on %d x-steps and %d y-steps", movedX, movedY))
        if movedX < 2 or movedY < 2 then
            fail("the player did not walk far enough in both axes -- stand somewhere open and "
                .. "run it again. No conclusion may be drawn from this run.")
            return
        end
        local winners = {}
        for _, b in ipairs(filterList) do
            local ok, sgnX, sgnY = true, nil, nil
            for i = 2, #samples do
                local dObjX = samples[i].objX - samples[i - 1].objX
                local dObjY = samples[i].objY - samples[i - 1].objY
                local dSx = samples[i].cand[b].x - samples[i - 1].cand[b].x
                local dSy = samples[i].cand[b].y - samples[i - 1].cand[b].y
                if dObjX == 0 then
                    if dSx ~= 0 then ok = false end
                elseif math.abs(dSx) ~= 16 * math.abs(dObjX) then
                    ok = false
                else
                    local s = dSx // (16 * dObjX)
                    if sgnX and sgnX ~= s then ok = false end
                    sgnX = s
                end
                if dObjY == 0 then
                    if dSy ~= 0 then ok = false end
                elseif math.abs(dSy) ~= 16 * math.abs(dObjY) then
                    ok = false
                else
                    local s = dSy // (16 * dObjY)
                    if sgnY and sgnY ~= s then ok = false end
                    sgnY = s
                end
                if not ok then break end
            end
            if ok then winners[#winners + 1] = { base = b, sgnX = sgnX, sgnY = sgnY } end
        end
        if #winners == 0 then
            fail("a candidate survived the standing-still cross-links but NONE tracked the "
                .. "walking player. That is the classic false positive; the address is not "
                .. "measured.")
            for _, b in ipairs(filterList) do
                local parts = {}
                for i = 1, #samples do
                    parts[#parts + 1] = string.format("(%d,%d|%d,%d)", samples[i].objX,
                        samples[i].objY, samples[i].cand[b].x, samples[i].cand[b].y)
                end
                log(string.format("   0x%08X: %s", b, table.concat(parts, " ")))
            end
            return
        end
        if #winners > 1 then
            fail(string.format("%d candidates tracked the player -- ambiguous, not measured",
                #winners))
            for _, w in ipairs(winners) do log(string.format("   0x%08X", w.base)) end
            return
        end
        local w = winners[1]
        log(string.format("RESULT: gSprites = 0x%08X  (sprite.x = %s16*obj.x, sprite.y = %s16*obj.y"
            .. ", constant offset, over %d steps)", w.base, w.sgnX < 0 and "-" or "+",
            w.sgnY < 0 and "-" or "+", #samples - 1))
        log(string.format("vanilla gSprites is 0x%08X -> shift on this build = 0x%X",
            GSPRITES_VANILLA, w.base - GSPRITES_VANILLA))
        log(string.format("gObjectEvents shift on this build = 0x%X (for comparison only)",
            avatarOffset))
        return
    end
end

MESHGHOST_DEV_UNLOAD = function()
    if logf then logf:close(); logf = nil end
end

if not MESHGHOST_DEV_LOADER then
    while true do MESHGHOST_DEV_TICK(); emu.frameadvance() end
end
