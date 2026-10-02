-- MeshGhost — Emerald warp-transition probe (dev tool, read-only, never shipped). Logs the inputs to the drawn
-- tier's two hiding mechanisms every frame while armed: the player sprite's invisible bit and the live-vs-ROM OBJ
-- palette, as the old scalar ratio and the blend fit live = a*rom + b (b in 0..255). A screenshot cannot see the
-- drawn tier. Write `arm <frames>` (default 240) or `off` into cavewarp.cmd beside it.

local SB1PTR = 0x03005d8c
local SB2PTR = 0x03005d90
local GPLAYERAVATAR = 0x02037590
local GSPRITES = 0x02020630
local SPRITE_SIZE = 0x44
local GMAIN_CB2 = 0x030022c4
local OBJPAL_RAM = 0x05000200
local PAL_BRENDAN = 0x084987f8
local PAL_MAY = 0x084a4278

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

-- drawRemotes' brightness arithmetic, repeated rather than shared so the probe can disagree with the adapter.
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
    local dim = 1
    if ref > 0 then dim = live / ref end
    if dim > 1 then dim = 1 elseif dim < 0 then dim = 0 end

    -- The blend fit, across all 48 channel values.
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
