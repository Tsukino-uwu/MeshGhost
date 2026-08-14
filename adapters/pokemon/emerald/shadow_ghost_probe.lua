-- Dev-only diagnostic: draws a second ghost sprite at a fixed tile offset next to the real
-- player, driven by the EXACT SAME local-state read + smoothPosition() + animation code as
-- meshghost_emerald.lua's real remote-rendering path -- but entirely locally, no bridge/relay/
-- core, no networking at all. Never writes memory.
--
-- WHY: found live 2026-08-14 -- comparing the ghost against a real loopback session made it
-- hard to judge smoothness on its own, since loopback's ghost also trails behind by a real
-- network round trip (relay forward + core interp buffer) on top of whatever the local
-- smoothing code does. This probe removes that confound entirely: the shadow ghost is driven by
-- the same frame's local read, smoothed the same way, with zero network delay, always exactly
-- SHADOW_OFFSET_TILES tiles away -- so it moves in perfect parallel with the real, natively-
-- rendered player character. Any choppiness visible in the shadow but not the real character is
-- then attributable to this script's own smoothing/animation code, not lag.
--
-- All memory addresses, sprite decode, smoothPosition(), and animation logic below are exact
-- copies of the real logic in meshghost_emerald.lua (2026-08-14) -- see that file's header for
-- the full derivation/citation trail for every address and constant; not re-derived here.

local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
local GSPRITECOORDOFFSETX_ADDR = 0x02021bbc
local GSPRITECOORDOFFSETY_ADDR = 0x02021bbe
local AVATAR_ADDR_ARCHIPELAGO_SHIFT = 0x284

local TILE = 16

local GOBJECTEVENTPIC_BRENDANNORMAL_ADDR = 0x084975f8
local GOBJECTEVENTPAL_BRENDAN_ADDR = 0x084987f8
local GOBJECTEVENTPIC_MAYNORMAL_ADDR = 0x084a3078
local GOBJECTEVENTPAL_MAY_ADDR = 0x084a4278
local GOBJECTEVENTPIC_BRENDANRUNNING_ADDR = 0x08497ef8
local GOBJECTEVENTPIC_MAYRUNNING_ADDR = 0x084a3978
local SPRITE_ADDR_ARCHIPELAGO_SHIFT = 0x7530

local FRAME_WIDTH_TILES = 2
local FRAME_HEIGHT_TILES = 4
local FRAME_WIDTH_PX = FRAME_WIDTH_TILES * 8
local FRAME_HEIGHT_PX = FRAME_HEIGHT_TILES * 8
local FRAMES_PER_PIC_TABLE = 9

local FACING = { [1] = "south", [2] = "north", [3] = "west", [4] = "east" }

local DIRECTION_ANIM = {
    south = { idle = 0, steps = { 3, 0, 4, 0 }, hFlip = false },
    north = { idle = 1, steps = { 5, 1, 6, 1 }, hFlip = false },
    west  = { idle = 2, steps = { 7, 2, 8, 2 }, hFlip = false },
    east  = { idle = 2, steps = { 7, 2, 8, 2 }, hFlip = true },
}
local WALK_POSE_DURATIONS = { 8, 8, 8, 8 }
local RUN_POSE_DURATIONS = { 5, 3, 5, 3 }

-- How far from the real player to draw the shadow, and in which direction. Positive X = east.
local SHADOW_OFFSET_TILES_X = 2
local SHADOW_OFFSET_TILES_Y = 0

if not memory.usememorydomain("System Bus") then
    console.log("ERROR: 'System Bus' memory domain not found on this core.")
    console.log("Domains available: " .. memory.getmemorydomainlist())
    return
end

local function expand5to8(v5) return (v5 << 3) | (v5 >> 2) end

local function decodePalette(addr)
    local pal = {}
    for i = 0, 15 do
        local c = memory.read_u16_le(addr + i * 2)
        local r5 = c & 0x1F
        local g5 = (c >> 5) & 0x1F
        local b5 = (c >> 10) & 0x1F
        pal[i] = { r = expand5to8(r5), g = expand5to8(g5), b = expand5to8(b5) }
    end
    return pal
end

