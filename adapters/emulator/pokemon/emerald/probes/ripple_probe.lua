-- MeshGhost — Emerald: every new sprite, ripple or not: what built it, where it appeared, how long it lived (dev tool).
-- Load it beside the adapter and write `arm <frames>` (default 600) into ripple.cmd beside this file while surfing.

local GSPRITES = 0x02020630
local SPRITE_SIZE = 0x44
local GPLAYERAVATAR = 0x02037590
local GOBJECTEVENTS = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local SB1PTR = 0x03005d8c

-- Its own directory, wherever the repo lives: no tracked file may carry a machine-specific path.
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
    -- The OAM data is inline in the sprite (8 bytes at +0x00), so these three halfwords are the whole of it.
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
        -- Everything already on screen, so a sprite born before the run is still identified when it changes or dies.
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
