-- MeshGhost — Emerald text-box / menu detection probe (DEVELOPMENT TOOL, never shipped)
--
-- WHY, AND WHY NOT THE LCD REGISTERS
-- A drawn ghost is painted after the PPU has finished, so nothing hides it: to keep it out of a
-- text box the adapter has to know that a box is open and where. The first attempt asked the
-- HARDWARE (the GBA's window registers WIN0H/WIN0V + DISPCNT's enable bits) and that failed the
-- same way it failed on Crystal's Game Boy window layer -- the game drives those registers every
-- frame during ordinary walking, so they describe the display, not the panel
-- (uiregion_probe.lua keeps that negative result).
--
-- This probe asks the other question, which is the one that worked on Crystal: WHAT DID THE GAME
-- DRAW? A GBA background is a tilemap in VRAM, and a panel is tiles written into it. If a text box
-- puts recognisable tile ids at fixed rows, that is a style-independent signal costing a handful
-- of reads.
--
-- HOW IT FINDS THE TILEMAPS -- no game address, no decomp symbol
-- Each background's control register (BG0CNT..BG3CNT at 0x04000008 + 2n) carries its SCREEN BASE
-- BLOCK in bits 8-12, in units of 2KB from the start of VRAM (0x06000000). That is GBA hardware,
-- documented independently of any cartridge, so the tilemap address is computed at runtime and
-- nothing here can go stale against a ROM revision. A 32x32 map entry is 16 bits, of which the low
-- 10 are the tile id.
--
-- WHAT TO DO WITH THE OUTPUT
-- Play normally, then open a text box (talk to someone / read a sign) and the START menu. Each
-- distinct bottom-of-screen tile pattern is logged once with the row and the ids in it. The pattern
-- that appears exactly when a box is open, and only then, is the detector.

-- Resolve this script's own directory instead of hardcoding one developer's
-- checkout. A tracked absolute path is unusable on anyone else's machine and is
-- the class of leak .githooks/pre-commit now refuses (pitfalls.md).
local MESHGHOST_DIR = (function()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end)()

local IO = 0x04000000
local VRAM = 0x06000000
local SCREEN_ROWS, SCREEN_COLS = 20, 30
-- EVERY row, not just the bottom ones. A text box sits at the bottom, but the START menu is a
-- panel down the right-hand side and covers rows a bottom-only sample would miss entirely -- and
-- the question this probe answers is "which rows does the game draw a panel into", which cannot be
-- answered by a probe that only looks where the answer was assumed to be.
local ROWS_OF_INTEREST = {}
for r = 0, 19 do ROWS_OF_INTEREST[#ROWS_OF_INTEREST + 1] = r end
local SAMPLE_EVERY_FRAMES = 12 -- ~5Hz. Cheap enough to leave running, often enough to catch a box
local LOG_MIN_GAP_FRAMES = 30
local SHOT_DIR = os.getenv("MESHGHOST_PROBE_SHOT_DIR") -- optional; never inside the repo

local LOG_PATH = MESHGHOST_DIR .. "/textbox_probe.log"
local logfile = io.open(LOG_PATH, "a")
local function say(m)
    console.log("TEXTBOX: " .. m)
    if logfile then logfile:write(os.date("%H:%M:%S ") .. m .. "\n") logfile:flush() end
end

-- Screen base block -> tilemap address, straight out of the background's own control register.
local function tilemapBase(bg)
    local cnt = memory.read_u16_le(IO + 0x08 + bg * 2)
    return VRAM + ((cnt >> 8) & 0x1F) * 0x800
end

local function tileAt(base, row, col)
    -- 32x32 map: one 16-bit entry per cell, low 10 bits are the tile id. Columns 0-29 of the
    -- visible screen sit in the first 32-wide block, which is all this probe looks at.
    return memory.read_u16_le(base + (row * 32 + col) * 2) & 0x3FF
end

local function rowSignature(base, row)
    local ids = {}
    for col = 0, SCREEN_COLS - 1, 3 do ids[#ids + 1] = tileAt(base, row, col) end
    return table.concat(ids, ",")
end

local frames, lastKey, lastLog, shots = 0, nil, -9999, 0
say("=== textbox probe start (bg tilemaps, sampled every " .. SAMPLE_EVERY_FRAMES .. " frames) ===")

MESHGHOST_DEV_TICK = function()
    frames = frames + 1
    if frames % SAMPLE_EVERY_FRAMES ~= 0 then return end

    -- Only the UI-candidate layers are logged in full, and only their NON-EMPTY rows: bg2/bg3
    -- carry the map, which changes with every step and would bury the signal in noise. Their
    -- presence is still confirmed once at startup by the first line this probe writes.
    local parts = {}
    for _, bg in ipairs({ 0, 1 }) do
        local base = tilemapBase(bg)
        local nonEmpty = 0
        for _, row in ipairs(ROWS_OF_INTEREST) do
            local sig = rowSignature(base, row)
            if sig:match("[1-9]") then
                nonEmpty = nonEmpty + 1
                parts[#parts + 1] = string.format("bg%d r%d [%s]", bg, row, sig)
            end
        end
        if nonEmpty == 0 then parts[#parts + 1] = string.format("bg%d empty", bg) end
    end
    local k = table.concat(parts, " | ")
    if k == lastKey then return end
    lastKey = k
    if frames - lastLog < LOG_MIN_GAP_FRAMES then return end
    lastLog = frames

    say(string.format("frame=%d %s", frames, k))
    if SHOT_DIR then
        shots = shots + 1
        pcall(function() client.screenshot(string.format("%stb_%04d.png", SHOT_DIR, shots)) end)
    end
end

MESHGHOST_DEV_UNLOAD = function()
    say("=== textbox probe stop ===")
    if logfile then logfile:close() logfile = nil end
end