local function decodeFramePixels(picAddr, frameIndex, palette)
    local frameAddr = picAddr + frameIndex * (FRAME_WIDTH_TILES * FRAME_HEIGHT_TILES * 32)
    local pixels = {}
    for py = 0, FRAME_HEIGHT_PX - 1 do
        local tileRow = py // 8
        local localY = py % 8
        for px = 0, FRAME_WIDTH_PX - 1 do
            local tileCol = px // 8
            local localX = px % 8
            local tileIndex = tileRow * FRAME_WIDTH_TILES + tileCol
            local tileByteOffset = tileIndex * 32 + localY * 4 + (localX // 2)
            local b = memory.read_u8(frameAddr + tileByteOffset)
            local index
            if localX % 2 == 0 then
                index = b & 0x0F
            else
                index = (b >> 4) & 0x0F
            end
            if index ~= 0 then
                local c = palette[index]
                local color = (0xFF << 24) | (c.r << 16) | (c.g << 8) | c.b
                pixels[#pixels + 1] = { x = px, y = py, color = color }
            end
        end
    end
    return pixels
end

local BRENDAN_PAL_REF_BYTES = { 0x0e, 0x53, 0x5f, 0x5b }
local function bytesMatchAt(addr, refBytes)
    for i, expected in ipairs(refBytes) do
        if memory.read_u8(addr + i - 1) ~= expected then
            return false
        end
    end
    return true
end

local function detectSpriteAddrOffset()
    if bytesMatchAt(GOBJECTEVENTPAL_BRENDAN_ADDR, BRENDAN_PAL_REF_BYTES) then
        console.log("MeshGhost shadow probe: sprite data found at the vanilla ROM address.")
        return 0
    end
    if bytesMatchAt(GOBJECTEVENTPAL_BRENDAN_ADDR + SPRITE_ADDR_ARCHIPELAGO_SHIFT, BRENDAN_PAL_REF_BYTES) then
        console.log("MeshGhost shadow probe: sprite data found at the known Archipelago-shifted ROM address.")
        return SPRITE_ADDR_ARCHIPELAGO_SHIFT
    end
    console.log("MeshGhost shadow probe: WARNING -- sprite data not found at either known address.")
    return 0
end

local MAP_GROUPS_COUNT = 34
local function playerObjEventExistsAt(gObjectEventsBase)
    for i = 0, 15 do
        local addr = gObjectEventsBase + i * OBJECTEVENT_SIZE
        local isPlayerBit = memory.read_u8(addr + 0x02) & 0x1
        local localId = memory.read_u8(addr + 0x08)
        local mapGroup = memory.read_u8(addr + 0x0a)
        if isPlayerBit == 1 and localId == 0xff and mapGroup < MAP_GROUPS_COUNT then
            return true
        end
    end
    return false
end

local avatarAddrOffset = 0
local avatarAddrConfirmed = false
local function tryDetectAvatarAddrOffset()
    if playerObjEventExistsAt(GOBJECTEVENTS_ADDR) then
        console.log("MeshGhost shadow probe: gObjectEvents/gPlayerAvatar found at the vanilla ROM address.")
        avatarAddrOffset = 0
        avatarAddrConfirmed = true
        return
    end
    if playerObjEventExistsAt(GOBJECTEVENTS_ADDR + AVATAR_ADDR_ARCHIPELAGO_SHIFT) then
        console.log("MeshGhost shadow probe: gObjectEvents/gPlayerAvatar found at the known Archipelago-shifted address.")
        avatarAddrOffset = AVATAR_ADDR_ARCHIPELAGO_SHIFT
        avatarAddrConfirmed = true
        return
    end
    -- Not found yet (e.g. still in the intro cutscene) -- main loop retries next frame.
end

local genderFrames = { male = { walk = {}, run = {} }, female = { walk = {}, run = {} } }
local function loadGenderFrames(offset)
    local malePalette = decodePalette(GOBJECTEVENTPAL_BRENDAN_ADDR + offset)
    local femalePalette = decodePalette(GOBJECTEVENTPAL_MAY_ADDR + offset)
    for i = 0, FRAMES_PER_PIC_TABLE - 1 do
        genderFrames.male.walk[i] = decodeFramePixels(GOBJECTEVENTPIC_BRENDANNORMAL_ADDR + offset, i, malePalette)
        genderFrames.male.run[i] = decodeFramePixels(GOBJECTEVENTPIC_BRENDANRUNNING_ADDR + offset, i, malePalette)
        genderFrames.female.walk[i] = decodeFramePixels(GOBJECTEVENTPIC_MAYNORMAL_ADDR + offset, i, femalePalette)
        genderFrames.female.run[i] = decodeFramePixels(GOBJECTEVENTPIC_MAYRUNNING_ADDR + offset, i, femalePalette)
    end
end

local lastMapGroup, lastMapNum = nil, nil
local function mapJustChanged(mapGroup, mapNum)
    local changed = lastMapGroup ~= nil and (mapGroup ~= lastMapGroup or mapNum ~= lastMapNum)
    lastMapGroup, lastMapNum = mapGroup, mapNum
    return changed
end

local function getLocalState()
    local base = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
    if base == 0 then return nil end

    local x = memory.read_s16_le(base + 0x00)
    local y = memory.read_s16_le(base + 0x02)
    local mapGroup = memory.read_s8(base + 0x04)
    local mapNum = memory.read_s8(base + 0x05)

    if mapJustChanged(mapGroup, mapNum) then return nil end

    local flags = memory.read_u8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x00)
    local runningState = memory.read_u8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x02)
    local objectEventId = memory.read_u8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05)
    local dashing = (flags & 0x80) ~= 0

    local objEventAddr = GOBJECTEVENTS_ADDR + avatarAddrOffset + (objectEventId * OBJECTEVENT_SIZE)
    local facingRaw = memory.read_u16_le(objEventAddr + 0x18) & 0xF
    local orientation = FACING[facingRaw] or "south"

    local anim
    if runningState == 2 and dashing then
        anim = "running"
    elseif runningState == 2 then
        anim = "walking"
    else
        anim = "idle"
    end

    return { x = x, y = y, orientation = orientation, anim = anim }
