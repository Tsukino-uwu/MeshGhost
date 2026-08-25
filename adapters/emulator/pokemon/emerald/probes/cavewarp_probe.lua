-- MeshGhost -- Emerald warp-transition probe (DEVELOPMENT TOOL, never shipped)
--
-- WHY IT EXISTS
-- The user, 2026-08-21, walking into a cave with all three tiers on screen: *"when going inside a
-- cave, the drawn ghost stays on the screen for a bit too long."* A cave mouth is a warp with no
-- door animation, which is exactly the case the drawn tier's two hiding mechanisms were NOT
-- measured against -- both were built and confirmed on a HOUSE door (`drawRemotes`' header, and
-- probes/turn_and_door_probe.lua):
--
--   1. the hard cut, taken from the invisible bit (0x04) on the player sprite's flags (+0x3e),
--      which the engine sets for a door transition; and
--   2. the scene-brightness ratio, live OBJ palette against the ROM palette, which fades the
--      painted copy with everything else.
--
-- A screenshot cannot settle this: the drawn tier is a Lua overlay painted after the frame, so
-- `client.screenshot()` never sees it (agent_docs/playing.md). So this probe logs the INPUTS to
-- both mechanisms every frame across a transition, and the answer is read off the table.
--
-- WHAT IT LOGS, one line per frame while armed:
--   f       -- frame counter
--   cb2     -- gMain.callback2, so the map-load/fade handlers are visible as themselves
--   map     -- gSaveBlock1Ptr->location group.num: when the map id ACTUALLY changes
--   spr     -- the player's sprite id, and inv=1 when its invisible bit is set (mechanism 1)
--   pal     -- the OBJ palette slot that sprite is drawn from
--   ratio   -- the OLD scalar brightness ratio, live/ROM clamped to 1: what the adapter used
--              until 2026-08-21, kept so a log line shows why it could not see a white fade
--   a, b    -- the blend fit the adapter uses now, live = a*rom + b (b in 0..255 units)
--
-- ADDRESSES are the adapter's own, already cited in meshghost_emerald.lua: gSaveBlock1Ptr
-- 0x03005d8c, gSaveBlock2Ptr 0x03005d90, gPlayerAvatar 0x02037590 (spriteId at +0x04),
-- gSprites 0x02020630 stride 0x44, gMain.callback2 0x030022c4, and the two ROM object palettes.
-- Palette RAM 0x05000200 is GBA hardware (OBJ palettes), not a fact about this game.
--
-- HOW TO USE. Load it beside the adapter through the dev loader, then write a command into
-- probes/cavewarp.cmd: `arm <frames>` starts a run (default 240), `off` stops one early. It logs
-- to a timestamped file beside itself -- a verdict that exists only in the Lua Console has to be
-- copied back by a human (adapters/_template/probes.md).
--
-- COST. Thirty-four 16-bit palette reads plus a handful of byte reads per frame, and only while
-- armed. It writes one buffered line per frame and flushes when the run ends, because per-frame
-- file I/O is itself measurable -- a probe's own logging cost 7.4 fps on 2026-08-21.

local SB1PTR = 0x03005d8c
local SB2PTR = 0x03005d90
local GPLAYERAVATAR = 0x02037590
local GSPRITES = 0x02020630
local SPRITE_SIZE = 0x44
local GMAIN_CB2 = 0x030022c4
local OBJPAL_RAM = 0x05000200
local PAL_BRENDAN = 0x084987f8
local PAL_MAY = 0x084a4278

-- Its own directory, so the log and the command file sit beside this script wherever the repo
-- lives -- the same helper fpshold.lua uses, and the reason is the public-repo rule: no tracked
-- file may carry a machine-specific path.
local function scriptDir()
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
    end
    return "."
end

local DIR = scriptDir() .. "/"
local CMD = DIR .. "cavewarp.cmd"

local r8 = memory.read_u8
local r16 = memory.read_u16_le
local r32 = memory.read_u32_le

local armed, left, buf, out, lastCmd, n = false, 0, nil, nil, "", 0

local function stamp()
    return os.date("%Y%m%d_%H%M%S")
end

local function readCmd()
    local f = io.open(CMD, "r")
    if not f then return nil end
    local s = f:read("*a") or ""
    f:close()
    return (s:gsub("%s+$", ""))
end

