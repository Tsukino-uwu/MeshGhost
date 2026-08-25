-- MeshGhost -- Emerald water-ripple probe (DEVELOPMENT TOOL, never shipped)
--
-- WHY IT EXISTS
-- The user, watching all three tiers surf at Sootopolis 2026-08-21: *"drawn & oam are not leaving
-- trails in the water when they move around."* A surfing character leaves a ripple behind it, and
-- that ripple is a FIELD EFFECT the engine spawns -- so the spawned tier has always had it for
-- free and neither of the two tiers that do their own drawing has it at all. It is the same family
-- as the jump shadow and the landing dust, both of which were built the same way: measure the
-- game's own sprite, then reproduce it from the ROM data it points at.
--
-- WHAT IT MEASURES, and it is deliberately measuring rather than reading an address out of a
-- decompilation, because what this needs is not "where is the template" but "when does the engine
-- decide to make one, and where does it put it":
--
--   * every sprite that COMES INTO EXISTENCE while the probe runs (inUse 0 -> 1), logged once with
--     its full descriptor: callback, the anims/images/oam pointers it was built from, its palette
--     slot and subpriority. Those three ROM pointers are all the adapter needs to draw the same
--     frames later -- exactly how the surf blob was reproduced, and it means no address here has
--     to be written down from memory;
--   * WHERE it appeared relative to the player, and what the player was doing at that moment --
--     position, facing, whether it had just changed tile;
--   * HOW LONG it lived, and its animation number and frame index each time either changed.
--
-- That is the whole specification of a trail: what it looks like, where it is dropped, how often,
-- and how long it lasts.
--
-- HOW TO USE. Load it beside the adapter through the dev loader, write `arm <frames>` into
-- probes/ripple.cmd (default 600 -- ten seconds, which wants the player surfing about for the
-- whole of it), and read the timestamped log beside this file.
--
-- LOOK FIRST, THEN READ THE LOG: it reports every new sprite, not only ripples, because deciding
-- in advance which ones are ripples is exactly the assumption worth not making. A ghost's own
-- effects appear here too and are identified by their callbacks, which the adapter already names.
--
-- COST. One pass over the 64-entry sprite table per frame -- 64 byte reads -- plus a handful of
-- reads per sprite that actually changed. Buffered, flushed at the end of the run, for the reason
-- every probe here is: per-frame file I/O measurably costs frame rate.
--
-- ADDRESSES are the adapter's own, cited there: gSprites 0x02020630 with stride 0x44, and the
-- sprite struct's offsets -- oam +0x00, anims +0x08, images +0x0c, callback +0x1c, pos1 +0x20/+22,
-- pos2 +0x24/+26, animNum +0x2a, animCmdIndex +0x2b, data +0x2e, flags +0x3e (inUse bit 0,
-- invisible bit 2), subpriority +0x43. gPlayerAvatar 0x02037590 (spriteId +0x04, objectEventId
-- +0x05), gObjectEvents 0x02037350 with stride 0x24, gSaveBlock1Ptr 0x03005d8c.

local GSPRITES = 0x02020630
local SPRITE_SIZE = 0x44
local GPLAYERAVATAR = 0x02037590
local GOBJECTEVENTS = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local SB1PTR = 0x03005d8c

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
local CMD = DIR .. "ripple.cmd"

local r8 = memory.read_u8
local r16 = memory.read_u16_le
local r32 = memory.read_u32_le
local rs16 = memory.read_s16_le

local armed, left, buf, out, lastCmd, n = false, 0, nil, nil, "", 0
-- per sprite index: { born, cb, animNum, animIdx }
local seen = {}