end

-- Exact copy of meshghost_emerald.lua's smoothPosition() -- this is the thing being evaluated.
local STEP_DURATION_FRAMES = { walking = 16, running = 8 }
local PLAUSIBLE_STEP_DURATION_MIN = 2
local PLAUSIBLE_STEP_DURATION_MAX = 40

local frameCounter = 0
local prevTileX, prevTileY = nil, nil
local committedTileX, committedTileY = nil, nil
local tileChangeFrame = 0
local activeStepDuration = STEP_DURATION_FRAMES.walking

local function smoothPosition(rawX, rawY, anim)
    if committedTileX == nil then
        prevTileX, prevTileY = rawX, rawY
        committedTileX, committedTileY = rawX, rawY
        tileChangeFrame = frameCounter
        activeStepDuration = STEP_DURATION_FRAMES[anim] or STEP_DURATION_FRAMES.walking
    elseif rawX ~= committedTileX or rawY ~= committedTileY then
        prevTileX, prevTileY = committedTileX, committedTileY
        committedTileX, committedTileY = rawX, rawY
        local measuredGap = frameCounter - tileChangeFrame
        if measuredGap >= PLAUSIBLE_STEP_DURATION_MIN and measuredGap <= PLAUSIBLE_STEP_DURATION_MAX then
            activeStepDuration = measuredGap
        else
            activeStepDuration = STEP_DURATION_FRAMES[anim] or STEP_DURATION_FRAMES.walking
        end
        tileChangeFrame = frameCounter
    end

    local fraction = (frameCounter - tileChangeFrame) / activeStepDuration
    if fraction > 1 then fraction = 1 end
    if fraction < 0 then fraction = 0 end

    return prevTileX + (committedTileX - prevTileX) * fraction,
           prevTileY + (committedTileY - prevTileY) * fraction
end

