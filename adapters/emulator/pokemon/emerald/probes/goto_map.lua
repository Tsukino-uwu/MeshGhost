-- MeshGhost — warp the player to any map through the game's own map load (dev tool, writes live RAM, never shipped).
-- Destination from MESHGHOST_WARP_GROUP/_NUM/_ID and MESHGHOST_WARP_X/_Y: CB2_LoadMap does not place the player, so
-- without X/Y a smaller map leaves them in its border. Checkpoints to slot 8 first; fires once, from the overworld.
-- Thumb entry points need the low bit set, so each callback is written +1.

local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local GFIELDCALLBACK_ADDR = 0x03005dac
local CB2_LOADMAP_ADDR = 0x08085fcc
local FIELDCB_DEFAULTWARPEXIT_ADDR = 0x080af398
local SWARPDESTINATION_ADDR = 0x020322e4 -- a static, derived as gLastUsedWarp + 8 by declaration order

-- Globals, so a script the loader runs before this one can set the destination; Mauville City by default.
local MAUVILLE_GROUP = MESHGHOST_WARP_GROUP or 0
local MAUVILLE_NUM = MESHGHOST_WARP_NUM or 2
local WARP_ID = MESHGHOST_WARP_ID or 0
-- nil keeps the coordinates from the map being left, which strands the player outside a smaller map.
local DEST_X = MESHGHOST_WARP_X
local DEST_Y = MESHGHOST_WARP_Y

local done, n = false, 0

local function tick()
    n = n + 1
    if done or n < 30 then return end

    local cb = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if cb ~= CB2_OVERWORLD_ADDR and cb ~= CB2_OVERWORLD_ADDR + 1 then
        if n % 120 == 0 then console.log("gotomap: waiting for the overworld...") end
        return
    end
    done = true

    savestate.saveslot(8)
    console.log("gotomap: checkpointed to slot 8 (loadslot 8 to come back)")

    -- Both the pending destination and the live location: the pending one alone was replaced before the load.
    local function writeWarp(addr)
        memory.write_u8(addr + 0, MAUVILLE_GROUP)
        memory.write_u8(addr + 1, MAUVILLE_NUM)
        memory.write_u8(addr + 2, WARP_ID)
        memory.write_u16_le(addr + 4, 0xffff) -- x = -1
        memory.write_u16_le(addr + 6, 0xffff) -- y = -1
    end
    writeWarp(SWARPDESTINATION_ADDR)
    local sb1 = memory.read_u32_le(0x03005d8c)
    writeWarp(sb1 + 0x04)

    -- And the position, which nothing on CB2_LoadMap's path sets.
    if DEST_X and DEST_Y then
        memory.write_u16_le(sb1 + 0x00, DEST_X)
        memory.write_u16_le(sb1 + 0x02, DEST_Y)
    else
        console.log(("gotomap: no MESHGHOST_WARP_X/_Y -- keeping (%d,%d). If the destination is "
            .. "smaller than that, the player lands in the border and cannot move.")
            :format(memory.read_s16_le(sb1 + 0x00), memory.read_s16_le(sb1 + 0x02)))
    end

    memory.write_u32_le(GFIELDCALLBACK_ADDR, FIELDCB_DEFAULTWARPEXIT_ADDR + 1)
    memory.write_u32_le(GMAIN_CALLBACK2_ADDR, CB2_LOADMAP_ADDR + 1)
    console.log(string.format("gotomap: warping to map %d.%d, warp %d, at (%s,%s)",
        MAUVILLE_GROUP, MAUVILLE_NUM, WARP_ID, tostring(DEST_X), tostring(DEST_Y)))
end

if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
