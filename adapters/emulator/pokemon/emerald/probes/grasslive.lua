-- What the ENGINE's grass sprites are doing (PROBE, never shipped).
-- The player and any spawned ghost standing in grass each own a real grass sprite. Reading them is
-- the reference the painted copy has to match: where it sits, which frame it is on, and -- the one
-- a screenshot cannot answer -- what subpriority it has relative to the character.
local GPLAYERAVATAR_ADDR = 0x02037590
local GSPRITES_ADDR = 0x02020630
local TALL = 0x0850caa0
local LONG = 0x0850cf94
local last = nil
local function tick()
    local tallImg = memory.read_u32_le(TALL + 0x0c)
    local longImg = memory.read_u32_le(LONG + 0x0c)
    local out = {}
    for i = 0, 63 do
        local d = GSPRITES_ADDR + i * 0x44
        if (memory.read_u8(d + 0x3e) & 0x01) ~= 0 then
            local img = memory.read_u32_le(d + 0x0c)
            -- Everything in use, not just a guessed match: the first version compared against the
            -- template's images pointer and found nothing, which proves the comparison wrong or
            -- the state absent -- and those are different problems.
            if memory.read_u32_le(d + 0x0c) == memory.read_u32_le(TALL + 0x0c)
                or memory.read_u32_le(d + 0x0c) == memory.read_u32_le(LONG + 0x0c) then
                out[#out + 1] = string.format(
                    "spr%d %s pos=%d,%d anim=%d/%d pal=%d prio=%d sub=%d inv=%s",
                    i, string.format("img=%08X", img),
                    memory.read_s16_le(d + 0x20), memory.read_s16_le(d + 0x22),
                    memory.read_u8(d + 0x2a), memory.read_u8(d + 0x2b),
                    (memory.read_u16_le(d + 0x04) >> 12) & 0x0f,
                    memory.read_u16_le(d + 0x04) >> 10 & 0x03,
                    memory.read_u8(d + 0x43),
                    tostring((memory.read_u8(d + 0x3e) & 0x04) ~= 0))
            end
        end
    end
    -- The player's own sprite, as the thing the grass is drawn against.
    local ps = GSPRITES_ADDR + memory.read_u8(GPLAYERAVATAR_ADDR + 0x04) * 0x44
    out[#out + 1] = string.format("PLAYER pos=%d,%d sub=%d prio=%d",
        memory.read_s16_le(ps + 0x20), memory.read_s16_le(ps + 0x22),
        memory.read_u8(ps + 0x43), memory.read_u16_le(ps + 0x04) >> 10 & 0x03)
    -- MY formula for the same tile, so the two can be compared rather than eyeballed. The drawn
    -- tier puts grass at the tile's top-left in screen space; the engine's sprite reports its own
    -- anchor, whose top-left is that minus the sprite's 8px half-size.
    local sb1 = memory.read_u32_le(0x03005d8c)
    local objId = memory.read_u8(GPLAYERAVATAR_ADDR + 0x05)
    local o = 0x02037350 + objId * 0x24
    local gx = memory.read_s16_le(o + 0x10)
    local gy = memory.read_s16_le(o + 0x12)
    local dx = -memory.read_s16_le(0x03005dec) - memory.read_s32_le(0x03005de0)
    local dy = -memory.read_s16_le(0x03005de8) - memory.read_s32_le(0x03005de4)
    local tileLeft = ((gx - memory.read_s16_le(sb1 + 0x00)) << 4) + dx
    local tileTop = ((gy - memory.read_s16_le(sb1 + 0x02)) << 4) + dy
    -- The behaviour under the player, so "no grass sprite" can be told apart from "no grass".
    -- A probe that reports nothing is a finding only once it can prove it would have reported
    -- something (_template/probes.md).
    local w = memory.read_s32_le(0x03005dc0)
    local mp = memory.read_u32_le(0x03005dc0 + 0x08)
    local beh = -1
    if mp ~= 0 and w > 0 then
        local id = memory.read_u16_le(mp + (gx + w * gy) * 2) & 0x03ff
        local lay = memory.read_u32_le(0x02037318)
        local ts, ix
        if id < 512 then ts, ix = memory.read_u32_le(lay + 0x10), id
        else ts, ix = memory.read_u32_le(lay + 0x14), id - 512 end
        if ts ~= 0 then
            local at = memory.read_u32_le(ts + 0x10)
            if at ~= 0 then beh = memory.read_u16_le(at + ix * 2) & 0xff end
        end
    end
    out[#out + 1] = string.format("behaviour=%d (2=tall 3=long)", beh)
    out[#out + 1] = string.format("MINE tile(%d,%d) topleft=%d,%d anchorWouldBe=%d,%d",
        gx, gy, tileLeft, tileTop, tileLeft + 8, tileTop + 8)
    -- Per frame while the player is moving between tiles, which is the case in question. The
    -- count matters as much as the positions: if the engine has TWO grass sprites mid-step and the
    -- painted copy draws two as well, the fault is elsewhere; if it has one somewhere the copy is
    -- not putting one, that is the answer.
    local line = table.concat(out, "  |  ")
    if line ~= last then last = line console.log("grasslive: " .. line) end
end
if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
