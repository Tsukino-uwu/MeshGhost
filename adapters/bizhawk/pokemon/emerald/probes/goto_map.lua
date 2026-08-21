-- MeshGhost -- warp the player to any map (DEV TOOL, never shipped)
--
-- WHY. Testing the Acro Bike means being where the Acro Bike is, and walking there costs the user
-- time for nothing (agent_docs/playing.md, "Drive the game YOURSELF before asking"). Cheating to
-- reach a state is explicitly allowed; cheating is never in an adapter.
--
-- HOW, and it is the game's own map load rather than a coordinate poke alone. Writing the
-- player's position by itself would move them WITHOUT loading the destination map -- the tiles,
-- objects and connections would still be the old map's. The route is four writes:
--   1. sWarpDestination AND gSaveBlock1Ptr->location -- where to go (struct WarpData: s8 mapGroup,
--      s8 mapNum, s8 warpId, pad, s16 x, s16 y).
--   2. gSaveBlock1Ptr->pos -- WHERE ON THAT MAP TO STAND. See below; this is not optional.
--   3. gMain.callback2 = CB2_LoadMap, which loads the map named by location.
--   4. gFieldCallback = FieldCB_DefaultWarpExit -- the ordinary arrive-from-a-warp fade-in, so it
--      looks like every other door in the game rather than a hard cut.
--
-- THE PLAYER'S POSITION IS OURS TO SET, and believing otherwise trapped the user twice on
-- 2026-08-21. CB2_LoadMap does NOT warp: it is FieldClearVBlankHBlankCallbacks, ScriptContext_Init,
-- UnlockPlayerFieldControls, then CB2_DoChangeMap -> CB2_LoadMap2 -> DoMapLoadLoop
-- (src/overworld.c). `WarpIntoMap` -- the function that calls ApplyCurrentWarp, LoadCurrentMapData
-- and SetPlayerCoordsFromWarp -- is never on that path; every caller of it is elsewhere
-- (field_screen_effect.c, field_effect.c, ...). So SetPlayerCoordsFromWarp never runs, warpId is
-- never consulted, and the player keeps the coordinates they had on the map they left.
--
-- That is invisible when the destination is BIGGER than the old coordinates, which is why this
-- probe looked correct for a week of warps to Mauville (40x20). Warping out of Route 126 at
-- (45,68) into Mossdeep City (80x40) put the player outside the map, in the border fill -- open
-- water with no land in it, and MAPGRID_UNDEFINED all round, so they could not move in any
-- direction. It reads exactly like a hang.
--
-- So give MESHGHOST_WARP_X / _Y for any destination smaller than where you are coming from. Take
-- them from the map's own data rather than inventing them -- a warp event's x/y in
-- data/maps/<Map>/map.json is a tile the game itself puts the player on. Without them this warns
-- and keeps the old coordinates, which is only safe for a big destination.
--
-- THE AVATAR STATE LOOKS AFTER ITSELF, and that is the one thing not to hand-fix: the map load
-- re-derives it from the tile landed on (GetAdjustedInitialTransitionFlags, src/overworld.c), so
-- a SURFING player warped onto a floor tile arrives on foot, with no blob to clean up.
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
-- Where to stand once there. nil keeps the coordinates from the map being left, which strands the
-- player outside anything smaller -- see the header.
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
    local sb1 = memory.read_u32_le(0x03005d8c)
    writeWarp(sb1 + 0x04)

    -- AND THE POSITION, because nothing on CB2_LoadMap's path will set it (see the header).
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
