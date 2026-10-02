-- MeshGhost — Emerald UI-region probe: do the GBA's window registers mark the text box and START menu (dev tool,
-- read-only, never shipped). Logs DISPCNT's window enables, WIN0/WIN1's rectangles, WININ, WINOUT and BLDCNT on change,
-- with a screenshot when MESHGHOST_PROBE_SHOT_DIR (trailing slash) is set; never point it into the repo.
-- Play normally: walk, open a text box, open the START menu, enter a building.
local MESHGHOST_DIR = (function()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end)()

local IO = 0x04000000
local SHOT_MIN_GAP_FRAMES = 45 -- ~0.75s: enough to catch a panel opening without a shot per frame
local SHOT_DIR = os.getenv("MESHGHOST_PROBE_SHOT_DIR")
local LOG_PATH = MESHGHOST_DIR .. "/uiregion_probe.log"

local logfile = io.open(LOG_PATH, "a")
local function say(m)
    console.log("UIREGION: " .. m)
    if logfile then logfile:write(os.date("%H:%M:%S ") .. m .. "\n") logfile:flush() end
end

local function r16(a) return memory.read_u16_le(a) end

local function snapshot()
    return {
        dispcnt = r16(IO + 0x00),
        win0h = r16(IO + 0x40), win1h = r16(IO + 0x42),
        win0v = r16(IO + 0x44), win1v = r16(IO + 0x46),
        winin = r16(IO + 0x48), winout = r16(IO + 0x4a),
        bldcnt = r16(IO + 0x50),
    }
end

local function describe(s)
    local function rect(h, v)
        return string.format("x %d..%d y %d..%d", (h >> 8) & 0xFF, h & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    end
    return string.format(
        "dispcnt=%04X win0=%s win1=%s enabled(w0=%d w1=%d obj=%d) winin=%04X winout=%04X bldcnt=%04X",
        s.dispcnt, rect(s.win0h, s.win0v), rect(s.win1h, s.win1v),
        (s.dispcnt >> 13) & 1, (s.dispcnt >> 14) & 1, (s.dispcnt >> 15) & 1,
        s.winin, s.winout, s.bldcnt)
end

local function key(s)
    return string.format("%04X|%04X|%04X|%04X|%04X|%04X|%04X|%04X",
        s.dispcnt, s.win0h, s.win0v, s.win1h, s.win1v, s.winin, s.winout, s.bldcnt)
end

-- These registers change every frame in ordinary play: sample at a cadence and log at most once a second.
local SAMPLE_EVERY_FRAMES = 10
local LOG_MIN_GAP_FRAMES = 60
local frames, lastKey, lastShot, lastLog, shots = 0, nil, -9999, -9999, 0
say("=== ui region probe start ===")

MESHGHOST_DEV_TICK = function()
    frames = frames + 1
    if frames % SAMPLE_EVERY_FRAMES ~= 0 then return end
    local s = snapshot()
    local k = key(s)
    if k == lastKey then return end
    lastKey = k
    if frames - lastLog < LOG_MIN_GAP_FRAMES then return end
    lastLog = frames
    say(string.format("frame=%d %s", frames, describe(s)))
    if SHOT_DIR and frames - lastShot >= SHOT_MIN_GAP_FRAMES then
        lastShot = frames
        shots = shots + 1
        pcall(function() client.screenshot(string.format("%sui_%04d.png", SHOT_DIR, shots)) end)
    end
end

MESHGHOST_DEV_UNLOAD = function()
    say("=== ui region probe stop ===")
    if logfile then logfile:close() logfile = nil end
end
