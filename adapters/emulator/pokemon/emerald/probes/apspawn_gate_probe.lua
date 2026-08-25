-- apspawn_gate_probe.lua -- READ-ONLY. Why does the Archipelago Emerald build receive a peer
-- (status line: remotes=1) and spawn nothing (ghosts=0)?
--
-- The adapter's spawn tier can decline for three different reasons and none of them logs on its
-- own, so this prints all three side by side once a second:
--
--   1. tiering.budget() came out 0        -- 16 slots minus the map's own cast minus the reserve.
--   2. the peer's area_id never matched    -- chooseSpawned filters on equality first.
--   3. spawnGhost() refused the cross-link -- the player's object/sprite link through gSprites.
--
-- (2) is not visible from outside the adapter, so this measures (1) and (3) and prints the local
-- area_id, which is the half of (2) that can be checked against the core's own view.
--
-- Writes nothing. Addresses are the adapter's own constants; the Archipelago shift is detected
-- the same way the adapter detects it rather than assumed.

local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE   = 0x24
local GSPRITES_ADDR      = 0x02020630
local SPRITE_SIZE        = 0x44
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
-- A fourth reason the adapter can decline, added after the first three came back clean:
-- syncGhost() only calls spawnGhost() on a SETTLED camera (gFieldCamera.x and .y both 0), so a
-- camera that never settles is a spawn that never happens and nothing logs it.
local GFIELDCAMERA_X_ADDR, GFIELDCAMERA_Y_ADDR = 0x03005de0, 0x03005de4
local AVATAR_ADDR_ARCHIPELAGO_SHIFT = 0x284
local MAP_GROUPS_COUNT   = 34
local GHOST_LOCAL_ID     = 255
local RESERVE            = 1

local function r8(a) return memory.read_u8(a) end
local function rs16(a) return memory.read_s16_le(a) end
local function r32(a) return memory.read_u32_le(a) end

-- Beside this script, not beside the emulator: BizHawk's working directory is its own install,
-- so a relative path would drop the log somewhere nobody looks.
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
local logPath = here .. "/apspawn_gate_" .. os.date("%Y%m%d_%H%M%S") .. ".log"
local fh = io.open(logPath, "a")
local function say(s)
    console.log(s)
    if fh then fh:write(s .. "\n"); fh:flush() end
end

-- Same test the adapter uses: the player's own object event has the player bit set, local id 0xff
-- and a map group in range. Whichever base passes is the one this build uses.
-- The bits are the adapter's own, copied field for field rather than remembered: the player
-- flag is bit 0 of +0x02 (NOT of +0x00, which is where a first guess put it and why this probe
-- logged nothing for its first run), local id 0xff at +0x08, map group in range at +0x0a.
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

-- The loader ticks whatever a script leaves in MESHGHOST_DEV_TICK; a script that registers its
-- own event handler instead is loaded, runs once, and is never called again (it says so in the
-- loader log, which is where this was caught).
say("apspawn_gate_probe: read-only, logging to " .. logPath)
MESHGHOST_DEV_TICK = tick
