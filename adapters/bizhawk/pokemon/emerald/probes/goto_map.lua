-- MeshGhost -- warp the player to any map (DEV TOOL, never shipped)
--
-- WHY. Testing the Acro Bike means being where the Acro Bike is, and walking there costs the user
-- time for nothing (agent_docs/playing.md, "Drive the game YOURSELF before asking"). Cheating to
-- reach a state is explicitly allowed; cheating is never in an adapter.
--
-- HOW, and it is the game's own warp rather than a coordinate poke. Writing the player's position
-- directly would move them WITHOUT loading the destination map -- the tiles, objects and
-- connections would still be the old map's. The engine's route is three writes:
--   1. sWarpDestination  -- where to go (struct WarpData: s8 mapGroup, s8 mapNum, s8 warpId,
--      pad, s16 x, s16 y).
--   2. gMain.callback2 = CB2_LoadMap -- which runs WarpIntoMap: ApplyCurrentWarp copies
--      sWarpDestination into gSaveBlock1Ptr->location, LoadCurrentMapData loads it, and
--      SetPlayerCoordsFromWarp places the player (overworld.c:603-630).
--   3. gFieldCallback = FieldCB_DefaultWarpExit -- the ordinary arrive-from-a-warp fade-in, so it
--      looks like every other door in the game rather than a hard cut.
-- warpId 0 rather than invented coordinates: SetPlayerCoordsFromWarp prefers a valid warpId and
-- takes the destination's own warp position, so it cannot land the player inside a wall.
--
-- ADDRESSES. gFieldCallback 03005DAC, CB2_LoadMap 08085FCC and FieldCB_DefaultWarpExit 080AF398
-- are named in pokeemerald.map; gMain.callback2 030022C4 is copied from the adapter.
-- sWarpDestination is a STATIC and so has no symbol, but it is derived rather than guessed: the
-- map file puts gLastUsedWarp at 020322DC, and overworld.c:193-194 declares sWarpDestination
-- immediately after it, one 8-byte struct WarpData later -> 020322E4.
--   MAP_MAUVILLE_CITY = (2 | (0 << 8)) -- mapNum 2, mapGroup 0 (constants/map_groups.h:13)
--
-- Thumb entry points need the low bit set, which is why each callback is written +1.
--
-- SAFETY. It checkpoints to savestate slot 8 first (slots 2+ are the agent's, 1 and 9 are the
-- user's), so the trip is free to undo. It fires ONCE and only from the overworld.

local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local GFIELDCALLBACK_ADDR = 0x03005dac
local CB2_LOADMAP_ADDR = 0x08085fcc
local FIELDCB_DEFAULTWARPEXIT_ADDR = 0x080af398
local SWARPDESTINATION_ADDR = 0x020322e4

-- Destination, as globals so a one-line script listed BEFORE this one in the loader's control
-- file can change it without editing this file -- the same pattern MESHGHOST_FORCE_GHOST_GFX uses,
-- and the reason it works mid-session is that the loader loads its targets in order.
-- Map ids are (mapNum | (mapGroup << 8)) in include/constants/map_groups.h, so the two are
-- written separately here. Defaults to Mauville City (mapNum 2, group 0).
local MAUVILLE_GROUP = MESHGHOST_WARP_GROUP or 0
local MAUVILLE_NUM = MESHGHOST_WARP_NUM or 2
local WARP_ID = MESHGHOST_WARP_ID or 0

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

    -- BOTH the pending destination and the live location, because the first attempt wrote only
    -- sWarpDestination and arrived back where it started: read afterwards, that struct held the
    -- CURRENT map, so something replaced the write between setting it and CB2_LoadMap running.
    -- ApplyCurrentWarp copies sWarpDestination over location, so writing both means whichever
    -- survives says Mauville.
    local function writeWarp(addr)
        memory.write_u8(addr + 0, MAUVILLE_GROUP)
        memory.write_u8(addr + 1, MAUVILLE_NUM)
        memory.write_u8(addr + 2, WARP_ID)
        memory.write_u16_le(addr + 4, 0xffff) -- x = -1, unused when warpId is valid
        memory.write_u16_le(addr + 6, 0xffff) -- y = -1
    end
    writeWarp(SWARPDESTINATION_ADDR)
    -- struct SaveBlock1: struct Coords16 pos at 0x00, struct WarpData location at 0x04.
    writeWarp(memory.read_u32_le(0x03005d8c) + 0x04)

    memory.write_u32_le(GFIELDCALLBACK_ADDR, FIELDCB_DEFAULTWARPEXIT_ADDR + 1)
    memory.write_u32_le(GMAIN_CALLBACK2_ADDR, CB2_LOADMAP_ADDR + 1)
    console.log(string.format("gotomap: warping to map %d.%d, warp %d",
        MAUVILLE_GROUP, MAUVILLE_NUM, WARP_ID))
end

if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
