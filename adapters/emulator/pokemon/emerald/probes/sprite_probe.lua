-- MeshGhost — does Brendan's overworld sprite decode straight from ROM (dev tool, read-only, vanilla only, never
-- shipped). Prints gObjectEventPal_Brendan as RGB and frame 0 of gObjectEventPic_BrendanNormal as a grid of palette
-- indices, one hex digit per pixel, to compare against the sprite on screen.

local GOBJECTEVENTPIC_BRENDANNORMAL_ADDR = 0x084975f8
local GOBJECTEVENTPAL_BRENDAN_ADDR = 0x084987f8
local FRAME_WIDTH_TILES = 2
local FRAME_HEIGHT_TILES = 4
local FRAME_BYTES = FRAME_WIDTH_TILES * FRAME_HEIGHT_TILES * 32

if not memory.usememorydomain("System Bus") then
    console.log("ERROR: 'System Bus' memory domain not found on this core.")
    console.log("Domains available: " .. memory.getmemorydomainlist())
    return
end

-- Replicates the top bits into the low ones so 31 becomes 255; a plain *8 would leave white at 248.
local function expand5to8(v5) return (v5 << 3) | (v5 >> 2) end

local function decodePalette(addr)
    local pal = {}
    for i = 0, 15 do
        local c = memory.read_u16_le(addr + i * 2)
        local r5 = c & 0x1F
        local g5 = (c >> 5) & 0x1F
        local b5 = (c >> 10) & 0x1F
        pal[i] = { r = expand5to8(r5), g = expand5to8(g5), b = expand5to8(b5) }
    end
    return pal
end

local function decodeFrame(addr)
    local widthPx = FRAME_WIDTH_TILES * 8
    local heightPx = FRAME_HEIGHT_TILES * 8
    local grid = {}
    for py = 0, heightPx - 1 do
        grid[py] = {}
        local tileRow = py // 8
        local localY = py % 8
        for px = 0, widthPx - 1 do
            local tileCol = px // 8
            local localX = px % 8
            local tileIndex = tileRow * FRAME_WIDTH_TILES + tileCol
            local tileByteOffset = tileIndex * 32 + localY * 4 + (localX // 2)
            local b = memory.read_u8(addr + tileByteOffset)
            local index
            if localX % 2 == 0 then
                index = b & 0x0F
            else
                index = (b >> 4) & 0x0F
            end
            grid[py][px] = index
        end
    end
    return grid, widthPx, heightPx
end

console.log("MeshGhost Phase 5.5 Step 1: decoding gObjectEventPic_BrendanNormal frame 0.")

local palette = decodePalette(GOBJECTEVENTPAL_BRENDAN_ADDR)
console.log("Palette (16 colors, BGR555 -> RGB):")
for i = 0, 15 do
    local c = palette[i]
    console.log(string.format("  [%2d] r=%3d g=%3d b=%3d", i, c.r, c.g, c.b))
end

local grid, w, h = decodeFrame(GOBJECTEVENTPIC_BRENDANNORMAL_ADDR)
console.log(string.format("Decoded frame 0, %dx%d px, as palette-index hex digits (0=transparent):", w, h))
for py = 0, h - 1 do
    local row = {}
    for px = 0, w - 1 do
        row[px + 1] = string.format("%X", grid[py][px])
    end
    console.log(table.concat(row))
end

console.log("Done. Compare the palette RGB values and the ASCII silhouette above against a real")
console.log("Brendan overworld sprite (hat/hair color, skin tone, and a recognizable humanoid")
console.log("shape with a hat on top) to confirm this is real decoded image data, not noise.")