local function playerScreenPos()
    local spriteId = memory.read_u8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04)
    local spriteAddr = GSPRITES_ADDR + (spriteId * SPRITE_SIZE)

    local sx = memory.read_s16_le(spriteAddr + 0x20)
    local sy = memory.read_s16_le(spriteAddr + 0x22)
    local sx2 = memory.read_s16_le(spriteAddr + 0x24)
    local sy2 = memory.read_s16_le(spriteAddr + 0x26)
    local cx = memory.read_s8(spriteAddr + 0x28)
    local cy = memory.read_s8(spriteAddr + 0x29)

    local coordOffsetX = memory.read_s16_le(GSPRITECOORDOFFSETX_ADDR)
    local coordOffsetY = memory.read_s16_le(GSPRITECOORDOFFSETY_ADDR)

    return sx + sx2 + cx + coordOffsetX, sy + sy2 + cy + coordOffsetY
end

local shadow = { animTimer = 0, animStepIndex = 1, lastAnim = nil, lastOrientation = nil }
local function advanceAnim(anim, orientation, dirInfo)
    if shadow.lastAnim ~= anim or shadow.lastOrientation ~= orientation then
        shadow.animTimer = 0
        shadow.animStepIndex = 1
        shadow.lastAnim = anim
        shadow.lastOrientation = orientation
    end
    local durations = (anim == "running") and RUN_POSE_DURATIONS or WALK_POSE_DURATIONS
    local framesPerStep = durations[shadow.animStepIndex]
    shadow.animTimer = shadow.animTimer + 1
    if shadow.animTimer >= framesPerStep then
        shadow.animTimer = 0
        shadow.animStepIndex = (shadow.animStepIndex % #dirInfo.steps) + 1
    end
    return dirInfo.steps[shadow.animStepIndex]
end

local function drawSpriteFrame(gender, pose, frameIndex, hFlip, screenX, screenY)
    local genderSet = genderFrames[gender] or genderFrames.male
    local pixels = (genderSet[pose] or genderSet.walk)[frameIndex]
    for i = 1, #pixels do
        local p = pixels[i]
        local px = hFlip and (FRAME_WIDTH_PX - 1 - p.x) or p.x
        gui.drawPixel(screenX + px, screenY + p.y, p.color)
    end
end

console.log("MeshGhost shadow-ghost probe running. No networking -- purely local, for comparing")
console.log("this script's own smoothing/animation against the real, natively-rendered player.")
console.log("Decoding Brendan/May sprite frames...")
local spriteAddrOffset = detectSpriteAddrOffset()
loadGenderFrames(spriteAddrOffset)
tryDetectAvatarAddrOffset()
console.log(string.format("Shadow ghost will track %d tile(s) east, %d tile(s) south of you.",
    SHADOW_OFFSET_TILES_X, SHADOW_OFFSET_TILES_Y))

local localGender = "male" -- cosmetic only for this probe; not worth the inOverworld()-gated
-- lazy resolution meshghost_emerald.lua uses, since gender doesn't affect what's being tested.

local lastFrameErrorLogged = 0
local function runFrame()
    frameCounter = frameCounter + 1
    gui.clearGraphics()

    if not avatarAddrConfirmed then
        tryDetectAvatarAddrOffset()
    end

    local state = getLocalState()
    if not state then return end

    local smoothX, smoothY = smoothPosition(state.x, state.y, state.anim)
    local playerScreenX, playerScreenY = playerScreenPos()

    local shadowScreenX = playerScreenX + SHADOW_OFFSET_TILES_X * TILE
    local shadowScreenY = playerScreenY + SHADOW_OFFSET_TILES_Y * TILE

    local dirInfo = DIRECTION_ANIM[state.orientation] or DIRECTION_ANIM.south
    local frameIndex, pose
    if state.anim == "walking" or state.anim == "running" then
        pose = (state.anim == "running") and "run" or "walk"
        frameIndex = advanceAnim(state.anim, state.orientation, dirInfo)
    else
        shadow.animTimer = 0
        shadow.animStepIndex = 1
        shadow.lastAnim = state.anim
        shadow.lastOrientation = state.orientation
        pose = "walk"
        frameIndex = dirInfo.idle
    end

    drawSpriteFrame(localGender, pose, frameIndex, dirInfo.hFlip, shadowScreenX, shadowScreenY)
end

while true do
    local ok, err = pcall(runFrame)
    if not ok then
        if frameCounter - lastFrameErrorLogged > 300 then
            console.log("MeshGhost shadow probe: frame error (continuing): " .. tostring(err))
            lastFrameErrorLogged = frameCounter
        end
    end
    emu.frameadvance()
end
