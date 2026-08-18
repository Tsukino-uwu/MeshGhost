-- Phase 5.5 Step 1: sprite-decode feasibility probe. Not a phase deliverable -- a throwaway
-- diagnostic to confirm, before building any rendering, that gObjectEventPic_BrendanNormal /
-- gObjectEventPal_Brendan really are raw uncompressed 4bpp tile data + a raw BGR555 palette at
-- the addresses found by reading the decomp, and that this script decodes them correctly.
-- Never writes memory. Same probe-script convention as battle_probe.lua.
--
-- Address source: pret/pokeemerald, built locally 2026-08-11 from a checkout matching ROM
-- SHA1 F3AE088181BF583E55DAF962A92BB46F4F1D07B7 (`make compare` -> "pokeemerald.gba: OK"),
-- same build cited by every other address in agent_docs/verified.md. Read directly from
-- pokeemerald.sym (not from memory):
--   gObjectEventPic_BrendanNormal = 0x084975F8, size 0x900 (9 walking frames x 256 bytes/frame)
--   gObjectEventPal_Brendan       = 0x084987F8, size 0x20 (16 colors x 2 bytes, BGR555)
-- Frame size: src/data/object_events/object_event_pic_tables.h's sPicTable_BrendanNormal uses
-- overworld_frame(gObjectEventPic_BrendanNormal, 2, 4, frame) -- a 2x4 tile grid (16x32px).
-- Confirmed uncompressed (not LZ77): src/data/object_events/object_event_graphics.h declares
-- both as INCGFX_U32(..., ".4bpp"/.gbapal", ...) -- the ".lz" suffix (used elsewhere in this
-- same decomp for compressed graphics) is absent here, so this is a plain byte array in ROM,
-- no decompression needed, just a direct memory read + 4bpp/BGR555 decode.
--
-- 4bpp tile format (standard GBA format, not project-specific -- same format every GBA game
-- uses, documented independently of any single decomp): each 8x8 tile is 32 bytes, 4 bytes per
-- row, 2 pixels per byte (low nibble = left pixel, high nibble = right pixel). This decomp's
-- tile grid is stored row-major: tile index = tileRow * gridWidthInTiles + tileCol.
--
-- NOT YET CONFIRMED: this probe is exactly what confirms it. Prints the whole decoded frame as
-- an ASCII palette-index grid (one hex digit per pixel -- a recognizable trainer silhouette,
-- hat on top, means the tile decode and frame offset are right) and the 16-color palette
-- resolved to RGB (should look like a plausible trainer palette: skin tone, cap color, etc.,
-- not visual noise).

local GOBJECTEVENTPIC_BRENDANNORMAL_ADDR = 0x084975f8
local GOBJECTEVENTPAL_BRENDAN_ADDR = 0x084987f8
local FRAME_WIDTH_TILES = 2
local FRAME_HEIGHT_TILES = 4
local FRAME_BYTES = FRAME_WIDTH_TILES * FRAME_HEIGHT_TILES * 32 -- 256

if not memory.usememorydomain("System Bus") then
    console.log("ERROR: 'System Bus' memory domain not found on this core.")
    console.log("Domains available: " .. memory.getmemorydomainlist())
    return
end

-- 5-bit -> 8-bit: replicate the top 3 bits into the low bits, the standard GBA color
-- expansion (not a project-specific choice -- same formula every GBA-color-aware tool uses)
-- rather than a naive *8 which would leave pure white as 0xF8 instead of 0xFF.
local function expand5to8(v5) return (v5 << 3) | (v5 >> 2) end

-- decodePalette reads 16 BGR555 u16 colors starting at addr, returns a table of {r,g,b} 0-255.
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

-- decodeFrame reads one FRAME_BYTES-byte 4bpp frame at addr, returns a
-- FRAME_WIDTH_TILES*8 x FRAME_HEIGHT_TILES*8 grid of palette indices (0-15), row-major.
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
