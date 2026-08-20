-- MeshGhost -- ride the ACRO BIKE three tiles left, three tiles right (DEV TOOL, never shipped)
--
-- WHY. User, 2026-08-20: *"the ghosts are hopping when just riding the bike normally left/right,
-- right now? thats not intended to happen"* -- and the request that came with it, *"do a test where
-- you just move 3 tiles left/right"*. Plain riding is the one Acro case with no wheelie and no hop
-- in it, so anything the ghost does off the ground during this run is ours, not the peer's.
--
-- WHAT IT ANSWERS, in one file, because the two halves have to be read on the SAME frame: what the
-- PLAYER's object reports while riding (its movement action, and whether its sprite leaves the
-- ground) beside what the GHOST's object is doing at that instant. A hop shows up as the sprite's
-- pos2 y going negative -- that is the vertical offset the jump/hop step functions write, and it is
-- how "it looks like it hopped" becomes a number rather than an impression.
--
-- It drives the pad itself (agent_docs/playing.md): a person cannot hold a steady three-tile
-- shuttle and watch two ghosts at once, and every leg here has to be identical to the last for a
-- difference between them to mean anything.
--
-- ONE PROBE HOLDS THE PAD. `joypad.set` replaces the whole pad state every frame, so a second
-- script writing an empty table cancels this one's press -- that trap cost two live runs on
-- 2026-08-20 (verified.md). Do not load this alongside another input probe.
--
-- Addresses copied from meshghost_emerald.lua, never from memory.
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local GSPRITES_ADDR = 0x02020630
local OBJECTEVENT_SIZE = 0x24
local SPRITE_SIZE = 0x44
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local ITEM_ACRO_BIKE = 272
local ACRO_BIKE_GFX = { [63] = true, [91] = true }   -- Brendan / May, verified.md's graphicsId table
local GHOST_LOCAL_ID = 255

local TILES_PER_LEG = 3
local LEG_FRAME_CAP = 300

local function r8(a) return memory.read_u8(a) end
local function rs16(a) return memory.read_s16_le(a) end

local BSLASH = string.char(92)
local logPath = ("%s/acroride_%s.log"):format(
    (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/" .. BSLASH .. "][^/" .. BSLASH .. "]*$") or "."),
    os.date("%Y%m%d_%H%M%S"))
local logFile = io.open(logPath, "a")
local function say(s)
    console.log("acroride: " .. s)
    if logFile then logFile:write(s .. string.char(10)) logFile:flush() end
end
local function line(s) if logFile then logFile:write(s .. string.char(10)) logFile:flush() end end

local function playerObj()
    return GOBJECTEVENTS_ADDR + r8(GPLAYERAVATAR_ADDR + 0x05) * OBJECTEVENT_SIZE
end

local function findGhost()
    for i = 0, 15 do
        local a = GOBJECTEVENTS_ADDR + i * OBJECTEVENT_SIZE
        if (r8(a) & 0x01) == 1 and (r8(a + 0x02) & 0x01) == 0 and r8(a + 0x08) == GHOST_LOCAL_ID then
            return a
        end
    end
    return nil
end

local function controllable()
    local cb = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if cb ~= CB2_OVERWORLD_ADDR and cb ~= CB2_OVERWORLD_ADDR + 1 then return false end
    return r8(GPLAYERAVATAR_ADDR + 0x06) == 0
end

-- Left first, then right, repeating: the same shuttle the user described.
local legs = { { key = "Left", dx = -1 }, { key = "Right", dx = 1 } }
local which, startX, frames, laps, phase, n = 1, nil, 0, 0, "mount", 0
-- The peer's action is only interesting when it CHANGES, but the ghost leaving the ground is
-- interesting on the frame it happens, so both are logged: a per-change line, and a per-frame line
-- whenever either sprite is off the ground.
local lastPlayerAct, lastGhostAct = nil, nil

