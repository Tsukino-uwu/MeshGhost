-- MeshGhost -- can we read the BG layers at all? (PROBE, never shipped)
--
-- WHY. A drawn reflection has to know whether a higher-priority BG covers a given pixel, which
-- means reading the BG control registers, the tilemaps and the tile pixels in VRAM. This project
-- has a recorded case of a VRAM region reading back as all zeros through the domain in use --
-- which, taken at face value, is a confident and completely false answer (probes.md, "A dud
-- instrument reads as a finding"). So this checks the instrument before anything is built on it.
--
-- Prints the four BG control registers, their scroll, and a non-triviality check on the tilemaps
-- and on tile pixel data.
local function say(s) console.log("bgread: " .. s) end
local done = false
local n = 0
local function tick()
    n = n + 1
    if done or n < 20 then return end
    done = true
    local r16 = function(a) return memory.read_u16_le(a) end
    for bg = 0, 3 do
        local cnt = r16(0x04000008 + bg * 2)
        say(string.format("BG%dCNT=%04X  priority=%d charBase=%d screenBase=%d  hofs=%d vofs=%d",
            bg, cnt, cnt & 3, (cnt >> 2) & 3, (cnt >> 8) & 0x1f,
            r16(0x04000010 + bg * 4), r16(0x04000012 + bg * 4)))
    end
    -- Tilemaps: how many of the first 1024 entries are non-zero, per BG. All-zero would mean the
    -- read is not landing on the tilemap.
    for bg = 1, 2 do
        local cnt = r16(0x04000008 + bg * 2)
        local base = 0x06000000 + ((cnt >> 8) & 0x1f) * 0x800
        local nz = 0
        for i = 0, 1023 do if r16(base + i * 2) ~= 0 then nz = nz + 1 end end
        say(string.format("BG%d tilemap at %08X: %d/1024 entries non-zero", bg, base, nz))
    end
    -- Tile pixels: how many of the first 4KB of character data are non-zero.
    local cnt1 = r16(0x0400000a)
    local charBase = 0x06000000 + ((cnt1 >> 2) & 3) * 0x4000
    local nz = 0
    for i = 0, 2047 do if r16(charBase + i * 2) ~= 0 then nz = nz + 1 end end
    say(string.format("tile pixels at %08X: %d/2048 halfwords non-zero", charBase, nz))
    say("DISPCNT=" .. string.format("%04X", r16(0x04000000)))
end
if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