-- drawRemotes' own brightness arithmetic, repeated here rather than shared: this probe must be
-- able to disagree with the adapter, and a shared helper could only ever agree with it.
local function sceneDim(spriteAddr)
    local slot = (r16(spriteAddr + 0x04) >> 12) & 0xF
    local romPal = PAL_BRENDAN
    local sb2 = r32(SB2PTR)
    if sb2 ~= 0 and r8(sb2 + 0x08) == 1 then romPal = PAL_MAY end
    local live, ref = 0, 0
    local sx, sy, sxx, sxy, syy = 0, 0, 0, 0, 0
    local xs, ys = {}, {}
    for i = 0, 15 do
        local c = r16(OBJPAL_RAM + slot * 32 + i * 2)
        live = live + (c & 0x1F) + ((c >> 5) & 0x1F) + ((c >> 10) & 0x1F)
        local o = r16(romPal + i * 2)
        ref = ref + (o & 0x1F) + ((o >> 5) & 0x1F) + ((o >> 10) & 0x1F)
        for s = 0, 10, 5 do
            local x, y = (o >> s) & 0x1F, (c >> s) & 0x1F
            local k = #xs + 1
            xs[k], ys[k] = x, y
            sx, sy = sx + x, sy + y
        end
    end
    -- The OLD scalar ratio, kept alongside the new fit so a log line shows both and the
    -- difference between them is visible rather than argued about.
    local dim = 1
    if ref > 0 then dim = live / ref end
    if dim > 1 then dim = 1 elseif dim < 0 then dim = 0 end

    -- drawRemotes' blend fit: live = a*rom + b across all 48 channel values.
    local nPts = #xs
    local mx, my = sx / nPts, sy / nPts
    for i = 1, nPts do
        local dx, dy = xs[i] - mx, ys[i] - my
        sxx, sxy, syy = sxx + dx * dx, sxy + dx * dy, syy + dy * dy
    end
    local a, b
    if syy < 1e-6 then
        a, b = 0, my
    elseif sxx > 1e-6 and sxy * sxy > 0.9 * sxx * syy then
        a = sxy / sxx
        b = my - a * mx
    end
    if not a then a, b = 1, 0 end
    if a > 1 then a = 1 elseif a < 0 then a = 0 end
    b = b * (255 / 31)
    if b > 255 then b = 255 elseif b < 0 then b = 0 end
    return dim, slot, live, ref, a, b
end

local function finish()
    if out and buf then
        out:write(table.concat(buf, "\n"))
        out:write("\n")
        out:close()
        console.log("cavewarp: wrote " .. #buf .. " frames")
    end
    armed, buf, out = false, nil, nil
end

MESHGHOST_DEV_TICK = function()
    n = n + 1

    if armed then
        local sb1 = r32(SB1PTR)
        local spriteId = r8(GPLAYERAVATAR + 0x04)
        local sa = GSPRITES + spriteId * SPRITE_SIZE
        local dim, slot, live, ref, a, b = sceneDim(sa)
        buf[#buf + 1] = string.format(
            "f=%d cb2=%08X map=%d.%d spr=%d inv=%d pal=%d live=%d ref=%d ratio=%.3f a=%.3f b=%.1f",
            n, r32(GMAIN_CB2),
            sb1 ~= 0 and r8(sb1 + 0x04) or -1, sb1 ~= 0 and r8(sb1 + 0x05) or -1,
            spriteId, (r8(sa + 0x3e) & 0x04) ~= 0 and 1 or 0,
            slot, live, ref, dim, a, b)
        left = left - 1
        if left <= 0 then finish() end
    end

    if n % 15 ~= 0 then return end
    local c = readCmd()
    if not c or c == "" or c == lastCmd then return end
    lastCmd = c
    local verb, a1 = c:match("^(%S+)%s*(%S*)")
    if verb == "arm" then
        if armed then finish() end
        local path = DIR .. "cavewarp_probe_" .. stamp() .. ".log"
        out = io.open(path, "w")
        if not out then
            console.log("cavewarp: could not open " .. path)
            return
        end
        buf, left, armed = {}, tonumber(a1) or 240, true
        console.log("cavewarp: armed for " .. left .. " frames -> " .. path)
    elseif verb == "off" then
        finish()
    end
end

MESHGHOST_DEV_UNLOAD = function() finish() end
