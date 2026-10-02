-- Phase 5.5 step 2, no network: draws the decoded Brendan frame with gui.drawPixel at a fixed offset from the
-- player, using sprite_probe.lua's decode and phase2_ghost.lua's screen position. The frame is decoded once (ROM
-- data never changes) into {x, y, color} draws, skipping palette index 0; gui.drawPixel takes 0xAARRGGBB. Never
-- writes memory.

local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GPLAYERAVATAR_ADDR = 0x02037590
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
local GSPRITECOORDOFFSETX_ADDR = 0x02021bbc
local GSPRITECOORDOFFSETY_ADDR = 0x02021bbe

local GOBJECTEVENTPIC_BRENDANNORMAL_ADDR = 0x084975f8
local GOBJECTEVENTPAL_BRENDAN_ADDR = 0x084987f8
local FRAME_WIDTH_TILES = 2
local FRAME_HEIGHT_TILES = 4

-- Arbitrary: just visibly apart from the player.
local GHOST_OFFSET_X = 24
local GHOST_OFFSET_Y = -16

if not memory.usememorydomain("System Bus") then
    console.log("ERROR: 'System Bus' memory domain not found on this core.")
    console.log("Domains available: " .. memory.getmemorydomainlist())
    return
end

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

-- One frame as a flat list of {x, y, color} from its top-left corner, skipping palette index 0 (transparent).
local function decodeFrameDrawList(picAddr, palAddr)
    local palette = decodePalette(palAddr)
    local widthPx = FRAME_WIDTH_TILES * 8
    local heightPx = FRAME_HEIGHT_TILES * 8
    local pixels = {}
    for py = 0, heightPx - 1 do
        local tileRow = py // 8
        local localY = py % 8
        for px = 0, widthPx - 1 do
            local tileCol = px // 8
            local localX = px % 8
            local tileIndex = tileRow * FRAME_WIDTH_TILES + tileCol
            local tileByteOffset = tileIndex * 32 + localY * 4 + (localX // 2)
            local b = memory.read_u8(picAddr + tileByteOffset)
            local index
            if localX % 2 == 0 then
                index = b & 0x0F
            else
                index = (b >> 4) & 0x0F
            end
            if index ~= 0 then
                local c = palette[index]
                local color = (0xFF << 24) | (c.r << 16) | (c.g << 8) | c.b
                pixels[#pixels + 1] = { x = px, y = py, color = color }
            end
        end
    end
    return pixels
end

console.log("MeshGhost Phase 5.5 Step 2: drawing decoded Brendan sprite next to the player.")
local ghostPixels = decodeFrameDrawList(GOBJECTEVENTPIC_BRENDANNORMAL_ADDR, GOBJECTEVENTPAL_BRENDAN_ADDR)
console.log(string.format("Decoded %d opaque pixels to draw each frame.", #ghostPixels))

while true do
    -- Every frame: BizHawk's overlay does not clear on its own.
    gui.clearGraphics()

    local base = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
    if base ~= 0 then
        local spriteId = memory.read_u8(GPLAYERAVATAR_ADDR + 0x04)
        local spriteAddr = GSPRITES_ADDR + (spriteId * SPRITE_SIZE)

        local x = memory.read_s16_le(spriteAddr + 0x20)
        local y = memory.read_s16_le(spriteAddr + 0x22)
        local x2 = memory.read_s16_le(spriteAddr + 0x24)
        local y2 = memory.read_s16_le(spriteAddr + 0x26)
        local centerToCornerVecX = memory.read_s8(spriteAddr + 0x28)
        local centerToCornerVecY = memory.read_s8(spriteAddr + 0x29)

        local coordOffsetX = memory.read_s16_le(GSPRITECOORDOFFSETX_ADDR)
        local coordOffsetY = memory.read_s16_le(GSPRITECOORDOFFSETY_ADDR)

        local screenX = x + x2 + centerToCornerVecX + coordOffsetX + GHOST_OFFSET_X
        local screenY = y + y2 + centerToCornerVecY + coordOffsetY + GHOST_OFFSET_Y

        for i = 1, #ghostPixels do
            local p = ghostPixels[i]
            gui.drawPixel(screenX + p.x, screenY + p.y, p.color)
        end
    end
    emu.frameadvance()
end
