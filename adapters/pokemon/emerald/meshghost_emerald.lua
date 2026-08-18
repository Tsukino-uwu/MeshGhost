-- This is the real, actively-maintained Emerald adapter -- what actually ships (see
-- packaging/README.md and .github/workflows/release.yml, which stage this file as
-- games/pokemon/emerald/meshghost_emerald.lua in the release zip) and what any future fix or
-- feature for this game should be made in. adapters/pokemon/emerald/probes/phase5_5_sprite.lua was a
-- byte-identical copy of this file at the moment it was renamed here from that original
-- development-phase name (2026-08-14, once this had been the stable, shipped adapter for a
-- while and "phase5_5_sprite" no longer read as the current, final one it actually was) --
-- it has since diverged (every fix and feature below this point in the history was made only
-- here) and is kept purely as a historical snapshot, not a live mirror -- edit only this file,
-- not that one, going forward.
--
-- Otherwise unchanged from its original Phase 5.5 content: real Brendan/May ghost sprite
-- instead of the magenta placeholder box. Same adapter <-> bridge <-> core round trip as
-- adapters/pokemon/emerald/probes/phase4_multiplayer.lua (state reading, screen-position anchor,
-- JSON, bridge protocol, remote-ghost set, tick model, overworld gate, LuaSocket loading --
-- all unchanged, see that script's header for the full derivation and citations, not
-- re-derived here). Never writes memory.
--
-- What's different from phase4_multiplayer.lua: drawRemotes() decodes and draws the real
-- Brendan/May overworld sprite (gender, facing direction, and walk/run animation, including a
-- genuinely separate running pose -- see below) via gui.drawPixel, instead of
-- gui.drawImage-ing a flat placeholder box. Local gender is read once at script start from
-- gSaveBlock2Ptr->playerGender and sent in extras.gender (agent_docs/contract.md's extras
-- field is already free-form/opaque, no core/relay change needed); a remote's advertised
-- gender picks which pic table its ghost is drawn from.
--
-- Sprite decode: see adapters/pokemon/emerald/probes/sprite_probe.lua (Step 1, confirmed 2026-08-11) and
-- sprite_ghost_test.lua (Step 2, confirmed 2026-08-11) for the 4bpp-tile/BGR555-palette decode
-- math and the gui.drawPixel color-format fix (0xAARRGGBB, not 0xRRGGBBAA), both cited in
-- agent_docs/verified.md. Addresses (pokeemerald.sym, same make-compare-verified build as
-- every other address in this project):
--   gObjectEventPic_BrendanNormal = 0x084975F8, size 0x900 (9 frames x 256 bytes, 2x4 tiles)
--   gObjectEventPal_Brendan       = 0x084987F8, size 0x20 (16 colors, BGR555)
--
-- Facing direction and walk/run animation frame indices + durations (in real game frames, at
-- the same ~60fps this script's own emu.frameadvance() loop runs at, so tracking them with a
-- local frame counter matches the real game's own animation speed exactly): from
-- src/data/object_events/object_event_anims.h's sAnim_FaceSouth/FaceNorth/FaceWest/FaceEast
-- (idle) and sAnim_GoSouth/GoNorth/GoWest/GoEast (walk, 4-step cycle {3,0,4,0}-shaped per
-- direction, uniform 8 frames/pose). Running is a GENUINELY SEPARATE pic table
-- (gObjectEventPic_BrendanRunning/_MayRunning, not a faster walk cycle) -- found live
-- 2026-08-11 after an earlier version of this script wrongly reused the ANIM_STD_GO_FAST_*
-- tier (which turned out to be unrelated to on-foot Running Shoes dashing -- all four GO_FAST/
-- FASTER/FASTEST tiers share the walk table's frame indices, only duration changes, so that
-- was a red herring): the real running pose comes from sAnim_RunSouth/RunNorth/RunWest/RunEast,
-- which reference combined pic-table indices 9-17 in sPicTable_BrendanNormal
-- (object_event_pic_tables.h) -- i.e. gObjectEventPic_BrendanNormal's frames 0-8 for walking,
-- gObjectEventPic_BrendanRunning's frames 0-8 (combined index minus 9) for running, sharing one
-- ObjectEventGraphicsInfo/palette. The running frame SEQUENCE per direction is the same
-- relative shape as walking ({3,0,4,0} etc., just from the other pic table), but NOT the same
-- durations -- sAnim_RunSouth is ANIMCMD_FRAME(12,5),(9,3),(13,5),(9,3), i.e. 5,3,5,3 frames
-- per pose, a real asymmetric cadence, not a flat quarter of the walk speed. East reuses West's
-- frames with hFlip=true (sAnim_FaceEast/GoEast/RunEast's ANIMCMD_FRAME(..., .hFlip = TRUE)) --
-- there is no separate mirrored bitmap in ROM, so drawing mirrors the frame's x-coordinate
-- instead. sAnimTable_BrendanMayNormal confirms these frame tables (both walk and run) are
-- shared between Brendan and May -- only the pixel/palette source differs, per gender.
--
-- Ghost placement, changed from phase4_multiplayer.lua: that script's GHOST_Y_CORRECTION
-- existed because the 16x16 placeholder box was one tile shorter than a real 16x32 overworld
-- sprite, so it needed shifting down to align with the character's feet. This script draws a
-- real 16x32 sprite (same dimensions as the local player's own, which playerScreenPos()'s
-- formula already correctly anchors by top-left corner) -- so no analogous correction is
-- needed here. Confirmed on screen live with two real peers, no offset hack required -- see
-- agent_docs/verified.md's "Phase 5.5 Step 3" entry.

local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
-- gSaveBlock2Ptr = 0x03005D90 (pointer, right next to gSaveBlock1Ptr at 0x03005D8C --
-- pokeemerald.sym, same make-compare-verified build as every other address in this project).
-- playerGender is struct SaveBlock2 offset +0x08 (include/global.h L511, "u8 playerGender").
-- MALE=0, FEMALE=1 (include/constants/global.h). Read once at script start, not every frame --
-- gender doesn't change mid-session, unlike everything else this script reads from memory.
local GSAVEBLOCK2PTR_ADDR = 0x03005d90
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
local GSPRITECOORDOFFSETX_ADDR = 0x02021bbc
local GSPRITECOORDOFFSETY_ADDR = 0x02021bbe

-- Archipelago's recompile relocates gObjectEvents/gPlayerAvatar too -- confirmed live
-- 2026-08-14 (same day as the CB2_Overworld/sprite fixes above), via a multi-stage live
-- investigation on a real .apemerald-patched ROM: a scripted snapshot-diff probe
-- (avatar_scan_probe.lua) narrowed all of EWRAM down to gObjectEvents[0].facingDirection by
-- requiring an exact down/left/up/right value match at each of four deliberate direction
-- changes in order; a hex dump (avatar_hexdump_probe.lua) then matched the surrounding bytes
-- field-by-field against pokeemerald's real struct ObjectEvent layout (isPlayer bit set,
-- trackedByCamera bit set, localId=0xFF=LOCALID_PLAYER, mapNum=9/mapGroup=0 matching the
-- already-known Littleroot Town location) to pin down gObjectEvents[0]'s exact base address,
-- 0x020375D4; an array-boundary scan (avatar_array_probe.lua) confirmed this really is index 0
-- (one slot earlier breaks the pattern entirely) and found gPlayerAvatar at the same +0x240
-- relationship vanilla uses (0x02037814); and a final live verification
-- (avatar_verify_probe.lua) confirmed flags/dash/runningState/facingDirection all track real,
-- responsive state at these addresses instead of the frozen garbage the vanilla addresses read
-- (verified.md, 2026-08-11, reproduced 2026-08-14) -- watched live through walking, dashing,
-- and turning in every direction.
-- Both addresses shift by the exact same delta relative to vanilla (0x284) -- detected once at
-- startup below (a live scan, not assumed) by looking for the player's own object event (the
-- isPlayer bit + LOCALID_PLAYER signature above) at each candidate base, the same discipline as
-- the sprite-address detection above. Scoped to this Archipelago Emerald base-patch version,
-- same portability caveat as every other Archipelago-specific address in this file.
local AVATAR_ADDR_ARCHIPELAGO_SHIFT = 0x284

local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c

-- Archipelago's Pokemon Emerald patch is one static base ROM recompile shared by every seed
-- (agent_docs/risks.md's Archipelago-coexistence entry: base_patch.bsdiff4 rewrites real game
-- logic, per-seed randomization is small write_token calls on top of that shared recompile) --
-- so CB2_Overworld, being base game code rather than per-seed content, moves to this same
-- address for every player on that patch version, not just one specific seed. No decomp source
-- exists for the patched build to cite the normal way, so this was instead confirmed the way
-- this project's own verification standard treats as equally valid when source isn't available:
-- watched live, 2026-08-14, via adapters/pokemon/emerald/probes/battle_probe.lua against a real
-- .apemerald-patched ROM. callback2 read 0x080867F1 while standing idle in the overworld, held
-- steady through walking and a route change (no line printed -- no change), and through a full
-- door-transition round trip (entering AND leaving a house) it briefly showed 0x08086965 ->
-- 0x0813873D -> 0x08086995 (warp/fade/map-load handlers) before settling back to 0x080867F1
-- both times -- the same "transient callback during a warp, then reverts to the field callback"
-- shape already documented for vanilla's own CB2_Overworld in verified.md. Scoped to this base
-- patch version; a future Archipelago Emerald world update could recompile to a different
-- address, the same portability risk noted in ideas.md for any other fixed-address assumption.
local CB2_OVERWORLD_ARCHIPELAGO_ADDR = 0x080867f1

local function inOverworld()
    local callback2 = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    return callback2 == CB2_OVERWORLD_ADDR or callback2 == CB2_OVERWORLD_ADDR + 1
        or callback2 == CB2_OVERWORLD_ARCHIPELAGO_ADDR or callback2 == CB2_OVERWORLD_ARCHIPELAGO_ADDR + 1
end

local TILE = 16 -- confirmed on screen in Phase 3, see phase4_multiplayer.lua's header.

local BRIDGE_HOST = "127.0.0.1"
-- PORT WALK. A core serves exactly ONE adapter (agent_docs/contract.md): a second bridge
-- connection is answered with `reject` and closed. Two copies of one game on one machine is a
-- normal thing to do, so a fixed port makes the second copy either fail or silently share the
-- first core -- a real mistake already recorded in pitfalls.md, made by launching EmuHawk
-- directly and skipping the environment variable. Instead: probe 7778 upward and take the first
-- core that answers `bridge_ready`. Shape copied from Pseudoregalia's BridgeClient (the tested
-- one) and matching Crystal's; the rationale, including the three things it got wrong first,
-- is in adapters/_template/PROTOCOL.md.
local BRIDGE_BASE_PORT = 7778
local BRIDGE_PORT_COUNT = 8
-- An explicit port is honoured and then NOT walked: someone who names a port means that port.
local BRIDGE_PORT_OVERRIDE = tonumber(os.getenv("MESHGHOST_BRIDGE_PORT") or "")
-- Silence is NOT acceptance -- see PROTOCOL.md. 90 frames = 1.5s, matching the other adapters.
local HELLO_ANSWER_FRAMES = 90
local BUSY_PORT_COOLDOWN_FRAMES = 600 -- 10s

-- Sent as this adapter's bridge Hello (internal/bridge.Hello) so the core can connect to the
-- relay without the user needing to type "game" into config.json themselves -- see
-- agent_docs/architecture.md's ADR. Opaque to the core; matches the folder name under
-- games/pokemon/emerald/ in the shipped release, per packaging/README.md's convention.
local GAME_ID = "emerald"

