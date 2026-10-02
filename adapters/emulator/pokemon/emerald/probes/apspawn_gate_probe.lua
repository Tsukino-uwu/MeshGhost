-- Read-only: why an Archipelago build receives a peer (remotes=1) and spawns nothing (ghosts=0). None of the spawn
-- tier's reasons to decline logs on its own, so once a second this prints the slot budget, the player's
-- object/sprite cross-link through gSprites, the camera, and the local area_id (the half of the area match
-- visible from outside the adapter). Addresses and the Archipelago shift test are the adapter's own.

local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE   = 0x24
local GSPRITES_ADDR      = 0x02020630
local SPRITE_SIZE        = 0x44
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
-- syncGhost() only spawns on a settled camera (gFieldCamera x and y both 0).
local GFIELDCAMERA_X_ADDR, GFIELDCAMERA_Y_ADDR = 0x03005de0, 0x03005de4
local AVATAR_ADDR_ARCHIPELAGO_SHIFT = 0x284
local MAP_GROUPS_COUNT   = 34
local GHOST_LOCAL_ID     = 255
local RESERVE            = 1

local function r8(a) return memory.read_u8(a) end
local function rs16(a) return memory.read_s16_le(a) end
local function r32(a) return memory.read_u32_le(a) end

-- Beside this script: BizHawk's working directory is its own install.
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
local logPath = here .. "/apspawn_gate_" .. os.date("%Y%m%d_%H%M%S") .. ".log"
local fh = io.open(logPath, "a")
local function say(s)
    console.log(s)
    if fh then fh:write(s .. "\n"); fh:flush() end
end

-- The adapter's player test; the player bit is bit 0 of +0x02, not of +0x00.
local function playerObjEventExistsAt(base)
    for i = 0, 15 do
        local a = base + i * OBJECTEVENT_SIZE
        if (r8(a + 0x02) & 0x01) == 1 and r8(a + 0x08) == 0xff
            and r8(a + 0x0a) < MAP_GROUPS_COUNT then
            return true
        end
    end
    return false
end

local shift = nil
local frame = 0

local function tick()
    frame = frame + 1
    if shift == nil then
        if playerObjEventExistsAt(GOBJECTEVENTS_ADDR + AVATAR_ADDR_ARCHIPELAGO_SHIFT) then
            shift = AVATAR_ADDR_ARCHIPELAGO_SHIFT
            say("probe: gObjectEvents at the Archipelago-shifted address (+0x284).")
        elseif playerObjEventExistsAt(GOBJECTEVENTS_ADDR) then
            shift = 0
            say("probe: gObjectEvents at the vanilla address.")
        else
            return
        end
    end
    if frame % 60 ~= 0 then return end

    local sb1 = r32(GSAVEBLOCK1PTR_ADDR)
    if sb1 == 0 then say("probe: no save loaded."); return end

    local cast, occupied = 0, {}
    for i = 0, 15 do
        local a = GOBJECTEVENTS_ADDR + shift + i * OBJECTEVENT_SIZE
        local active = (r8(a) & 0x01) == 1
        local localId = r8(a + 0x08)
        if active then
            occupied[#occupied + 1] = string.format("%d(id=%d,gfx=%d)", i, localId, r8(a + 0x05))
            if localId ~= GHOST_LOCAL_ID then cast = cast + 1 end
        end
    end

    local pObjId = r8(GPLAYERAVATAR_ADDR + shift + 0x05)
    local pObj = GOBJECTEVENTS_ADDR + shift + pObjId * OBJECTEVENT_SIZE
    local pSprId = r8(pObj + 0x04)
    local backlink = rs16(GSPRITES_ADDR + pSprId * SPRITE_SIZE + 0x2e)

    say(string.format(
        "probe: area=%d:%d pos=(%d,%d) cast=%d budget=%d  crosslink: playerObj=%d spr=%d back=%d %s",
        memory.read_s8(sb1 + 0x04), memory.read_s8(sb1 + 0x05),
        rs16(sb1 + 0x00), rs16(sb1 + 0x02),
        cast, math.max(0, 16 - cast - RESERVE),
        pObjId, pSprId, backlink,
        backlink == pObjId and "OK" or "MISMATCH -- spawnGhost would refuse"))
    local camX = memory.read_s32_le(GFIELDCAMERA_X_ADDR)
    local camY = memory.read_s32_le(GFIELDCAMERA_Y_ADDR)
    say(string.format("       camera: x=%d y=%d %s", camX, camY,
        (camX == 0 and camY == 0) and "SETTLED" or "NOT settled -- syncGhost will not spawn"))
    say("       objects in use: " .. table.concat(occupied, " "))
end

-- The loader ticks MESHGHOST_DEV_TICK; a script that registers its own event handler runs once and never again.
say("apspawn_gate_probe: read-only, logging to " .. logPath)
MESHGHOST_DEV_TICK = tick