local function say(line)
    if buf then buf[#buf + 1] = line end
end

local function readCmd()
    local f = io.open(CMD, "r")
    if not f then return nil end
    local s = f:read("*a") or ""
    f:close()
    return (s:gsub("%s+$", ""))
end

local function playerState()
    local objId = r8(GPLAYERAVATAR + 0x05)
    local o = GOBJECTEVENTS + objId * OBJECTEVENT_SIZE
    local sprId = r8(GPLAYERAVATAR + 0x04)
    local sa = GSPRITES + sprId * SPRITE_SIZE
    return string.format(
        "player tile=%d,%d facing=%d act=%d spr=%d,%d pos2=%d,%d anim=%d/%d",
        rs16(o + 0x10), rs16(o + 0x12), r8(o + 0x0d), r8(o + 0x1c),
        rs16(sa + 0x20), rs16(sa + 0x22), rs16(sa + 0x24), rs16(sa + 0x26),
        r8(sa + 0x2a), r8(sa + 0x2b))
end

local function describe(i)
    local a = GSPRITES + i * SPRITE_SIZE
    -- The OAM data is INLINE in the sprite (8 bytes at +0x00), not a pointer, so the three
    -- attribute halfwords below are the whole of it -- shape, size, tile, priority and palette.
    return string.format(
        "spr=%d cb=%08X anims=%08X images=%08X pal=%d subpri=%d "
        .. "attr=%04X/%04X/%04X pos=%d,%d pos2=%d,%d ctc=%d,%d data0=%d data2=%d",
        i, r32(a + 0x1c), r32(a + 0x08), r32(a + 0x0c),
        (r16(a + 0x04) >> 12) & 0xf, r8(a + 0x43),
        r16(a + 0x00), r16(a + 0x02), r16(a + 0x04),
        rs16(a + 0x20), rs16(a + 0x22), rs16(a + 0x24), rs16(a + 0x26),
        memory.read_s8(a + 0x28), memory.read_s8(a + 0x29),
        r16(a + 0x2e), r16(a + 0x32))
end

local function finish()
    if out and buf then
        out:write(table.concat(buf, "\n"))
        out:write("\n")
        out:close()
        console.log("ripple: wrote " .. #buf .. " lines")
    end
    armed, buf, out = false, nil, nil
    seen = {}
end

MESHGHOST_DEV_TICK = function()
    n = n + 1

    if armed then
        for i = 0, 63 do
            local a = GSPRITES + i * SPRITE_SIZE
            local live = (r8(a + 0x3e) & 0x01) ~= 0
            local rec = seen[i]
            if live and not rec then
                seen[i] = { born = n, animNum = r8(a + 0x2a), animIdx = r8(a + 0x2b) }
                say(string.format("f=%d NEW  %s", n, describe(i)))
                say(string.format("f=%d      %s", n, playerState()))
            elseif live and rec then
                local an, ai = r8(a + 0x2a), r8(a + 0x2b)
                if an ~= rec.animNum or ai ~= rec.animIdx then
                    say(string.format("f=%d ANIM spr=%d %d/%d -> %d/%d (age %d) pos=%d,%d",
                        n, i, rec.animNum, rec.animIdx, an, ai, n - rec.born,
                        rs16(a + 0x20), rs16(a + 0x22)))
                    rec.animNum, rec.animIdx = an, ai
                end
            elseif rec and not live then
                say(string.format("f=%d GONE spr=%d after %d frames", n, i, n - rec.born))
                seen[i] = nil
            end
        end
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
        local path = DIR .. "ripple_probe_" .. os.date("%Y%m%d_%H%M%S") .. ".log"
        out = io.open(path, "w")
        if not out then
            console.log("ripple: could not open " .. path)
            return
        end
        buf, left, armed, seen = {}, tonumber(a1) or 600, true, {}
        -- Everything already on screen, so a sprite that was born before the run can still be
        -- identified when it changes or dies -- and so the log opens with the scene it started in.
        for i = 0, 63 do
            local a = GSPRITES + i * SPRITE_SIZE
            if (r8(a + 0x3e) & 0x01) ~= 0 then
                seen[i] = { born = n, animNum = r8(a + 0x2a), animIdx = r8(a + 0x2b) }
                say(string.format("f=%d PRE  %s", n, describe(i)))
            end
        end
        say(string.format("f=%d      %s", n, playerState()))
        console.log("ripple: armed for " .. left .. " frames -> " .. path)
    elseif verb == "off" then
        finish()
    end
end

MESHGHOST_DEV_UNLOAD = function() finish() end
