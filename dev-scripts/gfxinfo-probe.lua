-- MeshGhost — dump ObjectEventGraphicsInfo for a few graphics ids (READ-ONLY)
-- The ghost renders as garbage when built from a non-player graphic, so compare the entries
-- field by field: a different size, OAM shape or subsprite table is the likely cause.
local PTRS = 0x08505620
local ids = { 0, 1, 63, 2, 137, 89, 90 }
local names = { [0]="Brendan normal", [1]="Brendan Mach Bike", [63]="Brendan Acro Bike",
                [2]="Brendan surfing", [137]="Brendan fishing", [89]="May normal",
                [90]="May Mach Bike" }
local f = io.open("C:/dev/MeshGhost/dev-scripts/gfxinfo.log", "w")
local function out(s) console.log(s) if f then f:write(s, "\n") end end
local function u16(a) return memory.read_u16_le(a) end
local function u32(a) return memory.read_u32_le(a) end
local function u8(a) return memory.read_u8(a) end

out("id   size  tiles  w   h  palTag palSlot oam        subspr     anims      images")
for _, id in ipairs(ids) do
    local p = u32(PTRS + id * 4)
    if p ~= 0 then
        out(string.format("%3d  %4X  %4d  %3d %3d  %04X   %d       %08X   %08X   %08X   %08X  %s",
            id, u16(p + 0x06), u16(p + 0x06) // 32, u16(p + 0x08), u16(p + 0x0a),
            u16(p + 0x02), u8(p + 0x0c) & 0x0f, u32(p + 0x10), u32(p + 0x14),
            u32(p + 0x18), u32(p + 0x1c), names[id] or ""))
    end
end
if f then f:close() end
MESHGHOST_DEV_TICK = function() end
