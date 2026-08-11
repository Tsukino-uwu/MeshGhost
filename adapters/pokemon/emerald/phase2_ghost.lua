-- Phase 2: fake ghost, no network. Draws a hardcoded-offset placeholder image next to the
-- local player every frame, using the same sprite->screen conversion the game itself uses
-- for field object sprites. Proves the map/camera -> screen pixel math before any network
-- code exists. Never writes memory.
--
-- Ghost position = local player's own on-screen sprite position + a hardcoded pixel offset.
-- This deliberately reuses the player's real screen coordinates (which already account for
-- camera scroll) rather than reimplementing camera math independently, so what's being
-- proven is "can we read and reproduce the game's own sprite->screen placement," which is
-- the actual risk Phase 3+ needs retired before real remote positions are involved.
--
-- Address/formula sources, all from the same make-compare-verified pokeemerald build used in
-- Phase 1 (see agent_docs/verified.md for the build verification entry):
--   gSaveBlock1Ptr = 0x03005d8c        (include/global.h L1081; reused from Phase 1 for the
--                                        nil/no-save-loaded gate)
--   gPlayerAvatar   = 0x02037590        (confirmed Phase 1, pokeemerald.map/.sym)
--     +0x04 spriteId  u8                (include/global.fieldmap.h L348)
--   gSprites         = 0x02020630, entry size 0x44 (pokeemerald.sym: `02020630 g 00001144
--                                        gSprites`; 0x1144 / (MAX_SPRITES+1=65) = 0x44,
--                                        matching struct Sprite's field layout below)
--   struct Sprite (include/sprite.h L194-242):
--     +0x20 x   s16
--     +0x22 y   s16
--     +0x24 x2  s16
--     +0x26 y2  s16
--     +0x28 centerToCornerVecX  s8
--     +0x29 centerToCornerVecY  s8
--   gSpriteCoordOffsetX = 0x02021bbc  s16  (pokeemerald.sym)
--   gSpriteCoordOffsetY = 0x02021bbe  s16  (pokeemerald.sym)
--
--   Screen-position formula (NOT re-derived independently -- copied in spirit, not in code,
--   from how the game computes it for offscreen-culling its own object event sprites):
--     screenX = sprite.x + sprite.x2 + sprite.centerToCornerVecX + gSpriteCoordOffsetX
--     screenY = sprite.y + sprite.y2 + sprite.centerToCornerVecY + gSpriteCoordOffsetY
--   Source: src/event_object_movement.c L7361-7363 (UpdateObjectEventOffscreen), which then
--   compares the result against DISPLAY_WIDTH/DISPLAY_HEIGHT (240x160) confirming this is a
--   top-left-origin screen-pixel value, not a map or camera-relative value. Assumes the
--   player's own sprite always has coordOffsetEnabled set (true for all field object sprites
--   per the same function) -- NOT YET CONFIRMED ON SCREEN, only read from source; the on-screen
--   test below is what confirms or refutes that assumption.
--
-- gui.drawImage signature/behavior source: TASEmulators/BizHawk
-- Assets/Lua/_docs_luacats/gui.d.lua -- "function gui.drawImage(path, x, y, width, height,
-- cache, surfaceName)", supports .bmp/.gif/.jpg/.png/.tif, caches file contents by path.
--
-- Placeholder art: adapters/pokemon/emerald/assets/ghost_placeholder.bmp, a flat 16x16 magenta box
-- generated for this project (not ripped from any game) -- see agent_docs/licensing.md.

local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GPLAYERAVATAR_ADDR = 0x02037590
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
local GSPRITECOORDOFFSETX_ADDR = 0x02021bbc
local GSPRITECOORDOFFSETY_ADDR = 0x02021bbe

-- Hardcoded screen-pixel offset from the local player's own screen position. Arbitrary for
-- Phase 2 -- there is no real remote player yet. Placed up-and-right of the player.
local GHOST_OFFSET_X = 16
local GHOST_OFFSET_Y = -16

-- Path made relative to this script's own location -- a portability fix (2026-08-11, ahead of
-- publishing this repo publicly) to a hardcoded absolute path from Phase 2's original session
-- that only ever worked on that one machine. Uses the same io.popen("cd") approach
-- phase3_loopback.lua's scriptDir() later established (see that script's header for why
-- debug.getinfo does NOT work here); this is the one deviation from this file's otherwise
-- frozen-historical-record status, since a hardcoded personal path is a real bug for anyone
-- else running this script, not just a stylistic inconsistency.
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