-- Sent as this adapter's bridge Hello alongside GAME_ID (internal/bridge.Hello's
-- game_version field, added for relay-safety hardening — see the ADR in
-- agent_docs/architecture.md). This is this *script's* own version, not a ROM
-- build/revision read from game memory — no cited address exists for that, and
-- CLAUDE.md's "no addresses from memory" rule means one isn't guessed at here.
-- Opaque to the core/relay, compared only by equality: it catches two peers
-- running different revisions of this adapter script, the most likely real
-- source of a silent protocol mismatch. Bumped from "phase5.5" (2026-08-15,
-- full project sweep): the script has had several substantive rounds of real
-- fixes since Phase 5.5 shipped (Archipelago address auto-detection, gender-
-- read timing, the sub-tile smoothing rewrite, the loopback ghost offset) with
-- the version string never bumped to match — exactly the silent-mismatch
-- failure this field exists to catch. This is a deliberate breaking change: an
-- older client reporting "phase5.5" is now refused a room started by a
-- "phase8" client, and vice versa, rather than silently interoperating with
-- unverified-compatible code on the other end.
local ADAPTER_VERSION = "phase8-spawn"

local FACING = { [1] = "south", [2] = "north", [3] = "west", [4] = "east" }

----------------------------------------------------------------------------
-- Sprite decode, both genders (Phase 5.5 Step 4). Decoded once at script
-- start into resolved-color pixel lists per frame index (0-8), since the
-- ROM data never changes at runtime.
----------------------------------------------------------------------------

