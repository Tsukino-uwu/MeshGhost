-- Phase 2 snapshot, not maintained: a fake ghost with no network. A placeholder is drawn every frame at a fixed
-- offset from the player's own on-screen sprite position, reusing the game's sprite-to-screen placement rather
-- than separate camera math. Never writes memory. The placeholder is a flat 16x16 magenta box made for this project.

local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GPLAYERAVATAR_ADDR = 0x02037590
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
local GSPRITECOORDOFFSETX_ADDR = 0x02021bbc
local GSPRITECOORDOFFSETY_ADDR = 0x02021bbe

-- Arbitrary: there is no remote player yet. Up and right of the player.
local GHOST_OFFSET_X = 16
local GHOST_OFFSET_Y = -16

-- The script's directory from io.popen("cd"), as phase3_loopback.lua does.
local function scriptDir()
    local pwd = io.popen and io.popen("cd"):read("*l")
    if not pwd or pwd == "" then
        error("MeshGhost Phase 2: could not determine the script's own directory (io.popen \"cd\" unavailable or returned nothing).")
    end
    return pwd .. "\\"
end

local GHOST_IMAGE_PATH = scriptDir() .. "assets/ghost_placeholder.bmp"
local GHOST_IMAGE_SIZE = 16

if not memory.usememorydomain("System Bus") then
    console.log("ERROR: 'System Bus' memory domain not found on this core.")
    console.log("Domains available: " .. memory.getmemorydomainlist())
    return
end

console.log("MeshGhost Phase 2 ghost probe running.")
console.log("Ghost should track the player, offset " .. GHOST_OFFSET_X .. "," .. GHOST_OFFSET_Y .. " px on screen.")

while true do
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

        local screenX = x + x2 + centerToCornerVecX + coordOffsetX
        local screenY = y + y2 + centerToCornerVecY + coordOffsetY

        gui.drawImage(GHOST_IMAGE_PATH, screenX + GHOST_OFFSET_X, screenY + GHOST_OFFSET_Y, GHOST_IMAGE_SIZE, GHOST_IMAGE_SIZE)
    end
    emu.frameadvance()
end
