-- MeshGhost — Emerald: which gSprites entry is the PLAYER, and where does it think it is? (PROBE)
--
-- READ-ONLY. Reads game memory, writes none, presses nothing, draws nothing.
--
-- THE QUESTION. On SPEEDCHOICE 1.2.2 every anchor the adapter needs is now measured and the player's
-- own tile is right -- pos=(3,11), coords=(10,18), consistent -- yet the adapter reports its player
-- SPRITE at screen (-56,160). A local player cannot be off the left edge of its own screen, so one
-- of two things is wrong: the spriteId read off the player's object event, or the gSprites base.
--
-- gsprites_scan_probe.lua confirmed 0x02020634 by WALKING the player and watching a sprite track
-- it, which is strong -- but it proves some sprite tracks the player, not that the entry the
-- adapter picks is that one. A shadow, a reflection or a follower tracks the player too.
--
-- So this prints, for BOTH plausible bases, the first few entries with their coordinates and their
-- inUse bit, beside the player's object-event spriteId. On vanilla the player's entry should sit
-- near the middle of a 240x160 screen; the build where it does not is the build with the fault.
-- Run it on vanilla first and diff -- a wrong base looks entirely reasonable on its own.

local BASES = { 0x02020630, 0x02020634 }
local SPRITE_SIZE = 0x44
local OBJECTEVENT_SIZE = 0x24
local GOBJECTEVENTS_ADDR = 0x02037350
local GPLAYERAVATAR_ADDR = 0x02037590
local SHIFTS = { 0, 0x284, 0xA4 } -- vanilla, Archipelago, SPEEDCHOICE

local SCRIPT_DIR = (function()
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
    end
    return "."
end)()

local function say(line)
    console.log(line)
    local f = io.open(SCRIPT_DIR .. "/playersprite_probe.log", "a")
    if f then f:write(line, "\n") f:close() end
end

local done = false

local function tick()
    if done then return end
    done = true

    local code = string.char(memory.read_u8(0x080000AC), memory.read_u8(0x080000AD),
        memory.read_u8(0x080000AE), memory.read_u8(0x080000AF))
    say("=== PLAYER SPRITE " .. code .. " " .. os.date("%H:%M:%S") .. " ===")

    -- Which object-event shift is live on this build, by the same test the adapter uses.
    local objBase, avShift
    for _, sh in ipairs(SHIFTS) do
        local a = GOBJECTEVENTS_ADDR + sh
        -- a plausible player entry: active bit set and coordinates inside a map
        local x = memory.read_s16_le(a + 0x10)
        local y = memory.read_s16_le(a + 0x12)
        if x > 0 and y > 0 and x < 200 and y < 200 then
            objBase, avShift = a, sh
            break
        end
    end
    if not objBase then
        say("  no plausible gObjectEvents base -- cannot continue")
        return
    end
    local pObjId = memory.read_u8(GPLAYERAVATAR_ADDR + avShift + 0x05)
    local pa = objBase + pObjId * OBJECTEVENT_SIZE
    local spriteId = memory.read_u8(pa + 0x04)
    say(string.format("  gObjectEvents shift=+0x%X  playerObjId=%d  spriteId=%d  objCoords=(%d,%d)",
        avShift, pObjId, spriteId,
        memory.read_s16_le(pa + 0x10), memory.read_s16_le(pa + 0x12)))

    for _, base in ipairs(BASES) do
        local a = base + spriteId * SPRITE_SIZE
        say(string.format("  base %08X -> player entry %08X: x=%d y=%d inUse=%d",
            base, a, memory.read_s16_le(a + 0x20), memory.read_s16_le(a + 0x22),
            memory.read_u8(a + 0x3E) & 1))
        local row = {}
        for i = 0, 5 do
            local e = base + i * SPRITE_SIZE
            row[#row + 1] = string.format("[%d](%d,%d)%s", i,
                memory.read_s16_le(e + 0x20), memory.read_s16_le(e + 0x22),
                ((memory.read_u8(e + 0x3E) & 1) == 1) and "*" or "")
        end
        say("    first six: " .. table.concat(row, " ") .. "   (* = inUse)")
    end
    say("  A screen is 240x160. The player's entry should be well inside it on a build that works.")
end

MESHGHOST_DEV_UNLOAD = function() end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
else
    while true do tick() emu.frameadvance() end
end
