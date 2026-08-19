-- MeshGhost — Emerald UI-region probe (DEVELOPMENT TOOL, never shipped)
--
-- WHAT IT IS FOR
-- A DRAWN ghost is painted onto the emulator's output after the PPU has finished, so it is subject
-- to none of the engine's occlusion: it would paint straight over a text box or the START menu.
-- Before shipping a drawn tier the region those panels occupy has to be KNOWN, and the project's
-- rule is that it is measured rather than guessed (agent_docs/ideas.md records how the same
-- question was answered on Crystal: a compile-time constant text box, plus a menu rectangle the
-- game publishes in RAM).
--
-- WHAT IT READS, and why these and not game variables
-- The GBA's own display registers, which are hardware, documented independently of any game, and
-- identical on every cartridge:
--   DISPCNT  0x04000000  bits 13/14/15 -- window 0, window 1, and the object window, enabled?
--   WIN0H/V  0x04000040 / 0x04000044   -- window 0's right|left and bottom|top, in PIXELS
--   WIN1H/V  0x04000042 / 0x04000046   -- window 1, same encoding
--   WININ    0x04000048                -- which layers draw INSIDE each window
--   WINOUT   0x0400004A                -- which layers draw outside them / in the object window
--   BLDCNT   0x04000050                -- what is being blended, which a panel usually changes
-- If Emerald marks its text box or menu with a hardware window, these state the rectangle exactly,
-- for free, with no address in any game's RAM to go stale. If it does not, that is also an answer,
-- and the honest conclusion is to say so rather than to invent a rectangle.
--
-- HOW TO READ ITS OUTPUT
-- Every changed register set is logged with a frame number, and a screenshot is taken alongside it
-- (rate-limited), so each row can be matched to what was actually on screen at that moment. Play
-- normally: walk, open a text box, open the START menu, enter a building.

local IO = 0x04000000
local SHOT_MIN_GAP_FRAMES = 45 -- ~0.75s: enough to catch a panel opening without a shot per frame
-- Screenshots go to the scratch directory of whoever is running this, NOT into the repo: they are
-- evidence for one session, and a probe that fills a tracked folder with PNGs is a mess the next
-- session inherits. Set MESHGHOST_PROBE_SHOT_DIR (with a trailing slash) to collect them.
local SHOT_DIR = os.getenv("MESHGHOST_PROBE_SHOT_DIR")
local LOG_PATH = "C:/dev/MeshGhost/adapters/bizhawk/pokemon/emerald/probes/uiregion_probe.log"

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
    -- Hn packs right in the low byte and left in the high byte; Vn packs bottom then top.
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

-- THROTTLED, and the throttle is not optional. The first version logged every change: these
-- registers change EVERY frame during normal play (measured 2026-08-19 -- values like "x 208..250"
-- that are mid-frame states, not panel geometry), so it wrote a line and flushed a file 60 times a
-- second and took the emulator from 60fps to 3. A probe that costs the thing it measures is worse
-- than no probe (CLAUDE.md), so this samples at a fixed cadence and logs at most once a second.
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