local function sample(tag)
    local p = playerObj()
    local ps = GSPRITES_ADDR + r8(p + 0x04) * SPRITE_SIZE
    local g = findGhost()
    local gs = g and (GSPRITES_ADDR + r8(g + 0x04) * SPRITE_SIZE) or nil
    local pAct, gAct = r8(p + 0x1c), g and r8(g + 0x1c) or -1
    local pY, gY = rs16(ps + 0x26), gs and rs16(gs + 0x26) or 0
    local changed = (pAct ~= lastPlayerAct) or (gAct ~= lastGhostAct)
    if changed or pY ~= 0 or gY ~= 0 or tag then
        lastPlayerAct, lastGhostAct = pAct, gAct
        line(string.format(
            "%s leg=%s f=%d | player act=%02X gfx=%d dir=%02X pos2=%d,%d anim=%d/%d xy=%d,%d"
            .. " | ghost act=%02X gfx=%s pos2=%d,%d anim=%s/%s xy=%s,%s",
            tag or "-", legs[which].key, frames,
            pAct, r8(p + 0x05), r8(p + 0x18), rs16(ps + 0x24), pY, r8(ps + 0x2a), r8(ps + 0x2b),
            rs16(p + 0x10), rs16(p + 0x12),
            gAct, g and tostring(r8(g + 0x05)) or "-",
            gs and rs16(gs + 0x24) or 0, gY,
            gs and tostring(r8(gs + 0x2a)) or "-", gs and tostring(r8(gs + 0x2b)) or "-",
            g and tostring(rs16(g + 0x10)) or "-", g and tostring(rs16(g + 0x12)) or "-"))
    end
end

local function tick()
    if not controllable() then return end

    -- Mount the bike the game's own way (probes/use_acro.lua): register it to SELECT and tap.
    if phase == "mount" then
        local p = playerObj()
        if ACRO_BIKE_GFX[r8(p + 0x05)] then
            say("already on the Acro Bike -- riding")
            phase, n = "ride", 0
            return
        end
        n = n + 1
        if n == 1 then
            local sb1 = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
            if sb1 == 0 then n = 0 return end
            memory.write_u16_le(sb1 + 0x496, ITEM_ACRO_BIKE)
            say("registered the Acro Bike to SELECT")
            return
        end
        joypad.set({ Select = n >= 10 and n <= 16 })
        if n > 40 then
            joypad.set({})
            if ACRO_BIKE_GFX[r8(p + 0x05)] then
                say("on the Acro Bike -- riding " .. TILES_PER_LEG .. " tiles left/right")
                phase, n = "ride", 0
            else
                say("SELECT did not put us on the bike (graphicsId " .. r8(p + 0x05) .. ") -- retrying")
                n = 0
            end
        end
        return
    end

    local p = playerObj()
    if not ACRO_BIKE_GFX[r8(p + 0x05)] then
        joypad.set({})
        say("no longer on the Acro Bike -- stopping so nothing is measured off it")
        phase = "done"
        return
    end

    local x = rs16(p + 0x10)
    if startX == nil then
        startX = x
        frames = 0
        line(string.format("# leg %s from x=%d (lap %d)", legs[which].key, startX, laps))
    end

    joypad.set({ [legs[which].key] = true })
    frames = frames + 1
    sample(nil)

    local gained = (x - startX) * legs[which].dx
    if gained >= TILES_PER_LEG or frames >= LEG_FRAME_CAP then
        joypad.set({})
        sample("ENDLEG")
        say(string.format("leg %s: %d of %d tiles in %d frames", legs[which].key, gained,
            TILES_PER_LEG, frames))
        which = which % #legs + 1
        startX = nil
        if which == 1 then
            laps = laps + 1
            if laps >= 3 then
                say("done after 3 laps -- " .. logPath)
                phase = "done"
            end
        end
    end
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = function() if phase ~= "done" then tick() end end
    MESHGHOST_DEV_UNLOAD = function() joypad.set({}) end
else
    while true do if phase ~= "done" then tick() end emu.frameadvance() end
end
