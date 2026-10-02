-- MeshGhost — Emerald capacity probe (dev tool, read-only, vanilla only, never shipped).
-- Every REPORT_SECONDS: the player's area_id and tile, object events in use out of 16, engine sprites out of 64,
-- hardware OAM entries in use out of 128, and the frame rate against the wall clock.
local MESHGHOST_DIR = (function()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end)()

local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local OBJECT_EVENTS_COUNT = 16
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
local MAX_SPRITES = 64
local OAM_ADDR = 0x07000000
local OAM_ENTRIES = 128

local REPORT_SECONDS = 10 -- os.time has 1s resolution; 10s keeps the fps figure within a few percent

local LOG_PATH = MESHGHOST_DIR .. "/capacity_probe.log"
local logfile = io.open(LOG_PATH, "a")
local function say(m)
    console.log("CAPACITY: " .. m)
    if logfile then logfile:write(os.date("%Y-%m-%d %H:%M:%S ") .. m .. "\n") logfile:flush() end
end

-- Tags each row with the condition that produced it.
local LABEL = os.getenv("MESHGHOST_CAPACITY_LABEL") or ""

local function activeObjects()
    local n, ids = 0, {}
    for i = 0, OBJECT_EVENTS_COUNT - 1 do
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
        if (memory.read_u8(GSPRITES_ADDR + i * SPRITE_SIZE + 0x3e) & 0x01) == 1 then n = n + 1 end
    end
    return n
end

-- Emerald parks unused OAM entries on one dummy entry instead of disabling them, so the most common one is unused.
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
