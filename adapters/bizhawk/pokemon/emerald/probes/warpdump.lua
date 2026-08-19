-- Where does the game think it is, and what is in the warp structs? (PROBE, never shipped)
local done, n = false, 0
local function tick()
    n = n + 1
    if done or n < 20 then return end
    done = true
    local sb1 = memory.read_u32_le(0x03005d8c)
    -- struct SaveBlock1: struct Coords16 pos (0x00), struct WarpData location (0x04)
    console.log(string.format("warpdump: location group=%d num=%d warpId=%d pos=%d,%d",
        memory.read_u8(sb1 + 0x04), memory.read_u8(sb1 + 0x05),
        memory.read_s8(sb1 + 0x06),
        memory.read_s16_le(sb1 + 0x00), memory.read_s16_le(sb1 + 0x02)))
    for a = 0x020322d8, 0x02032300, 4 do
        console.log(string.format("warpdump: %08X = %02X %02X %02X %02X", a,
            memory.read_u8(a), memory.read_u8(a+1), memory.read_u8(a+2), memory.read_u8(a+3)))
    end
end
if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
