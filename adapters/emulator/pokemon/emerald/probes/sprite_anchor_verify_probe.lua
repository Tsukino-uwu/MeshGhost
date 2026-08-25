-- Dev-only follow-up to avatar_verify_probe.lua. That probe confirmed gPlayerAvatar/
-- gObjectEvents are now correct on this Archipelago-patched ROM (real, responsive
-- flags/runningState/facingDirection) -- but the ghost is still observed stuck at a
-- per-reboot-fixed screen position, meaning something ELSE in playerScreenPos()'s formula is
-- still wrong. This probe watches the two pieces never independently tested: GSPRITES_ADDR
-- (0x02020630 vanilla) and GSPRITECOORDOFFSETX/Y_ADDR (0x02021bbc/0x02021bbe vanilla) -- if
-- either is also shifted on this ROM, sx/sy/sx2/sy2/cx/cy would read frozen garbage even with a
-- now-correct spriteId feeding into them. Read-only, never writes memory.

local GPLAYERAVATAR_ADDR = 0x02037814 -- confirmed Archipelago address this session, hardcoded
-- here rather than re-detecting, since this probe is meant to run right after
-- avatar_verify_probe.lua already confirmed this exact address is correct on this ROM/session.
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
local GSPRITECOORDOFFSETX_ADDR = 0x02021bbc
local GSPRITECOORDOFFSETY_ADDR = 0x02021bbe

if not memory.usememorydomain("System Bus") then
    console.log("ERROR: 'System Bus' memory domain not found on this core.")
    console.log("Domains available: " .. memory.getmemorydomainlist())
    return
end

console.log("MeshGhost sprite-anchor verify probe running.")
console.log(string.format("gPlayerAvatar=0x%08X  gSprites=0x%08X  coordOffsetX/Y=0x%08X/0x%08X",
    GPLAYERAVATAR_ADDR, GSPRITES_ADDR, GSPRITECOORDOFFSETX_ADDR, GSPRITECOORDOFFSETY_ADDR))
console.log("Walk around in different directions and watch whether sx/sy/screenX/screenY")
console.log("actually change, or sit frozen while you visibly move on screen.")

local lastLine = nil

while true do
    local spriteId = memory.read_u8(GPLAYERAVATAR_ADDR + 0x04)
    local spriteAddr = GSPRITES_ADDR + (spriteId * SPRITE_SIZE)

    local sx = memory.read_s16_le(spriteAddr + 0x20)
    local sy = memory.read_s16_le(spriteAddr + 0x22)
    local sx2 = memory.read_s16_le(spriteAddr + 0x24)
    local sy2 = memory.read_s16_le(spriteAddr + 0x26)
    local cx = memory.read_s8(spriteAddr + 0x28)
    local cy = memory.read_s8(spriteAddr + 0x29)

    local coordOffsetX = memory.read_s16_le(GSPRITECOORDOFFSETX_ADDR)
    local coordOffsetY = memory.read_s16_le(GSPRITECOORDOFFSETY_ADDR)

    local screenX = sx + sx2 + cx + coordOffsetX
    local screenY = sy + sy2 + cy + coordOffsetY

    local line = string.format(
        "spriteId=%d  sx=%d sy=%d sx2=%d sy2=%d cx=%d cy=%d  coordOffsetX=%d coordOffsetY=%d  -> screenX=%d screenY=%d",
        spriteId, sx, sy, sx2, sy2, cx, cy, coordOffsetX, coordOffsetY, screenX, screenY)
    if line ~= lastLine then
        console.log(line)
        lastLine = line
    end
    emu.frameadvance()
end
