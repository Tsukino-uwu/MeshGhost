-- MeshGhost — Emerald capacity probe (DEVELOPMENT TOOL, never shipped)
--
-- Answers "how many ghosts can this game actually hold, and what gives out first?" in the GAME's
-- own terms rather than in the network's. Runs alongside the adapter under
-- dev-scripts/bizhawk-dev-loader.lua and only READS memory.
--
-- What it reports, every REPORT_SECONDS:
--   * where the player is -- mapGroup:mapNum (the adapter's own area_id) and tile position, so a
--     synthetic peer can be aimed at exactly that area with meshghost-fakeadapter's -area-id;
--   * object events in use out of 16 (OBJECT_EVENTS_COUNT). This is the engine array every NPC,
--     the player and every ghost share, so it is the first ceiling a ghost can hit;
--   * sprites in use out of 64 (MAX_SPRITES), the engine's own sprite table;
--   * hardware OAM entries that are actually enabled, out of 128 -- the ceiling UNDER the engine
--     one. A GBA object is one OAM entry, and a 16x32 overworld character is drawn from two;
--   * measured frames per second, counted against the wall clock rather than assumed. A capacity
--     answer that ignores whether the emulator still runs at full speed is not an answer.
--
-- Addresses are the ones the adapter itself uses (see meshghost_emerald.lua's header for their
-- provenance) -- vanilla Emerald only, so on an Archipelago ROM the numbers here are meaningless.
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local OBJECT_EVENTS_COUNT = 16
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
local MAX_SPRITES = 64
local OAM_ADDR = 0x07000000
local OAM_ENTRIES = 128

local REPORT_SECONDS = 10 -- wall clock, from os.time (1s resolution), so a longer window than
                          -- feels necessary: 10s keeps the fps figure inside a few percent.

local LOG_PATH = "C:/dev/MeshGhost/adapters/bizhawk/pokemon/emerald/probes/capacity_probe.log"
local logfile = io.open(LOG_PATH, "a")
local function say(m)
    console.log("CAPACITY: " .. m)
    if logfile then logfile:write(os.date("%Y-%m-%d %H:%M:%S ") .. m .. "\n") logfile:flush() end
end

-- A label the operator sets from outside, so a run's rows say which condition produced them.
local LABEL = os.getenv("MESHGHOST_CAPACITY_LABEL") or ""

local function activeObjects()
    local n, ids = 0, {}
    for i = 0, OBJECT_EVENTS_COUNT - 1 do
        -- bit 0 of the first bitfield byte is `active` (the same bit the adapter's own spawn path
        -- sets when it takes a slot and clears when it releases one).
        if (memory.read_u8(GOBJECTEVENTS_ADDR + i * OBJECTEVENT_SIZE) & 0x01) == 1 then
            n = n + 1
            ids[#ids + 1] = i
        end
    end
    return n, table.concat(ids, ",")
end

local function spritesInUse()
    local n = 0
    for i = 0, MAX_SPRITES - 1 do
        -- struct Sprite's `inUse` is the low bit of the bitfield byte at +0x3E, which is the same
        -- byte the adapter logs as `flags` for a ghost's sprite.
        if (memory.read_u8(GSPRITES_ADDR + i * SPRITE_SIZE + 0x3e) & 0x01) == 1 then n = n + 1 end
    end
    return n
end

-- OAM entries actually IN USE, out of 128. The obvious test -- the hardware's own disable bit --
-- reads 128/128 on this game and means nothing: Emerald does not disable unused objects, it parks
-- them on a dummy entry (off the bottom of the screen), so every entry looks "enabled". Instead
-- this calibrates itself: whatever 8-byte attribute pattern is the MOST COMMON across the 128
-- entries is the parked/unused one, and everything unlike it is a real object. That holds as long
-- as unused entries outnumber any single duplicated real one, which is true whenever there is
-- headroom -- and if it ever stops being true, the count is conservative rather than silently
-- wrong.
local function oamInUse()
    local counts, entries = {}, {}
    for i = 0, OAM_ENTRIES - 1 do
        local a = OAM_ADDR + i * 8
        local key = string.format("%04X%04X%04X",
            memory.read_u16_le(a), memory.read_u16_le(a + 2), memory.read_u16_le(a + 4))
        entries[i] = key
        counts[key] = (counts[key] or 0) + 1
    end
    local dummy, best = nil, -1
    for key, n in pairs(counts) do
        if n > best then dummy, best = key, n end
    end
    local n = 0
    for i = 0, OAM_ENTRIES - 1 do
        if entries[i] ~= dummy then n = n + 1 end
    end
    return n
end

local frames, lastReport, lastCpu = 0, os.time(), os.clock()
say(string.format("=== capacity probe start%s ===", LABEL ~= "" and (" [" .. LABEL .. "]") or ""))

MESHGHOST_DEV_TICK = function()
    frames = frames + 1
    local now = os.time()
    if now - lastReport < REPORT_SECONDS then return end
    local elapsed = now - lastReport
    local cpu = os.clock() - lastCpu
    local counted = frames
    lastReport, lastCpu, frames = now, os.clock(), 0

    local sb1 = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
    local where = "no save loaded"
    if sb1 ~= 0 then
        where = string.format("area=%d:%d pos=(%d,%d)",
            memory.read_s8(sb1 + 0x04), memory.read_s8(sb1 + 0x05),
            memory.read_s16_le(sb1 + 0x00), memory.read_s16_le(sb1 + 0x02))
    end
    local objN, objIds = activeObjects()
    say(string.format("%s%s objects=%d/%d [%s] sprites=%d/%d oam=%d/%d fps=%.1f",
        LABEL ~= "" and ("[" .. LABEL .. "] ") or "", where,
        objN, OBJECT_EVENTS_COUNT, objIds, spritesInUse(), MAX_SPRITES,
        oamInUse(), OAM_ENTRIES, counted / elapsed)
        .. string.format(" (%d frames in %ds wall, %.1fs cpu)", counted, elapsed, cpu))
end

MESHGHOST_DEV_UNLOAD = function()
    say("=== capacity probe stop ===")
    if logfile then logfile:close() logfile = nil end
end
