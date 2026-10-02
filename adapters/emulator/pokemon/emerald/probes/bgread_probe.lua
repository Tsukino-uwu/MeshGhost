-- Can the BG layers be read at all? Prints the four BG control registers and their scroll, and checks that the
-- tilemaps and the tile pixels are not all zero: an all-zero VRAM read is an instrument fault, not an answer.
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
    -- All zero would mean the read is not landing on the tilemap.
    for bg = 1, 2 do
        local cnt = r16(0x04000008 + bg * 2)
        local base = 0x06000000 + ((cnt >> 8) & 0x1f) * 0x800
        local nz = 0
        for i = 0, 1023 do if r16(base + i * 2) ~= 0 then nz = nz + 1 end end
        say(string.format("BG%d tilemap at %08X: %d/1024 entries non-zero", bg, base, nz))
    end
    local cnt1 = r16(0x0400000a)
    local charBase = 0x06000000 + ((cnt1 >> 2) & 3) * 0x4000
    local nz = 0
    for i = 0, 2047 do if r16(charBase + i * 2) ~= 0 then nz = nz + 1 end end
    say(string.format("tile pixels at %08X: %d/2048 halfwords non-zero", charBase, nz))
    say("DISPCNT=" .. string.format("%04X", r16(0x04000000)))
end
if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