local GOBJECTEVENTPIC_BRENDANNORMAL_ADDR = 0x084975f8
local GOBJECTEVENTPAL_BRENDAN_ADDR = 0x084987f8
-- gObjectEventPic_MayNormal / gObjectEventPal_May, same pokeemerald.sym build as every other
-- address in this project (see agent_docs/phases/phase5_5.md's research summary):
-- 0x084A3078 (size 0x900, same 9-frame layout as Brendan's) and 0x084A4278 (size 0x20).
local GOBJECTEVENTPIC_MAYNORMAL_ADDR = 0x084a3078
local GOBJECTEVENTPAL_MAY_ADDR = 0x084a4278
-- Real, separate running-pose pic tables -- confirmed via object_event_anims.h's
-- sAnim_RunSouth/RunNorth/RunWest/RunEast, which reference combined pic-table indices 9-17
-- (i.e. this table's own local frames 0-8), distinct from the plain walk cycle (indices 0-8,
-- gObjectEventPic_*Normal). Same palette as each gender's Normal table -- the running frames
-- are a separate SpriteFrameImage entry in the SAME sPicTable_BrendanNormal array
-- (object_event_pic_tables.h), sharing one ObjectEventGraphicsInfo (and therefore one
-- paletteTag) with the walk frames, not a second palette.
local GOBJECTEVENTPIC_BRENDANRUNNING_ADDR = 0x08497ef8
local GOBJECTEVENTPIC_MAYRUNNING_ADDR = 0x084a3978

-- Archipelago's recompile relocates this whole sprite/palette data block -- confirmed
-- 2026-08-14 by directly comparing ROM file bytes (not a runtime read) between the vanilla ROM
-- and two independent Archipelago-patched-ROM files: the exact 256-byte raw tile block at each
-- vanilla *_PIC_*_ADDR above, and the exact 32-byte raw palette block at each *_PAL_*_ADDR
-- above, were each found at exactly ONE new location in both patched ROMs (identical between
-- the two, i.e. seed-independent, consistent with Archipelago's Emerald patch being one static
-- base recompile shared by every seed -- see agent_docs/risks.md's Archipelago-coexistence
-- entry). All six addresses shifted by the exact same delta: +0x7530. This is a genuinely
-- different address family from CB2_Overworld's own Archipelago shift (which moved by a
-- different amount, 0x995, in ROM code rather than ROM data) -- no single ROM-wide offset
-- applies to everything, only to this contiguous graphics block.
-- Detected once at startup below (a live byte comparison, not assumed) rather than hardcoded as
-- "the" address, since a future Archipelago Emerald world/generator version could recompile to
-- a different offset -- the same portability caveat as every other address in this project.
local SPRITE_ADDR_ARCHIPELAGO_SHIFT = 0x7530

local FRAME_WIDTH_TILES = 2
local FRAME_HEIGHT_TILES = 4
local FRAME_WIDTH_PX = FRAME_WIDTH_TILES * 8
local FRAME_HEIGHT_PX = FRAME_HEIGHT_TILES * 8
local FRAMES_PER_PIC_TABLE = 9

-- Direction -> {idle frame index, {4-step frame sequence}, hFlip}. Confirmed from
-- object_event_anims.h: sAnim_RunSouth/etc's combined-table indices (12,9,13,9 for south),
-- minus the running table's +9 offset, are {3,0,4,0} -- the SAME relative sequence as walking
-- (sAnim_GoSouth), just read from the running pic table instead of the walk one. So one
-- direction/frame-sequence table serves both -- only which pic table (walk vs run) and the
-- per-pose hold durations differ. South/North/West are drawn as-is; East reuses West's frames
-- mirrored.
local DIRECTION_ANIM = {
    south = { idle = 0, steps = { 3, 0, 4, 0 }, hFlip = false },
    north = { idle = 1, steps = { 5, 1, 6, 1 }, hFlip = false },
    west  = { idle = 2, steps = { 7, 2, 8, 2 }, hFlip = false },
    east  = { idle = 2, steps = { 7, 2, 8, 2 }, hFlip = true },
}
-- Per-pose hold durations (frames), indexed the same as DIRECTION_ANIM's steps array. Walking
-- (sAnim_GoSouth/etc) holds each of the 4 poses for a uniform 8 frames. Running (sAnim_RunSouth
-- /etc) does NOT hold uniformly -- ANIMCMD_FRAME(12,5),(9,3),(13,5),(9,3) -- 5,3,5,3, a real,
-- asymmetric cadence, not a flat quarter of the walk speed.
local WALK_POSE_DURATIONS = { 8, 8, 8, 8 }
local RUN_POSE_DURATIONS = { 5, 3, 5, 3 }

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

-- decodeFramePixels decodes one frame at picAddr + frameIndex*256 bytes, returning a flat
-- list of {x, y, color} (0xAARRGGBB, see phase5.5 Step 2's verified.md entry for why),
-- skipping palette index 0 (transparent).
local function decodeFramePixels(picAddr, frameIndex, palette)
    local frameAddr = picAddr + frameIndex * (FRAME_WIDTH_TILES * FRAME_HEIGHT_TILES * 32)
    local pixels = {}
    for py = 0, FRAME_HEIGHT_PX - 1 do
        local tileRow = py // 8
        local localY = py % 8
        for px = 0, FRAME_WIDTH_PX - 1 do
            local tileCol = px // 8
            local localX = px % 8
            local tileIndex = tileRow * FRAME_WIDTH_TILES + tileCol
            local tileByteOffset = tileIndex * 32 + localY * 4 + (localX // 2)
            local b = memory.read_u8(frameAddr + tileByteOffset)
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

-- genderFrames[gender][pose][i] (i = 0..8) = decoded pixel list for that gender/pose-set's
-- pic table, frame i. pose is "walk" (used for idle too -- idle frames 0-2 only exist in the
-- walk/Normal pic table) or "run" (the separate table above). All four combinations decoded
-- once at startup -- a remote's gender and current anim pick which table drawSpriteFrame reads
-- from, never which tables exist (all always loaded, since any combination could show up).
local genderFrames = { male = { walk = {}, run = {} }, female = { walk = {}, run = {} } }

-- Detect once at startup whether the vanilla or Archipelago-shifted sprite/palette addresses
-- are actually live, by comparing Brendan's palette's first 4 raw bytes (0x0E 0x53 0x5F 0x5B,
-- read directly from the vanilla ROM file 2026-08-14) against both candidate locations -- a
-- live verification, not an assumption, same discipline as vram_probe.lua's VRAM<->System-Bus
-- aliasing check. Falls back to vanilla (with a loud warning) if neither matches, e.g. a future
-- Archipelago Emerald world/generator version that recompiles to a third, unknown offset.
local BRENDAN_PAL_REF_BYTES = { 0x0e, 0x53, 0x5f, 0x5b }
local function bytesMatchAt(addr, refBytes)
    for i, expected in ipairs(refBytes) do
        if memory.read_u8(addr + i - 1) ~= expected then
            return false
        end
    end
    return true
end

local function detectSpriteAddrOffset()
    if bytesMatchAt(GOBJECTEVENTPAL_BRENDAN_ADDR, BRENDAN_PAL_REF_BYTES) then
        console.log("MeshGhost: sprite data found at the vanilla ROM address.")
        return 0
    end
    if bytesMatchAt(GOBJECTEVENTPAL_BRENDAN_ADDR + SPRITE_ADDR_ARCHIPELAGO_SHIFT, BRENDAN_PAL_REF_BYTES) then
        console.log("MeshGhost: sprite data found at the known Archipelago-shifted ROM address.")
        return SPRITE_ADDR_ARCHIPELAGO_SHIFT
    end
    console.log("MeshGhost: WARNING -- Brendan/May sprite data not found at the vanilla address "
        .. "or the known Archipelago-shifted address. Falling back to vanilla addresses, but "
        .. "the decoded sprite is likely wrong on this ROM.")
    return 0
end

-- Scans up to all 16 gObjectEvents entries at the given base for the player's own entry (the
-- isPlayer bit set AND localId == LOCALID_PLAYER (0xFF) -- pokeemerald's own sentinel for the
-- player's object event, confirmed live 2026-08-14 the same way as the header comment above
-- describes). Returns true if found, without needing to know which index it's at in advance.
--
-- BUG FOUND LIVE 2026-08-14, fixed same day: the isPlayer+localId check alone has a real false
-- positive against the OLD vanilla address once it's abandoned/frozen garbage under Archipelago
-- -- that garbage reads as a flat repeating `FF 03 FF 03...` pattern (already confirmed via a
-- hex dump), and since OBJECTEVENT_SIZE (0x24) is even, every entry lands on the same phase of
-- that 2-byte repeat: offset+0x02 and offset+0x08 both read 0xFF, which satisfies BOTH
-- isPlayerBit==1 (0xFF's low bit is set) AND localId==0xFF simultaneously, at every single
-- entry -- a false "found it" on the abandoned vanilla address, which is exactly what
-- happened live (avatarAddrOffset resolved to 0/vanilla on a ROM already confirmed relocated).
-- Fix: also require mapGroup to be a plausible real value -- the same garbage pattern reads
-- mapGroup as 0xFF (255), nowhere close to a real Emerald map group, while the real entry reads
-- 0 (Littleroot Town, already independently confirmed). A uniform repeating byte pattern can
-- satisfy one narrow bit-level check by coincidence; it's much less likely to also produce a
-- plausible, unrelated field at a different offset. Bound is MAP_GROUPS_COUNT (34, valid values
-- 0-33) from pret/pokeemerald's include/constants/map_groups.h, the same make-compare-verified
-- build cited everywhere else in this project -- not an arbitrary round number.
local MAP_GROUPS_COUNT = 34
local function playerObjEventExistsAt(gObjectEventsBase)
    for i = 0, 15 do
        local addr = gObjectEventsBase + i * OBJECTEVENT_SIZE
        local isPlayerBit = memory.read_u8(addr + 0x02) & 0x1
        local localId = memory.read_u8(addr + 0x08)
        local mapGroup = memory.read_u8(addr + 0x0a)
        if isPlayerBit == 1 and localId == 0xff and mapGroup < MAP_GROUPS_COUNT then
            return true
        end
    end
    return false
end

-- Found live 2026-08-14, same day as the fix above: a script loaded WHILE still in the intro
-- cutscene (before the map/object-event system has spawned the player's own entry) fails BOTH
-- candidate checks -- there's no real object event data yet at either address, vanilla or
-- Archipelago-shifted. Calling this once at startup and keeping whatever it returns forever
-- (the original design) permanently locks in the fallback (vanilla) for the rest of the
-- session, even after real gameplay starts and the correct data becomes available -- confirmed
-- live: reloading the script after actually being in-game fixes it every time, proving this is
-- a timing bug, not a wrong address. Same class of problem readLocalGender()'s own header
-- comment already documents for gSaveBlock1Ptr/gSaveBlock2Ptr. Fix: don't call this once and
-- trust the result forever -- call tryDetectAvatarAddrOffset() every frame (see the main loop
-- below) until it actually finds the player's entry, then stop.
--
-- Resolved lazily (see tryDetectAvatarAddrOffset() and the main loop below) -- 0 on vanilla, or
-- AVATAR_ADDR_ARCHIPELAGO_SHIFT once detected. Declared here (before getLocalState() and
-- playerScreenPos() are defined) so both can close over it as an upvalue.
local avatarAddrOffset = 0
local avatarAddrConfirmed = false

local function tryDetectAvatarAddrOffset()
    if playerObjEventExistsAt(GOBJECTEVENTS_ADDR) then
        console.log("MeshGhost: gObjectEvents/gPlayerAvatar found at the vanilla ROM address.")
        avatarAddrOffset = 0
        avatarAddrConfirmed = true
        return
    end
    if playerObjEventExistsAt(GOBJECTEVENTS_ADDR + AVATAR_ADDR_ARCHIPELAGO_SHIFT) then
        console.log("MeshGhost: gObjectEvents/gPlayerAvatar found at the known Archipelago-shifted address.")
        avatarAddrOffset = AVATAR_ADDR_ARCHIPELAGO_SHIFT
        avatarAddrConfirmed = true
        return
    end
    -- Not found yet -- most likely still in the intro/title/character-creation sequence and
    -- the object event system hasn't spawned the player's entry yet. Leave avatarAddrOffset at
    -- its current value and avatarAddrConfirmed false; the main loop will call this again next
    -- frame rather than latching in a guess.
end

local function loadGenderFrames()
    local offset = detectSpriteAddrOffset()
    local malePalette = decodePalette(GOBJECTEVENTPAL_BRENDAN_ADDR + offset)
    local femalePalette = decodePalette(GOBJECTEVENTPAL_MAY_ADDR + offset)
    for i = 0, FRAMES_PER_PIC_TABLE - 1 do
        genderFrames.male.walk[i] = decodeFramePixels(GOBJECTEVENTPIC_BRENDANNORMAL_ADDR + offset, i, malePalette)
        genderFrames.male.run[i] = decodeFramePixels(GOBJECTEVENTPIC_BRENDANRUNNING_ADDR + offset, i, malePalette)
        genderFrames.female.walk[i] = decodeFramePixels(GOBJECTEVENTPIC_MAYNORMAL_ADDR + offset, i, femalePalette)
        genderFrames.female.run[i] = decodeFramePixels(GOBJECTEVENTPIC_MAYRUNNING_ADDR + offset, i, femalePalette)
    end
end

----------------------------------------------------------------------------
-- Paths, resolved relative to this script's own location -- same
-- io.popen("cd") approach as phase4_multiplayer.lua, see its header for why
-- debug.getinfo does NOT work here (BizHawk loads scripts as in-memory
-- string chunks, not files).
----------------------------------------------------------------------------

-- Ask Lua where THIS file is, rather than asking the OS where the process happens to be.
-- Two real bugs fixed here, 2026-08-18:
--   * `io.popen("cd")` returns the CURRENT WORKING DIRECTORY, which is only the script's own
--     directory because BizHawk chdirs into it when a script is opened by hand. Load this file
--     any other way -- from another script, or with a different working directory -- and it
--     looked for lib/x64/ in the wrong place and died with "The specified module could not be
--     found", which reads like a missing DLL rather than a wrong path.
--   * `io.popen` spawns a real `cmd` process, so every launch flashed a console window on screen.
--     The user noticed it; there is no reason for an adapter to start a shell to find itself.
-- debug.getinfo's `source` is the path this chunk was loaded from, which is the actual question.
local function scriptDir()
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        local dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$")
        if dir and dir ~= "" then
            return dir .. "/"
        end
    end
    -- Fallback for a host that does not populate `source` (none seen). Keeps the old behaviour
    -- rather than failing outright, but it is the wrong answer whenever the two differ.
    local pwd = io.popen and io.popen("cd"):read("*l")
    if not pwd or pwd == "" then
        error("MeshGhost: could not determine the script's own directory.")
    end
    return pwd .. "\\"
end

local SCRIPT_DIR = scriptDir()

----------------------------------------------------------------------------
-- LuaSocket: identical to phase4_multiplayer.lua, see its header for the
-- full derivation of why lua54.dll must be pre-loaded by full path first.
----------------------------------------------------------------------------

-- Windows LoadLibrary is documented as NOT supporting forward slashes, and package.loadlib is a
-- thin wrapper over it. Everything else here is happy with either separator, so this conversion is
-- applied to DLL paths only. Found live 2026-08-18: scriptDir() changing from io.popen("cd")
-- (which returns backslashes) to debug.getinfo (which returns whatever separator the loader used)
-- turned a working load into "The specified module could not be found" -- an error that reads as
-- a missing DLL and sends you hunting for the file, when the file is there and the SEPARATOR is
-- the problem.
local function dllPath(rel)
    return (SCRIPT_DIR .. rel):gsub("/", "\\")
end

local function preloadLua54()
    pcall(function()
        package.loadlib(dllPath("lib/x64/lua54.dll"), "meshghost_force_preload")
    end)
end

local function loadSocketCore()
    if package.config:sub(1, 1) ~= "\\" then
        error("MeshGhost: only Windows is supported by the vendored LuaSocket binary so far.")
    end
    local luaMajor, luaMinor = _VERSION:match("Lua (%d+)%.(%d+)")
    if luaMajor ~= "5" or luaMinor ~= "4" then
        error("MeshGhost: only Lua 5.4 is supported by the vendored LuaSocket binary so far (got " .. _VERSION .. ").")
    end
    local arch = os.getenv("PROCESSOR_ARCHITECTURE") or ""
    if not arch:find("64") then
        error("MeshGhost: only x64 is supported by the vendored LuaSocket binary so far.")
    end
    preloadLua54()
    local socketDll = dllPath("lib/x64/socket-windows-5-4.dll")
    local loader, loadErr = package.loadlib(socketDll, "luaopen_socket_core")
    if not loader then
        error(string.format("MeshGhost: could not load %s (%s)", socketDll, tostring(loadErr)))
    end
    return loader()
end

-- A log file beside the script, as Crystal's adapter has always had and this one never did --
-- found live 2026-08-18: the adapter failed to connect and there was NO way to see why from
-- outside the emulator, because every message went to the Lua Console only. An adapter that can
-- only be diagnosed by someone sitting in front of the GUI cannot be diagnosed by whoever is
-- actually debugging it, and a user reporting a problem has nothing to send.
-- Prefer a logs/ subfolder so the adapter folder itself stays readable -- a development session
-- reloads the script many times and each run opens its own timestamped file, which buried the
-- four .md files under two dozen logs in one afternoon. No mkdir: io.open simply fails if the
-- directory is missing, which is the fallback, and creating one would mean os.execute -- the same
-- shell call whose console-window flash was removed from this file earlier today.
local logfile
do
    local name = string.format("meshghost_emerald_%s.log", os.date("%Y%m%d_%H%M%S"))
    logfile = io.open(SCRIPT_DIR .. "logs/" .. name, "w") or io.open(SCRIPT_DIR .. name, "w")
end

local rawConsoleLog = console.log
console.log = function(msg)
    rawConsoleLog(msg)
    if logfile then
        logfile:write(tostring(msg), "\n")
        logfile:flush()
    end
end

-- File only. A per-tick line in the Lua Console scrolls the startup lines out of view, and those
-- name the ROM and every address in use -- which is what a reader actually needs. Same split
-- Crystal's adapter uses (probes.md: detail to the log file, headlines to the console).
local function logFile(msg)
    if logfile then
        logfile:write(msg, "\n")
        logfile:flush()
    end
end

local socketCore = loadSocketCore()

----------------------------------------------------------------------------
-- Minimal JSON -- identical to phase4_multiplayer.lua, see its header.
----------------------------------------------------------------------------

local JSON_STRING_ESCAPES = {
    ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}
local function jsonString(s)
    -- Every field this feeds is currently a fixed constant (area_id, orientation, anim, gender,
    -- game_id/version) so this has never fired in practice, but the escaping was still
    -- incomplete: an unescaped control char, especially \n, would corrupt the NDJSON framing
    -- (one line on the wire becomes two) rather than just producing invalid JSON.
    s = s:gsub('[\\"%c]', function(c)
        return JSON_STRING_ESCAPES[c] or string.format("\\u%04x", c:byte())
    end)
    return '"' .. s .. '"'
end

-- gender is sent in extras -- agent_docs/contract.md's packet schema already has extras as a
-- free-form, core/relay-opaque dict for exactly this kind of adapter-specific data; no
-- core/relay change needed. "male"/"female" matches pokeemerald's own MALE/FEMALE naming
-- (include/constants/global.h) for direct traceability, same pattern orientation's
-- "south"/"north"/"west"/"east" already follows against DIR_* naming.
local function encodeLocalState(areaId, x, y, orientation, anim, gender)
    return string.format(
        '{"type":"local_state","payload":{"state":{"area_id":%s,"position":[%s,%s],"orientation":%s,"anim":%s,"extras":{"gender":%s}}}}',
        jsonString(areaId), tostring(x), tostring(y), jsonString(orientation), jsonString(anim), jsonString(gender))
end

local ENCODED_NO_SEND = '{"type":"local_state","payload":{"state":null}}'

local decodeValue -- forward declaration

local function skipWs(s, i)
    local _, j = s:find("^[ \t\r\n]*", i)
    return j + 1
end

local function decodeString(s, i)
    local j = i + 1
    local out = {}
    while true do
        local c = s:sub(j, j)
        if c == "" then
            error("json: unterminated string")
        elseif c == '"' then
            return table.concat(out), j + 1
        elseif c == "\\" then
            local e = s:sub(j + 1, j + 1)
            if e == "n" then table.insert(out, "\n")
            elseif e == "t" then table.insert(out, "\t")
            elseif e == "r" then table.insert(out, "\r")
            elseif e == "u" then
                local hex = s:sub(j + 2, j + 5)
                table.insert(out, string.char(tonumber(hex, 16) % 256))
                j = j + 4
            else
                table.insert(out, e)
            end
            j = j + 2
        else
            table.insert(out, c)
            j = j + 1
        end
    end
end

local function decodeNumber(s, i)
    local _, j, num = s:find("^(-?%d+%.?%d*[eE]?[%+%-]?%d*)", i)
    if not num then error("json: expected number") end
    return tonumber(num), j + 1
end

local function decodeObject(s, i)
    local obj = {}
    i = skipWs(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
        local key
        key, i = decodeString(s, i)
        i = skipWs(s, i)
        if s:sub(i, i) ~= ":" then error("json: expected ':'") end
        i = skipWs(s, i + 1)
        local val
        val, i = decodeValue(s, i)
        obj[key] = val
        i = skipWs(s, i)
        local c = s:sub(i, i)
        if c == "," then
            i = skipWs(s, i + 1)
        elseif c == "}" then
            return obj, i + 1
        else
            error("json: expected ',' or '}'")
        end
    end
end

local function decodeArray(s, i)
    local arr = {}
    i = skipWs(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
        local val
        val, i = decodeValue(s, i)
        table.insert(arr, val)
        i = skipWs(s, i)
        local c = s:sub(i, i)
        if c == "," then
            i = skipWs(s, i + 1)
        elseif c == "]" then
            return arr, i + 1
        else
            error("json: expected ',' or ']'")
        end
    end
end

decodeValue = function(s, i)
    i = skipWs(s, i)
    local c = s:sub(i, i)
    if c == "{" then return decodeObject(s, i)
    elseif c == "[" then return decodeArray(s, i)
    elseif c == '"' then return decodeString(s, i)
    elseif c == "t" then
        if s:sub(i, i + 3) ~= "true" then error("json: bad literal") end
        return true, i + 4
    elseif c == "f" then
        if s:sub(i, i + 4) ~= "false" then error("json: bad literal") end
        return false, i + 5
    elseif c == "n" then
        if s:sub(i, i + 3) ~= "null" then error("json: bad literal") end
        return nil, i + 4
    else
        return decodeNumber(s, i)
    end
end

local function jsonDecode(line)
    local ok, val = pcall(function()
        local v = decodeValue(line, 1)
        return v
    end)
    if not ok then return nil end
    return val
end

----------------------------------------------------------------------------
-- Bridge connection -- identical to phase4_multiplayer.lua, see its header.
----------------------------------------------------------------------------

-- Declared here, not down with the movement state, because the bridge's port walk below reads it
-- and Lua would otherwise resolve it to a nil GLOBAL -- which surfaces as "attempt to compare
-- number with nil" on the first connect attempt, once per frame, forever. Found live 2026-08-18.
local frameCounter = 0

local sock = nil
local connected = false
-- Forward declaration. resetBridge() below has to drop every spawned ghost, but the spawn code
-- that defines this is far further down (it needs the address/offset detection above it). Without
-- the forward local, the call site would resolve to a GLOBAL, find nil, and the pcall around it
-- would swallow that silently -- leaving a peer's ghost standing in the game forever after a
-- bridge drop, which is exactly the bug the call exists to prevent.
local despawnAllGhosts
-- `connected` is a socket fact; `ready` is a protocol one. The core answers every hello with
-- bridge_ready or reject (agent_docs/contract.md), and only bridge_ready means this core is ours.
local ready = false
local recvPartial = "" -- straddling-line remainder from the last drainBridge() timeout; belongs
                        -- to the current connection, so resetBridge() clears it too.

-- Ports that answered but would not have us, with the frame their cooldown ends.
local busyUntil = {}
local currentPort = nil
local helloSentAtFrame = nil

local function markPortBusy(port, why)
    if port then
        busyUntil[port] = frameCounter + BUSY_PORT_COOLDOWN_FRAMES
        console.log(string.format("MeshGhost: port %d %s -- skipping it for %ds.",
            port, why, BUSY_PORT_COOLDOWN_FRAMES // 60))
    end
end

-- A short blocking timeout rather than the non-blocking connect this used to do: a sweep needs a
-- yes/no per candidate within the same frame, and on loopback a closed port refuses immediately,
-- so the timeout is a ceiling that is essentially never reached.
local function tryPort(port)
    local s = socketCore.tcp()
    if not s then return false end
    s:settimeout(0.05)
    local ok = s:connect(BRIDGE_HOST, port)
    if not ok then
        pcall(function() s:close() end)
        return false
    end
    s:settimeout(0)
    sock, connected, ready, recvPartial = s, true, false, ""
    currentPort = port
    return true
end

-- One sweep across the whole range per attempt, not one port per attempt -- one port per retry
-- interval would take many seconds to find a free core a few ports up.
local function connectBridge()
    if BRIDGE_PORT_OVERRIDE then
        tryPort(BRIDGE_PORT_OVERRIDE)
        return
    end
    for i = 0, BRIDGE_PORT_COUNT - 1 do
        local port = BRIDGE_BASE_PORT + i
        if (busyUntil[port] or 0) <= frameCounter then
            if tryPort(port) then return end
        end
    end
end

local function resetBridge()
    if connected then
        console.log("MeshGhost: bridge connection lost, will retry connecting.")
    end
    if sock then pcall(function() sock:close() end) end
    -- A dropped bridge means every remote's state is now stale, so their ghosts go with it --
    -- the same "nothing else would ever notice and clear this" failure the overlay path already
    -- had, except a spawned object persists in the game rather than simply stopping being drawn.
    pcall(despawnAllGhosts)
    sock = nil
    connected = false
    ready = false
    helloSentAtFrame = nil
    recvPartial = ""
end

local function sendLine(line)
    line = line .. "\n"
    local sent, err, lastByte = sock:send(line)
    if sent then return end
    if err == "timeout" and (lastByte or 0) == 0 then
        -- Nothing went out at all -- PROTOCOL.md's tick loop resends fresh state next tick
        -- regardless, so a fully-dropped send here just means this tick's frame is skipped.
        return
    end
    -- A partial send (0 < lastByte < #line) previously went uncounted as success -- the
    -- unsent tail is gone, and resuming next tick with a fresh line would deliver a truncated,
    -- newline-less fragment to the core, corrupting NDJSON framing for the rest of the
    -- connection (the core would concatenate it with whatever line comes next). Same
    -- "when in doubt, drop and reconnect cleanly" posture as any other hard send error, and
    -- mirrors the fix already made in the C++ adapter's BridgeClient::send_line.
    resetBridge()
end

----------------------------------------------------------------------------
-- Local state reading -- identical to phase4_multiplayer.lua, see its header.
----------------------------------------------------------------------------

local lastMapGroup, lastMapNum = nil, nil

local function mapJustChanged(mapGroup, mapNum)
    local changed = lastMapGroup ~= nil and (mapGroup ~= lastMapGroup or mapNum ~= lastMapNum)
    lastMapGroup, lastMapNum = mapGroup, mapNum
    return changed
end

local function getLocalState()
    local base = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
    if base == 0 then return nil end

    local x = memory.read_s16_le(base + 0x00)
    local y = memory.read_s16_le(base + 0x02)
    local mapGroup = memory.read_s8(base + 0x04)
    local mapNum = memory.read_s8(base + 0x05)

    if mapJustChanged(mapGroup, mapNum) then return nil end

    local flags = memory.read_u8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x00)
    local runningState = memory.read_u8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x02)
    local objectEventId = memory.read_u8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05)
    local dashing = (flags & 0x80) ~= 0

    local objEventAddr = GOBJECTEVENTS_ADDR + avatarAddrOffset + (objectEventId * OBJECTEVENT_SIZE)
    local facingRaw = memory.read_u16_le(objEventAddr + 0x18) & 0xF
    local orientation = FACING[facingRaw] or "south"

    local anim
    if runningState == 2 and dashing then
        anim = "running"
    elseif runningState == 2 then
        anim = "walking"
    else
        anim = "idle"
    end

    return {
        areaId = mapGroup .. ":" .. mapNum,
        x = x,
        y = y,
        orientation = orientation,
        anim = anim,
    }
end

-- readLocalGender returns "male"/"female", or nil if no save is loaded yet (mirrors
-- getLocalState's own base==0 gate). Called once, the first time getLocalState succeeds AND
-- the player is confirmed in the overworld (see the inOverworld() gate at the call site below,
-- added 2026-08-14) -- not every frame, since gender doesn't change mid-session. The
-- inOverworld() gate specifically guards against gSaveBlock1Ptr/gSaveBlock2Ptr already being
-- non-null before the intro cutscene/title screen/character select finish -- unverified
-- whether that's actually true on this game (flagged, not confirmed, see risks.md), but if it
-- is, resolving gender the moment getLocalState() alone succeeds could latch in a
-- default/uninitialized byte before the player ever actually chose a gender, and (since this
-- only ever runs once) never self-correct for the rest of the session.
local function readLocalGender()
    local base = memory.read_u32_le(GSAVEBLOCK2PTR_ADDR)
    if base == 0 then return nil end
    local gender = memory.read_u8(base + 0x08)
    return (gender == 1) and "female" or "male"
end

----------------------------------------------------------------------------
-- Sub-tile position smoothing. getLocalState() above returns pos.x/y as
-- read straight from gSaveBlock1Ptr -- a whole-tile coordinate that only
-- changes once per completed tile-step, not a continuous pixel position.
-- Found live 2026-08-11: sending that raw value made a remote's ghost look
-- choppy/teleport-y on the other client's screen. Fix: track locally, in
-- the adapter, when pos.x/y last changed and linearly blend from the
-- previous committed tile to the new one over STEP_DURATION_FRAMES[anim]
-- frames.
--
-- History, both dead ends kept as notes so they aren't re-attempted blind:
-- (1) MEASURING the real gap between commits and using that as the glide
-- duration (added 2026-08-11 to self-correct for a possibly-wrong assumed
-- constant, replacing an earlier fixed-only version) turned out to be a net
-- regression, root-caused live 2026-08-14 via a real per-frame raw-position
-- trace (see git history/DIAG_RAW_POS if this needs re-deriving): normal
-- tap-then-pause play (not holding a direction key continuously) produces
-- commit-to-commit gaps that are MOSTLY idle time plus one real step, which
-- a plausibility-range check alone can't distinguish from a genuinely slow
-- single step -- so the ghost visibly crawled through what should have
-- been "stand still, then snap." The same trace also proved the fixed
-- constants below have ZERO measured variance across many real continuous
-- steps (always exactly 8 or exactly 16, never 9/10/14/15/etc.) -- the
-- self-correction measuring was supposedly there for was never actually
-- happening. (2) Also tried and reverted same-day: gating the measured gap
-- on whether `anim` matched the prior step (to fix cross-pace reuse) --
-- also proved wrong by the same trace, since `anim` can already show the
-- NEXT pace before the CURRENT (still-old-paced) step's commit event
-- lands, so gating on it forced some steps to animate at the WRONG pace's
-- duration. Given (1) and (2), reverted to fixed-only: no measuring, no
-- gating, just the plain constant for whatever anim is active right now.
----------------------------------------------------------------------------

-- Real per-tile frame counts. Originally measured live 2026-08-11 (temporary diagnostic
-- printing every real gap between consecutive tile commits) and re-confirmed live 2026-08-14
-- with zero variance across many real continuous steps -- see agent_docs/verified.md.
local STEP_DURATION_FRAMES = { walking = 16, running = 8 }

local prevTileX, prevTileY = nil, nil
local committedTileX, committedTileY = nil, nil
local committedAreaId = nil
local tileChangeFrame = 0
-- The duration used to glide the CURRENT step, locked in once when that step commits rather
-- than re-derived from anim on every frame of the glide. Found live 2026-08-11: re-deriving it
-- live let the denominator itself change mid-glide whenever anim changed before the glide
-- finished (e.g. running -> idle the instant you stop, or a step right after unblocking from a
-- wall), which made the fraction jump backward or lurch -- exactly the "snaps when I suddenly
-- stop running" and "wall bump then running" reports. Locking it to whatever anim was active
-- at the moment the step STARTED fixes that: the rest of that one glide always finishes at the
-- pace it began at, regardless of what anim does before it completes.
local activeStepDuration = STEP_DURATION_FRAMES.walking
-- True only while gliding a REAL committed step (the elseif branch below) -- explicitly false
-- for the first-sample/map-transition bootstrap case, which also starts a fraction-driven
-- window but was never an actual step. Added 2026-08-14 after the diagnostics below fired
-- during the ~16-frame bootstrap window right after connecting, before the player had moved at
-- all -- confusing and wasted the log budget on a non-event. Used to gate DIAG_STEP_CURVE/
-- DIAG_SCREENPOS_PARTS below onto only genuine movement.
local inRealGlide = false
-- Set when a glide finishes (fraction reaches 1), but not ACTED on until the START of the next
-- call -- deferred by one frame on purpose so the completion frame itself still reads
-- inRealGlide == true (the diagnostics' caller reads it AFTER this function returns, so
-- clearing it in the same call that finishes the glide would silently drop the last, most
-- relevant frame -- exactly the one a reported "snap at the end" needs to be visible in).
local glideJustCompleted = false

local function smoothPosition(rawX, rawY, areaId, anim)
    if glideJustCompleted then
        inRealGlide = false
        glideJustCompleted = false
    end

    if committedTileX == nil or areaId ~= committedAreaId then
        -- First sample, or a map transition -- nothing to interpolate from, snap instead of
        -- gliding across a map boundary or from nothing. Never a real glide.
        prevTileX, prevTileY = rawX, rawY
        committedTileX, committedTileY = rawX, rawY
        committedAreaId = areaId
        tileChangeFrame = frameCounter
        activeStepDuration = STEP_DURATION_FRAMES[anim] or STEP_DURATION_FRAMES.walking
        inRealGlide = false
    elseif rawX ~= committedTileX or rawY ~= committedTileY then
        prevTileX, prevTileY = committedTileX, committedTileY
        committedTileX, committedTileY = rawX, rawY
        tileChangeFrame = frameCounter
        activeStepDuration = STEP_DURATION_FRAMES[anim] or STEP_DURATION_FRAMES.walking
        inRealGlide = true
    end

    local fraction = (frameCounter - tileChangeFrame) / activeStepDuration
    if fraction >= 1 then glideJustCompleted = true end
    if fraction > 1 then fraction = 1 end
    if fraction < 0 then fraction = 0 end

    return prevTileX + (committedTileX - prevTileX) * fraction,
           prevTileY + (committedTileY - prevTileY) * fraction
end

-- DIAGNOSTIC, added 2026-08-14 -- checks a specific live-reported symptom: a single-tile walk
-- still looks "slightly off" between the real player and the ghost even ignoring network delay,
-- with a visible snap right as the step completes. Working theory: our own synthetic glide
-- (smoothX/Y above, a fixed linear ramp over STEP_DURATION_FRAMES[anim] frames) might not land
-- in exact frame-for-frame lockstep with the REAL sprite's own pixel motion that
-- playerScreenPos() reads -- if the real sprite's per-frame pixel delta isn't a clean, constant
-- 1px/frame (e.g. it moves in an uneven pattern, or finishes/resets a frame earlier or later
-- than our own frameCounter-based timing expects), the mismatch would show up exactly as a
-- small end-of-step correction. Logs both curves side by side, gated to only real glides (see
-- inRealGlide above) and capped to DIAG_STEP_CURVE_MAX_LOGS actual logged frames -- generous
-- (a full minute's worth of real step-frames) so there's no rush between reloading the script
-- and actually moving.
local DIAG_STEP_CURVE = false
local DIAG_STEP_CURVE_MAX_LOGS = 3600
local diagStepCurveLogCount = 0
local diagPrevRealX, diagPrevRealY = nil, nil

local DIAG_SCREENPOS_PARTS = false
local DIAG_SCREENPOS_PARTS_MAX_LOGS = 200
local diagScreenPosPartsLogCount = 0

local function playerScreenPos()
    local spriteId = memory.read_u8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04)
    local spriteAddr = GSPRITES_ADDR + (spriteId * SPRITE_SIZE)

    local sx = memory.read_s16_le(spriteAddr + 0x20)
    local sy = memory.read_s16_le(spriteAddr + 0x22)
    local sx2 = memory.read_s16_le(spriteAddr + 0x24)
    local sy2 = memory.read_s16_le(spriteAddr + 0x26)
    local cx = memory.read_s8(spriteAddr + 0x28)
    local cy = memory.read_s8(spriteAddr + 0x29)

    local coordOffsetX = memory.read_s16_le(GSPRITECOORDOFFSETX_ADDR)
    local coordOffsetY = memory.read_s16_le(GSPRITECOORDOFFSETY_ADDR)

    -- DIAGNOSTIC, added 2026-08-14 -- the combined return value stayed frozen across an entire
    -- real walked tile (see the DIAG CURVE trace), which could mean either "correct, camera
    -- absorbs all scroll" or "reading a stale/wrong address never checked for this Archipelago
    -- ROM's shift" -- logging each component separately (spriteId included, to catch a wrong
    -- sprite-slot read too) instead of just the sum should show directly which one, if any, is
    -- the one not moving. Gated to only log during a real committed step's glide (inRealGlide,
    -- an upvalue from smoothPosition() above) -- found live: gating on raw fraction/timing alone
    -- also fired during the bootstrap window right after connecting, before the player had
    -- moved at all.
    if DIAG_SCREENPOS_PARTS and inRealGlide and diagScreenPosPartsLogCount < DIAG_SCREENPOS_PARTS_MAX_LOGS then
        diagScreenPosPartsLogCount = diagScreenPosPartsLogCount + 1
        console.log(string.format(
            "MeshGhost DIAG PARTS: frame=%d spriteId=%d sx=%d sy=%d sx2=%d sy2=%d cx=%d cy=%d coordOffsetX=%d coordOffsetY=%d",
            frameCounter, spriteId, sx, sy, sx2, sy2, cx, cy, coordOffsetX, coordOffsetY))
    end

    return sx + sx2 + cx + coordOffsetX, sy + sy2 + cy + coordOffsetY
end

----------------------------------------------------------------------------
-- Remote ghost set. Per the tick model (agent_docs/contract.md): an
-- adapter-owned map the core upserts into via render_remote and removes
-- from via despawn_remote, redrawn every frame regardless of when new
-- network data last arrived. Extended from phase4_multiplayer.lua with
-- per-remote animation state (animTimer/animStepIndex), which must survive
-- across render_remote updates (a new position update every ~1/10s must
-- NOT reset which walk-cycle frame is currently showing) -- so updates
-- merge into the existing entry instead of replacing it wholesale.
----------------------------------------------------------------------------

local remotes = {}

local function handleBridgeLine(line)
    local env = jsonDecode(line)
    if not env or type(env) ~= "table" then return end

    if env.type == "bridge_ready" then
        ready = true
        console.log(string.format("MeshGhost: bridge_ready on port %s -- this core is ours.",
            tostring(currentPort)))
    elseif env.type == "reject" then
        -- The reason is for the log, never for branching on: the right response to any rejection
        -- is the same one, which is to try the next port.
        local payload = env.payload
        console.log("MeshGhost: rejected ("
            .. tostring(type(payload) == "table" and payload.reason or "no reason given") .. ")")
        markPortBusy(currentPort, "is a core that already has an adapter")
        resetBridge()
    elseif env.type == "render_remote" then
        local payload = env.payload
        if type(payload) == "table" and type(payload.state) == "table" and payload.player_id then
            local st = payload.state
            local pos = st.position
            if type(pos) == "table" and pos[1] and pos[2] then
                local r = remotes[payload.player_id]
                if not r then
                    r = { animTimer = 0, animStepIndex = 0 }
                    remotes[payload.player_id] = r
                end
                r.areaId = st.area_id
                r.x = pos[1]
                r.y = pos[2]
                r.orientation = st.orientation
                r.anim = st.anim
                -- extras is free-form/opaque per agent_docs/contract.md; default to "male" if
                -- absent (e.g. an older client without this field) rather than erroring, same
                -- forward-compatibility posture the relay/core already apply.
                r.gender = (type(st.extras) == "table" and st.extras.gender) or "male"
            end
        end
    elseif env.type == "despawn_remote" then
        local payload = env.payload
        if type(payload) == "table" and payload.player_id then
            remotes[payload.player_id] = nil
        end
    end
end

local function drainBridge()
    while true do
        -- With settimeout(0), a line straddling this call's read boundary comes back as
        -- nil, "timeout", partial -- LuaSocket 3.0's documented behavior for a pattern that
        -- can't complete before the timeout (see adapters/pokemon/emerald/lib/x64/
        -- luasocket.LICENSE.txt for the vendored version). The old code discarded that
        -- partial outright, which is almost certainly the "receive-side corruption" noted in
        -- MeshGhostPseudo/Mod/src/BridgeClient.hpp:4-6 -- every line after the first split
        -- would lose its leading bytes. Feed the partial back in as the prefix for the next
        -- receive() so it resumes mid-line instead of dropping it.
        local line, err, partial = sock:receive("*l", recvPartial)
        if line then
            recvPartial = ""
            handleBridgeLine(line)
        elseif err == "timeout" then
            recvPartial = partial or ""
            return
        else
            recvPartial = ""
            resetBridge()
            remotes = {}
            return
        end
    end
end

----------------------------------------------------------------------------
-- Drawing. See the header for the placement-formula change from
-- phase4_multiplayer.lua (no GHOST_Y_CORRECTION needed -- confirmed live).
----------------------------------------------------------------------------

-- advanceAnim steps a remote's walk/run animation forward by one frame (called once per emu
-- frame, only while the remote is walking/running) and returns the frame index to draw for its
-- current direction. Resets to step 0 whenever the direction or anim tag changes, so a fresh
-- movement always starts from a consistent pose rather than resuming wherever a previous,
-- different-direction cycle left off.
local function advanceAnim(remote, dirInfo)
    if remote.lastAnim ~= remote.anim or remote.lastOrientation ~= remote.orientation then
        remote.animTimer = 0
        remote.animStepIndex = 1
        remote.lastAnim = remote.anim
        remote.lastOrientation = remote.orientation
    end

    local durations = (remote.anim == "running") and RUN_POSE_DURATIONS or WALK_POSE_DURATIONS
    local framesPerStep = durations[remote.animStepIndex]
    remote.animTimer = remote.animTimer + 1
    if remote.animTimer >= framesPerStep then
        remote.animTimer = 0
        remote.animStepIndex = (remote.animStepIndex % #dirInfo.steps) + 1
    end
    return dirInfo.steps[remote.animStepIndex]
end

local function drawSpriteFrame(gender, pose, frameIndex, hFlip, screenX, screenY)
    local genderSet = genderFrames[gender] or genderFrames.male
    local pixels = (genderSet[pose] or genderSet.walk)[frameIndex]
    for i = 1, #pixels do
        local p = pixels[i]
        local px = hFlip and (FRAME_WIDTH_PX - 1 - p.x) or p.x
        gui.drawPixel(screenX + px, screenY + p.y, p.color)
    end
end

-- A loopback-echoed ghost (internal/relay's dev-only -loopback flag, id = "<id>-ghost") would
-- otherwise render directly on top of the real player -- both are the same position by
-- definition, since it's an echo of your own state. Found live 2026-08-14: this made it hard to
-- visually tell the real character and the ghost apart at all, especially for judging rendering
-- quality (smoothing, animation) side by side -- the whole point of using loopback for that kind
-- of test. Nudge it a couple tiles to the side purely for local rendering (screen position only
-- -- never changes what's actually sent/received over the network) so it visibly mimics the
-- player in parallel instead of sitting on top of them. Not specific to the "-ghost" suffix
-- semantically -- any player_id could in principle end this way -- but that's the relay's own
-- real naming convention for exactly this case, so it's a reliable signal here.
--
-- Two genuinely different, both-valid loopback use cases, per the user (2026-08-14): offset
-- (the default) for visually judging rendering/animation/smoothing quality side by side, since
-- an exact overlap makes the two impossible to tell apart; zero offset (exact trail) for
-- verifying the ghost actually tracks the real position precisely, which an offset would
-- obscure. Controlled via MESHGHOST_LOOPBACK_TRAIL, same env-var pattern as
-- MESHGHOST_BRIDGE_PORT above -- set (to anything) to force exact-trail mode, unset for the
-- default offset mode. A launch-time env var rather than a code constant so switching between
-- the two doesn't need a script reload/edit, just a different .local.bat -- see
-- dev-scripts/README.md.
local LOOPBACK_GHOST_OFFSET_TILES_X = (os.getenv("MESHGHOST_LOOPBACK_TRAIL") and 0) or 2
local LOOPBACK_GHOST_OFFSET_TILES_Y = 0

----------------------------------------------------------------------------
-- Spawning real object events (2026-08-18) -- the engine draws, we do not.
--
-- A peer is rendered by writing a real ObjectEvent plus a Sprite into free slots and letting
-- Emerald's own engine draw, animate and walk it. This replaces the gui.drawPixel overlay
-- (drawSpriteFrame/drawRemotes below, still used on ROMs this cannot write to safely). What it
-- buys, confirmed on screen 2026-08-18: correct occlusion -- a ghost is hidden BEHIND the pause
-- menu, which the overlay never was -- correct palette and gender for free, and step animation
-- and sub-tile sliding played by the engine rather than reimplemented here.
--
-- The full derivation, and every trap that cost a live test, is in
-- adapters/pokemon/emerald/probes/spawn_test.lua and agent_docs/verified.md. The three that
-- matter most when reading this code:
--   * the ObjectEvent is synthesised from InitObjectEventStateFromTemplate's own field list;
--   * the Sprite is COPIED from the player's (four ROM pointers cannot be synthesised) but must
--     then be given its OWN VRAM tiles, or it displays the player's current animation frame;
--   * MovementType_None is the only movement type with no autonomous behaviour that still runs
--     the generic update which plays out held movements.
----------------------------------------------------------------------------

local GSPRITES_SPAWN_ADDR = 0x02020630
local SPRITE_STRUCT_SIZE = 0x44
local MAX_SPRITES = 64
local MAP_OFFSET = 7

local GFIELDCAMERA_X_ADDR = 0x03005de0
local GFIELDCAMERA_Y_ADDR = 0x03005de4
local GTOTALCAMERAPIXELOFFSETY_ADDR = 0x03005de8
local GTOTALCAMERAPIXELOFFSETX_ADDR = 0x03005dec

local SSPRITETILEALLOCBITMAP_ADDR = 0x02021b3c
local GRESERVEDSPRITETILECOUNT_ADDR = 0x02021b3a
local GOBJECTEVENTGRAPHICSINFOPOINTERS_ADDR = 0x08505620
local TOTAL_OBJ_TILE_COUNT = 1024
local TILE_SIZE_4BPP = 32

local MOVEMENTTYPE_NONE_CB = 0x0808f3e0 + 1 -- +1 selects Thumb
local MOVEMENT_TYPE_NONE = 0x00

-- Direction ids and the movement actions indexed by them (constants/event_object_movement.h).
local DIR_ID = { south = 1, north = 2, west = 3, east = 4 }
local FACE_ACTION = { [1] = 0x00, [2] = 0x01, [3] = 0x02, [4] = 0x03 }
local WALK_ACTION = { [1] = 0x08, [2] = 0x09, [3] = 0x0a, [4] = 0x0b }
-- PLAYER_RUN, not WALK_FAST. Both cross a tile quickly, but WALK_FAST (0x15) reuses the WALKING
-- frames while PLAYER_RUN (0x35) plays ANIM_RUN_*, which is what running actually looks like.
-- Found live 2026-08-18: "it moves around properly, but its not running" -- the ghost was keeping
-- up and still visibly walking. The run frames exist on the ghost because it borrows the player's
-- graphics, which is the one graphic in the game that has them.
local RUN_ACTION = { [1] = 0x35, [2] = 0x36, [3] = 0x37, [4] = 0x38 }

local function w8(a, v) memory.write_u8(a, v & 0xff) end
local function w16(a, v) memory.write_u16_le(a, v & 0xffff) end
local function w32(a, v) memory.write_u32_le(a, v & 0xffffffff) end
local function r8(a) return memory.read_u8(a) end
local function r16(a) return memory.read_u16_le(a) end
local function rs16(a) return memory.read_s16_le(a) end
local function r32(a) return memory.read_u32_le(a) end

local function objAddr(i) return GOBJECTEVENTS_ADDR + avatarAddrOffset + i * OBJECTEVENT_SIZE end
local function sprAddr(i) return GSPRITES_SPAWN_ADDR + i * SPRITE_STRUCT_SIZE end

local function tileIsAllocated(n)
    return (r8(SSPRITETILEALLOCBITMAP_ADDR + (n // 8)) >> (n % 8)) & 1 == 1
end

local function setTileAllocated(n, on)
    local a = SSPRITETILEALLOCBITMAP_ADDR + (n // 8)
    local v = r8(a)
    if on then v = v | (1 << (n % 8)) else v = v & ~(1 << (n % 8)) end
    w8(a, v)
end

-- AllocSpriteTiles (sprite.c:702), imitated. Returns nil when OBJ VRAM has no run this long,
-- which is a real outcome on a busy map rather than a theoretical one.
local function allocSpriteTiles(tileCount)
    local i = r16(GRESERVEDSPRITETILECOUNT_ADDR)
    while true do
        while tileIsAllocated(i) do
            i = i + 1
            if i >= TOTAL_OBJ_TILE_COUNT then return nil end
        end
        local start, found = i, 1
        while found ~= tileCount do
            i = i + 1
            if i >= TOTAL_OBJ_TILE_COUNT then return nil end
            if not tileIsAllocated(i) then found = found + 1 else break end
        end
        if found == tileCount then
            for t = start, start + tileCount - 1 do setTileAllocated(t, true) end
            return start
        end
    end
end

local function graphicsFrameTileCount(graphicsId)
    local infoPtr = r32(GOBJECTEVENTGRAPHICSINFOPOINTERS_ADDR + graphicsId * 4)
    if infoPtr == 0 then return nil end
    local size = r16(infoPtr + 0x06)
    if size == 0 then return nil end
    return size // TILE_SIZE_4BPP
end

-- GetMapCoordsFromSpritePos (event_object_movement.c:4793) plus TrySetupObjectEventSprite's own
-- +8 / +16+centerToCorner adjustment. Computed, never copied: copying a template's screen
-- position is what drew Crystal's first ghost off the bottom of the screen.
local function spriteScreenPos(mapX, mapY, centerToCornerVecY)
    local sb1 = r32(GSAVEBLOCK1PTR_ADDR)
    local camX, camY = 0, 0
    local fcx = memory.read_s32_le(GFIELDCAMERA_X_ADDR)
    local fcy = memory.read_s32_le(GFIELDCAMERA_Y_ADDR)
    if fcx > 0 then camX = 1 elseif fcx < 0 then camX = -1 end
    if fcy > 0 then camY = 1 elseif fcy < 0 then camY = -1 end
    local x = (((mapX + camX) - rs16(sb1 + 0x00)) << 4) - rs16(GTOTALCAMERAPIXELOFFSETX_ADDR)
    local y = (((mapY + camY) - rs16(sb1 + 0x02)) << 4) - rs16(GTOTALCAMERAPIXELOFFSETY_ADDR)
    local c2cY = centerToCornerVecY
    if c2cY > 127 then c2cY = c2cY - 256 end
    return x + 8, y + 16 + c2cY
end

-- Downward, like the sprite scan, and for a second reason beyond staying out of the engine's way:
-- ghosts use LOCALID_PLAYER (see spawnGhost), and GetObjectEventIdByLocalId scans UPWARD from 0
-- returning the first match. Taking high slots keeps the real player -- normally slot 0 -- ahead
-- of every ghost, so anything asking "which object is the player" still gets the player.
-- A ghost's screen position is computed once, at spawn or teleport, and from then on the engine
-- only applies camera DELTAS to it. So the computation has to happen at a moment when the
-- formula is exact, and it is only exact when the camera is at rest: mid-scroll, the sub-tile
-- remainder gets baked into the sprite permanently and the ghost renders a few pixels off its
-- tile forever. Crystal hit the same thing. Waiting a frame costs nothing -- the camera settles
-- constantly -- and it is the difference between a ghost on the grid and a ghost beside it.
local function cameraIsSettled()
    return memory.read_s32_le(GFIELDCAMERA_X_ADDR) == 0
        and memory.read_s32_le(GFIELDCAMERA_Y_ADDR) == 0
end

local function findFreeObjectSlot()
    for i = 15, 0, -1 do
        if (r8(objAddr(i) + 0x00) & 0x01) == 0 then return i end
    end
    return nil
end

-- Downward: the engine's own CreateSprite takes the lowest free index, so taking a high one keeps
-- the ghost out of the way of whatever the game allocates next.
local function findFreeSpriteSlot()
    for i = MAX_SPRITES - 1, 0, -1 do
        if (r8(sprAddr(i) + 0x3e) & 0x01) == 0 then return i end
    end
    return nil
end

-- LOCALID_PLAYER (255), deliberately, and it is the fix for a real bug found live 2026-08-18:
-- talking to a ghost ran a garbage script and dumped the user into the slot-machine minigame.
-- An A-press resolves a script by looking the object's localId up in the MAP'S TEMPLATE TABLE
-- (GetObjectEventScriptPointerByObjectEventId -> GetObjectEventTemplateByLocalIdAndMap). A
-- synthesised ghost has no template, the lookup returns NULL, and the game runs whatever is at
-- that address -- the decomp even marks that NULL deref as a known bug.
-- GetInteractedObjectEventScript (field_control_avatar.c:292) returns NULL outright for any
-- object whose localId is LOCALID_PLAYER, so borrowing that id makes the ghost non-interactable
-- using the engine's own check rather than a guard of ours.
local GHOST_LOCAL_ID = 255

-- ghosts[playerId] = { objId, sprId, localId, tileStart, tileCount, mapX, mapY }
local ghosts = {}

-- Forward declaration: despawnGhost below must ask "is this still ours" before it destroys
-- anything, and the identity check itself reads the save block pointer defined further down.
local ghostAlive

local function freeGhostTiles(g)
    if g.tileStart then
        for t = g.tileStart, g.tileStart + g.tileCount - 1 do setTileAllocated(t, false) end
    end
end

-- Deliberately NOT an imitation of RemoveObjectEventInternal, which calls DestroySprite and frees
-- tiles via the sprite's own images->size. We free exactly the range we allocated: simpler, and it
-- cannot free somebody else's VRAM.
-- IDENTITY FIRST, always. A map load runs ResetSpriteData (overworld.c:2134), which calls
-- FreeSpriteTileRanges and ResetAllSprites, and RemoveAllObjectEventsExceptPlayer clears the
-- object array -- then the NEW map's NPCs are given those same slots and those same tiles. So
-- destroying "our" ghost without checking it is still ours would deactivate a real NPC and free
-- the tiles of somebody else's sprite. Both are silent: the NPC just vanishes, and the VRAM
-- corruption shows up later somewhere unrelated.
--
-- This is why the re-spawn on map change is NOT a bandage. The engine genuinely destroys every
-- object it owns on a map load, a ghost is not one of its objects, and nothing exists to recreate
-- it -- so re-spawning is the correct response to a documented engine lifecycle, not a patch over
-- a bug of ours. What WOULD have been a bandage is what this replaces: cleaning up a slot we no
-- longer own and hoping the numbers still meant what they meant.
local function despawnGhost(playerId)
    local g = ghosts[playerId]
    if not g then return end
    if ghostAlive(g) then
        w8(objAddr(g.objId) + 0x00, 0)
        local d = sprAddr(g.sprId)
        w8(d + 0x3e, (r8(d + 0x3e) & ~0x01) | 0x04) -- inUse = 0, invisible = 1
        freeGhostTiles(g)
    end
    -- Not ours any more: drop the bookkeeping and touch nothing. The engine already reclaimed
    -- both the slot and the tiles when it tore the map down.
    ghosts[playerId] = nil
end

despawnAllGhosts = function()
    for playerId in pairs(ghosts) do despawnGhost(playerId) end
end

-- Liveness by IDENTITY, never by slot state: a map load clears the array and the next map's own
-- NPCs take the same slots, which answers "is this slot active?" perfectly plausibly. Confirmed
-- live 2026-08-18 -- slot 4 came back as a real NPC of the new map.
-- Identity WITHOUT the map, and that omission is the whole point.
--
-- Route-to-route in Emerald is a CONNECTION, not a warp: crossing the boundary changes mapNum
-- while the object array is left intact. An identity check that included "map matches" therefore
-- declared a perfectly live ghost dead at every route boundary -- so the adapter dropped its
-- record and spawned a NEW ghost, while the old object stayed active with nobody tracking it.
-- Walking back and forth left a line of them, and since ghosts are solid, enough orphans would
-- eventually wall off the route. Found live 2026-08-18, from a screenshot of five.
--
-- What identifies a ghost instead: it is active, it is NOT the player, and its localId is
-- LOCALID_PLAYER. Only our ghosts are in that state -- a real NPC always has localId < 255
-- (map templates number from 1), and the player has isPlayer set. That survives a connection
-- crossing (nothing changes) and correctly reports death after a warp, where the engine clears
-- the array and any NPC given the slot arrives with a template localId.
ghostAlive = function(g)
    local a = objAddr(g.objId)
    if (r8(a + 0x00) & 0x01) ~= 1 then return false end          -- not active
    if (r8(a + 0x02) & 0x01) == 1 then return false end          -- became the player somehow
    if r8(a + 0x08) ~= GHOST_LOCAL_ID then return false end      -- slot reused by a real NPC
    if r8(a + 0x04) ~= g.sprId then return false end             -- no longer points at our sprite
    return (r8(sprAddr(g.sprId) + 0x3e) & 0x01) == 1             -- and that sprite still exists
end

-- Orphan sweep. Anything wearing our marker that we are not tracking is a ghost from a previous
-- script load or a bug -- ours are the only objects that can be active, not the player, and
-- localId LOCALID_PLAYER. Clearing them is what stops solid leftovers accumulating into a wall.
-- Their VRAM tiles are not freed here because their ranges are unknown; the engine's own
-- FreeSpriteTileRanges on the next map load reclaims those.
local function sweepOrphanGhosts()
    local mine = {}
    for _, g in pairs(ghosts) do mine[g.objId] = true end
    for i = 0, 15 do
        local a = objAddr(i)
        if not mine[i]
            and (r8(a + 0x00) & 0x01) == 1
            and (r8(a + 0x02) & 0x01) == 0
            and r8(a + 0x08) == GHOST_LOCAL_ID then
            local sprId = r8(a + 0x04)
            w8(a + 0x00, 0)
            if sprId < MAX_SPRITES then
                local d = sprAddr(sprId)
                w8(d + 0x3e, (r8(d + 0x3e) & ~0x01) | 0x04)
            end
            console.log(string.format("MeshGhost: cleared an orphaned ghost in object slot %d.", i))
        end
    end
end

local function spawnGhost(playerId, mapX, mapY, orientation)
    local playerObjId = r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05)
    local pObj = objAddr(playerObjId)
    local playerSprId = r8(pObj + 0x04)

    -- Before writing a byte: the player's object event and the sprite it names must agree. This is
    -- what proves gSprites is where we think it is -- the one thing an address shift could break
    -- silently, and the one that would corrupt a live sprite if wrong.
    if rs16(sprAddr(playerSprId) + 0x2e) ~= playerObjId then
        console.log("MeshGhost: refusing to spawn -- the player's object/sprite cross-link does "
            .. "not check out, so gSprites is not where this build expects.")
        return nil
    end

    local objId = findFreeObjectSlot()
    local sprId = findFreeSpriteSlot()
    local localId = GHOST_LOCAL_ID
    if not objId or not sprId then
        console.log("MeshGhost: no free slot for a ghost (objects or sprites full).")
        return nil
    end

    local sb1 = r32(GSAVEBLOCK1PTR_ADDR)
    local graphicsId = r8(pObj + 0x05)
    local elevation = r8(pObj + 0x0b) & 0x0f
    local gx, gy = mapX + MAP_OFFSET, mapY + MAP_OFFSET
    local dir = DIR_ID[orientation] or DIR_ID.south

    local tileCount = graphicsFrameTileCount(graphicsId)
    if not tileCount then return nil end
    local tileStart = allocSpriteTiles(tileCount)
    if not tileStart then
        console.log("MeshGhost: no run of free OBJ tiles for a ghost.")
        return nil
    end

    -- The object event: zeroed, then exactly the fields InitObjectEventStateFromTemplate sets,
    -- with movementType forced to NONE so nothing drives the ghost but us.
    local a = objAddr(objId)
    for off = 0, OBJECTEVENT_SIZE - 1 do w8(a + off, 0) end
    w8(a + 0x00, 0x05) -- active | triggerGroundEffectsOnMove
    w8(a + 0x05, graphicsId)
    w8(a + 0x06, MOVEMENT_TYPE_NONE)
    w8(a + 0x08, localId)
    w8(a + 0x09, r8(sb1 + 0x05)) -- mapNum
    w8(a + 0x0a, r8(sb1 + 0x04)) -- mapGroup
    w8(a + 0x0b, elevation | (elevation << 4))
    w16(a + 0x0c, gx) w16(a + 0x0e, gy)
    w16(a + 0x10, gx) w16(a + 0x12, gy)
    w16(a + 0x14, gx) w16(a + 0x16, gy)
    w8(a + 0x18, dir | (dir << 4))
    w8(a + 0x20, dir)
    w8(a + 0x04, sprId)

    -- The sprite: copied from the player's for its four ROM pointers, OAM shape and palette, then
    -- patched -- including its OWN tiles, without which it shows the player's current frame.
    local src, dst = sprAddr(playerSprId), sprAddr(sprId)
    for off = 0, SPRITE_STRUCT_SIZE - 1 do w8(dst + off, r8(src + off)) end
    local attr2 = r16(dst + 0x04)
    w16(dst + 0x04, (attr2 & 0xfc00) | (tileStart & 0x03ff))
    local sx, sy = spriteScreenPos(gx, gy, r8(dst + 0x29))
    w32(dst + 0x1c, MOVEMENTTYPE_NONE_CB)
    w16(dst + 0x20, sx) w16(dst + 0x22, sy)
    w16(dst + 0x24, 0) w16(dst + 0x26, 0)
    for k = 0, 7 do w16(dst + 0x2e + k * 2, 0) end
    w16(dst + 0x2e, objId)
    w8(dst + 0x2a, 0) w8(dst + 0x2b, 0)
    w8(dst + 0x3e, (r8(dst + 0x3e) | 0x03) & ~0x04)
    w8(dst + 0x3f, r8(dst + 0x3f) | 0x04)

    ghosts[playerId] = {
        objId = objId, sprId = sprId, localId = localId,
        tileStart = tileStart, tileCount = tileCount, mapX = mapX, mapY = mapY,
    }
    return ghosts[playerId]
end

-- ObjectEventSetHeldMovement (event_object_movement.c:4870): three object fields plus the sprite's
-- action-function index. The engine plays out the whole tile -- animation, slide, coordinates.
local function requestAction(g, action)
    local a = objAddr(g.objId)
    w8(a + 0x1c, action)
    w8(a + 0x00, (r8(a + 0x00) | 0x40) & ~0x80) -- heldMovementActive = 1, finished = 0
    w16(sprAddr(g.sprId) + 0x32, 0) -- data[2] = sActionFuncId
end

-- ObjectEventClearHeldMovement (event_object_movement.c:4895). The engine sets
-- heldMovementFinished when a step completes but leaves heldMovementActive SET -- clearing is the
-- caller's job. Found live 2026-08-18: a ghost took exactly one step and then froze forever,
-- reading held=1/1 in the log, because "active" was being treated as "still moving".
local MOVEMENT_ACTION_NONE = 0xff
local function clearHeldMovement(g)
    local a = objAddr(g.objId)
    w8(a + 0x1c, MOVEMENT_ACTION_NONE)
    w8(a + 0x00, r8(a + 0x00) & ~0xc0) -- heldMovementActive = 0, heldMovementFinished = 0
    local d = sprAddr(g.sprId)
    w16(d + 0x30, 0) -- data[1] = sTypeFuncId
    w16(d + 0x32, 0) -- data[2] = sActionFuncId
end

-- "Ready for a new order", which is not the same question as "is a movement flagged active".
local function ghostIsIdle(g)
    local b0 = r8(objAddr(g.objId) + 0x00)
    local active = (b0 >> 6) & 0x01
    local finished = (b0 >> 7) & 0x01
    if active == 1 and finished == 1 then
        clearHeldMovement(g)
        return true
    end
    return active == 0
end

local function teleportGhost(g, mapX, mapY)
    local a = objAddr(g.objId)
    local gx, gy = mapX + MAP_OFFSET, mapY + MAP_OFFSET
    w16(a + 0x0c, gx) w16(a + 0x0e, gy)
    w16(a + 0x10, gx) w16(a + 0x12, gy)
    w16(a + 0x14, gx) w16(a + 0x16, gy)
    local d = sprAddr(g.sprId)
    local sx, sy = spriteScreenPos(gx, gy, r8(d + 0x29))
    w16(d + 0x20, sx) w16(d + 0x22, sy)
    w16(d + 0x24, 0) w16(d + 0x26, 0)
    g.mapX, g.mapY = mapX, mapY
end

-- One remote, one frame. Spawn if missing, step it if it moved one tile, teleport if it jumped,
-- and turn it on the spot otherwise.
local function syncGhost(playerId, remote)
    local targetX = math.floor(remote.x + 0.5)
    local targetY = math.floor(remote.y + 0.5)
    if playerId:match("%-ghost$") then
        targetX = targetX + LOOPBACK_GHOST_OFFSET_TILES_X
        targetY = targetY + LOOPBACK_GHOST_OFFSET_TILES_Y
    end

    local g = ghosts[playerId]
    if g and not ghostAlive(g) then
        -- The engine cleared it (map load) or culled it (walked out of view). Both are normal, and
        -- in both cases the tiles went with it -- freeing our old range here would clear bits the
        -- new map's sprites now own. Drop the record, free nothing.
        ghosts[playerId] = nil
        g = nil
    end
    if not g then
        -- Placement is only exact on a settled camera; a frame's wait is free.
        if cameraIsSettled() then
            spawnGhost(playerId, targetX, targetY, remote.orientation)
        end
        return
    end

    if not ghostIsIdle(g) then return end -- never interrupt a half-played step

    local dir = DIR_ID[remote.orientation] or DIR_ID.south

    -- Trust the engine's own coordinates rather than our record of them: it owns the object once
    -- a step is under way, and a step that got cancelled would otherwise leave us out of sync.
    local a = objAddr(g.objId)
    local curX = rs16(a + 0x10) - MAP_OFFSET
    local curY = rs16(a + 0x12) - MAP_OFFSET
    local dx, dy = targetX - curX, targetY - curY

    if dx == 0 and dy == 0 then
        if (r8(a + 0x18) & 0x0f) ~= dir then requestAction(g, FACE_ACTION[dir]) end
        return
    end

    if math.abs(dx) + math.abs(dy) == 1 then
        local stepDir
        if dx == 1 then stepDir = DIR_ID.east
        elseif dx == -1 then stepDir = DIR_ID.west
        elseif dy == 1 then stepDir = DIR_ID.south
        else stepDir = DIR_ID.north end
        local actions = (remote.anim == "running") and RUN_ACTION or WALK_ACTION
        requestAction(g, actions[stepDir])
    else
        -- More than a tile out: a warp, a dropped packet, or a peer moving faster than we sample.
        -- Walking it there would fall further behind every frame, so place it -- but only once the
        -- camera has settled, for the same reason as spawning.
        if not cameraIsSettled() then return end
        teleportGhost(g, targetX, targetY)
        if (r8(a + 0x18) & 0x0f) ~= dir then requestAction(g, FACE_ACTION[dir]) end
    end
end

local function syncRemoteGhosts(localAreaId)
    for playerId in pairs(ghosts) do
        local remote = remotes[playerId]
        -- Gone, or somewhere else. area_id is opaque and compared by equality only.
        if not remote or remote.areaId ~= localAreaId then despawnGhost(playerId) end
    end
    for playerId, remote in pairs(remotes) do
        if remote.areaId == localAreaId then syncGhost(playerId, remote) end
    end
end

local function drawRemotes(localAreaId, playerMapX, playerMapY)
    local playerScreenX, playerScreenY = playerScreenPos()
    for playerId, remote in pairs(remotes) do
        if remote.areaId == localAreaId then
            local screenX = playerScreenX + (remote.x - playerMapX) * TILE
            local screenY = playerScreenY + (remote.y - playerMapY) * TILE
            if playerId:match("%-ghost$") then
                screenX = screenX + LOOPBACK_GHOST_OFFSET_TILES_X * TILE
                screenY = screenY + LOOPBACK_GHOST_OFFSET_TILES_Y * TILE
            end

            local dirInfo = DIRECTION_ANIM[remote.orientation] or DIRECTION_ANIM.south
            local frameIndex, pose
            if remote.anim == "walking" or remote.anim == "running" then
                pose = (remote.anim == "running") and "run" or "walk"
                frameIndex = advanceAnim(remote, dirInfo)
            else
                remote.animTimer = 0
                remote.animStepIndex = 1
                remote.lastAnim = remote.anim
                remote.lastOrientation = remote.orientation
                pose = "walk" -- idle frames (0-2) only exist in the walk/Normal pic table
                frameIndex = dirInfo.idle
            end

            drawSpriteFrame(remote.gender, pose, frameIndex, dirInfo.hFlip, screenX, screenY)
        end
        -- A remote in a different area is deliberately not drawn at all --
        -- area_id is opaque and compared by equality only
        -- (agent_docs/contract.md); this is not the same as despawning it.
    end
end

----------------------------------------------------------------------------
-- Main loop. The adapter always drives (agent_docs/contract.md's tick
-- model): once per emu frame, try to connect if needed, send local state,
-- drain and apply whatever the core pushed back, then redraw every known
-- remote unconditionally.
----------------------------------------------------------------------------

if not memory.usememorydomain("System Bus") then
    console.log("ERROR: 'System Bus' memory domain not found on this core.")
    console.log("Domains available: " .. memory.getmemorydomainlist())
    return
end

console.log("MeshGhost Emerald adapter running.")
console.log("Decoding Brendan/May sprite frames...")
loadGenderFrames()
tryDetectAvatarAddrOffset() -- may not find it yet if loaded during the intro/title sequence --
-- see the main loop below, which keeps retrying every frame until it succeeds.
if BRIDGE_PORT_OVERRIDE then
    console.log(string.format("Bridge target %s:%d (MESHGHOST_BRIDGE_PORT is set, so no port walk).",
        BRIDGE_HOST, BRIDGE_PORT_OVERRIDE))
else
    console.log(string.format("Bridge: walking %s:%d-%d for a core that will have us. Two copies "
        .. "on one machine each find their own.", BRIDGE_HOST, BRIDGE_BASE_PORT,
        BRIDGE_BASE_PORT + BRIDGE_PORT_COUNT - 1))
end

local localGender = nil -- resolved lazily, first frame a save is loaded (see readLocalGender)

-- One frame's worth of work, pcall-wrapped below so a malformed remote (a bad jsonDecode
-- result reaching handleBridgeLine, an unexpected shape in memory reads, etc.) logs and skips
-- a frame instead of a single Lua error killing the whole adapter for the rest of the session.
local function runFrame()
    frameCounter = frameCounter + 1
    gui.clearGraphics()

    if not avatarAddrConfirmed then
        tryDetectAvatarAddrOffset()
    end

    -- A connection that never got an answer is not worth keeping: something that accepts and
    -- then stays silent is far more likely an unrelated program holding a port in our range than
    -- a core. Dropping it costs nothing (the walk tries elsewhere); committing to it costs the
    -- whole session.
    if connected and not ready and helloSentAtFrame
        and frameCounter - helloSentAtFrame > HELLO_ANSWER_FRAMES then
        markPortBusy(currentPort, "never answered our hello, so it is not a core we can use")
        resetBridge()
    end

    if not connected then
        connectBridge()
        if connected then
            console.log(string.format("MeshGhost: bridge connected on %s:%d.", BRIDGE_HOST, currentPort))
            helloSentAtFrame = frameCounter
            -- Must be the first message on a fresh connection, before any local_state --
            -- see internal/bridge.Hello. Declares the game so the core can connect to the
            -- relay without the user typing "game" into config.json themselves.
            sendLine(string.format('{"type":"hello","payload":{"game_id":%s,"game_version":%s}}', jsonString(GAME_ID), jsonString(ADAPTER_VERSION)))
            -- A fresh bridge connection means a fresh core process on the other end (the
            -- previous one either restarted or its own connection died) -- any remote it had
            -- previously told us about is stale, since the despawn_remote for it (if any was
            -- ever sent) may have been lost during the outage, same failure shape as the
            -- already-known "gui.* overlay doesn't auto-clear" class of bug: nothing else
            -- would ever notice and clear a stale entry on its own. Found live 2026-08-11: a
            -- restarted core process without restarting this script left an old peer's ghost
            -- on screen alongside the new one.
            remotes = {}
            despawnAllGhosts()
        end
    end

    -- Once every 5s, to the log file only: enough to tell which link in the chain is quiet
    -- without reading the game. "connected" and "ready" are different questions, and so are
    -- "a peer is known" and "a ghost exists for it" -- a silent failure looks different in each.
    if frameCounter % 60 == 0 then
        sweepOrphanGhosts()
    end

    if frameCounter % 300 == 0 then
        local nRemotes, nGhosts = 0, 0
        for _ in pairs(remotes) do nRemotes = nRemotes + 1 end
        for _ in pairs(ghosts) do nGhosts = nGhosts + 1 end
        logFile(string.format(
            "status: frame=%d connected=%s ready=%s port=%s remotes=%d ghosts=%d overworld=%s",
            frameCounter, tostring(connected), tostring(ready), tostring(currentPort),
            nRemotes, nGhosts, tostring(inOverworld())))
        -- Collision follows the object's map coordinates; drawing follows the sprite's screen
        -- position. A ghost whose hitbox sits away from its picture means those two disagree, so
        -- both are logged next to the player's own pair as the control.
        local sb1 = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
        if sb1 ~= 0 then
            local pObjId = r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05)
            local pa, ps = objAddr(pObjId), sprAddr(r8(objAddr(pObjId) + 0x04))
            logFile(string.format(
                "  player: pos=(%d,%d) coords=(%d,%d) sprite=(%d,%d) camOff=(%d,%d)",
                rs16(sb1 + 0x00), rs16(sb1 + 0x02), rs16(pa + 0x10), rs16(pa + 0x12),
                rs16(ps + 0x20), rs16(ps + 0x22),
                rs16(GTOTALCAMERAPIXELOFFSETX_ADDR), rs16(GTOTALCAMERAPIXELOFFSETY_ADDR)))
            for playerId, g in pairs(ghosts) do
                local ga, gs = objAddr(g.objId), sprAddr(g.sprId)
                logFile(string.format(
                    "  ghost %s: obj=%d spr=%d coords=(%d,%d) sprite=(%d,%d) held=%d/%d anim=%d "
                        .. "action=%d peerAnim=%s",
                    tostring(playerId), g.objId, g.sprId, rs16(ga + 0x10), rs16(ga + 0x12),
                    rs16(gs + 0x20), rs16(gs + 0x22),
                    (r8(ga + 0x00) >> 6) & 1, (r8(ga + 0x00) >> 7) & 1, r8(gs + 0x2a),
                    r8(ga + 0x1c), tostring(remotes[playerId] and remotes[playerId].anim)))
            end
        end
    end

    if connected then
        local state = getLocalState()
        local smoothX, smoothY, smoothAreaId
        if state then
            -- inOverworld() gate added 2026-08-14 -- see readLocalGender's header comment for
            -- why: getLocalState() succeeding alone (gSaveBlock1Ptr non-null) isn't confirmed
            -- to mean a real save is loaded and the player has actually chosen a gender yet.
            if not localGender and inOverworld() then
                localGender = readLocalGender()
                if localGender then
                    console.log("MeshGhost: local gender = " .. localGender)
                end
            end
            smoothX, smoothY = smoothPosition(state.x, state.y, state.areaId, state.anim)
            smoothAreaId = state.areaId
            if DIAG_STEP_CURVE and inRealGlide and diagStepCurveLogCount < DIAG_STEP_CURVE_MAX_LOGS then
                local realX, realY = playerScreenPos()
                local deltaX = diagPrevRealX and (realX - diagPrevRealX) or 0
                local deltaY = diagPrevRealY and (realY - diagPrevRealY) or 0
                diagPrevRealX, diagPrevRealY = realX, realY
                diagStepCurveLogCount = diagStepCurveLogCount + 1
                console.log(string.format(
                    "MeshGhost DIAG CURVE: frame=%d smoothX=%.4f smoothY=%.4f realScreenX=%d realScreenY=%d realDX=%d realDY=%d",
                    frameCounter, smoothX, smoothY, realX, realY, deltaX, deltaY))
            end
            -- Not until bridge_ready. "The socket connected" is not "this core is ours", and
            -- sending state to a core that is about to reject us is state sent to somebody
            -- else's session (agent_docs/contract.md, PROTOCOL.md's tick loop).
            if ready then
                sendLine(encodeLocalState(state.areaId, smoothX, smoothY, state.orientation, state.anim, localGender or "male"))
            end
        elseif ready then
            sendLine(ENCODED_NO_SEND)
        end

        if connected then
            drainBridge()
        end

        -- Reuses the SAME smoothed self-position just computed above (not a fresh raw
        -- integer re-read) as the anchor for placing remotes -- found live 2026-08-11 that
        -- anchoring on the raw integer tile position while playerScreenPos() (used inside
        -- drawRemotes) is a smooth, continuously-updating pixel position made even a
        -- perfectly stationary remote's ghost visibly wobble on this client's own screen
        -- whenever the local player was mid-step. Skips drawing for the rare single frame
        -- where state is nil (the map-transition debounce) rather than falling back to a
        -- raw read that wouldn't be consistent with what was just sent to the network.
        if connected and inOverworld() and smoothX then
            -- SPAWN where we can, DRAW where we cannot. The spawn path writes gObjectEvents and
            -- gSprites; gObjectEvents' Archipelago relocation is measured and applied
            -- (avatarAddrOffset), but gSprites' is NOT -- the adapter only ever read gSprites at
            -- its vanilla address. Reading a wrong address returns a wrong number; WRITING one
            -- corrupts whatever now lives there, so a patched ROM keeps the overlay until that
            -- shift is measured. Registered in BANDAGES.md as a deliberate, temporary split.
            if avatarAddrOffset == 0 then
                syncRemoteGhosts(smoothAreaId)
            else
                drawRemotes(smoothAreaId, smoothX, smoothY)
            end
        end
    end
end

local lastFrameErrorLogged = 0

local function guardedFrame()
    local ok, err = pcall(runFrame)
    if not ok then
        -- Rate-limited: a per-frame error would otherwise spam the console every 1/60s.
        if frameCounter - lastFrameErrorLogged > 300 then
            console.log("MeshGhost: frame error (continuing): " .. tostring(err))
            lastFrameErrorLogged = frameCounter
        end
    end
end

-- Four lines of dev affordance, and the only one in this file: when loaded by
-- dev-scripts/bizhawk-dev-loader.lua (a development tool, never shipped), hand it the per-frame
-- function instead of taking the frame loop, so the adapter can be swapped and reloaded live like
-- any probe. A player opening this file in the Lua Console sets neither global and gets the
-- normal loop below, unchanged. Without this, testing an adapter edit costs a full emulator
-- relaunch each time, which is the cost the loader exists to remove.
MESHGHOST_DEV_TICK = guardedFrame
MESHGHOST_DEV_UNLOAD = function()
    -- Both halves matter. Ghosts are objects living in the game and nothing else will clear them.
    -- The log file is a real OS handle: without closing it, every reload during a development
    -- session leaks one, and the files stay locked -- which is how eleven of them ended up
    -- unmovable on 2026-08-18 while trying to tidy the folder they were cluttering.
    pcall(despawnAllGhosts)
    if logfile then
        logfile:close()
        logfile = nil
    end
end

if not MESHGHOST_DEV_LOADER then
    while true do
        guardedFrame()
        emu.frameadvance()
    end
end
