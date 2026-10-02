-- MeshGhost — Emerald: which tilemap rows does the game draw a panel into? (dev tool, read-only, never shipped)
-- Play normally, then open a text box and the START menu; each change in BG0/BG1's drawn rows is logged.

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
-- Every row: a text box sits at the bottom, but the START menu is a panel down the right-hand side.
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

-- BGxCNT bits 8-12 are the screen base block, in 2KB units from VRAM's start: GBA hardware, no game address.
local function tilemapBase(bg)
    local cnt = memory.read_u16_le(IO + 0x08 + bg * 2)
    return VRAM + ((cnt >> 8) & 0x1F) * 0x800
end

local function tileAt(base, row, col)
    -- One 16-bit entry per cell, tile id in the low 10 bits; screen columns 0-29 sit in the first 32-wide block.
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

    -- BG0 and BG1 only, non-empty rows only: BG2 and BG3 carry the map, which changes with every step.
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
