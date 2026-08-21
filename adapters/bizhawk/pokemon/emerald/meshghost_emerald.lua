-- MeshGhost — Pokémon Emerald adapter
--
-- *** WRITES GAME RAM. *** Object RAM only (gObjectEvents, gSprites, the sprite-tile
-- allocation bitmap), never a save, cosmetic only. See agent_docs/architecture.md's
-- 2026-08-18 ADR, which extends Crystal's spawn ADR to this adapter, and the ROM guard
-- below. The header used to end "Never writes memory" -- true until the spawn path landed
-- 2026-08-18, and left standing afterwards; it was the most misleading line in the file.
--
-- This is the real, actively-maintained Emerald adapter -- what actually ships (see
-- packaging/README.md and .github/workflows/release.yml, which stage this file as
-- games/pokemon/emerald/meshghost_emerald.lua in the release zip) and what any future fix or
-- feature for this game should be made in. adapters/bizhawk/pokemon/emerald/probes/phase5_5_sprite.lua was a
-- byte-identical copy of this file at the moment it was renamed here from that original
-- development-phase name (2026-08-14, once this had been the stable, shipped adapter for a
-- while and "phase5_5_sprite" no longer read as the current, final one it actually was) --
-- it has since diverged (every fix and feature below this point in the history was made only
-- here) and is kept purely as a historical snapshot, not a live mirror -- edit only this file,
-- not that one, going forward.
--
-- Otherwise unchanged from its original Phase 5.5 content: real Brendan/May ghost sprite
-- instead of the magenta placeholder box. Same adapter <-> bridge <-> core round trip as
-- adapters/bizhawk/pokemon/emerald/probes/phase4_multiplayer.lua (state reading, screen-position anchor,
-- JSON, bridge protocol, remote-ghost set, tick model, overworld gate, LuaSocket loading --
-- all unchanged, see that script's header for the full derivation and citations, not
-- re-derived here). That inherited content is read-only; the RAM writes this adapter now does
-- are the spawn path added 2026-08-18, described in the banner at the top of this file.
--
-- What's different from phase4_multiplayer.lua: drawRemotes() decodes and draws the real
-- Brendan/May overworld sprite (gender, facing direction, and walk/run animation, including a
-- genuinely separate running pose -- see below) via gui.drawPixel, instead of
-- gui.drawImage-ing a flat placeholder box. Local gender is read once at script start from
-- gSaveBlock2Ptr->playerGender and sent in extras.gender (agent_docs/contract.md's extras
-- field is already free-form/opaque, no core/relay change needed); a remote's advertised
-- gender picks which pic table its ghost is drawn from.
--
-- Sprite decode: see adapters/bizhawk/pokemon/emerald/probes/sprite_probe.lua (Step 1, confirmed 2026-08-11) and
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
-- watched live, 2026-08-14, via adapters/bizhawk/pokemon/emerald/probes/battle_probe.lua against a real
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
-- Global FIRST, then the environment -- the same order Crystal's adapter uses, and the reason
-- matters when more than one emulator is open: an environment variable is fixed when BizHawk
-- launches, while a global can be set by whatever loads this script, which is how a dev loader
-- pins an already-running instance to its own core. Emerald read only the environment until
-- 2026-08-19, so a session that pinned the port by global was silently port-walked instead --
-- and walked straight into two other instances' cores, attaching to one of them.
local BRIDGE_PORT_OVERRIDE = tonumber(MESHGHOST_BRIDGE_PORT
    or os.getenv("MESHGHOST_BRIDGE_PORT") or "")
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
    -- CACHED, because this offset is not only about the pictures decoded below. The same
    -- Archipelago recompile that moved the sprite/palette block moved the ROM POINTER TABLE
    -- graphicsInfo() reads (measured 2026-08-19: at the vanilla address its entries are not even
    -- ROM pointers; at +0x7530 every entry is a valid graphics info struct). Nothing applied the
    -- offset there, so on a patched ROM graphicsInfo() returned nil for every id, spawnGhost()
    -- hit `if not info then return nil end`, and the adapter silently spawned NOTHING while
    -- reporting peers received and in the same area. Stored on genderFrames rather than as a new
    -- local: the main chunk is at Lua's 200-local ceiling.
    genderFrames.romOffset = offset
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
    -- MESHGHOST_SCRIPT_DIR, if set. This exists because of the case below it: loaded with
    -- `--lua=<path>` BizHawk reports `source` as `[string "main"]`, NOT a path, so the branch
    -- above cannot answer and the io.popen fallback is what actually ran -- every launch, which
    -- is where the console-window flash came from. Anything launching this script can hand it
    -- the answer for free instead (dev-scripts do), and then no process is spawned at all.
    -- Game-specific FIRST. An environment variable is process-wide, and BizHawk runs every Lua
    -- script in one process -- so a plain MESHGHOST_SCRIPT_DIR set for one adapter is inherited
    -- by the next one loaded, which sent Crystal's log and DLL search into Emerald's folder
    -- (found live 2026-08-18, loading both adapters in one emulator).
    local fromEnv = MESHGHOST_SCRIPT_DIR
        or os.getenv("MESHGHOST_SCRIPT_DIR_EMERALD")
        or os.getenv("MESHGHOST_SCRIPT_DIR")
    if fromEnv and fromEnv ~= "" then
        return (fromEnv:gsub("[/\\]$", "")) .. "/"
    end

    -- Last resort, and it DOES get used: `--lua=` with no env var set. It answers with the
    -- working directory rather than this script's, so it is only right when the two happen to
    -- agree -- and it spawns a real `cmd` to ask, which is the window that flashes. Removing it
    -- outright on 2026-08-18 broke `--lua=` loading immediately ("could not determine the
    -- script's own directory"), which is how we learned the comment calling it unreachable was
    -- wrong. Kept, and now reached only when nothing better was offered.
    local pwd = io.popen and io.popen("cd"):read("*l")
    if not pwd or pwd == "" then
        error("MeshGhost: could not determine the script's own directory. Load this file from "
            .. "BizHawk's Lua Console, or set MESHGHOST_SCRIPT_DIR to the folder holding it.")
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
--
-- THE NAME CARRIES THIS EMULATOR'S PROCESS ID, and that is not decoration. Two emulators running
-- the same game (a vanilla ROM and a patched seed, which is the normal two-instance session here)
-- run this same script, and a name resolved only to the SECOND collides whenever both reload in
-- the same second -- which is exactly what a control-file edit or a shared restart does. Both then
-- hold the same file open and their lines interleave mid-write, producing mangled lines like
-- "atus: frame=..." where one write landed inside another. Found live 2026-08-19 with two Emerald
-- instances; a pid cannot collide while both processes exist, where a port can (the bridge port is
-- walked, and is not known yet at this point anyway).
local logfile
do
    local okPid, pid = pcall(function()
        luanet.load_assembly("System")
        return luanet.import_type("System.Diagnostics.Process").GetCurrentProcess().Id
    end)
    -- No pid available (a BizHawk build without luanet): fall back to a pinned bridge port, and
    -- then to the clock's fractional part -- any discriminator beats none, because the failure
    -- being prevented is silent corruption of the file rather than a missing one.
    local tag = (okPid and pid) or BRIDGE_PORT_OVERRIDE
        or math.floor((os.clock() % 1) * 100000)
    local name = string.format("meshghost_emerald_%s_%s.log", os.date("%Y%m%d_%H%M%S"), tostring(tag))
    logfile = io.open(SCRIPT_DIR .. "logs/" .. name, "w") or io.open(SCRIPT_DIR .. name, "w")
    -- Beside the logs, and set only here so it inherits whichever directory actually worked.
    genderFrames.xmapCachePath = SCRIPT_DIR .. "logs/xmap_cache.txt"
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
-- The player's CURRENT graphic, which is the whole of their special state. sPlayerAvatarGfxIds
-- (field_player_avatar.c:246) gives every state its own graphicsId per gender -- normal, both
-- bikes, surfing, underwater, field move, fishing, watering -- so a peer's appearance is this one
-- byte and needs no anim classifier or per-mode timing. Sent in `extras`, which contract.md
-- defines as opaque free-form data the core never inspects.
-- DO NOT PUBLISH A STATE THE GAME HAS NOT FINISHED SETTING UP.
--
-- When the player picks up a rod, the game sets the 32-wide fishing graphic about four frames
-- before its fishing task applies the pos2 that re-centres the character on its tile. Those frames
-- are real and briefly visible, but they land while the bag is closing, where an 8px hop cannot be
-- seen. Sent on the wire they become a ghost adopting the rod 8px to the side and then snapping --
-- in a quiet frame, where it is the only thing moving.
--
-- Filtering it at the RECEIVER was tried twice and cannot work: the transient outlives one update
-- and spans two at 20Hz, so "the same state twice" is satisfied by the unsettled state itself.
-- The sender is the only place that sees every frame, so it is the only place that can tell a
-- settled state from a half-built one. A new graphic is held until its offset stops changing --
-- typically two frames, and the peer simply keeps seeing the previous state meanwhile, which is
-- exactly what the player looked like then.
local function localGraphicsId()
    if not avatarAddrConfirmed then return nil end
    local objId = memory.read_u8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05)
    if objId > 15 then return nil end
    local gfx = memory.read_u8(GOBJECTEVENTS_ADDR + avatarAddrOffset + objId * OBJECTEVENT_SIZE
        + 0x05)
    -- Inlined rather than via sprAddr/rs16: those are defined much further down this file, and a
    -- forward reference here would silently read a nil global.
    local sox = memory.read_s16_le(GSPRITES_ADDR
        + memory.read_u8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04) * SPRITE_SIZE + 0x24)
    if gfx ~= genderFrames.sentGfx then
        -- HOW LONG TO HOLD IS MEASURED, not picked. The offset arrives four frames after the
        -- graphic (probes: pos2 0,0 for four frames, then 8,0), and "the same value twice" is
        -- useless against that -- two of those four frames agree with each other, which is exactly
        -- why the first version of this published the unsettled state anyway. Holding SIX frames
        -- clears the measured settle with room to spare, and 100ms is invisible behind the 250ms
        -- of interpolation already in front of it.
        -- Counted in CALLS, not frames: frameCounter is declared further down this file and a
        -- forward reference reads a nil global (caught by the syntax/forward-ref check, and by the
        -- adapter's own error count, within one reload). This runs once per frame from the send
        -- path, so a call is a frame.
        -- THE HOLD IS FOR GRAPHICS WITH AN OFFSET, and only fishing has one. It exists because the
        -- offset lands four frames after the graphic, and publishing the pair unsettled drew an
        -- 8px flash -- measured, above. The walker and both bikes sit at offset 0 on every frame,
        -- so for them the six frames bought nothing and cost exactly the lag the user could see:
        -- the spawned ghost mounting seven frames after the player (frame-by-frame capture,
        -- 2026-08-20). Fishing is 137/138 (Brendan/May, verified.md); anything unrecognised keeps
        -- the hold, which is the conservative side.
        -- SURFING, THE FIELD-MOVE POSE AND UNDERWATER JOINED THE LIST, 2026-08-21, and the reason
        -- is the same one that put the bikes in it: they have no lagging offset to wait for, so
        -- the hold bought nothing and cost lag that showed on screen.
        --
        -- Here the lag was not merely visible, it was CORRUPTING. The game sets the surfing
        -- graphic and the jump onto the water in a single step (`documentation.md`), so holding
        -- the graphic for six frames while the ACTION goes out immediately delivers them to the
        -- ghost five frames apart -- and the engine, told to jump, sets the jump's animation
        -- number on a sprite still wearing the field-move graphic, whose animation table is
        -- shorter and has no such entry. The ghost then draws a frame that does not exist:
        -- measured as `anim=20/4 gfx=3` and `frame-out-of-range` in probes/dive_probe.lua, and
        -- reported from the chair as *"a weird grey/flashing glitched sprite"* every few attempts.
        --
        -- The pair these publish together is honest: their offset is set in the same engine step
        -- as the graphic (the surf blob's bob, the jump arc), not four frames later like the rod's.
        local KNOWN_OFFSETFREE = { [0]=true, [89]=true, [1]=true, [90]=true, [63]=true, [91]=true,
            [2]=true, [92]=true, [3]=true, [93]=true, [111]=true, [112]=true }
        if KNOWN_OFFSETFREE[gfx] then
            genderFrames.sentGfx = gfx
        elseif gfx ~= genderFrames.pendingGfx then
            genderFrames.pendingGfx, genderFrames.pendingTicks = gfx, 0
        else
            genderFrames.pendingTicks = (genderFrames.pendingTicks or 0) + 1
            if genderFrames.pendingTicks >= 6 then genderFrames.sentGfx = gfx end
        end
        if gfx ~= genderFrames.sentGfx then
            -- HOLD THE OFFSET WITH THE GRAPHIC -- by FREEZING it, not zeroing it. They describe
            -- one state, and the six frames of hold must publish the pair that was true together:
            -- the graphic still on the wire and the offset it was last sent with. Zeroing was the
            -- first attempt at this and it is wrong in exactly one direction: putting the rod
            -- AWAY held gfx 137 while already sending sox 0, so every cast ended with the peer's
            -- ghost obeying a mismatched pair -- a 32-wide fishing frame at a walker's offset,
            -- 8px off for the length of the hold. Measured at all six cast-ends in one trace
            -- (f=2512, 3027, 5301, 5452, 5613, 5753): sox flips ~9 frames before gfx does.
            -- Leaving sendSox/sendSoy untouched here publishes 137+8 for the hold, then 0+0
            -- together, and the start direction stays right too: a walker's frozen offset is 0.
            return genderFrames.sentGfx
        end
    end
    genderFrames.sendSox = sox
    genderFrames.sendSoy = memory.read_s16_le(GSPRITES_ADDR
        + memory.read_u8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04) * SPRITE_SIZE + 0x26)
    return gfx
end

-- `sanim` is the player's own SPRITE ANIMATION NUMBER, and it is what `gfx` alone cannot say.
--
-- Adopting a peer's graphicsId makes a ghost hold a fishing rod; it does not make it FISH. The
-- game drives that animation from its own fishing task -- and a ghost has no task, so it sits on
-- the first frame of the animation forever. The user, watching it: *"neither of them are doing the
-- mid fishing animations, just the starting fishing one"* (2026-08-19).
--
-- The animation number is the missing half. Both ends are on the same graphic by then, so the
-- numbering matches, and the peer's own sprite is the authority on what that character is doing.
-- `spaused` is the third thing a sprite's animation state is made of, after the number and the
-- frame -- IS IT RUNNING. A ghost has no task to start or stop its animation, so this decides
-- whether the engine should be handed the animation to play or told to hold one frame.
--
-- Without it every mirrored state was un-paused, which is right for fishing (the game's task really
-- is animating the player) and wrong for a bike standing still: measured 2026-08-19, the player's
-- own Mach Bike sprite idles at anim 7 frame 3 with animPaused SET, while a spawned ghost pedalled
-- on the spot. The user: *"idle it looks fine on the drawn ghost already, but on the spawned one
-- its doing a 'moving' animation when idle"*.
--
-- `noanim` is `spaused`'s missing partner, and the pair is not redundant. `spaused` says the
-- sprite's animation is not running; `disableAnim` says the OBJECT is forbidden one, and that
-- outranks a movement. Everywhere else in the game those agree, so one bit was enough -- ice is
-- where they come apart. ForcedMovement_Slide sets disableAnim and then walks the character fast
-- (src/field_player_avatar.c:526-533), which is a character CROSSING TILES with its legs held
-- still. Without this bit a ghost is told "moving", the engine gives it the walk cycle its action
-- carries, and it strides across the ice while the player glides: measured in Shoal Cave,
-- 2026-08-21 -- the player held anim 10/0 with disableAnim set for the whole slide while the
-- ghost's own copy cycled 10/2, 10/3 under the same action id on the same tile.
local function encodeLocalState(areaId, x, y, orientation, anim, gender, gfx, sanim, sidx, act,
    sox, soy, spaused, pspeed, noanim)
    return string.format(
        '{"type":"local_state","payload":{"state":{"area_id":%s,"position":[%s,%s],"orientation":%s,"anim":%s,"extras":{"gender":%s,"gfx":%s,"sanim":%s,"sidx":%s,"act":%s,"sox":%s,"soy":%s,"spaused":%s,"pspeed":%s,"noanim":%s}}}}',
        jsonString(areaId), tostring(x), tostring(y), jsonString(orientation), jsonString(anim),
        jsonString(gender), tostring(gfx or "null"), tostring(sanim or "null"),
        tostring(sidx or "null"), tostring(act or "null"),
        tostring(sox or "null"), tostring(soy or "null"), tostring(spaused or "null"),
        tostring(pspeed or "null"), tostring(noanim or "null"))
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
        -- NOT table.insert: decodeValue returns nil for JSON `null`, and table.insert(t, nil)
        -- is an error in Lua 5.4 -- so a single null anywhere inside an array threw, jsonDecode
        -- swallowed it, and the WHOLE line was dropped. `extras` is free-form peer-controlled
        -- data (contract.md), so a peer can put one there; the effect was that peer's ghost
        -- silently freezing while every other message kept flowing. Assigning leaves a hole
        -- instead, which the `if pos[1] and pos[2]` guard below already rejects on its own.
        arr[#arr + 1] = val
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

-- The first port in the range with NOTHING listening on it, as observed by the last sweep. That
-- is where autostart puts a new core, and getting it from the sweep rather than assuming
-- BRIDGE_BASE_PORT is what makes a second copy of the game work: the base port is taken by the
-- first copy's core, so spawning there produced a core that could not bind and exited instantly,
-- leaving the second emulator with no core at all (found live 2026-08-18, two Emeralds).
--
-- A port that answered and then REJECTED us is not free -- it is somebody else's core, and it is
-- skipped by busyUntil above rather than recorded here.
local firstFreePort = nil

-- One sweep across the whole range per attempt, not one port per attempt -- one port per retry
-- interval would take many seconds to find a free core a few ports up.
local function connectBridge()
    if BRIDGE_PORT_OVERRIDE then
        firstFreePort = BRIDGE_PORT_OVERRIDE
        tryPort(BRIDGE_PORT_OVERRIDE)
        return
    end
    firstFreePort = nil
    for i = 0, BRIDGE_PORT_COUNT - 1 do
        local port = BRIDGE_BASE_PORT + i
        if (busyUntil[port] or 0) <= frameCounter then
            if tryPort(port) then return end
            -- Nothing answered here, so it is free for a core of our own.
            if not firstFreePort then firstFreePort = port end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Autostart: start a core ourselves, and let it die with the emulator.
--
-- Every adapter is meant to do this (agent_docs/plans.md). It looked impossible from Lua for a
-- while, because os.execute and io.popen both run `cmd /c ...` -- so the console window that
-- flashes belongs to the SHELL doing the launching, and no amount of hiding the child helps.
-- Confirmed by watching all five shell variants flash, `powershell -WindowStyle Hidden` longest.
--
-- The way through is luanet, NLua's .NET bridge, which this BizHawk build exposes: build a
-- System.Diagnostics.ProcessStartInfo with UseShellExecute=false and CreateNoWindow=true and
-- there is no shell and no window at all. Confirmed invisible by the user against a deliberate
-- window-showing control, 2026-08-18 -- see agent_docs/environment.md and
-- dev-scripts/bizhawk-spawn-probe.lua.
--
-- Auto-close comes from the same bridge: GetCurrentProcess().Id is EmuHawk's pid, so the core
-- gets -exit-with-pid and exits when the emulator does, however the emulator goes away. That is
-- the same mechanism TEVI and Pseudoregalia use.
local coreChild, coreSpawnFrame, coreSpawnFailed = nil, nil, false

-- Opting out is supported, not a debug switch: an antivirus that objects to one program starting
-- another is a real thing, and the documented answer is to set this and run the core yourself.
local AUTOSTART = os.getenv("MESHGHOST_NO_AUTOSTART") == nil

-- meshghost.exe is not shipped beside this script (it is 9 MB and every game would carry a copy),
-- so look where it actually is: the release root is three levels up from games/pokemon/emerald,
-- and a source checkout is four up from adapters/bizhawk/pokemon/emerald. Beside the script wins
-- if someone put one there deliberately.
local function findCoreExe()
    local candidates = {
        SCRIPT_DIR .. "meshghost.exe",
        SCRIPT_DIR .. "../../../meshghost.exe",
        SCRIPT_DIR .. "../../../../meshghost.exe",
    }
    for _, path in ipairs(candidates) do
        local f = io.open(path, "rb")
        if f then
            f:close()
            return path
        end
    end
    return nil
end

local function coreStillRunning()
    if not coreChild then return false end
    local ok, exited = pcall(function() return coreChild.HasExited end)
    if not ok then return false end
    return not exited
end

local function startCore(port)
    if not AUTOSTART or coreSpawnFailed or coreStillRunning() then return end
    -- No free port in the whole range: every one of them is somebody else's core. Spawning
    -- anywhere here would just produce a process that cannot bind and exits.
    if not port then return end
    -- A core takes a moment to bind; spawning again before then is how you get a pile of
    -- processes fighting over one port.
    if coreSpawnFrame and (frameCounter - coreSpawnFrame) < 300 then return end

    local exe = findCoreExe()
    if not exe then
        coreSpawnFailed = true
        console.log("MeshGhost: meshghost.exe not found near this script -- not starting a core. "
            .. "Start it yourself, or put a copy beside this file.")
        return
    end

    coreSpawnFrame = frameCounter
    local ok, err = pcall(function()
        luanet.load_assembly("System") -- without this import_type returns nil
        local Process = luanet.import_type("System.Diagnostics.Process")
        local StartInfo = luanet.import_type("System.Diagnostics.ProcessStartInfo")
        local si = StartInfo()
        si.FileName = exe
        -- No relay settings: the core reads config.json from its own directory, which is the file
        -- a player edits. Passing -relay here would silently override it.
        si.Arguments = string.format("-exit-with-pid=%d -bridge=%s:%d",
            Process.GetCurrentProcess().Id, BRIDGE_HOST, port)
        si.UseShellExecute = false
        si.CreateNoWindow = true
        coreChild = Process.Start(si)
    end)
    if not ok then
        coreSpawnFailed = true
        console.log("MeshGhost: could not start a core: " .. tostring(err))
        return
    end
    console.log(string.format("MeshGhost: started a core (no window) on bridge port %d; "
        .. "it will exit with the emulator.", port))
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
    -- ...and the hardware tier's entries, for the same reason and one more: nothing in the engine's
    -- per-frame path clears them, so a dropped bridge would otherwise leave a row of frozen bodies
    -- on screen until the next map load.
    pcall(hwReleaseAll, true)
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

-- One table, not two locals: the main chunk is at Lua's 200-local ceiling (see frameErrors).
local lastMap = { group = nil, num = nil }

local function mapJustChanged(mapGroup, mapNum)
    local changed = lastMap.group ~= nil and (mapGroup ~= lastMap.group or mapNum ~= lastMap.num)
    if changed then lastMap.changedAt = frameCounter end
    lastMap.group, lastMap.num = mapGroup, mapNum
    return changed
end

-- SESSION GATE: nothing is sent until the player is actually IN THE GAME.
-- gSaveBlock1Ptr being non-null is NOT that question. Observed live 2026-08-19: the pointer is
-- already populated at the CONTINUE screen, so the adapter used to broadcast the player's saved
-- position (pos=(10,10), overworld=false) for as long as anyone sat in the main menu -- a peer
-- saw a ghost of them standing at their last save point while they were in a menu. The user's
-- answer (2026-08-19): "it should not show/send the ghost for other people if you are in the main
-- menu/intro. should only show when you are actually in game."
--
-- The gate is a LATCH, not a per-frame inOverworld() test, and the difference matters. Being
-- outside the overworld is not by itself "not in game": a battle, a warp fade and a map load all
-- leave CB2 pointing somewhere else for a while, and contract.md's closed question already
-- decided that position stays valid (and worth sending) through all of them -- the ghost simply
-- stands still. So: the latch OPENS on the first frame the player is confirmed in the overworld,
-- and CLOSES only when gSaveBlock1Ptr reads null again, which is the title screen / intro with no
-- save loaded -- the one state contract.md always agreed warrants nil, and the state a soft reset
-- lands in on its way back to the continue screen.
--
-- One TABLE rather than two plain locals on purpose: Lua's compiler allows at most 200 local
-- variables per function, the main chunk included, and this script's file scope is already at
-- 198 of them -- two more would be within one edit of "too many local variables" at load time,
-- which is a hard parse failure, not a warning.
--   session.live  -- the latch itself.
--   session.ended -- set on the latch's true->false edge, consumed by runFrame.
--
-- Leaving the game has to be ANNOUNCED, not merely gone quiet about. The core holds a peer's newest sample forever
-- (core/interp.go's remoteBuffer.at does not expire), so a client that just stops sending leaves
-- its ghost FROZEN on every other screen rather than gone. Dropping the bridge is the mechanism
-- the core already documents and tests for exactly this ("backing out to the main menu",
-- core_test.go's TestBridgeDisconnectDespawnsForPeer): the core turns a bridge disconnect into a
-- goodbye to the relay, the relay into a real leave, and every peer despawns the ghost. The
-- adapter reconnects on the next frame and sits there sending nothing, so re-entering the game
-- starts sending immediately.
local session = { live = false, ended = false }

local function getLocalState()
    local base = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
    if base == 0 then
        if session.live then session.ended = true end
        session.live = false
        return nil
    end

    if not session.live then
        if not inOverworld() then return nil end
        session.live = true
        console.log("MeshGhost: in game -- now sending local state.")
    end

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

-- The SAME pacing, applied to a DRAWN peer. A spawned ghost never needed this: the engine walks
-- it tile to tile at exactly these durations, which is most of why it looks right. A drawn one had
-- nobody doing that, so it was painted wherever the newest sample said -- and the user, seeing
-- both renderers side by side for the first time (MESHGHOST_COMPARE_TIERS, 2026-08-19), described
-- precisely what that does: *"really stuttery/choppy"*, and *"moving/catching up with the player
-- too fast"* next to a spawned ghost that "properly follows". Both are one bug. Samples arrive at
-- the relay's rate, not the game's, so a renderer that follows them literally moves at the
-- NETWORK's pace, in jumps of whatever distance arrived.
--
-- So a drawn peer now glides between TILES over the same 16/8 frames the game gives a step, from
-- per-peer state kept on the peer's own table (no new chunk locals -- this file is at 196 of
-- Lua's 200). A jump longer than one tile is a warp, a respawn or first sight, and snaps.
-- SMOOTH WITH A FILTER, WHICH HAS NO CLOCK OF ITS OWN.
--
-- Seven attempts at moving a drawn ghost, and the measurements finally separate the two questions
-- that were tangled together the whole time:
--
--   * WHY it looked wrong. Every model before this one had its own timing -- a step duration, a
--     speed, a state machine -- running against a world that scrolls on the game's clock. Two
--     clocks beat, and the beat was the chop. That diagnosis was right and is why nothing here
--     schedules anything any more.
--   * Why "just draw the peer where it is" was ALSO wrong. Measured
--     (probes/tier_compare.log): a peer's position changes in 549 frames out of 4140 -- one frame
--     in eight -- in jumps of 2 to 4 pixels. The core interpolates (`-interp`, 100ms by default)
--     but it DELIVERS at the relay's rate, around 8-20 a second, while this tier redraws at 60.
--     Between deliveries the position is a constant, so drawing it faithfully draws a staircase.
--     The engine hides the same staircase for a spawned ghost by walking it a tile at a time.
--
-- So the adapter does have to smooth -- it just must not schedule. An exponential filter is the
-- shape that fits: it has a lag and nothing else. No step duration to disagree with the game's,
-- no phase to drift, no state machine to be out of sync with the world's scroll. Whatever rate
-- positions arrive at, and however uneven, it turns them into continuous motion, and it cannot
-- beat against anything because there is no periodicity in it to beat with.
--
-- MATCHING THE SPAWNED GHOST, deliberately: the user's call, 2026-08-19, asked for the two
-- renderers to be *"1:1 to the spawned ghost as much as possible"*.
--
-- A drawn ghost is naturally AHEAD of a spawned one -- not by error, but because the engine cannot
-- begin a step until its object is standing on a tile, so an engine-driven ghost always trails the
-- truth by up to one step. Ours has no such rule and sits where the peer actually is. That is the
-- better behaviour for a real peer and the wrong one for a comparison, so the trailing distance is
-- reproduced here rather than the step machine that causes it: the filter follows the peer's
-- position from a few frames ago. Same lag, none of the two-clock beating that five separate
-- movement models produced.
-- On genderFrames rather than as a chunk local, for the ceiling reason above.
genderFrames.drawnDelay = tonumber(MESHGHOST_EMERALD_DRAWN_DELAY_FRAMES
    or os.getenv("MESHGHOST_EMERALD_DRAWN_DELAY_FRAMES") or "") or 8

local function glideRemote(r, targetX, targetY)
    -- The delay line: a short ring of recent positions, read from DRAWN_DELAY_FRAMES ago.
    r.hist = r.hist or {}
    r.hist[frameCounter % 32] = { targetX, targetY }
    -- Kept before the delay lookup overwrites targetX/Y: the speed measurement below wants where
    -- the peer actually IS, not where the delay line is replaying from.
    local rawTargetX, rawTargetY = targetX, targetY
    local old = r.hist[(frameCounter - genderFrames.drawnDelay) % 32]
    if old then targetX, targetY = old[1], old[2] end

    -- First sight, a new area, or further than two tiles: a warp or a dropped peer. Snap, and do
    -- not drag a filter across a discontinuity that is not movement.
    if r.gX == nil or r.gAreaId ~= r.areaId
        or math.abs(targetX - r.gX) > 2 or math.abs(targetY - r.gY) > 2 then
        r.gX, r.gY, r.gAreaId = targetX, targetY, r.areaId
        r.gMoved, r.gDist = false, 0
        return r.gX, r.gY
    end
    r.gAreaId = r.areaId

    -- CONSTANT SPEED, NOT AN EASE. The filter here used to be `x += (target - x) * 0.25`, which is
    -- an exponential ease: it never travels at a steady rate, and its steady-state lag grows with
    -- how fast the peer is going. That is invisible at walking pace and obvious on a bike -- the
    -- user asked for the square test on one, 2026-08-20, and the log answered it: while the peer
    -- was at tile 27.19 the drawn ghost sat at 26.019 and closed at 0.002, 0.015, 0.026, 0.036,
    -- 0.042, 0.048 tiles a frame -- accelerating, never constant, over a tile behind. A character
    -- that drifts toward where it should be instead of travelling there IS the definition of
    -- gliding, whatever its legs are doing.
    --
    -- A character in this game crosses a tile at a fixed speed and stops. So: move toward the
    -- (delayed) target at the speed the TARGET ITSELF is moving, which is the peer's own speed
    -- whatever they are riding, with a quarter extra so a gap closes instead of persisting, and
    -- never overshoot. The delay line above still provides the trailing distance the engine's own
    -- step machine would produce; this only decides how the ground between is covered.
    local prevX, prevY = r.gX, r.gY
    -- TARGET SPEED OVER A WINDOW, NOT FRAME TO FRAME -- fixed 2026-08-21, and the frame-to-frame
    -- version was a real defect rather than a rough edge.
    --
    -- The peer's position stream is bursty by nature: it advances a little for several frames and
    -- then jumps at a tile boundary (the Mach Bike measurement in the comment above). Measured
    -- between consecutive frames, tspd is therefore ZERO on most frames, which collapses the limit
    -- below to its 0.02 floor -- and a ghost that may move 0.025 tiles a frame cannot follow a
    -- player RUNNING at 0.25. It falls further behind every frame until the two-tile discontinuity
    -- guard above fires and snaps it forward.
    --
    -- Measured on the scripted left/right ride (probes/tier_compare.log, 2026-08-21): the camera
    -- moved 4px a frame while the glide advanced 1.25px, and the ghost sawtoothed -- drifting ~3px
    -- a frame for seventeen frames and then jumping 2.4 tiles. That is what the user saw as
    -- *"really choppy"* and *"lagging behind"*. It was never the tier being judged; all three
    -- non-engine renderers share this filter.
    --
    -- The same history ring the delay line uses already holds where the target was N frames ago, so
    -- average speed is one subtraction and needs no new state. Averaging over the window turns
    -- "nothing arrived this frame" into the peer's real speed instead of a standstill.
    local WINDOW = 8
    local was = r.hist[(frameCounter - WINDOW) % 32]
    local tspd = 0
    if was then
        tspd = (math.abs(rawTargetX - was[1]) + math.abs(rawTargetY - was[2])) / WINDOW
    elseif r.tgtPrevX then
        tspd = math.abs(targetX - r.tgtPrevX) + math.abs(targetY - r.tgtPrevY)
    end
    r.tgtPrevX, r.tgtPrevY = targetX, targetY
    -- The floor matters: with the target still, a zero limit would freeze a ghost that is not yet
    -- where it belongs. 0.02 tiles a frame closes a sub-pixel gap without being visible as motion.
    --
    -- CAPPED, because the peer's own position stream is not continuous. Measured on the Mach Bike
    -- across 1x1 and 2x2 squares: the peer's reported position advances 0.06 a frame and then
    -- JUMPS about 0.6 of a tile at the boundary -- it reports roughly half a tile of sub-tile
    -- progress and then arrives. Taking the speed from that jump let the ghost cover 0.81 of a
    -- tile in a single frame, which is a pop, not motion. The old ease hid this by never following
    -- anything faithfully.
    --
    -- 0.25 tiles a frame is the game's own ceiling -- a tile in four frames, the fastest a Mach
    -- Bike moves -- so nothing legitimate is ever slowed by this, and a wire discontinuity is
    -- absorbed over three frames instead of popped in one.
    local ddx, ddy = targetX - r.gX, targetY - r.gY
    local dist = math.abs(ddx) + math.abs(ddy)
    -- A CHARACTER FINISHES ITS STEP AT SPEED. IT NEVER CRAWLS THE LAST BIT IN.
    --
    -- The floor is the right answer for a sub-pixel gap and the wrong one for a real distance, and
    -- the two are told apart by `dist` rather than by tspd. When the peer stops, tspd decays to
    -- zero over the window above and the limit drops to the floor -- so whatever ground the ghost
    -- still owed got paid off at 0.025 tiles a frame however far it was.
    --
    -- After an ice slide that is most of a tile, because a slide is fast and the position stream
    -- is bursty. Measured on the scripted left/right slide (probes/tier_compare.log, 2026-08-21):
    -- the peer stopped at f=224 with the drawn copy 0.86 tiles behind, which then closed at 0.025
    -- a frame and took 34 frames -- over half a second of visible creep after the player had
    -- already come to rest. The user: the drawn ghost *"is doing the ending part a bit slow"*.
    --
    -- So the travelling speed is held as the floor until the ghost has actually arrived: it
    -- finishes at the pace it was going and then stops, which is what the engine's own step
    -- machine does. `move` is still clamped to `dist`, so this cannot overshoot.
    -- THE PEAK, NOT THE LATEST. tspd is an 8-frame average, so when the peer stops it does not
    -- drop to zero -- it DECAYS across the window. Assigning it every frame therefore walked the
    -- floor down with it and left the last value above the threshold, which measured 0.023 against
    -- a travelling 0.0625: the crawl came back at three quarters of its old length and the fix
    -- read as almost no fix at all. Held at the high-water mark instead, and dropped only once the
    -- ghost has arrived, so the next movement starts from its own speed rather than this one's.
    if tspd > (r.gSpd or 0) then r.gSpd = tspd end
    if dist <= 0.05 then r.gSpd = nil end
    local limit = math.min(math.max(tspd, r.gSpd or 0, 0.02) * 1.25, 0.25)
    if dist > 0 then
        local move = math.min(dist, limit)
        r.gX = r.gX + ddx / dist * move
        r.gY = r.gY + ddy / dist * move
    end
    local dx, dy = math.abs(r.gX - prevX), math.abs(r.gY - prevY)

    -- Movement, for the walk cycle: a filter never quite arrives, so "is it moving" is a question
    -- about whether it is still meaningfully closing, not about being exactly equal.
    r.gMoved = (math.abs(targetX - r.gX) + math.abs(targetY - r.gY)) > 0.02
    -- Distance covered, in tiles. The engine changes pose every 8 pixels, so this keeps a tile at
    -- two poses whatever rate the peer's positions arrived at.
    r.gDist = (r.gDist or 0) + dx + dy
    -- WALKING INTO A WALL covers no ground, and a distance-driven cycle therefore froze on a
    -- single pose: the user, comparing, *"does not animate the walking into a wall animations, it
    -- just does the pose and stays in it"*. The peer is plainly walking; it is the GROUND that is
    -- missing. So when a peer reports walking or running without moving, the cycle advances at
    -- that pace anyway -- a sixteenth of a tile per frame walking, an eighth running, which are
    -- the same 8 frames per pose the engine spends.
    -- "Is the peer moving" is asked of the TARGET, not of the filter's own step. A filter
    -- approaches a new position asymptotically and never lands exactly on it, so testing its
    -- per-frame delta against zero was true only when the ghost had ALREADY been standing still --
    -- exactly the difference the user found: the wall animation played *"if im next to a wall, and
    -- walk into it"* but not *"if i walk and hit a wall and keep walking"*, where the filter was
    -- still converging from the approach. The target is a discrete value off the wire; it either
    -- changed this frame or it did not, with no residue to threshold.
    if targetX == r.lastTX and targetY == r.lastTY then
        -- HALF pace, because walking into a wall is not walking: the game plays the walk-in-place
        -- SLOW animation on a collision (field_player_avatar.c:1011, already cited above where the
        -- bump action is chosen). At full walking pace the user's verdict was that the drawn ghost
        -- did it *"a bit too fast"*.
        if r.anim == "running" then r.gDist = r.gDist + 0.0625
        elseif r.anim == "walking" then r.gDist = r.gDist + 0.03125 end
    end
    r.lastTX, r.lastTY = targetX, targetY
    return r.gX, r.gY
end

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
-- Same reason as lastMap above: diagnostics share one table so shipped behaviour keeps the
-- scarce local slots.
local diag = { stepCurveLogs = 0, prevRealX = nil, prevRealY = nil, screenPosLogs = 0 }

local DIAG_SCREENPOS_PARTS = false
local DIAG_SCREENPOS_PARTS_MAX_LOGS = 200

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
    if DIAG_SCREENPOS_PARTS and inRealGlide and diag.screenPosLogs < DIAG_SCREENPOS_PARTS_MAX_LOGS then
        diag.screenPosLogs = diag.screenPosLogs + 1
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

-- ===== CROSS-MAP GHOSTS: a peer across a route seam is visible, a peer in a house is not =====
--
-- The user's ask, 2026-08-20: *"see ghosts when going between routes, but still hide them when
-- entering houses"*, with distance culling so nothing far away costs anything, and *"i want it to
-- exist before appearing on a screen so that ghosts never pop in/out"*.
--
-- The game's own map system already draws this exact line. Maps join two ways: CONNECTIONS (route
-- touching town -- seamless, you can see across) and WARPS (doors, cave mouths). Houses are only
-- ever reached by warp, so the rule "translate peers on maps CONNECTED to mine, hide everyone
-- else" is routes-visible-houses-hidden with no house special-case, and it is also the distance
-- cull: two maps away is not in my connection list, so it does not exist for me.
--
-- HOW: translated AT INGEST into the local map's tile frame, so the entire downstream pipeline --
-- anchor, glide, both tiers, collision -- sees ordinary local coordinates and needs no changes.
-- Re-translated every frame from the stored wire coordinates, so the local player crossing a seam
-- rebases every peer the same frame instead of waiting a delivery.
--
-- Structures measured live 2026-08-20 (`probes/connections.lua`, and its log): the header copy at
-- 02037318 carries the connections pointer at +0x0C -> {count s32, list ptr}, entries 12 bytes
-- {direction u8, offset s32 +4, mapGroup u8 +8, mapNum u8 +9}, directions 1/2/3/4 =
-- south/north/west/east. Verified on both sides of a real seam, including a double west
-- connection whose offset=20 is the field doing its job. Field names from pokeemerald
-- include/global.h; the layout is the probe's measurement, not trust.
--
-- gMapGroups (group:num -> ROM header, for a NEIGHBOR's dimensions) is SELF-LOCATED, never
-- hardcoded: find the ROM original of the live header copy by its own first 16 bytes, then the
-- pointer to it, then the pointer to that -- each step read back before use, the same posture as
-- the Archipelago sprite-shift detection. Located across ~6s of frames in 128KB chunks; until it
-- completes, cross-map stays off and behaviour is exactly yesterday's.
--
-- THE MARGIN is the no-pop rule: a translated peer within 7 tiles of the map edge exists on both
-- tiers, and 7 is the engine's own border width -- one tile more than the screen can show past a
-- seam vertically. (The far screen CORNER can exceed it by a tile; accepted for v1 and noted.)
genderFrames.xmap = { scanStep = 1, scanAt = 0, hits = {}, groupsAt = nil,
    conns = nil, connsFor = nil, ourW = 0, ourH = 0 }

-- THE SCAN RESULT IS CACHED ACROSS LOADS, because the ~7-second self-location window is not
-- cosmetic: a seam crossed before arming gets the old teardown, and during a dev session the
-- adapter reloads constantly -- the user kept seeing "spawned vanishes fully, drawn slightly" at
-- crossings that were all landing inside fresh arming windows, while every armed measurement was
-- clean. Keyed by the ROM's own 4-byte game code and VERIFIED before trust: the cached address
-- must resolve the CURRENT map's header to the same bytes as the live copy, so a wrong or stale
-- cache costs one failed check and falls back to the full scan, never a wrong read.
-- genderFrames.xmapCachePath is set in the log-open block ABOVE (beside the logs) -- no
-- declaration here: this line runs later in the load than that block, and an `= nil` "declaration"
-- wiped the already-set path, which the loud save caught as "path never set".
genderFrames.xmapTryCache = function()
    local xm = genderFrames.xmap
    if not genderFrames.xmapCachePath then return false end
    local f = io.open(genderFrames.xmapCachePath, "r")
    if not f then return false end
    local line = f:read("*l") f:close()
    local code, addr = string.match(line or "", "^(%x+) (%x+)")
    if not code or tonumber(code, 16) ~= memory.read_u32_le(0x080000AC) then return false end
    local base = tonumber(addr, 16)
    local sb1 = memory.read_u32_le(0x03005d8c)
    if sb1 == 0 then return false end
    local grp, num = memory.read_u8(sb1 + 0x04), memory.read_u8(sb1 + 0x05)
    local ga = memory.read_u32_le(base + grp * 4)
    if ga < 0x08000000 or ga >= 0x09000000 then return false end
    local hdr = memory.read_u32_le(ga + num * 4)
    if hdr < 0x08000000 or hdr >= 0x09000000 then return false end
    for k = 0, 12, 4 do
        if memory.read_u32_le(hdr + k) ~= memory.read_u32_le(0x02037318 + k) then return false end
    end
    xm.groupsAt = base
    console.log("MeshGhost: cross-map ghosts armed instantly (cached gMapGroups verified)")
    return true
end
genderFrames.xmapSaveCache = function()
    -- Loud on every exit: the first version failed SILENTLY (path nil or open failed, no way to
    -- tell which), and a silent cache miss re-opens the 7-second window it exists to close.
    if not genderFrames.xmapCachePath then
        console.log("MeshGhost: xmap cache NOT saved -- path never set")
        return
    end
    local f = io.open(genderFrames.xmapCachePath, "w")
    if not f then
        console.log("MeshGhost: xmap cache NOT saved -- cannot write " .. genderFrames.xmapCachePath)
    end
    if f then
        f:write(string.format("%08X %08X", memory.read_u32_le(0x080000AC),
            genderFrames.xmap.groupsAt) .. string.char(10))
        f:close()
    end
end

genderFrames.xmapLocalKey = function()
    local sb1 = memory.read_u32_le(0x03005d8c)
    if sb1 == 0 then return nil end
    return memory.read_u8(sb1 + 0x04) .. ":" .. memory.read_u8(sb1 + 0x05)
end

-- One 128KB chunk of the ROM scan per frame; three passes as in the probe.
genderFrames.xmapScan = function()
    local xm = genderFrames.xmap
    -- A failed pass RETRIES rather than giving up: the scan takes ~400 frames, and the player
    -- crossing a seam mid-pass swaps the header under it -- the verify then finds zero candidates
    -- and a permanent give-up leaves cross-map off for the whole session, measured live when a
    -- driven crossing raced the scan. A short pause between attempts keeps the retry polite.
    if xm.groupsAt then return end
    if xm.scanStep > 3 then
        if not xm.retryAt then xm.retryAt = frameCounter + 300 end
        if frameCounter < xm.retryAt then return end
        xm.scanStep, xm.scanAt, xm.retryAt = 1, 0, nil
    end
    local GMH = 0x02037318
    if xm.scanAt == 0 then
        xm.scanAt = 0x08000000
        xm.hits = {}
        if xm.scanStep == 1 then
            xm.target = memory.read_u32_le(GMH)
            -- SNAPSHOT, not a live comparison: the pass takes ~130 frames and the player crossing
            -- a seam mid-pass swaps the header under it -- verifying against the LIVE copy then
            -- fails every pass that straddles a crossing, and in real roaming the scan can retry
            -- for minutes. The signature and the map identity are captured HERE, so the pass finds
            -- the map it started on regardless of where the player has wandered since.
            xm.sig = {}
            for k = 0, 12, 4 do xm.sig[k] = memory.read_u32_le(GMH + k) end
            local sb1s = memory.read_u32_le(0x03005d8c)
            xm.sigGrp, xm.sigNum = memory.read_u8(sb1s + 0x04), memory.read_u8(sb1s + 0x05)
        elseif xm.scanStep == 2 then xm.target = xm.romHeader
        else xm.target = xm.groupArray end
        if not xm.target or xm.target == 0 then xm.scanStep = 4 return end
    end
    local b = memory.read_bytes_as_array(xm.scanAt, 0x20000)
    local t = xm.target
    local b0, b1 = t % 256, math.floor(t / 256) % 256
    local b2, b3 = math.floor(t / 65536) % 256, math.floor(t / 16777216) % 256
    for i = 1, 0x20000 - 3, 4 do
        if b[i] == b0 and b[i + 1] == b1 and b[i + 2] == b2 and b[i + 3] == b3 then
            xm.hits[#xm.hits + 1] = xm.scanAt + i - 1
        end
    end
    xm.scanAt = xm.scanAt + 0x20000
    if xm.scanAt < 0x09000000 then return end
    -- pass complete: interpret
    local sb1 = memory.read_u32_le(0x03005d8c)
    if sb1 == 0 then xm.scanAt = 0 return end
    if xm.scanStep == 1 then
        local m
        local count = 0
        for _, a in ipairs(xm.hits) do
            local ok = true
            for k = 0, 12, 4 do
                if memory.read_u32_le(a + k) ~= xm.sig[k] then ok = false break end
            end
            if ok then m = a count = count + 1 end
        end
        if count ~= 1 then xm.scanStep = 4 return end   -- ambiguous: the retry re-snapshots
        xm.romHeader = m
    elseif xm.scanStep == 2 then
        local num = xm.sigNum
        for _, a in ipairs(xm.hits) do
            if memory.read_u32_le(a - num * 4 + num * 4) == xm.romHeader then
                xm.groupArray = a - num * 4
                break
            end
        end
        if not xm.groupArray then xm.scanStep = 4 return end
    else
        local grp = xm.sigGrp
        for _, a in ipairs(xm.hits) do
            local base = a - grp * 4
            if memory.read_u32_le(base + grp * 4) == xm.groupArray then xm.groupsAt = base break end
        end
        if xm.groupsAt then
            console.log("MeshGhost: cross-map ghosts armed (gMapGroups self-located at "
                .. string.format("%08X", xm.groupsAt) .. ")")
            genderFrames.xmapSaveCache()
        end
        xm.scanStep = 4
        return
    end
    xm.scanStep = xm.scanStep + 1
    xm.scanAt = 0
end

genderFrames.xmapDims = function(g, n)
    local xm = genderFrames.xmap
    local hdr = memory.read_u32_le(memory.read_u32_le(xm.groupsAt + g * 4) + n * 4)
    if hdr < 0x08000000 or hdr >= 0x09000000 then return nil end
    local lay = memory.read_u32_le(hdr)
    if lay < 0x08000000 then return nil end
    return memory.read_s32_le(lay), memory.read_s32_le(lay + 4)
end

genderFrames.xmapBuild = function(localKey)
    local xm = genderFrames.xmap
    xm.conns, xm.connsFor = {}, localKey
    local sb1 = memory.read_u32_le(0x03005d8c)
    local g, n = memory.read_u8(sb1 + 0x04), memory.read_u8(sb1 + 0x05)
    local w, h = genderFrames.xmapDims(g, n)
    if not w or w <= 0 or w > 1000 then return end
    xm.ourW, xm.ourH = w, h
    local connPtr = memory.read_u32_le(0x02037318 + 0x0c)
    if connPtr < 0x08000000 or connPtr >= 0x09000000 then return end   -- a house: no connections
    local count = memory.read_s32_le(connPtr)
    local list = memory.read_u32_le(connPtr + 4)
    if count < 0 or count > 8 or list < 0x08000000 then return end
    for i = 0, count - 1 do
        local c = list + i * 12
        local dir = memory.read_u8(c)
        if dir >= 1 and dir <= 4 then                 -- dive/emerge are warps in spirit: excluded
            local cg, cn = memory.read_u8(c + 8), memory.read_u8(c + 9)
            local nw, nh = genderFrames.xmapDims(cg, cn)
            if nw then
                xm.conns[cg .. ":" .. cn] =
                    { dir = dir, off = memory.read_s32_le(c + 4), w = nw, h = nh }
            end
        end
    end
end

-- Mutates r.x / r.y / r.areaId from the stored wire values. Local peers pass through untouched;
-- connected peers inside the margin arrive in OUR tile frame; everyone else keeps their real
-- areaId and stays hidden exactly as before this feature existed.
genderFrames.xmapTranslate = function(r, localKey)
    if not r.srcAreaId then return end
    if r.srcAreaId == localKey then
        r.areaId, r.x, r.y = localKey, r.sx, r.sy
        return
    end
    local xm = genderFrames.xmap
    local c = xm.conns and xm.connsFor == localKey and xm.conns[r.srcAreaId] or nil
    if not c then r.areaId = r.srcAreaId return end
    local lx, ly
    -- The engine's own stitch arithmetic (pokeemerald src/fieldmap.c's connection handling);
    -- the offset shifts along the seam. Signs verified live with a test peer before shipping.
    if c.dir == 2 then lx, ly = r.sx + c.off, r.sy - c.h          -- north: neighbor above
    elseif c.dir == 1 then lx, ly = r.sx + c.off, r.sy + xm.ourH  -- south
    elseif c.dir == 3 then lx, ly = r.sx - c.w, r.sy + c.off      -- west
    else lx, ly = r.sx + xm.ourW, r.sy + c.off end                -- east
    -- 10, not the border 7: the user, 2026-08-20 -- *"2-3 tiles extra as a safety measure, just
    -- to make sure its always spawned before appearing on the screen"*. Existence reaches 10
    -- tiles past the edge; the SPAWNED tier still stops at the engine border (its grid coordinate
    -- would go negative past 7 -- chooseSpawned gates it), so a peer in the 8..10 band exists for
    -- the tier system and promotes to a real object well before the screen can show it.
    if lx >= -10 and ly >= -10 and lx <= xm.ourW + 9 and ly <= xm.ourH + 9 then
        r.areaId, r.x, r.y = localKey, lx, ly
    else
        r.areaId = r.srcAreaId                                     -- connected but out of range
    end
end

-- MESHGHOST_EMERALD_TEST_PEER = "g:n,x,y" (x may be the literal "px" for the player's own x):
-- injects a synthetic standing peer so cross-map rendering is testable without a second client.
-- Probe flag, never shipped set; the loopback ghost cannot test this because it always shares the
-- player's own map.
genderFrames.xmapTestPeer = function(localKey)
    local cfg = MESHGHOST_EMERALD_TEST_PEER or os.getenv("MESHGHOST_EMERALD_TEST_PEER")
    -- "off" TURNS IT OFF, and that needs saying because nothing else can. This flag is normally set
    -- in the EMULATOR'S PROCESS ENVIRONMENT at launch, which outlives every script reload -- so a
    -- Lua global cannot clear it: `nil or os.getenv(...)` falls straight through to the environment,
    -- and even setting the global to false does the same. Until 2026-08-21 the only way to remove
    -- the synthetic peer was to relaunch BizHawk, which means closing the user's game.
    --
    -- So an explicit "off" (or "none", or empty) is honoured before the pattern match, and a
    -- one-line loader script can now retire it mid-session. Found when the user asked to remove a
    -- peer left over from cross-route testing days earlier -- exactly the "an unset flag keeps its
    -- previous value" trap agent_docs/environment.md records, in its most durable form.
    if not cfg or cfg == "off" or cfg == "none" or cfg == "" then
        -- And it must be REMOVED, not merely left unrefreshed: a peer this function stops updating
        -- would otherwise sit in `remotes` forever, still rendered, answering to nobody.
        --
        -- Dropping the entry is the whole job -- deliberately, rather than tearing the ghost down
        -- here. Both tiers already reap a peer that has gone: syncRemoteGhosts despawns any ghost
        -- whose remote is nil, and renderHardwareGhosts releases any slot whose peer is nil. Using
        -- those paths means a retired test peer leaves exactly the way a real departing player does,
        -- and it also avoids a forward reference -- despawnGhost is a file-scope local declared far
        -- below this line, so calling it from here would resolve to a nil global at runtime.
        remotes["xmap-test"] = nil
        return
    end
    local area, xs, ys = string.match(cfg, "^([%d]+:[%d]+),([%w]+),([%-%d]+)$")
    if not area then return end
    local x
    if xs == "px" then
        local sb1 = memory.read_u32_le(0x03005d8c)
        x = memory.read_s16_le(sb1 + 0x00)
        -- The player's x only means anything on the neighbor's frame when the seam offset is 0;
        -- good enough for a dev flag.
    else
        x = tonumber(xs)
    end
    local r = remotes["xmap-test"]
    if not r then
        r = { animTimer = 0, animStepIndex = 0 }
        remotes["xmap-test"] = r
    end
    r.srcAreaId, r.sx, r.sy = area, x, tonumber(ys)
    r.orientation, r.anim, r.gender = "south", "idle", "male"
    r.gfx, r.sanim, r.sidx, r.act, r.spaused, r.sox, r.soy = 0, 4, 1, 0, 1, 0, 0
end

-- CROSSING A SEAM REBASES EVERYTHING, IN THE FRAME IT HAPPENS. When the local player walks over a
-- connection the whole coordinate frame shifts by the seam delta, and every piece of per-peer
-- state that holds old-frame numbers -- the glide filter, its delay ring, a spawned ghost's
-- bookkeeping -- suddenly reads as "this peer teleported a map away", which tears the ghost down
-- and rebuilds it: *"the ghosts that are following are still reloading whenever i go between
-- routes"*. The delta is knowable from the OLD map's connection entry toward the new map
-- (crossing north into B: y += B's height, x -= the seam offset), so shift the state instead of
-- letting it be wrong. A WARP has no connection entry, deltas stay nil, and the old teardown
-- behaviour stands -- which is exactly right for a door.
genderFrames.xmapRebase = function(newKey)
    local xm = genderFrames.xmap
    local c = xm.conns and xm.conns[newKey] or nil
    if not c then return end
    xm.rebasedAt = frameCounter
    local dx, dy
    if c.dir == 2 then dx, dy = -c.off, c.h
    elseif c.dir == 1 then dx, dy = -c.off, -xm.ourH
    elseif c.dir == 3 then dx, dy = c.w, -c.off
    else dx, dy = -xm.ourW, -c.off end
    for _, r in pairs(remotes) do
        if r.gX then r.gX, r.gY = r.gX + dx, r.gY + dy end
        if r.tgtPrevX then r.tgtPrevX, r.tgtPrevY = r.tgtPrevX + dx, r.tgtPrevY + dy end
        if r.hist then
            for _, p in pairs(r.hist) do p[1], p[2] = p[1] + dx, p[2] + dy end
        end
    end
    -- Count only: ghostAlive is ALSO defined later than this function, the same late-binding trap
    -- that just cost an hour with `ghosts` itself. The count is enough for the log.
    local n = 0
    for _, g in pairs(genderFrames.xmapGhosts or {}) do
        if g.mapX then g.mapX, g.mapY = g.mapX + dx, g.mapY + dy end
        n = n + 1
    end
    logFile(string.format("f=%d XMAP rebase -> %s d=%d,%d ghosts=%d", frameCounter, newKey, dx, dy, n))
end

genderFrames.xmapTick = function()
    local localKey = genderFrames.xmapLocalKey()
    if not localKey then return end
    local xm = genderFrames.xmap
    if not xm.groupsAt then
        -- The verified cache first -- instant arming on every reload after the first scan -- and
        -- the full scan only when the cache is missing, stale, or for another ROM.
        if not xm.cacheTried then
            xm.cacheTried = true
            genderFrames.xmapTryCache()
        end
        if not xm.groupsAt then genderFrames.xmapScan() end
    end
    if xm.lastKey and xm.lastKey ~= localKey then genderFrames.xmapRebase(localKey) end
    xm.lastKey = localKey
    if xm.groupsAt and xm.connsFor ~= localKey then genderFrames.xmapBuild(localKey) end
    genderFrames.xmapTestPeer(localKey)
    for _, r in pairs(remotes) do genderFrames.xmapTranslate(r, localKey) end
end

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
                -- The wire truth, kept beside the working copy: xmapTranslate rewrites areaId/x/y
                -- into the LOCAL map's frame when the peer stands on a connected neighbor, and it
                -- re-runs every frame from these -- so the local player crossing a seam rebases
                -- every peer immediately instead of a delivery later. Translated inline here too,
                -- so a fresh state is never one frame stale.
                r.srcAreaId, r.sx, r.sy = st.area_id, pos[1], pos[2]
                genderFrames.xmapTranslate(r, genderFrames.xmapLocalKey())
                r.orientation = st.orientation
                r.anim = st.anim
                -- extras is free-form/opaque per agent_docs/contract.md; default to "male" if
                -- absent (e.g. an older client without this field) rather than erroring, same
                -- forward-compatibility posture the relay/core already apply.
                r.gender = (type(st.extras) == "table" and st.extras.gender) or "male"
                -- The peer's own graphic. Absent from an older peer, in which case the ghost
                -- falls back to borrowing this machine's player graphic, exactly as before.
                -- ADOPT A NEW GRAPHIC ONLY ONCE IT HAS SETTLED.
                --
                -- Measured frame by frame: when the player picks up a rod, the game gives it the
                -- 32-wide fishing graphic FOUR FRAMES before its fishing task applies the pos2
                -- that keeps the character on its tile. The player is visible throughout, so those
                -- four frames are real -- but they land while the bag is still closing, where an
                -- 8px hop is invisible. A ghost replaying them 250ms later, in a clean frame, is
                -- the only thing moving on screen, and it reads as a snap.
                --
                -- The bar is that a ghost LOOKS like the player doing it (CLAUDE.md), so a pose
                -- the player's own hop was imperceptible in is not one to reproduce. Taking the
                -- graphic only after two consecutive updates agree means the swap lands together
                -- with the settled offset, and the intermediate is never drawn. Costs one update
                -- of delay on a state change -- invisible next to the interpolation already in
                -- front of it -- and nothing at all in the steady state.
                local newGfx = (type(st.extras) == "table" and tonumber(st.extras.gfx)) or nil
                local newSox = (type(st.extras) == "table" and tonumber(st.extras.sox)) or 0
                -- The graphic AND its offset have to agree twice, not the graphic alone.
                --
                -- First attempt required two consecutive updates to agree on the GRAPHIC, which
                -- did not help: the player holds the new graphic at pos2 0 for four frames while
                -- its task catches up, and at 20Hz that spans two updates -- so both carried the
                -- unsettled pair and the ghost adopted it anyway. Traced from inside the adapter:
                -- gfx=137 arriving with sox=0, twice, then sox=8.
                --
                -- Pairing them means a state is taken only once it has stopped changing, which is
                -- what the player looks like by the time anyone can see it.
                -- A JUMP_SPECIAL SKIPS THE WAIT, because it can only arrive already settled.
                --
                -- The pairing above exists for a state whose OFFSET catches up after its graphic
                -- (fishing, measured). The surf start is the opposite case: the game sets the
                -- graphic and the jump onto the water in the SAME engine step
                -- (`documentation.md`), so a state carrying 0x3A..0x3D cannot be half-formed --
                -- and waiting one more update means the ghost performs the jump still wearing the
                -- field-move graphic, hopping onto the sea in the wrong pose.
                local newAct = (type(st.extras) == "table" and tonumber(st.extras.act)) or nil
                local pair = tostring(newGfx) .. ":" .. tostring(newSox)
                if pair == r.statePair
                    or (newAct and newAct >= 0x3a and newAct <= 0x3d) then r.gfx = newGfx end
                r.statePair = pair
                if r.gfx == nil then r.gfx = newGfx end
                -- THE ANIMATION IS HELD WITH THE GRAPHIC, because it only means anything against
                -- one. Every special state has its own animation table, of its own length, so an
                -- animation number from the new state applied to the still-current graphic can name
                -- a frame that graphic does not have.
                --
                -- The graphic above is deliberately deferred by one update; the animation used to
                -- be adopted immediately. That gap MANUFACTURED a pair the peer was never in.
                -- Measured 2026-08-21 with probes/dive_probe.lua, which logged the player's own
                -- (graphic, animation) every time either changed across many surf starts: it goes
                -- gfx=3 anim=0/0..0/4, then straight to gfx=2 anim=20/0 -- `gfx=3 anim=20` never
                -- happens. The ghost was in it for one frame at every transition, and both
                -- self-drawn tiers plus the spawned one each showed it differently: the spawned
                -- ghost drew a frame that does not exist (*"a weird grey/flashing glitched
                -- sprite"*), and the painted tier could not resolve it and fell back to a walker
                -- (*"the drawn ghost still disappear for a bit when surf is started"*). Three
                -- separate consumer-side defences were written before the pair itself was measured;
                -- the lesson is in pitfalls.md.
                --
                -- `act` is deliberately NOT held with them: it is a movement action, not indexed by
                -- graphic, and the receive side already declines to start one while a swap of this
                -- ghost's graphic is pending.
                local sa = (type(st.extras) == "table" and tonumber(st.extras.sanim)) or nil
                local si = (type(st.extras) == "table" and tonumber(st.extras.sidx)) or nil
                if r.gfx == newGfx then
                    r.sanim = (sa and sa >= 0 and sa <= 255 and math.floor(sa) == sa) and sa or nil
                    r.sidx = (si and si >= 0 and si <= 255 and math.floor(si) == si) and si or nil
                end
                local ac = (type(st.extras) == "table" and tonumber(st.extras.act)) or nil
                r.act = (ac and ac >= 0 and ac <= 255 and math.floor(ac) == ac) and ac or nil
                -- Peer-controlled, so bounded: a sprite offset beyond a tile or two is not a pose,
                -- it is someone trying to put a ghost through a wall.
                local ox = (type(st.extras) == "table" and tonumber(st.extras.sox)) or nil
                local oy = (type(st.extras) == "table" and tonumber(st.extras.soy)) or nil
                r.sox = (ox and ox >= -32 and ox <= 32) and math.floor(ox) or nil
                r.soy = (oy and oy >= -32 and oy <= 32) and math.floor(oy) or nil
                -- Whether the peer's own sprite is HELD or running. nil (an older peer) keeps the
                -- previous behaviour of handing the animation to the engine.
                local sp = (type(st.extras) == "table" and tonumber(st.extras.spaused)) or nil
                r.spaused = sp ~= nil and sp ~= 0 or nil
                -- And whether the peer is FORBIDDEN an animation, which is a stronger statement
                -- than "not running" and is the only one that survives a movement. nil for a peer
                -- that predates the field, which keeps exactly the old behaviour.
                local na = (type(st.extras) == "table" and tonumber(st.extras.noanim)) or nil
                r.noanim = na ~= nil and na ~= 0 or nil
                local ps = (type(st.extras) == "table" and tonumber(st.extras.pspeed)) or nil
                r.pspeed = (ps and ps >= 0 and ps <= 4 and math.floor(ps) == ps) and ps or nil
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
        -- handleBridgeLine() below can tear the connection down from inside this loop: a
        -- `reject` calls resetBridge(), which closes the socket and sets `sock` to nil. Without
        -- this check the very next iteration indexes a nil `sock` and throws, so every single
        -- rejection -- the ordinary outcome of the port walk meeting somebody else's core --
        -- cost a Lua error and the rest of that frame's work. Found by reading, 2026-08-19.
        if not connected or not sock then return end
        -- With settimeout(0), a line straddling this call's read boundary comes back as
        -- nil, "timeout", partial -- LuaSocket 3.0's documented behavior for a pattern that
        -- can't complete before the timeout (see adapters/bizhawk/pokemon/emerald/lib/x64/
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

-- RUN-LENGTH CACHE for the drawn tier. One gui.drawPixel per opaque pixel is affordable for one
-- or two overlay ghosts, which is all this path ever had to do before the two-tier renderer; it is
-- not affordable for a screenful. Measured 2026-08-19 with 137 drawn peers: ~40,000 pixel calls a
-- frame took the emulator to 17fps. A character's rows are mostly flat colour, so each row is
-- collapsed into horizontal runs ONCE per (gender, pose, frame) and cached; drawing then costs one
-- gui.drawLine per run. Mirroring is applied to a run's endpoints, so a flipped frame needs no
-- second cache entry.
-- The cache and its builder hang off genderFrames, the decoded-sprite table they are derived
-- from, rather than becoming file-scope locals of their own: the main chunk is AT Lua's hard
-- ceiling of 200 locals, and one more makes the script fail to parse (found exactly that way,
-- 2026-08-19). genderFrames is only ever indexed by gender, so extra string keys are safe.
genderFrames.runCache = {}

-- A decoded pixel list -> a run list. Split out from runsFor when the walker needed a SECOND
-- decode of the same frames in the reflection palette (2026-08-21): the run building is identical,
-- only the colours differ, and a second copy of it is how two paths drift apart.
genderFrames.runsFromPixels = function(pixels)
    -- Bucket by row first: the decoded pixel list is not guaranteed to be row-major, and a run
    -- built from an unsorted list would be silently wrong rather than merely slow.
    local rows = {}
    for i = 1, #pixels do
        local px = pixels[i]
        local row = rows[px.y]
        if not row then row = {} rows[px.y] = row end
        row[px.x] = px.color
    end

    local runs = {}
    for y, row in pairs(rows) do
        local x = 0
        while x < FRAME_WIDTH_PX do
            local color = row[x]
            if color then
                local x2 = x
                while row[x2 + 1] == color do x2 = x2 + 1 end
                runs[#runs + 1] = { y = y, x1 = x, x2 = x2, color = color }
                x = x2 + 1
            else
                x = x + 1
            end
        end
    end
    return runs
end

genderFrames.runsFor = function(gender, pose, frameIndex)
    local key = gender .. ":" .. pose .. ":" .. frameIndex
    local cached = genderFrames.runCache[key]
    if cached then return cached end
    local genderSet = genderFrames[gender] or genderFrames.male
    local runs = genderFrames.runsFromPixels((genderSet[pose] or genderSet.walk)[frameIndex])
    genderFrames.runCache[key] = runs
    return runs
end

-- THE WALKER'S OWN FRAME, DECODED AGAIN IN THE REFLECTION PALETTE.
--
-- The peer-graphic path gets this from runsFromImages, which takes a palette slot. The cached
-- walker path cannot: its frames were decoded once, at load, with the character's ROM palette
-- baked into each pixel's colour, and a colour cannot be mapped back to the palette index it came
-- from. So the same picture is decoded a second time from the same ROM address with the live
-- reflection palette -- no approximation, and the same machinery the load path uses.
--
-- Cached like every other decode, and stamped with the palette's own contents so a fade or a map
-- change invalidates it rather than leaving a ghost reflected in yesterday's colours.
genderFrames.walkerReflectRuns = function(gender, pose, frameIndex, palSlot)
    local key = string.format("wr:%s:%s:%d:%d", gender, pose, frameIndex, palSlot & 0x0f)
    local stamp = genderFrames.paletteStamp(palSlot)
    local cached = genderFrames.peerRunCache[key]
    if cached and cached.palStamp == stamp then return cached end
    local off = genderFrames.romOffset or 0
    local pic
    if gender == "female" then
        pic = (pose == "run") and GOBJECTEVENTPIC_MAYRUNNING_ADDR or GOBJECTEVENTPIC_MAYNORMAL_ADDR
    else
        pic = (pose == "run") and GOBJECTEVENTPIC_BRENDANRUNNING_ADDR
            or GOBJECTEVENTPIC_BRENDANNORMAL_ADDR
    end
    -- decodePalette's shape, from live palette RAM instead of ROM: OBJ palettes are 16 colours of
    -- 32 bytes each at 0x05000200 (GBA hardware).
    local pal = {}
    for i = 0, 15 do
        -- memory.read_u16_le, not the file's `r16` shorthand: that is a LOCAL declared several
        -- hundred lines below this function, so naming it here compiles to a nil global lookup --
        -- the trap this file carries a note about at its first occurrence.
        local c = memory.read_u16_le(0x05000200 + (palSlot & 0x0f) * 32 + i * 2)
        pal[i] = { r = expand5to8(c & 0x1F), g = expand5to8((c >> 5) & 0x1F),
            b = expand5to8((c >> 10) & 0x1F) }
    end
    local runs = genderFrames.runsFromPixels(decodeFramePixels(pic + off, frameIndex, pal))
    runs.palStamp = stamp
    genderFrames.peerRunCache[key] = runs
    return runs
end

-- One horizontal span of one colour. Split out because the clip can turn a single run into two,
-- and a line-or-pixel decision repeated three times is how the two paths drift apart.
local function drawRun(x1, x2, y, color)
    if x2 < x1 then return end
    if x1 == x2 then
        gui.drawPixel(x1, y, color)
    else
        gui.drawLine(x1, y, x2, y, color)
    end
end

-- panelRows, when given, is the region the GAME drew its own UI into this frame: panelRows[row]
-- is {x1, x2} in screen pixels for that 8-pixel row, or nil where the row is clear. It comes from
-- the background tilemap (tiering.scanPanel), i.e. from what the game DREW.
--
-- Clipping is per RUN and per ROW, which is what makes this behave like the engine rather than
-- like a blunt switch: with a text box open (bottom six rows, full width) a drawn ghost keeps its
-- head and shoulders above the box; with the START menu open (right-hand columns, rows 0-13) a
-- ghost standing to the LEFT of the menu is untouched, and one behind it loses only the part the
-- menu covers. Blanking every drawn ghost whenever any panel opened would be the easy version and
-- would look wrong for exactly the case the user cares about -- most of the screen is still the
-- world.
-- `dim` is how bright the SCENE is right now, 0 (black) to 1 (full), measured from the hardware
-- palette by the caller. A spawned ghost is drawn by the PPU and so is dimmed by every fade, cave
-- and night the game applies; a painted one is put on top of the finished frame and is dimmed by
-- nothing, which is why it shone through a house exit. Scaling the run colours is the same
-- operation the hardware performs, applied where we draw instead.
-- keepSpans reaches this path too, and forgetting it here is why the first occlusion attempt
-- changed nothing on screen: a peer on FOOT is drawn from the gender frames, not from the peer's
-- own graphic, so the mask was applied to the branch that only runs on a bike, a rod or a
-- surfboard. Both paths draw a character and both need hiding behind the map.
local function drawSpriteFrame(gender, pose, frameIndex, hFlip, screenX, screenY, panelRows, dim,
    keepSpans)
    drawRunList(genderFrames.runsFor(gender, pose, frameIndex), FRAME_WIDTH_PX, hFlip,
        screenX, screenY, panelRows, dim, nil, nil, keepSpans)
end

-- One run list, at a screen position: the clip against the game's own panels and the scene-
-- brightness scaling, shared by both draw paths. Split out when the peer-graphic path arrived --
-- a second copy of the clipping is exactly how two paths drift apart.
--
-- A GLOBAL, deliberately: this chunk is at 198 of Lua's 200 locals, and a shared helper is a
-- better use of the remaining budget than a name. Assigned before anything calls it.
-- vFlipHeight: draw the frame upside down within a box that tall, for a REFLECTION. The engine
-- makes one by copying the sprite with ST_OAM_VFLIP (SetUpReflection, pokeemerald
-- src/field_effect_helpers.c:47-68); this tier has no OAM to set a flip bit on, so the row index
-- is mirrored instead. nil for everything that is not a reflection, which is everything else.
-- xScale: squeeze or stretch the frame horizontally about its own centre, for a rippling
-- reflection. 1.0 (or nil) for everything else.
--
-- keepSpans: draw ONLY inside these x ranges, keyed by absolute screen y -- the opposite of
-- panelRows, which excludes. A reflection needs it because the engine keeps one off the land with
-- OAM priority 3 (SetUpReflection, pokeemerald src/field_effect_helpers.c:53) and a painted tier
-- has no priority at all: it draws on top of the finished frame, so a reflection that reaches past
-- the shore lands on the grass. Reported on screen 2026-08-19: *"the drawn ghosts reflection,
-- draws outside of water as well"*. nil means "no restriction", which is every other caller.
function drawRunList(runs, frameWidth, hFlip, screenX, screenY, panelRows, dim, vFlipHeight,
    xScale, keepSpans)
    -- GAP DETECTOR (dev, COMPARE_TIERS sessions): every call is counted so the frame's end can
    -- ask "was ANYTHING painted?". The user sees the drawn copy vanish for a moment at the start
    -- of surfing, and a vanish is not a fallback -- a fallback still paints a walker. A vanish is
    -- a frame where the overlay was CLEARED and this function then never ran, and no probe of
    -- stored state can see that; only counting the paints can.
    -- A bare GLOBAL, deliberately: `tiering` is a file-scope local declared 450 lines BELOW this
    -- function, so naming it here reads a nil global and errors -- which is exactly what happened
    -- on this counter's first version (2026-08-21): every paint died on this line, the drawn tier
    -- vanished entirely, and the "gap" lines it produced were the error's shadow. The fourth bite
    -- of the forward-reference trap this file documents.
    MG_DRAWN_CALLS = (MG_DRAWN_CALLS or 0) + 1
    for i = 1, #runs do
        local r = runs[i]
        local color = r.color
        -- The scene's own blend, applied to this run's colour: c*dim + add. Both terms come from
        -- fitting the live OBJ palette against the cartridge's, once per frame, in drawRemotes --
        -- the additive term is what lets a fade toward WHITE (a cave mouth) wash the painted copy
        -- out the way the hardware washes out everything else.
        local add = genderFrames.tintAdd or 0
        if (dim and dim < 0.99) or add > 0.5 then
            -- Per RUN, not per pixel, and only while something is actually fading the screen:
            -- in a steady scene this whole branch is two comparisons.
            local m = dim or 1
            local rr = math.floor(((color >> 16) & 0xFF) * m + add)
            local gg = math.floor(((color >> 8) & 0xFF) * m + add)
            local bb = math.floor((color & 0xFF) * m + add)
            if rr > 255 then rr = 255 end
            if gg > 255 then gg = 255 end
            if bb > 255 then bb = 255 end
            color = (0xFF << 24) | (rr << 16) | (gg << 8) | bb
        end
        -- vFlipHeight mirrors the row index for a REFLECTION, and the mirror is `h - y`, not
        -- `h - 1 - y`. That is not an off-by-one, it is the hardware's own arithmetic: the engine
        -- does not use the OAM flip bit for a reflection, it makes it an AFFINE sprite through
        -- matrix 0 (SetUpReflection, src/field_effect_helpers.c:66-68), and a GBA affine transform
        -- is centred on h/2 -- 16 for a 32-row sprite, not 15.5. So the hardware samples
        -- texture = 32 - screen, one row lower than a flip bit's 31 - screen.
        --
        -- MEASURED, not reasoned: with the poses finally matching, a framebuffer diff put the
        -- engine's own reflection pixel at row 108 for a body whose reflection box starts at 86
        -- (2026-08-21) -- box row 22, which only `h - y` produces. This tier was drawing at 107
        -- and the water does not begin until 107, so the single row of hat that the player, the
        -- spawned ghost and the OAM copy all show was the one row this tier threw away. The user,
        -- four times: *"the drawn ghost still don't have the tiny tiny reflection when standing a
        -- tile further away from the water"*.
        local y = screenY + (vFlipHeight and (vFlipHeight - r.y) or r.y)
        local x1, x2 = r.x1, r.x2
        if hFlip then x1, x2 = frameWidth - 1 - r.x2, frameWidth - 1 - r.x1 end
        if xScale then
            -- About the CENTRE, which is what an affine sprite scales about -- and BOTH EDGES ARE
            -- ROUNDED THE SAME WAY, which is the whole of it.
            --
            -- This used to floor the near edge and ceil the far one (transformed as x2+1 and
            -- brought back), to keep neighbouring runs contiguous. Two different roundings on the
            -- two ends of a run do not scale it, they INFLATE it: a one-pixel run came out two or
            -- three pixels wide, and it breathed in and out as the ripple's scale swung. Nothing
            -- on the hardware does that -- an affine sprite scales where each screen pixel SAMPLES
            -- from, so a one-pixel feature shifts by a pixel and stays one pixel. The user, on the
            -- single-pixel sliver of hat at a shoreline, which is the only place a whole-pixel
            -- inflation is visible: *"it looks a bit bigger than the other ghosts reflection here,
            -- about 2-3 times as big"*, and *"its wobbling back forth properly, but looks like the
            -- shrink/expand is not supposed to be here"*.
            --
            -- THE HARDWARE'S OWN MAPPING, INVERTED. A GBA affine sprite does not scale a source
            -- run onto the screen; it walks the DESTINATION and, for each screen pixel, samples
            -- `texture = (x - cx) * a / 256 + cx`, TRUNCATED. So the destination range covering a
            -- source run [x1, x2] is where that truncation lands inside it:
            --     x_dest in [ cx + (x1 - cx)*s , cx + (x2 + 1 - cx)*s )      with s = 256/a
            -- which is ceil on the near edge and ceil-minus-one on the far one -- the SAME rule at
            -- both ends, so width is preserved and the run still slides as `a` swings.
            --
            -- Both of the wrong answers were tried on screen first. `floor` on the near edge and
            -- `ceil` on the far one is what shipped: it inflates a one-pixel run to two or three,
            -- breathing with the ripple (*"about 2-3 times as big"*). Nearest-neighbour on both
            -- ends fixes the width but pins the run to one column, because rounding a sub-pixel
            -- shift never crosses a boundary -- *"now its not moving left/right anymore"*. Only
            -- the inverse mapping does both, and it is what the hardware does.
            --
            -- MEASURED against the engine's own reflection, six frames apart: its single pixel
            -- alternates between columns 53 and 54 (and 117/118, 149/150 for the other two
            -- characters) -- one pixel wide, moving by one. That is the target this reproduces.
            local mid = frameWidth / 2
            local nx1 = math.ceil(mid + (x1 - mid) * xScale)
            local nx2 = math.ceil(mid + (x2 + 1 - mid) * xScale) - 1
            x1, x2 = nx1, nx2
            if x2 < x1 then x2 = x1 end
        end
        local ax1, ax2 = screenX + x1, screenX + x2

        -- A run can survive as several pieces once it is cut to the water, so the panel clip below
        -- runs per piece. Without keepSpans there is exactly one piece and this costs one compare.
        local pieces = keepSpans and keepSpans[math.floor(y)]
        local nPieces = 1
        if keepSpans then nPieces = pieces and #pieces or 0 end
        for k = 1, nPieces do
            local kx1, kx2 = ax1, ax2
            if pieces then
                local pc = pieces[k]
                if kx1 < pc[1] then kx1 = pc[1] end
                if kx2 > pc[2] then kx2 = pc[2] end
            end
            -- THE CAVE'S LIT CIRCLE, intersected -- not subtracted like the panel below. Outside
            -- it the hardware displays nothing, so neither may we. Costs one halfword per row and
            -- only where a flash effect is actually running; see genderFrames.flashSpan.
            local fl, fr = genderFrames.flashSpan(y)
            if fl then
                if kx1 < fl then kx1 = fl end
                if kx2 > fr then kx2 = fr end
            end
            if kx1 <= kx2 then
                -- math.floor, NOT a shift: y comes from the sub-tile smoothing and is a FLOAT, and
                -- Lua 5.4's >> demands an integer -- "number has no integer representation" thrown
                -- once per run, i.e. every frame, which the frame-error counter caught immediately
                -- (2026-08-19).
                local span = panelRows and y >= 0 and panelRows[math.floor(y / 8)]
                if span and kx2 >= span[1] and kx1 <= span[2] then
                    -- Counted, because "the clip ran" and "the clip did anything" are different
                    -- claims and only the second is evidence. Published as clipped=.
                    genderFrames.clippedRuns = (genderFrames.clippedRuns or 0) + 1
                    -- Keep whatever falls outside the panel: a run straddling the menu's left edge
                    -- is still drawn up to that edge.
                    if kx1 < span[1] then
                        drawRun(kx1, math.min(kx2, span[1] - 1), y, color)
                        MG_SPANS = (MG_SPANS or 0) + 1
                    end
                    if kx2 > span[2] then
                        drawRun(math.max(kx1, span[2] + 1), kx2, y, color)
                        MG_SPANS = (MG_SPANS or 0) + 1
                    end
                else
                    drawRun(kx1, kx2, y, color)
                    MG_SPANS = (MG_SPANS or 0) + 1
                end
            end
        end
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
-- The globals let a loader script place the copies for a particular question without a restart --
-- e.g. "OAM directly above me, spawned one tile to my right" for judging occlusion, where the
-- default spread puts them on different ground. MESHGHOST_LOOPBACK_TRAIL still wins: it is the
-- exact-trail mode, and an offset would defeat it.
local LOOPBACK_GHOST_OFFSET_TILES_X = (os.getenv("MESHGHOST_LOOPBACK_TRAIL") and 0)
    or tonumber(MESHGHOST_LOOPBACK_OFFSET_X or "") or 2
local LOOPBACK_GHOST_OFFSET_TILES_Y = (os.getenv("MESHGHOST_LOOPBACK_TRAIL") and 0)
    or tonumber(MESHGHOST_LOOPBACK_OFFSET_Y or "") or 0

-- SIDE-BY-SIDE TIER COMPARISON (dev only, off by default) -- MESHGHOST_COMPARE_TIERS.
--
-- The two renderers are hard to judge one at a time. A spawned ghost is drawn by the engine and
-- gets its occlusion, its palette and its cave/water treatment for free; a painted one is put on
-- top of the finished frame and gets none of that unless we build it. Which of those the drawn
-- tier is MISSING is a question about a specific place -- a dark cave, water with a reflection,
-- a doorway, tall grass -- and switching flags between two runs cannot answer it, because the
-- place has changed by the time the other renderer is on.
--
-- So: with this set, the ONE loopback ghost is rendered TWICE, both at once, from the same peer
-- state -- spawned two tiles to the right (where it has always been), painted two tiles to the
-- LEFT. Whatever the painted one is missing is then visible in the same frame, in the same
-- lighting, next to a correct copy of itself. The user's request, 2026-08-19, and the intended
-- default way to eyeball a BizHawk adapter's drawn tier in dev.
--
-- Deliberately NOT gated on MESHGHOST_EMERALD_DRAWN_OVERFLOW: the whole point is to look at the
-- drawn tier while it is shipped off. With the overflow tier off, the loopback ghost is the ONLY
-- peer painted; with it on, it is painted in addition to the real overflow. Deliberately also
-- ignores MESHGHOST_LOOPBACK_TRAIL's zero offset -- two ghosts stacked on the player is exactly
-- the comparison this mode exists to avoid.
-- ONE top-level local, not two: this chunk sits at 197 of Lua's hard 200, and the painted side's
-- offset is only ever needed inside drawRemotes, where it is declared instead.
local COMPARE_TIERS = (MESHGHOST_COMPARE_TIERS or os.getenv("MESHGHOST_COMPARE_TIERS")) and true or false

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
-- adapters/bizhawk/pokemon/emerald/probes/spawn_test.lua and agent_docs/verified.md. The three that
-- matter most when reading this code:
--   * the ObjectEvent is synthesised from InitObjectEventStateFromTemplate's own field list;
--   * the Sprite is COPIED from the player's (four ROM pointers cannot be synthesised) but must
--     then be given its OWN VRAM tiles, or it displays the player's current animation frame;
--   * MovementType_None is the only movement type with no autonomous behaviour that still runs
--     the generic update which plays out held movements.
----------------------------------------------------------------------------

-- gSprites and its stride are already declared once at the top of this file (GSPRITES_ADDR /
-- SPRITE_SIZE) with their provenance. The spawn path used to redeclare them here under different
-- names and identical values: two names for one address is how a future correction gets applied
-- to one of them and not the other -- and Lua's 200-local ceiling in the main chunk made the
-- duplicates cost something concrete as well.
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
-- TURNING uses walk-in-place-FAST, not a face action, because that is what the player does.
-- `PlayerTurnInPlace` (field_player_avatar.c:1027) calls GetWalkInPlaceFastMovementAction, and
-- MOVEMENT_ACTION_FACE_* is a static pose with no leg movement -- which is exactly how a ghost
-- using it looked: it snapped to the new direction without animating. Found by the user watching,
-- 2026-08-18; nothing in the log distinguishes the two.
local FACE_ACTION = { [1] = 0x21, [2] = 0x22, [3] = 0x23, [4] = 0x24 }
-- The static poses, kept for the one case that wants no animation: placing a ghost at spawn,
-- where there is no previous direction to have turned from.
local FACE_STILL_ACTION = { [1] = 0x00, [2] = 0x01, [3] = 0x02, [4] = 0x03 }
-- BUMPING into a wall. The player does not simply stand there: PlayerNotOnBikeCollide
-- (field_player_avatar.c:1011) plays a collision sound and a walk-in-place SLOW animation, which
-- is the little shuffle you see holding a direction against a wall. A peer doing that reports
-- "walking" with a position that never changes, so the ghost can reproduce it.
local BUMP_ACTION = { [1] = 0x19, [2] = 0x1a, [3] = 0x1b, [4] = 0x1c }
-- How long a peer must be "walking but not moving" before it counts as a bump. Without this, the
-- instant a normal step completes -- position already updated, anim still walking -- looks
-- identical to a bump, and every step would end with a spurious shuffle.
local BUMP_AFTER_FRAMES = 20
local WALK_ACTION = { [1] = 0x08, [2] = 0x09, [3] = 0x0a, [4] = 0x0b }
-- PLAYER_RUN, not WALK_FAST. Both cross a tile quickly, but WALK_FAST (0x15) reuses the WALKING
-- frames while PLAYER_RUN (0x35) plays ANIM_RUN_*, which is what running actually looks like.
-- Found live 2026-08-18: "it moves around properly, but its not running" -- the ghost was keeping
-- up and still visibly walking. The run frames exist on the ghost because it borrows the player's
-- graphics, which is the one graphic in the game that has them.
local RUN_ACTION = { [1] = 0x35, [2] = 0x36, [3] = 0x37, [4] = 0x38 }

-- LEDGES. A ledge hop is not two steps, it is one JUMP that covers two tiles with an arc, and the
-- engine has an action for exactly that: MOVEMENT_ACTION_JUMP_2_DOWN/UP/LEFT/RIGHT = 0xC..0xF
-- (pokeemerald include/constants/event_object_movement.h:99-102), indexed here the same way every
-- other action table is -- the decomp's DOWN/UP/LEFT/RIGHT order matches DIR_ID's south/north/
-- west/east, which WALK_NORMAL_* at 0x8..0xB already confirms.
--
-- Without this a peer hopping a ledge moved two tiles in one update, which fell through to the
-- "more than a tile out" branch and TELEPORTED the ghost across -- no arc, no hop. The user, with
-- both renderers on screen: *"neither ghost knows how to jump down/off a ledge"* (2026-08-19).
-- Expressed as base + (dir - 1) rather than a table, because this chunk is AT Lua's hard ceiling
-- of 200 locals and the syntax check refused the table version outright. The arithmetic is exact:
-- the decomp lists JUMP_2_DOWN/UP/LEFT/RIGHT consecutively from 0xC, in the same order DIR_ID
-- numbers south/north/west/east -- which WALK_NORMAL_* at 0x8..0xB independently confirms.
-- (0x0c is used inline below: this chunk is at Lua's 200-local ceiling, and a constant used once
-- is the cheapest thing to inline.)

local function w8(a, v) memory.write_u8(a, v & 0xff) end
local function w16(a, v) memory.write_u16_le(a, v & 0xffff) end
local function w32(a, v) memory.write_u32_le(a, v & 0xffffffff) end
local function r8(a) return memory.read_u8(a) end
local function r16(a) return memory.read_u16_le(a) end
local function rs16(a) return memory.read_s16_le(a) end
local function r32(a) return memory.read_u32_le(a) end

local function objAddr(i) return GOBJECTEVENTS_ADDR + avatarAddrOffset + i * OBJECTEVENT_SIZE end
local function sprAddr(i) return GSPRITES_ADDR + i * SPRITE_SIZE end

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

-- struct ObjectEventGraphicsInfo (include/global.fieldmap.h): tileTag 0x00, paletteTag 0x02,
-- reflectionPaletteTag 0x04, size 0x06, width 0x08, height 0x0A, paletteSlot/flags 0x0C,
-- tracks 0x0D, oam 0x10, subspriteTables 0x14, anims 0x18, images 0x1C, affineAnims 0x20.
-- ROM is 0x08000000-0x09FFFFFF on the GBA (the two 16 MB waitstate mirrors of the cartridge).
-- Used below to sanity-check a pointer before anything is read through it or written into a
-- live sprite: everything in this table, and everything it points at, is ROM data.
local function isRomPtr(p) return p >= 0x08000000 and p <= 0x09ffffff end

-- The graphicsId reaching here can come from a PEER over the wire (extras.gfx), so it is
-- untrusted input, not a local read -- `_template/PROTOCOL.md`'s peer-controlled-data note, and
-- status.md's open "adapters' parsing never audited". Unvalidated it indexes a ROM pointer table
-- with an arbitrary integer, and the four pointers pulled out of whatever that lands on are
-- written straight into a live sprite for the engine to dereference. Two bounds, neither invented:
--   * 0-255, because the field this ends up in is `objectEvent.graphicsId`, a u8 -- the same fact
--     the `w8(a + 0x05, graphicsId)` in spawnGhost already relies on. A value outside it could
--     never have described this ghost anyway.
--   * every pointer must actually point into ROM. That rejects a table entry past the real end of
--     the table without this file having to assert a count it cannot cite.
local function graphicsInfo(graphicsId)
    if type(graphicsId) ~= "number" or graphicsId ~= math.floor(graphicsId)
        or graphicsId < 0 or graphicsId > 255 then
        return nil
    end
    -- The Archipelago-shifted ROM offset, or 0 on vanilla -- see loadGenderFrames(). Without it
    -- this table read lands on the old, abandoned address and every lookup fails.
    local ptr = r32(GOBJECTEVENTGRAPHICSINFOPOINTERS_ADDR + (genderFrames.romOffset or 0)
        + graphicsId * 4)
    if not isRomPtr(ptr) then return nil end
    local size = r16(ptr + 0x06)
    if size == 0 then return nil end
    -- The four pointers below are written verbatim into a live sprite for the ENGINE to
    -- dereference, so a bad one is not a wrong picture, it is a crash in the game's own code.
    -- anims/images must exist; oam, subspriteTables and affineAnims are legitimately allowed to
    -- be null (a graphic without subsprites, an unanimated one) but never anything else.
    local anims, images = r32(ptr + 0x18), r32(ptr + 0x1c)
    local oam, subs, affine = r32(ptr + 0x10), r32(ptr + 0x14), r32(ptr + 0x20)
    if not isRomPtr(anims) or not isRomPtr(images) then return nil end
    if oam ~= 0 and not isRomPtr(oam) then return nil end
    if subs ~= 0 and not isRomPtr(subs) then return nil end
    if affine ~= 0 and not isRomPtr(affine) then return nil end
    return {
        ptr = ptr,
        paletteTag = r16(ptr + 0x02),
        size = size,
        tileCount = size // TILE_SIZE_4BPP,
        width = r16(ptr + 0x08),
        height = r16(ptr + 0x0a),
        paletteSlot = r8(ptr + 0x0c) & 0x0f,
        -- The struct pointer itself, for fields nothing else needed until the shadow did:
        -- shadowSize is bits 4-5 of +0x0C, sharing that byte with paletteSlot.
        raw = ptr,
        oam = r32(ptr + 0x10),
        subspriteTables = r32(ptr + 0x14),
        anims = r32(ptr + 0x18),
        images = r32(ptr + 0x1c),
        affineAnims = r32(ptr + 0x20),
    }
end

-- PUBLISH A PAIR THAT IS TRUE TOGETHER: an animation number that the published GRAPHIC actually
-- has.
--
-- The sender reads the graphic through localGraphicsId() -- which may be holding a previous value
-- -- and the animation number straight off the live sprite. Those are two different moments, and
-- for a frame or two at every transition they disagree: measured 2026-08-21 at the start of
-- surfing, `gfx=3 sanim=20` went out on the wire, a surfing animation on the field-move graphic,
-- whose table is shorter and has no entry 20.
--
-- Every consumer then breaks in its own way and has to be defended separately -- the spawned ghost
-- drew a frame that does not exist (*"a weird grey/flashing glitched sprite"*), the painted tier
-- gave up and fell back to a walker (*"the drawn ghost still disappear for a bit"*), and each fix
-- covered one tier. **The pair is what is wrong, so the pair is what to fix**, once, before it
-- leaves this machine.
--
-- Falls back to the last pair that WAS coherent for this graphic rather than to zero: during a
-- transition the previous good frame is the one a character was just showing, so holding it for a
-- frame is invisible, where snapping to the first frame of animation 0 is a flick of its own.
genderFrames.lastCoherentAnim = {}
genderFrames.coherentAnim = function(gfx, animNum, animIdx)
    local info = gfx and graphicsInfo(gfx)
    if not info or info.anims == 0 or info.images == 0 then return animNum, animIdx end
    local ap = r32(info.anims + (animNum or 0) * 4)
    if isRomPtr(ap) then
        local frame = r32(ap + (animIdx or 0) * 4) & 0xffff
        if isRomPtr(r32(info.images + frame * 8)) then
            genderFrames.lastCoherentAnim[gfx] = { animNum, animIdx }
            return animNum, animIdx
        end
    end
    local prev = genderFrames.lastCoherentAnim[gfx]
    if prev then return prev[1], prev[2] end
    return 0, 0
end


-- DRAW A PEER AS WHATEVER IT ACTUALLY IS -- a bike, a surfer, someone fishing.
--
-- The painted tier decoded only the walk and run pic tables for the local player's gender, so it
-- could draw a character walking and nothing else: with the spawned ghost fishing correctly beside
-- it, the user's report was *"the drawn one is not doing the starting fishing or mid fishing
-- animations at all"* (2026-08-19). Everything needed was already parsed by graphicsInfo() and
-- simply never used.
--
-- Three ROM reads turn a peer's animation state into a picture, all of them from that struct:
--   * anims[animNum]                 -- the animation table for the state (fishing, biking, ...)
--   * [animCmdIndex]                 -- the command currently playing, 4 bytes, imageValue in the
--                                       low 16 bits and hFlip at bit 22 (pokeemerald
--                                       include/sprite.h:48-57, union AnimCmd:74-80)
--   * images[imageValue]             -- struct SpriteFrameImage {const u8 *data; u16 size;}, so
--                                       8 bytes per entry and the pixels are the first pointer
--
-- The peer sends animNum and animCmdIndex; both ends are on the same graphic, so both resolve to
-- the same frame. SIZE comes from the graphic too (a bike is wider than a walker), which is why
-- this cannot reuse the fixed-size path above.
--
-- COLOURS come from the LIVE OBJ palette at the graphic's own slot, not from ROM. That is exact
-- whenever the palette is loaded -- which it is whenever anything on the map wears that graphic,
-- including the peer's own spawned copy -- and it also means a drawn peer dims with every fade and
-- cave for free, the same way the scene-brightness scaling does. When it is NOT loaded the colours
-- would be another character's; that is the known limit of this route, and the reason the
-- cartridge palette table is the next thing to find if it bites.
genderFrames.peerRunCache = {}

-- ONE FRAME'S PIXELS, from an explicit images pointer, size and palette slot.
--
-- Split out of runsForPeerGfx so the same decoder can serve things that are not object-event
-- graphics at all, because two of them turned out to be needed the moment a peer went in the
-- water: the SURF BLOB (a field-effect sprite template, with its own images and no graphicsId)
-- and a REFLECTION (the very same frame, decoded once more in the reflection palette). Nothing
-- about 4bpp tiles or run-building is specific to a character, so nothing here needed to be
-- written twice.
--
-- The palette slot is part of the cache key, not just the frame: the reflection is the same
-- pixels in different colours, and keying on the image alone would hand the first one decoded to
-- both.
-- A CHEAP FINGERPRINT OF ONE LIVE OBJ PALETTE, memoised for the frame.
--
-- The cache below bakes colours at decode time, so an entry made while the palette was not the
-- steady-state one -- mid-fade, or with a different map's palettes loaded -- stayed wrong for the
-- rest of the session. Found exactly that way 2026-08-20: the adapter was reloaded while the game
-- sat in a battle, the first decode after it took the battle's palette, and every drawn ghost was
-- washed out from then on while the spawned one looked normal.
--
-- So the cache is keyed on WHAT THE PALETTE HELD as well as on the frame. Recomputing the stamp is
-- 16 halfword reads, and memoising it per frame per slot keeps that at 16 reads per slot per frame
-- no matter how many peers ask -- the same footing as the scene-brightness read, which costs 32.
genderFrames.palStamp = {}
genderFrames.palStampFrame = -1
genderFrames.paletteStamp = function(slot)
    slot = slot & 0x0f
    local fc = emu.framecount()
    if genderFrames.palStampFrame ~= fc then
        genderFrames.palStampFrame = fc
        genderFrames.palStamp = {}
    end
    local s = genderFrames.palStamp[slot]
    if s then return s end
    s = 0
    for i = 0, 15 do
        s = (s * 33 + r16(0x05000200 + slot * 32 + i * 2)) % 0x100000000
    end
    genderFrames.palStamp[slot] = s
    return s
end

-- Forward-declared here and filled in much further down, the same pattern the surf-blob helpers
-- use. It has to be ABOVE the first reference, not merely above the table: a local declared later
-- in this chunk is not in scope for an earlier function, so it compiles to a global read of nil
-- and throws on the first frame that reaches it. That is exactly what happened -- the palette-stamp
-- counter below referenced `tiering` from up here while the declaration sat 140 lines lower, and
-- the drawn tier threw every frame for 302 frames straight and rendered nothing at all. Moving the
-- declaration costs no extra local, which matters at this chunk's 200 ceiling.
local tiering

genderFrames.runsFromImages = function(cacheKey, imagesPtr, width, height, imageIndex, paletteSlot)
    local stamp = genderFrames.paletteStamp(paletteSlot)
    local cached = genderFrames.peerRunCache[cacheKey]
    if cached and cached.palStamp == stamp then return cached end

    local pixels = r32(imagesPtr + imageIndex * 8)
    if not isRomPtr(pixels) then return nil end

    -- 4bpp tiles, 8x8, laid out row of tiles by row of tiles -- the same decode the gender path
    -- uses, with the dimensions passed in rather than assumed.
    local wTiles = width // 8
    local pal = {}
    for i = 0, 15 do
        local c = r16(0x05000200 + (paletteSlot & 0x0f) * 32 + i * 2)
        pal[i] = (0xFF << 24) | (expand5to8(c & 0x1F) << 16)
            | (expand5to8((c >> 5) & 0x1F) << 8) | expand5to8((c >> 10) & 0x1F)
    end

    local runs = {}
    for py = 0, height - 1 do
        local tileRow, localY = py // 8, py % 8
        local x = 0
        while x < width do
            local tileIndex = tileRow * wTiles + (x // 8)
            local b = r8(pixels + tileIndex * 32 + localY * 4 + ((x % 8) // 2))
            local idx = (x % 2 == 0) and (b & 0x0F) or ((b >> 4) & 0x0F)
            if idx ~= 0 then
                local color = pal[idx]
                local x2 = x
                -- Extend the run while the colour holds, exactly like the gender path.
                while x2 + 1 < width do
                    local ti = tileRow * wTiles + ((x2 + 1) // 8)
                    local nb = r8(pixels + ti * 32 + localY * 4 + (((x2 + 1) % 8) // 2))
                    local ni = ((x2 + 1) % 2 == 0) and (nb & 0x0F) or ((nb >> 4) & 0x0F)
                    if ni == 0 or pal[ni] ~= color then break end
                    x2 = x2 + 1
                end
                runs[#runs + 1] = { y = py, x1 = x, x2 = x2, color = color }
                x = x2 + 1
            else
                x = x + 1
            end
        end
    end
    -- STAMP THE ENTRY, or the invalidation above can never match and every peer re-decodes from
    -- ROM every frame. The comparison was written without this and read `cached.palStamp` as nil
    -- forever -- a cache that always misses, which is worse than no cache at all: it pays the
    -- lookup AND the decode. Caught by reading the write site rather than the read site.
    runs.palStamp = stamp
    genderFrames.peerRunCache[cacheKey] = runs
    return runs
end

-- Declared here rather than beside the spawn code further down, because the DRAWN tier below is
-- the first use and a local declared later in this chunk is not in scope for an earlier function
-- -- it compiles to a global lookup and silently reads nil. Provenance for both, and the rest of
-- the field effect's numbers, is in the surf-blob section that spawns it.
--   gFieldEffectObjectTemplate_SurfBlob  0850CBC4  (images at +0x0C, anims at +0x08)
-- The blob's frames are 32x32 (documentation.md's surfing section), which is both its tile cost
-- and, halved and negated, its centerToCornerVec.
local GFIELDEFFECTTEMPLATE_SURFBLOB = 0x0850cbc4
local SURFBLOB_FRAME_PX = 32
-- The water ripple's frame, measured off the game's own sprite: 16x16, centerToCornerVec -8,-8
-- (probes/ripple_probe.lua, 2026-08-21).
--
-- A FIELD, NOT A LOCAL, and that is not style: adding one more file-scope local here put this
-- chunk over Lua's hard ceiling of 200, which does not misbehave at runtime -- the script fails to
-- PARSE, "too many local variables (limit is 200) in main function". Caught the moment the ripple
-- work first loaded, exactly as the surf blob's own note two lines up warns.
genderFrames.rippleFramePx = 16

-- gOamMatrices 02021BC0 (pokeemerald.map), 32 entries of four s16 -- a, b, c, d. Entries 0 and 1
-- are the ones a MOVING reflection is drawn through; see reflectionXScale below. A FIELD, not a
-- local: adding one more local here is what pushed this chunk past Lua's hard ceiling of 200 and
-- turned the whole adapter into "too many local variables", which is a parse failure rather than
-- a misbehaviour -- the file loads not at all.
genderFrames.oamMatricesAddr = 0x02021bc0

-- THE SURF BLOB, FOR THE TIER THAT HAS NO ENGINE TO HAND IT TO.
--
-- A spawned ghost gets its blob for free: build the sprite, point its data[2] at the ghost, and
-- UpdateSurfBlobFieldEffect animates and follows it every frame. A DRAWN peer has no sprite and
-- no object event, so the frame it would be showing has to be resolved here instead.
--
-- Which is one lookup, because the blob's animation table is as simple as a table gets: four
-- animations, one frame each, one per facing (pokeemerald src/data/field_effects/
-- field_effect_objects.h:179-209 -- sSurfBlobAnim_FaceSouth/North/West/East, holding images
-- 0, 1, 2 and 2-with-hFlip). So animNum is the facing minus one, in DIR_* order
-- (DIR_SOUTH 1, DIR_NORTH 2, DIR_WEST 3, DIR_EAST 4 -- include/constants/global.h), and east is
-- west mirrored. CONFIRMED LIVE as well as read: probes/surfblob_probe.lua watched the game's own
-- blob report anim 0 / image 0 while the player faced south, 2026-08-19.
--
-- The images pointer is read from the template in ROM rather than written down, so it stays
-- correct on a build where the data moved; the palette slot is read off the game's own blob
-- (measured 0, the same probe).
-- Fields on genderFrames rather than new locals: this chunk sits one or two names below Lua's
-- hard ceiling of 200 locals per function, past which the script does not misbehave, it fails to
-- parse. Same reason the tiering table exists.
-- SLOT 0 IS THE FALLBACK, NOT THE ANSWER. The blob's palette must be resolved from its template's
-- TAG through the engine's own table, because the slot a tag lives in is not fixed: at a surf
-- start the show-mon effect loads a POKEMON's palette, and if it takes the slot we assumed, our
-- blob renders in that Pokemon's colours -- *"a weird glitched orange sprite"* on exactly the two
-- tiers that hardcoded 0. The hardware tier already resolved by tag and was the one tier the user
-- never reported it on, which is what identified this: three renderers, one differing in exactly
-- the suspected way.
genderFrames.blobPaletteSlot = 0
genderFrames.blobPalette = function()
    return hwPaletteSlotForTag(r16(GFIELDEFFECTTEMPLATE_SURFBLOB + 0x02))
        or genderFrames.blobPaletteSlot
end
-- The reverse of FACING, so a peer's orientation string picks the blob's animation.
genderFrames.dirOf = { south = 1, north = 2, west = 3, east = 4 }
genderFrames.blobDirImage = { [1] = 0, [2] = 1, [3] = 2, [4] = 2 }

genderFrames.runsForSurfBlob = function(facing)
    local imageIndex = genderFrames.blobDirImage[facing or 1] or 0
    local images = r32(GFIELDEFFECTTEMPLATE_SURFBLOB + 0x0c)
    if not isRomPtr(images) then return nil end
    local runs = genderFrames.runsFromImages(
        string.format("blob:%d", imageIndex), images,
        SURFBLOB_FRAME_PX, SURFBLOB_FRAME_PX, imageIndex, genderFrames.blobPalette())
    -- East is the west frame mirrored, which is the flag the anim command carries.
    return runs, (facing == 4)
end

-- A REFLECTION IN THE WATER, likewise.
--
-- The engine makes one by COPYING the sprite (SetUpReflection, pokeemerald
-- src/field_effect_helpers.c:47-68): same tiles, same shape, vertically flipped, priority 3 and
-- subpriority 152 so it sits behind everything, and -- the part that makes it read as a
-- reflection rather than an upside-down character -- a DIFFERENT palette, gReflectionEffectPaletteMap
-- (src/event_object_movement.c:182). Its vertical offset is the graphic's own height minus two
-- (GetReflectionVerticalOffset, :70-73), and its y2 is the main sprite's negated (:145).
--
-- So the drawn tier needs the same frame decoded a second time in the mapped palette, and drawn
-- flipped at +height-2. No approximation is involved anywhere in that, which matters: an
-- invented reflection is exactly the kind of lookalike that never converges (pitfalls.md,
-- "Approximating the game's own art never converges").
-- THE RIPPLE, WHICH IS THE HALF OF A REFLECTION THAT IS NOT A FLIP.
--
-- A moving reflection is not drawn as a plain vertical flip: SetUpReflection sets
-- ST_OAM_AFFINE_NORMAL on it and points it at OAM matrix 0, or matrix 1 when the character itself
-- is horizontally flipped (pokeemerald src/field_effect_helpers.c:66-68 and :158-166). Nothing in
-- the overworld source writes those two matrices, so what they DO was measured rather than read --
-- probes/surfblob_probe.lua, 2026-08-19, watching them while the player surfed:
--
--   oamMatrix[0] = 256,0,0,-256 -> 260,... -> 252,... -> 256,...   one step per frame
--   oamMatrix[1] = the same with `a` negated -- that is the horizontal flip, nothing more
--
-- So `d` is a constant -256 (the vertical flip, which this tier does by mirroring the row index)
-- and `a` is a triangle wave between 252 and 260. On an affine sprite the texture is stepped by
-- `a`, so the DRAWN width is width * 256 / a: about a pixel of total width, breathing in and out
-- once a second or so. That is the *"left/right shrink thing"*.
--
-- Read live rather than reproduced from those numbers, because the game already computes it and a
-- reconstruction would have its own phase to keep in step -- the failure this adapter has hit more
-- than any other. The magnitude is taken from entry 0: entry 1 differs only in the sign that this
-- tier already expresses through hFlip.
--
-- ICE IS THE EXCEPTION, and it is the engine's exception rather than a special case of ours: an
-- ice reflection is set up with stillReflection TRUE, which never turns the affine mode on, so
-- there is no matrix in play and nothing to breathe. Asked for one, this returns a flat 1.0.
-- Without it a peer on Shoal Cave's ice shimmered like a peer on a pond.
-- THE FLASH CIRCLE, WHICH IS THE ONE PIECE OF OCCLUSION THIS TIER CAN ACTUALLY HAVE.
--
-- A dark cave is not a drawn overlay. It is WINDOW 0: the engine writes the lit span for every
-- scanline into the scanline-effect buffer and DMAs it to REG_WIN0H each HBlank
-- (`sFlashEffectParams` targets `&REG_WIN0H`, src/field_screen_effect.c), so outside the circle
-- the layers simply are not displayed. The spawned and OAM copies are real sprites and the window
-- clips them for free; this tier paints after the PPU has finished, where windows no longer exist,
-- so the user saw the painted ghost shining through the dark -- *"drawn ghost is not hidden in
-- darkness/caves"*.
--
-- Unlike the fog, this one is fixable, and cheaply: the lit region is READABLE DATA rather than a
-- priority we cannot win. One halfword per painted row gives that row's span, and the paint is
-- intersected with it.
--
-- Measured live in Granite Cave B1F, 2026-08-21: rows 56..104 lit, 114-126 at the top edge
-- widening to 96-144 at the middle -- centre (120, 80), radius 24, which is
-- `sFlashLevelToRadius[7]`. Every other row reads 0-0.
--
-- WHAT IT MUST NOT DO IS CLIP WHEN THERE IS NO CIRCLE. An all-zero buffer means "nothing lit
-- anywhere", so trusting it unconditionally would erase this tier on every ordinary map. The
-- effect is therefore confirmed at its source: gScanlineEffect's dmaDest must be REG_WIN0H and its
-- state non-zero. Another scanline effect on another register leaves this alone.
--   gScanlineEffect 02039B28 { dmaDest 0x08, srcBuffer 0x14, state 0x15 } (pokeemerald.map and
--   include/scanline_effect.h), gScanlineEffectRegBuffers 02038C28, u16[2][0x3C0].
--
-- VANILLA ONLY, like the hardware tier and the fishing hook: those are our own build's addresses
-- and a patched ROM moves them. There the clip declines rather than reading someone else's memory,
-- so a painted ghost still shows through a dark cave on an Archipelago seed. Known, and much
-- better than clipping to garbage.
genderFrames.flashCheckedAt, genderFrames.flashBuf = -100, nil
genderFrames.flashSpan = function(y)
    if frameCounter ~= genderFrames.flashCheckedAt then
        genderFrames.flashCheckedAt = frameCounter
        genderFrames.flashBuf = nil
        if avatarAddrOffset == 0
            and r32(0x02039b28 + 0x08) == 0x04000040
            and r8(0x02039b28 + 0x15) ~= 0
        then
            genderFrames.flashBuf = 0x02038c28 + (r8(0x02039b28 + 0x14) & 1) * 0x3c0 * 2
        end
    end
    if not genderFrames.flashBuf then return nil end
    local row = math.floor(y)
    if row < 0 or row > 159 then return nil end
    local v = r16(genderFrames.flashBuf + row * 2)
    -- WIN0H is (left << 8) | right, and the right edge is EXCLUSIVE on the hardware.
    return v >> 8, (v & 0xff) - 1
end

-- WHICH PICTURE THE PEER IS ACTUALLY SHOWING, resolved the engine's way: the graphic's anim table
-- indexed by animNum, then by animCmdIndex, and the low half of that AnimCmd_frame is the image
-- index. Returns nil rather than a guess when anything is unreadable -- a peer mid-graphic-swap
-- carries an animNum belonging to the graphic it is leaving, which indexes past the table's end.
-- The same two reads the compare log already did inline; named because a second caller needed it.
genderFrames.peerImageIndex = function(remote)
    local gi = graphicsInfo(remote.gfx or 0)
    if not gi or gi.anims == 0 then return nil end
    local ap = r32(gi.anims + (remote.sanim or 0) * 4)
    if not isRomPtr(ap) then return nil end
    return r32(ap + (remote.sidx or 0) * 4) & 0xffff
end

genderFrames.reflectionXScale = function(kind)
    if kind == "ice" then return 1.0 end
    local a = rs16(genderFrames.oamMatricesAddr)
    if a == 0 then return 1.0 end
    return 256.0 / math.abs(a)
end


-- WHERE A REFLECTION MAY BE PAINTED -- which is a question about DEPTH, not about water.
--
-- The first version of this clipped to reflective water tiles and was wrong in the way the user
-- named exactly: *"its supposed to go under the edge but still draw, but not get drawn on top of
-- the grass"*. A reflection is not clipped to the pond; it is a sprite at OAM priority 3
-- (SetUpReflection, pokeemerald src/field_effect_helpers.c:53) and the map covers it or does not.
--
-- Which the map decides per metatile, through its LAYER TYPE (field_camera.c's DrawMetatile,
-- :255-300 -- and the game's own comment on the NORMAL case says it outright, "which covers object
-- event sprites"):
--
--   NORMAL  (0)  ground -> BG2, top -> BG1.  BG2 is ABOVE a priority-3 sprite, so grass, sand and
--                ordinary ground HIDE a reflection completely. This is the case that was painting
--                over the grass.
--   COVERED (1)  ground -> BG3, top -> BG2.  BG3 is BELOW the sprite, so the reflection shows,
--                and the top layer on BG2 covers whatever part of it the edge art occupies --
--                which is precisely "goes under the edge but still draws".
--   SPLIT   (2)  ground -> BG3, top -> BG1.  Same story for the part that matters here.
--
-- So the test is "is this tile's ground drawn on the bottom layer", i.e. layer type is not NORMAL.
-- Water tiles are COVERED/SPLIT (that is what lets a surfing character be drawn over them at all),
-- so this keeps every case the water test got right and fixes the shore.
--
--   attributes: behaviour = bits 0-7, layer type = bits 12-15 (include/global.fieldmap.h:39-47)
-- WHICH PIXELS OF A METATILE COVER A SPRITE -- a 16-row bitmask, decoded once per metatile.
--
-- Tile-granular was not enough, and the shore is where it shows: clipping whole 16px cells kept
-- the reflection over the grass half of the pond's border tiles -- *"its still trying to draw
-- outside the water on the grass at the side"*. The engine has no such granularity problem
-- because it is not clipping at all; the BG simply covers the sprite pixel by pixel. So this
-- asks the same question per pixel.
--
-- Which layers cover a priority-3 reflection is decided by the metatile's LAYER TYPE, because
-- that is what chooses the BG each layer is drawn on (DrawMetatile, pokeemerald
-- src/field_camera.c:255-300) and the overworld gives BG1 priority 1, BG2 priority 2 and BG3
-- priority 3 (sOverworldBgTemplates, src/overworld.c:266-303 -- and read back live from BG1CNT/
-- BG2CNT/BG3CNT to be sure). A sprite at priority 3 loses to BG1 and BG2 and WINS against BG3,
-- since OBJ takes ties.
--
--   NORMAL  (0)  ground -> BG2, top -> BG1.  BOTH cover. Grass hides a reflection completely.
--   COVERED (1)  ground -> BG3, top -> BG2.  Only the top layer covers -- the pond's stone lip.
--   SPLIT   (2)  ground -> BG3, top -> BG1.  Only the top layer covers.
--
-- A metatile is 8 tilemap entries: four for the bottom layer then four for the top, each 2x2 in
-- reading order, and each carrying a tile index plus the two flip bits (struct Tileset.metatiles
-- at +0x0C, include/global.fieldmap.h:64-73; NUM_TILES_PER_METATILE 8, NUM_TILES_IN_PRIMARY 512).
-- The pixels come from VRAM rather than the tileset's own `tiles` pointer, because that data is
-- usually COMPRESSED in ROM while VRAM always holds it decompressed and ready -- confirmed
-- readable first, with probes/bgread_probe.lua, since this project has a recorded case of a VRAM
-- region reading back as all zeros and that answer looks like a finding.
--
-- Decoded once per metatile and cached; the cache is dropped when the map layout changes.
genderFrames.coverCache = {}
genderFrames.coverLayout = nil

-- `who` is "sprite" for an ordinary character or "reflection" for one, and the answer genuinely
-- differs, because the two are drawn at different OAM priorities and a BG only covers a sprite it
-- outranks. sElevationToPriority (src/event_object_movement.c:7729) puts a character on ordinary
-- ground at priority 2; SetUpReflection pins a reflection at 3. Against BG1/BG2/BG3 at priorities
-- 1/2/3 (sOverworldBgTemplates), with OBJ winning ties:
--
--                     BG1 (prio 1)   BG2 (prio 2)   BG3 (prio 3)
--   character (2)     covers         ties, OBJ wins  no
--   reflection (3)    covers         covers          ties, OBJ wins
--
-- Crossed with where DrawMetatile puts each layer (src/field_camera.c:255-300):
--
--   NORMAL   ground->BG2, top->BG1 : character hidden by the TOP layer only;
--                                    reflection hidden by BOTH (this is grass, and it hides one).
--   COVERED  ground->BG3, top->BG2 : character hidden by NOTHING; reflection by the top layer.
--   SPLIT    ground->BG3, top->BG1 : both hidden by the top layer only.
--
-- The character row is what makes a drawn ghost disappear behind a building: the roof edge and the
-- tree tops that overlap a walkable tile are that tile's TOP layer, which is exactly the layer the
-- engine puts above sprites.
-- The metatile's layer type on its own -- what coverMask branches on. Split out so a diagnostic
-- can report it without re-deriving it, and so the two can never disagree about what they read.
genderFrames.layerTypeOf = function(metatileId)
    if not metatileId then return nil end
    local layout = r32(0x02037318)
    if layout == 0 then return nil end
    local tileset, index
    if metatileId < 512 then
        tileset, index = r32(layout + 0x10), metatileId
    else
        tileset, index = r32(layout + 0x14), metatileId - 512
    end
    if tileset == 0 then return nil end
    local attrs = r32(tileset + 0x10)
    if attrs == 0 then return nil end
    return (r16(attrs + index * 2) >> 12) & 0x0f
end

genderFrames.coverMask = function(metatileId, who)
    local key = (who or "reflection") .. metatileId
    local cached = genderFrames.coverCache[key]
    if cached ~= nil then return cached end

    local layout = r32(0x02037318)
    local tileset, index
    if metatileId < 512 then
        tileset, index = r32(layout + 0x10), metatileId
    else
        tileset, index = r32(layout + 0x14), metatileId - 512
    end
    if tileset == 0 then genderFrames.coverCache[key] = false return false end
    local metatiles = r32(tileset + 0x0c)
    local attrs = r32(tileset + 0x10)
    if metatiles == 0 or attrs == 0 then
        genderFrames.coverCache[key] = false
        return false
    end
    local layerType = (r16(attrs + index * 2) >> 12) & 0x0f

    local rows = {}
    for i = 0, 15 do rows[i] = 0 end
    -- Which layers can cover THIS kind of sprite, per the table above.
    local layers
    if who == "sprite" then
        layers = (layerType == 1) and {} or { 4 }   -- COVERED hides a character not at all
    else
        layers = (layerType == 0) and { 0, 4 } or { 4 }
    end
    for _, lay in ipairs(layers) do
        for quad = 0, 3 do
            local e = r16(metatiles + (index * 8 + lay + quad) * 2)
            local tileIndex = e & 0x03ff
            local hflip, vflip = (e & 0x0400) ~= 0, (e & 0x0800) ~= 0
            local ox, oy = (quad % 2) * 8, (quad // 2) * 8
            for py = 0, 7 do
                local sy = vflip and (7 - py) or py
                local w0 = r16(0x06000000 + tileIndex * 32 + sy * 4)
                local w1 = r16(0x06000000 + tileIndex * 32 + sy * 4 + 2)
                local row = rows[oy + py]
                for px = 0, 7 do
                    local sx = hflip and (7 - px) or px
                    -- A 4bpp tile row is FOUR bytes for EIGHT pixels, so the byte holding pixel
                    -- sx is sx // 2 -- not sx. Indexing by the pixel read every second byte and
                    -- called the odd pixels transparent, which would have punched holes through
                    -- half of every covering tile.
                    local bi = sx // 2
                    local byte
                    if bi < 2 then byte = (w0 >> (bi * 8)) & 0xff
                    else byte = (w1 >> ((bi - 2) * 8)) & 0xff end
                    -- Two pixels per byte, low nibble first.
                    local v = (sx % 2 == 0) and (byte & 0x0f) or ((byte >> 4) & 0x0f)
                    if v ~= 0 then row = row | (1 << (ox + px)) end
                end
                rows[oy + py] = row
            end
        end
    end
    genderFrames.coverCache[key] = rows
    return rows
end

-- The metatile id at a grid coordinate, and the cache guard that goes with it.
genderFrames.metatileAt = function(x, y)
    local width = memory.read_s32_le(0x03005dc0)
    local map = r32(0x03005dc0 + 0x08)
    if map == 0 or width <= 0 then return nil end
    local height = memory.read_s32_le(0x03005dc0 + 0x04)
    if x < 0 or y < 0 or x >= width or y >= height then return nil end
    return r16(map + (x + width * y) * 2) & 0x03ff
end

-- Whether a peer HAS a reflection at all is the separate question, and the engine answers it from
-- the metatile behaviour below the character -- ObjectEventGetNearbyReflectionType
-- (src/event_object_movement.c:7625-7650) scans downward from currentCoords.y + 1 --
-- against MetatileBehavior_IsReflective (src/metatile_behavior.c:199-210), a short fixed list.
-- Note what is NOT on it: MB_OCEAN_WATER. The sea does not reflect in this game, so a peer surfing
-- at sea correctly gets nothing, and drawing one there was our invention.
--   MB_POND_WATER 16, MB_SOOTOPOLIS_DEEP_WATER 20, MB_PUDDLE 22,
--   MB_UNUSED_SOOTOPOLIS_DEEP_WATER_2 26, MB_ICE 32, MB_REFLECTION_UNDER_BRIDGE 43
--   (include/constants/metatile_behaviors.h, enum from 0 -- cross-checked against the two values
--   this repo already had measured, MB_POND_WATER 16 and MB_OCEAN_WATER 21.)
--
-- AND THERE ARE TWO KINDS OF REFLECTION, not one. GetReflectionTypeByMetatileBehavior
-- (src/event_object_movement.c) asks MetatileBehavior_IsIce FIRST and only then IsReflective, so
-- MB_ICE is REFL_TYPE_ICE and everything else on the list is REFL_TYPE_WATER. The difference is
-- the whole shimmer: GroundEffect_IceReflection calls SetUpReflection with stillReflection TRUE,
-- which skips ST_OAM_AFFINE_NORMAL and leaves the reflection a plain vertical flip, while the
-- water one is drawn through OAM matrix 0/1 and breathes (src/field_effect_helpers.c:47-68,
-- :151-166). Ice does not ripple, so its reflection does not either.
--
-- The values are the kind rather than `true` so both self-drawn tiers can ask which one they are
-- drawing; every existing caller only tested truthiness and is unaffected.
genderFrames.reflectiveBehaviour = {
    [16] = "water", [20] = "water", [22] = "water", [26] = "water",
    [32] = "ice",
    [43] = "water",
}

-- THE ENGINE'S SCAN, and it is wider than one tile in both senses.
--
-- ObjectEventGetNearbyReflectionType (src/event_object_movement.c:7625-7650) walks a region
-- (info->width + 8) >> 4 tiles across and (info->height + 8) >> 4 down, starting one row BELOW the
-- character, and it does so around the PREVIOUS coordinates as well as the current ones.
--
-- Both parts matter, and the second is what a first reading loses. Because previousCoords is
-- included, a character stepping off the water keeps its reflection for the whole of that step --
-- so the reflection slides along under the bank and is eaten by the land pixels covering it,
-- rather than blinking out the instant the tile beneath changes. The user, watching a drawn ghost
-- with only the current tile tested: *"for the player it kinda glides and smoothly goes away, for
-- the drawn ghost the reflection just cuts and gets removed"*.
--
-- Coordinates are grid coordinates (map + MAP_OFFSET); prev may be nil, which just means the scan
-- is done once.
genderFrames.hasReflection = function(x, y, px, py, w, h)
    for i = 0, (h or 2) - 1 do
        for pass = 1, (px and 2 or 1) do
            local cx, cy = x, y
            if pass == 2 then cx, cy = px, py end
            for j = 0, (w or 2) - 1 do
                -- j = 0 is the character's own column; past that the engine checks both sides.
                for _, dx in ipairs(j == 0 and { 0 } or { j, -j }) do
                    local attr = genderFrames.attrAt(cx + dx, cy + 1 + i)
                    -- The KIND, not just yes -- and the first tile that yields one wins, which is
                    -- what the engine's RETURN_REFLECTION_TYPE_AT macro does at each step of this
                    -- same scan. A string is truthy, so callers that only wanted yes/no still work.
                    local kind = attr and genderFrames.reflectiveBehaviour[attr & 0xff]
                    if kind then return kind end
                end
            end
        end
    end
    return false
end

-- The metatile ATTRIBUTES at a map coordinate: the map grid gives a metatile id, and which of the
-- two loaded tilesets owns it decides where its attributes live. Same reads as
-- probes/watertile.lua, which measured them.
--   gBackupMapLayout 03005DC0 { s32 width 0x00, s32 height 0x04, u16 *map 0x08 }
--   gMapHeader       02037318 -> mapLayout 0x00 -> primary 0x10, secondary 0x14, attributes 0x10
--   MAPGRID_METATILE_ID_MASK 0x03FF, primary metatile count 512
genderFrames.attrAt = function(x, y)
    local width = memory.read_s32_le(0x03005dc0)
    local map = r32(0x03005dc0 + 0x08)
    if map == 0 or width <= 0 then return nil end
    local height = memory.read_s32_le(0x03005dc0 + 0x04)
    if x < 0 or y < 0 or x >= width or y >= height then return nil end
    local metatileId = r16(map + (x + width * y) * 2) & 0x03ff
    local layout = r32(0x02037318)
    if layout == 0 then return nil end
    local tileset, index
    if metatileId < 512 then
        tileset, index = r32(layout + 0x10), metatileId
    else
        tileset, index = r32(layout + 0x14), metatileId - 512
    end
    if tileset == 0 then return nil end
    local attrs = r32(tileset + 0x10)
    if attrs == 0 then return nil end
    return r16(attrs + index * 2)
end

-- The x ranges, per screen row, a reflection may be painted in -- nil for "cannot tell right now",
-- an empty list for "all of this is covered".
--
-- Screen pixel to map tile is the exact INVERSE of the placement this tier already uses
-- (`originX + (mapX - anchorX) * TILE + camPix`), so it needs no new assumption about the camera.
-- The one correction is that the placement maps a map coordinate to the FRAME's top-left while the
-- character stands on the frame's bottom tile, hence the FRAME_HEIGHT_PX - TILE term.
--
-- Nine tile lookups at most, not one per pixel: the tiles under a 32x32 frame are a 3x3 grid at
-- worst, so the attributes are read once and the pixel ranges come out of arithmetic. A per-pixel
-- version would be ~1000 reads a frame, which is the read budget this file keeps warning about
-- (_template/probes.md).
-- The screen->grid origin, shared by everything that asks where a painted thing is standing.
genderFrames.gridBase = function()
    local ax, ox = tiering.anchorX, tiering.originXStill
    local ay, oy = tiering.anchorY, tiering.originYStill
    if not (ax and ox and ay and oy) then return nil end
    return ox + rs16(GTOTALCAMERAPIXELOFFSETX_ADDR) - (ax + MAP_OFFSET) * TILE,
        oy + rs16(GTOTALCAMERAPIXELOFFSETY_ADDR) + (FRAME_HEIGHT_PX - TILE)
            - (ay + MAP_OFFSET) * TILE
end

-- GRASS DRAWN OVER A PAINTED GHOST, because in this game grass is a SPRITE, not scenery.
--
-- A character standing in tall grass is hidden from the waist down, and the BG mask above cannot
-- do it: measured 2026-08-20, the grass metatile's TOP layer is completely EMPTY
-- (`BOTTOM 2012 2013 2022 2023  TOP 0000 0000 0000 0000`, layer type NORMAL), so no BG layer is
-- covering anything. The engine spawns a field-effect SPRITE per object standing in grass and
-- draws it above them (FldEff_TallGrass, src/field_effect_helpers.c:291-309). A spawned ghost gets
-- one for free, being a real object event; a painted one gets nothing, and the user saw exactly
-- that -- *"its not hidden in tall grass ... player & spawned work as intended"*.
--
-- So the painted tier draws the grass itself, over the character, from the field effect's own art:
--   gFieldEffectObjectTemplate_TallGrass  0850CAA0   (MB_TALL_GRASS  2)
--   gFieldEffectObjectTemplate_LongGrass  0850CF94   (MB_LONG_GRASS  3)
-- both named in pokeemerald.map. Placement is the blob's helper again --
-- SetSpritePosToOffsetMapCoords(x, y, 8, 8) puts it at the tile's centre, and a 16x16 sprite
-- centred on a tile is a sprite at the tile's corner, so it lands on the character's own tile.
--
-- The PALETTE is read off a live one rather than resolved from the template's tag: the player is
-- standing in the same grass whenever this matters, so the engine already has the answer on screen.
-- Without one, nothing is drawn -- a wrong-coloured rectangle over a ghost is worse than no grass.
genderFrames.grassTemplate = { [2] = 0x0850caa0, [3] = 0x0850cf94 }

-- WHICH FRAME OF THE RUSTLE, decoded from the template's own animation rather than assumed.
--
-- Grass does not sit still when something walks into it: the tall-grass animation is frames
-- 1,2,3,4,0 at ten game-frames each and then it settles (sAnim_TallGrass,
-- src/data/field_effects/field_effect_objects.h:79-87). A painted ghost drawing frame 0 forever
-- stands in grass that never moves -- *"the grass is supposed to shake/move when you walk trought
-- it"*.
--
-- The commands are read at runtime instead of the numbers being copied here, so long grass gets
-- its own timing rather than tall grass's: union AnimCmd packs imageValue in the low 16 bits and
-- duration in the next 6 (include/sprite.h), and the list ends with a command whose low half is
-- 0xFFFF. Elapsed frames are walked through the durations; past the end it holds the last frame,
-- which is what "settled" is.
-- One pass of grass for a peer: the tiles its FEET overlap in the given row range, each with its
-- own rustle clock. Called twice per peer -- once for the row above, BEFORE the character is drawn,
-- and once for its own row and below, AFTER -- because that is the order the engine draws them in
-- (measured: the tile below a character has a lower subpriority than the character, the tile above
-- a higher one).
--
-- THE CLOCK RESTARTS ON ENTRY, not on first sight. Keyed on first-ever-drawn, a tile walked over
-- twice rustled only the first time -- and a looping test walks the same tiles for ever, so the
-- grass simply never moved again: *"its still not making the grass shake, like the player does"*.
-- A tile that was not covered last frame is being stepped onto now, which is exactly when the game
-- spawns its sprite.
-- topLimit: never paint above this screen row. Mid-step the character spans two tiles and both
-- their grass is in front of it, but how far up that reaches depends on the sub-tile phase of the
-- step -- at some phases the upper tile's top edge sits almost level with the character's head and
-- swallows it. The game leaves a sliver: *"you are supposed to still see a tiny bit of the hat at
-- the top, but not the head/body"*. Bounding the coverage keeps that true at every phase instead of
-- only some, which is what a tile-aligned overlay over a smoothly-interpolated ghost cannot do on
-- its own.
genderFrames.drawGrassRows = function(playerId, gbX, gbY, left, footY, rowFrom, rowTo, panelRows,
    dim, topLimit)
    local clip = nil
    if topLimit then
        clip = {}
        for y = math.floor(topLimit), math.floor(topLimit) + 3 * TILE do
            clip[y] = { { -9999, 9999 } }
        end
    end
    tiering.grassTiles = tiering.grassTiles or {}
    local st = tiering.grassTiles[playerId] or {}
    local x0 = math.floor((left - gbX) / TILE)
    local x1 = math.floor((left + FRAME_WIDTH_PX - 1 - gbX) / TILE)
    for gy = rowFrom, rowTo do
        for gx = x0, x1 do
            local key = gx .. "," .. gy
            local e = st[key]
            -- Drawn last frame? then this is the same visit and its clock keeps running. Otherwise
            -- the ghost has just stepped on, which is when the game spawns the sprite -- so the
            -- rustle starts over. Keyed on first-ever-drawn instead, a tile walked over twice
            -- rustled only the first time, and a looping walk never saw it move again.
            if not e or (frameCounter - e[2]) > 1 then e = { frameCounter, frameCounter } end
            e[2] = frameCounter
            st[key] = e
            local attr = genderFrames.attrAt(gx, gy)
            local beh = attr and (attr & 0xff)
            local runs = beh and genderFrames.grassRuns(beh,
                genderFrames.grassFrameAt(beh, frameCounter - e[1]))
            if runs then
                drawRunList(runs, TILE, false, gbX + gx * TILE, gbY + gy * TILE, panelRows,
                    dim, nil, nil, clip)
            end
        end
    end
    -- Drop what this peer has walked away from, so the table cannot grow all session.
    for k, v in pairs(st) do
        if frameCounter - v[2] > 300 then st[k] = nil end
    end
    tiering.grassTiles[playerId] = st
end

-- LANDING DUST, painted, for both tiers.
--
-- The engine spawns it at the character's own tile the moment a jump lands
-- (GroundEffect_JumpLandingDust -> FLDEFF_DUST, src/event_object_movement.c:7995-8002) from
-- gFieldEffectObjectTemplate_GroundImpactDust (0850CCA0, pokeemerald.map): a 16x8 sprite whose
-- animation is frames 0,1,2 at eight game-frames each, so 24 frames and gone.
--
-- Painted for BOTH tiers, for different reasons. The drawn tier has no engine to spawn it at all.
-- The spawned tier does get the engine's own dust -- but our painted SHADOW covers it, because an
-- overlay is drawn after the hardware has finished, and the real shadow sprite that would sit
-- underneath is disabled after it crashed the game. Painting the dust on top of our own shadow
-- puts it back in view: the user's suggestion, and the right one while the sprite is off.
--
-- The palette is read off a live dust sprite, which exists whenever the engine has spawned one --
-- and on the spawned tier it always has, at the same moment, which is exactly when this draws.
genderFrames.dustTemplate = 0x0850cca0

genderFrames.dustRuns = function(frame)
    local images = r32(genderFrames.dustTemplate + 0x0c)
    if not isRomPtr(images) then return nil end
    -- THE PALETTE BY TAG, not by finding a neighbour. This used to scan all 64 sprites for a live
    -- dust sprite and copy its palette slot, which fails outright when nobody else happens to be
    -- landing -- and once the trail below started calling this once per live puff per frame, that
    -- scan became the per-frame cost of the whole feature. `IndexOfSpritePaletteTag` is the
    -- engine's own answer and it is a 16-entry table: sSpritePaletteTags 03000CF0 (pokeemerald.sym)
    -- against the dust template's FLDEFF_PAL_TAG_GENERAL_0 (0x1004, constants/field_effects.h:112).
    local pal = hwPaletteSlotForTag(0x1004)
    if not pal then return nil end
    -- 16x8, from the template's own OAM shape (gObjectEventBaseOam_16x8).
    return genderFrames.runsFromImages(string.format("dust:%d:%d", pal, frame),
        images, TILE, TILE // 2, frame, pal)
end

-- Frame index for a landing that happened `elapsed` frames ago, walked from the template's own
-- animation commands -- nil once it has finished, which is what stops it being drawn.
genderFrames.dustFrameAt = function(elapsed)
    local anims = r32(genderFrames.dustTemplate + 0x08)
    if not isRomPtr(anims) then return nil end
    local list = r32(anims)
    if not isRomPtr(list) then return nil end
    local t = elapsed
    for i = 0, 15 do
        local cmd = r32(list + i * 4)
        local img = cmd & 0xffff
        if img == 0xffff then return nil end       -- ANIMCMD_END: the puff is over
        local dur = (cmd >> 16) & 0x3f
        if dur == 0 then dur = 1 end
        if t < dur then return img end
        t = t - dur
    end
    return nil
end

-- THE WATER TRAIL, painted, for both self-drawn tiers.
--
-- A character moving on water leaves a ripple behind it, and it is a FIELD EFFECT -- so the
-- spawned tier has always had it from the engine and neither tier that draws for itself had it at
-- all. The user, watching all three surf at Sootopolis 2026-08-21: *"drawn & oam are not leaving
-- trails in the water when they move around."*
--
-- EVERY NUMBER HERE WAS MEASURED, with probes/ripple_probe.lua watching the game's own ripples
-- while the player surfed (2026-08-21), because what this needs is not "where is the template"
-- but "when does the engine decide to make one, and where does it put it":
--
--   * ONE PER TILE STEPPED, not on a timer. They appeared every 8 frames and 16 pixels apart --
--     and surfing crosses a tile in exactly 8 frames (the player's tile went 32,46 -> 32,47 over
--     those same frames), so the cadence is per step. A timer would have drifted against speed.
--   * 16x16, palette tag 0x1005, subpriority 151 -- between the reflection (152) and the blob
--     (150), which is where the hardware tier's pools put it.
--   * EIGHT animation frames over an 80-frame life, walked from the template's own animation
--     commands here rather than written down, so a different build stays correct.
--   * At the character's sprite position plus (0, height/2 - 2) -- the engine's own expression --
--     which in the top-left terms these tiers draw in is (width/2 - 8, height - 10), the ripple's
--     own frame being 16x16 with centerToCornerVec -8,-8.
--   * It does NOT follow the character. Position is fixed at birth and camera-anchored, exactly
--     like the landing-dust trail beside it.
--
-- THE TEMPLATE ADDRESS WAS DERIVED, NOT REMEMBERED. A live ripple sprite reported the anims and
-- images pointers it was built from (0850CB04 and 0850CAB8); the template is whatever structure
-- carries that pair at +0x08 and +0x0c, and one scan of the surrounding ROM found exactly one --
-- 0850CB08, whose callback matches the live sprite's and whose paletteTag is 0x1005.
genderFrames.rippleTemplate = 0x0850cb08

-- Frame index for a ripple born `elapsed` frames ago; nil once it has finished, which is what
-- stops it being drawn. Same walk of the animation commands as the landing dust's.
genderFrames.rippleFrameAt = function(elapsed)
    local anims = r32(genderFrames.rippleTemplate + 0x08)
    if not isRomPtr(anims) then return nil end
    local list = r32(anims)
    if not isRomPtr(list) then return nil end
    local t = elapsed
    for i = 0, 15 do
        local cmd = r32(list + i * 4)
        local img = cmd & 0xffff
        if img == 0xffff then return nil end       -- ANIMCMD_END: the ripple is over
        local dur = (cmd >> 16) & 0x3f
        if dur == 0 then dur = 1 end
        if t < dur then return img end
        t = t - dur
    end
    return nil
end

genderFrames.rippleRuns = function(frame)
    local images = r32(genderFrames.rippleTemplate + 0x0c)
    if not isRomPtr(images) then return nil end
    -- The palette by TAG, the engine's own IndexOfSpritePaletteTag, for the same reason the dust
    -- uses it: finding a live neighbour fails exactly when nobody else happens to be rippling.
    local pal = hwPaletteSlotForTag(r16(genderFrames.rippleTemplate + 0x02))
    if not pal then return nil end
    return genderFrames.runsFromImages(string.format("ripple:%d:%d", pal, frame),
        images, genderFrames.rippleFramePx, genderFrames.rippleFramePx, frame, pal)
end

-- Where a ripple belongs, given the character's frame top-left and the graphic's own size, and
-- WHETHER one is due this frame. Due means: this peer is surfing, and the tile it is drawn on has
-- just changed -- which the reflection's previous-tile store already knows, since it stamps the
-- frame the tile changed on. One store per tier, so each tier answers for where IT draws.
-- `surfing` is passed IN rather than tested here, and that is not a style choice: SURFING_GFX is a
-- local declared some two hundred lines BELOW this function, so naming it here compiles to a nil
-- global lookup -- "attempt to index a nil value (global 'SURFING_GFX')", once per frame, from
-- inside the draw path, which aborts the whole tick. That took the painted ghost off the screen
-- entirely and the hardware tier's reflection with it (2026-08-21). Both callers sit below the
-- declaration and can answer the question themselves.
genderFrames.rippleDue = function(store, playerId, surfing)
    if not surfing then return false end
    local e = store[playerId]
    return e ~= nil and e[4] == frameCounter
end

-- HOW LONG ONE BOUNCE LASTS, for the acro actions that REPEAT while B is held.
--
-- The reason this exists: a held-B wheelie hop is ONE movement action that bounces over and over,
-- so a peer sends the same `act` for as long as the button is down. Both painted tiers latch their
-- dust on the air->ground EDGE of that action, and during continuous hopping there is no edge --
-- measured 2026-08-21, one "took off" and no landing for a solid minute while the ghost bounced
-- the whole time. The spawned tier is unaffected because the ENGINE emits its dust per step
-- rather than per action, which is exactly why the defect showed on two tiers and not three.
--
-- So the bounce is counted instead, on the engine's own number rather than one tuned by eye.
-- `DoJumpSpriteMovement` (event_object_movement.c:8462-8492) ends a jump at `distanceToTime`:
-- 16 frames for JUMP_DISTANCE_IN_PLACE and JUMP_DISTANCE_NORMAL, 32 for JUMP_DISTANCE_FAR. The
-- acro actions pick those distances at :6854-7024 --
--   0x70..0x73 ACRO_WHEELIE_HOP_FACE_*  IN_PLACE  ) 16
--   0x74..0x77 ACRO_WHEELIE_HOP_*       NORMAL    )
--   0x78..0x7B ACRO_WHEELIE_JUMP_*      FAR         32
-- A ledge hop returns nil and keeps the edge rule: it is a ONE-SHOT action whose id leaves the
-- jump range when it finishes, so it has an edge and does not need counting -- and counting it
-- would puff halfway through a two-tile hop.
-- THE SIDE HOP (0x42..0x45) IS DELIBERATELY ABSENT, and that absence is the whole rule.
--
-- Counting bounces is for actions that REPEAT under a held button while reporting one id -- the
-- wheelie hops. A side hop is discrete: each one is its own action, so its landing shows up as an
-- ordinary air->ground edge and the edge already puffs exactly once. Counting it as well spawned a
-- fresh puff every 16 frames on top of that, and since a side hop also travels a tile, those puffs
-- were left strung out behind the ghost -- a line of dust no engine-driven character produces. The
-- user, watching all three tiers, 2026-08-21: *"the dust is not supposed to trail for the OAM &
-- drawn ghosts when side hopping"*. The shadow is unaffected: `isJumpAction` still covers 0x42..
-- 0x45, which is what says airborne.
genderFrames.hopFrames = function(act)
    if act == nil then return nil end
    if act >= 0x70 and act <= 0x77 then return 16 end
    if act >= 0x78 and act <= 0x7b then return 32 end
    return nil
end


-- Remember when a peer last landed, so every tier puffs on the same frame. Returns the dust frame
-- the newest puff is up to (nil once it has played out), and SECOND a landed-this-frame edge --
-- which is what the trail below is built from, and is idempotent within a frame on purpose:
-- three tiers ask about the same peer, and only the first caller advances the latch, so the
-- edge is answered from `at == frameCounter` rather than from who called first.
genderFrames.noteLanding = function(playerId, jumping, act)
    tiering.landed = tiering.landed or {}
    local e = tiering.landed[playerId]
    local period = jumping and genderFrames.hopFrames(act)
    if jumping then
        if not (e and e.air) then
            tiering.landed[playerId] = { air = true, airAt = frameCounter, at = (e and e.at) or nil }
        elseif period and e.airAt and frameCounter - e.airAt >= period then
            -- A BOUNCE FINISHED WITHOUT THE ACTION CHANGING. Still airborne -- the next bounce
            -- starts on this same frame, which is what B held down means -- but it touched the
            -- ground to do it, and that is what the dust marks.
            tiering.landed[playerId] = { air = true, airAt = frameCounter, at = frameCounter }
        end
    elseif e and e.air then
        -- Left the air this frame: that is the landing, on the tile it came down on.
        tiering.landed[playerId] = { air = false, at = frameCounter }
    end
    local cur = tiering.landed[playerId]
    local f = cur and cur.at and genderFrames.dustFrameAt(frameCounter - cur.at) or nil
    return f, (cur ~= nil and cur.at == frameCounter) or false
end

genderFrames.grassFrameAt = function(behaviour, elapsed)
    local tmpl = genderFrames.grassTemplate[behaviour]
    if not tmpl then return 0 end
    local anims = r32(tmpl + 0x08)
    if not isRomPtr(anims) then return 0 end
    local list = r32(anims)
    if not isRomPtr(list) then return 0 end
    local t, last = elapsed, 0
    for i = 0, 15 do
        local cmd = r32(list + i * 4)
        local img = cmd & 0xffff
        if img == 0xffff then break end            -- ANIMCMD_END
        local dur = (cmd >> 16) & 0x3f
        if dur == 0 then dur = 1 end
        last = img
        if t < dur then return img end
        t = t - dur
    end
    return last
end

genderFrames.grassRuns = function(behaviour, frame)
    local tmpl = genderFrames.grassTemplate[behaviour]
    if not tmpl then return nil end
    local images = r32(tmpl + 0x0c)
    if not isRomPtr(images) then return nil end
    -- Find a live sprite already drawing this effect and take its palette slot.
    local pal = nil
    for i = 0, 63 do
        local d = sprAddr(i)
        if (r8(d + 0x3e) & 0x01) ~= 0 and r32(d + 0x0c) == images then
            pal = (r16(d + 0x04) >> 12) & 0x0f
            break
        end
    end
    if not pal then return nil end
    frame = frame or 0
    return genderFrames.runsFromImages(string.format("grass%d:%d:%d", behaviour, pal, frame),
        images, TILE, TILE, frame, pal)
end

genderFrames.reflectiveSpans = function(left, top, width, height, who)
    -- THE GRID MUST NOT BOB.
    --
    -- The first version derived it from the tier's own anchors (originY, captured from
    -- playerScreenY). That reads the player's sprite position -- which INCLUDES pos2, and while
    -- anyone is surfing pos2 is the bob. So the entire tile grid bobbed up and down with the
    -- player by a few pixels, and the reflection was cut two or three rows early: measured
    -- 2026-08-19, ink 90..109 with the mask keeping only 90..101, where the engine's own ink ran
    -- to 103 and was covered by the pond's stone lip from 104.
    --
    -- The self-check that was supposed to catch a bad grid could not: it ran the PLAYER's own
    -- frame position through the same inverse, so both sides carried the same bias and agreed
    -- perfectly. A consistency check between two things sharing an input proves they share it.
    --
    -- So it uses the still copy of the origin captured beside the anchor. Everything else is the
    -- same inverse as before, with MAP_OFFSET folded in so ty and tx come out in the GRID
    -- coordinates the attribute lookups take.
    local baseX, baseY = genderFrames.gridBase()
    if not baseX then return nil end
    local txMin = math.floor((left - baseX) / TILE)
    local txMax = math.floor((left + width - 1 - baseX) / TILE)
    local tyMin = math.floor((top - baseY) / TILE)
    local tyMax = math.floor((top + height - 1 - baseY) / TILE)

    -- Drop the decoded masks when the map changes -- a new layout means new tilesets, and a
    -- metatile id means something else entirely under them.
    local layout = r32(0x02037318)
    if layout == 0 then return nil end
    if genderFrames.coverLayout ~= layout then
        genderFrames.coverCache, genderFrames.coverLayout = {}, layout
    end

    local gxMin = math.floor((left - baseX) / TILE)
    local gxMax = math.floor((left + width - 1 - baseX) / TILE)
    local spans = {}
    for py = math.floor(top), math.floor(top) + height - 1 do
        local gy = math.floor((py - baseY) / TILE)
        local inTile = py - baseY - gy * TILE
        local list, openFrom = {}, nil
        for gx = gxMin, gxMax do
            local id = genderFrames.metatileAt(gx, gy)
            local mask = id and genderFrames.coverMask(id, who)
            -- Off the map, or a metatile we could not decode: treat it as covering, so an unknown
            -- never becomes a reason to paint somewhere.
            -- mask == true means "this metatile covers everywhere" (see coverMask); a table is
            -- the per-pixel case; nil or false means we could not read it, and an unknown never
            -- becomes a reason to paint.
            local rowBits = 0xffff
            if type(mask) == "table" then rowBits = mask[inTile] or 0xffff end
            local tileLeft = baseX + gx * TILE
            for bx = 0, TILE - 1 do
                if (rowBits >> bx) & 1 == 0 then
                    if not openFrom then openFrom = tileLeft + bx end
                elseif openFrom then
                    list[#list + 1] = { openFrom, tileLeft + bx - 1 }
                    openFrom = nil
                end
            end
        end
        if openFrom then
            list[#list + 1] = { openFrom, baseX + (gxMax + 1) * TILE - 1 }
        end
        spans[py] = list
    end
    return spans
end

-- DOES THIS GHOST REFLECT, AND IN WHICH PALETTE -- the engine's own ground test, in one place.
--
-- Extracted 2026-08-21 when it turned out to be needed in three: the painted tier's peer-graphic
-- path (where it was written), the painted tier's CACHED WALKER path (where it never existed at
-- all, which is the whole of *"the drawn ghost don't have its reflection when standing on grass,
-- close to water"* -- a peer on foot with no special graphic takes the walker path, and that path
-- simply had no reflection code), and the hardware tier.
--
-- ASKED WHERE THE TIER DRAWS, not where the peer is. In compare mode the copies are deliberately
-- several tiles apart, so a peer out on a pond has twins standing on the grass beside it, and a
-- gate asked about the PEER happily authorises a reflection on dry land.
--
-- `store` is the caller's OWN previous-tile table, and that is not tidiness: two tiers drawing the
-- same peer in two places cannot share an answer about the ground under it.
--
-- THE PREVIOUS TILE EXPIRES. The engine's lag lasts one movement -- previousCoords is what the
-- ground-effect update compares against while a step plays out, which is what slides a reflection
-- out from under a character leaving the water instead of blinking it off. Held indefinitely, a
-- ghost parked at the shore keeps claiming the water tile it arrived from and paints a reflection
-- across the bank: *"it draws on top of the edge as well, that sits between the grass/water"*.
-- One step is 16 frames of engine-driven movement, and standing still collapses previous back
-- onto current, exactly as it is for a character who has stopped.
genderFrames.reflectPalFor = function(store, playerId, areaId, ggx, ggy, wTiles, hTiles, palSlot)
    local lt = store[playerId]
    if lt and (lt[3] ~= areaId or frameCounter - lt[4] > 16) then lt = nil end
    local yes = genderFrames.hasReflection(ggx, ggy, lt and lt[1], lt and lt[2], wTiles, hTiles)
    local cur = store[playerId]
    if not cur or cur[5] ~= ggx or cur[6] ~= ggy then
        -- Slots 1,2 are the tile stepped FROM; 5,6 the current one, so "did it change" is
        -- answered without losing the previous.
        store[playerId] = {
            cur and cur[5] or ggx, cur and cur[6] or ggy, areaId, frameCounter, ggx, ggy,
        }
    end
    -- The KIND comes back as a second value: "ice" reflections are still and "water" ones ripple,
    -- and only the caller knows which of its two draw paths that has to reach.
    return yes and genderFrames.reflectionPalette[(palSlot or 0) & 0x0f] or nil, yes or nil
end

genderFrames.reflectionPalette = {
    -- Every entry from the game's own table, so a graphic that lives in an NPC slot reflects
    -- correctly too rather than borrowing the player's colours. The reflection slots map to
    -- themselves, which is what makes a reflection of a reflection harmless.
    [0] = 1, [1] = 1, [2] = 6, [3] = 7, [4] = 8, [5] = 9,
    [6] = 6, [7] = 7, [8] = 8, [9] = 9, [10] = 11, [11] = 11,
}


genderFrames.runsForPeerGfx = function(gfx, animNum, animIdx)
    local info = graphicsInfo(gfx)
    if not info or info.anims == 0 or info.images == 0 then return nil end

    local animPtr = r32(info.anims + (animNum or 0) * 4)
    if not isRomPtr(animPtr) then return nil end
    local cmd = r32(animPtr + (animIdx or 0) * 4)
    local imageIndex = cmd & 0xFFFF
    local hFlip = ((cmd >> 22) & 1) == 1
    -- A loop/jump command rather than a frame: its "imageValue" is a marker, not an index. Frames
    -- are bounded by the graphic's own image count, so an out-of-range value is the tell.
    local frameCount = info.size > 0 and (info.width * info.height // 2) or 0
    if frameCount == 0 then return nil end
    -- NOT EVERY COMMAND INDEX IS A FRAME, and giving up on one costs the whole graphic.
    --
    -- An animation is a list of commands, and the last of them is a marker -- an end or a jump --
    -- whose value is not an image index. A peer can legitimately report an index sitting on one:
    -- the Acro Bike's wheelie hop arrived as animation 21, command 1, while the engine held the
    -- last frame. Returning nil there sent the whole draw to the cached WALKER, so a peer hopping
    -- along on a bike flickered onto its feet -- *"the drawn ghost is getting of their bike all
    -- the time visually while im hopping and moving around on the bike"*, and the fallback was
    -- silent until a log line was added at it.
    --
    -- Walking back to the last real frame is what the engine displays anyway: a marker command
    -- does not change the picture, it decides what plays next. So the worst case becomes the frame
    -- the peer is actually showing, instead of a different character.
    if imageIndex * frameCount >= 0x10000000 then
        local found = nil
        for i = 0, (animIdx or 0) - 1 do
            local c = r32(animPtr + i * 4) & 0xFFFF
            if c * frameCount < 0x10000000 then found = c end
        end
        if not found then return nil end
        -- Logged, not counted: which (animation, index) pair needed walking back, and to what.
        -- A substitution that fires constantly, or lands on a frame from the wrong stride, looks
        -- like a peer doing something it never did -- and this path is new enough not to be
        -- trusted silently. COMPARE_TIERS only, and throttled by the pair so a steady state
        -- prints once rather than sixty times a second.
        if COMPARE_TIERS then
            local k = string.format("%s:%s:%s", tostring(gfx), tostring(animNum), tostring(animIdx))
            if genderFrames.walkedBackKey ~= k then
                genderFrames.walkedBackKey = k
                logFile(string.format("DRAWN WALKED BACK: gfx=%s anim=%s/%s -> image %s",
                    tostring(gfx), tostring(animNum), tostring(animIdx), tostring(found)))
            end
        end
        imageIndex = found
        hFlip = ((r32(animPtr) >> 22) & 1) == 1
    end

    local runs = genderFrames.runsFromImages(
        string.format("g%d:%d", gfx, imageIndex), info.images, info.width, info.height,
        imageIndex, info.paletteSlot)
    if not runs then return nil end
    -- The image index comes back too: a reflection is this exact frame in another palette, and
    -- resolving it twice invites the two halves disagreeing about which frame they describe --
    -- the defect shape this adapter has hit more than any other.
    return runs, info, hFlip, imageIndex
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

-- ghosts[playerId] = { objId, sprId, localId, tileStart, tileCount, mapX, mapY }
local ghosts = {}

-- WHAT ANOTHER PEER ALREADY HOLDS. The engine's active bit answers "is this slot in use by the
-- GAME", which is not the same question as "is it in use by US", and the gap between the two is a
-- real bug: standing in a doorway, the engine culls ghost slots constantly (a door is a warp
-- tile), and a culled slot reads inactive for the frames between the cull and the respawn. A
-- second peer searching in that window is handed a slot the first peer's record still names, and
-- from then on BOTH peers write the same object every frame. On screen that is one ghost
-- teleporting between two places several times a second -- reported 2026-08-20 as *"both ghosts
-- in emerald are blinking in/out all the time ... when i stand right infront of a door"*, and
-- visible in the log as one object slot alternating between two peers' positions every 8 frames.
-- Written as two inline loops rather than one shared helper, and that is not a style choice:
-- Lua caps a chunk at 200 locals and this file sits against that ceiling, so a new top-level
-- `local function` here fails the whole script to load ("too many local variables", hit while
-- making this very fix). Locals inside a function are free.
local function findFreeObjectSlot()
    local claimed = {}
    for _, g in pairs(ghosts) do claimed[g.objId] = true end
    for i = 15, 0, -1 do
        if (r8(objAddr(i) + 0x00) & 0x01) == 0 and not claimed[i] then return i end
    end
    return nil
end

-- Downward: the engine's own CreateSprite takes the lowest free index, so taking a high one keeps
-- the ghost out of the way of whatever the game allocates next.
local function findFreeSpriteSlot()
    local claimed = {}
    for _, g in pairs(ghosts) do claimed[g.sprId] = true end
    for i = MAX_SPRITES - 1, 0, -1 do
        if (r8(sprAddr(i) + 0x3e) & 0x01) == 0 and not claimed[i] then return i end
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
-- DECLARED ABOVE findFreeObjectSlot, not here: the slot searches have to see what is already
-- claimed, and a local declared after them would be a nil global at their call site -- the exact
-- late-binding trap this file has been bitten by before (see the xmapGhosts note below).
-- Registered for the cross-map rebase, which is defined a thousand lines EARLIER than this local
-- and cannot close over it -- referencing `ghosts` there silently read a nil global and killed
-- every frame on the far side of a seam until the guard's console-only error finally reached a
-- file (pitfalls.md, 2026-08-20).
genderFrames.xmapGhosts = ghosts

-- Forward declaration: despawnGhost below must ask "is this still ours" before it destroys
-- anything, and the identity check itself reads the save block pointer defined further down.
local ghostAlive
-- Forward declarations for the surf-blob code, which is defined further down (it needs the sprite
-- and tile helpers above it) but is used by spawnGhost/despawnGhost, which come first. Without
-- these the names resolve to nil GLOBALS at the call site -- the same forward-reference trap that
-- has now bitten three times in this file (despawnAllGhosts, frameCounter, and this).
local despawnSurfBlob
local spawnSurfBlob
local SURFING_GFX

-- Tile ranges we could not free at the time, because we were in a battle and the bitmap was not
-- ours to write. Settled on the way back to the overworld. On genderFrames for the ceiling reason.
genderFrames.pendingTileFrees = {}
genderFrames.deferredTileFrees = {} -- swap-time frees, held a few frames; see swapGhostGraphicInPlace
-- Queue a deferred free ONCE per range: the same tiles can be reached by several despawn paths
-- (a ghost's body, its blob, its shadow, a hardware release), and queuing twice means freeing
-- twice, which is the double-free described at the service point.
function queueTileFree(entry)
    for _, e in ipairs(genderFrames.deferredTileFrees) do
        if e.start == entry.start then return end
    end
    genderFrames.deferredTileFrees[#genderFrames.deferredTileFrees + 1] = entry
end

local function freeGhostTiles(g)
    -- NEVER FREE ACROSS A STATE LOAD. The load rewinds the engine's allocation bitmap to the
    -- save-time session's state, so the ranges our records name no longer correspond to bits we
    -- own -- clearing them un-allocates whatever THAT session had there, and the next allocation
    -- lands on live tiles. This is precisely the forget-don't-free rule detectStateLoad preaches,
    -- and its own despawn sweep violated it through this helper: found 2026-08-21 as *"we also
    -- regressed the OAM ghost, as it glitch/goes away when using a save state now"*.
    if genderFrames.stateLoadPurge then return end
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
    -- NEVER WRITE INTO THE ARRAYS OUTSIDE THE OVERWORLD, not even to clean up after ourselves.
    --
    -- `ghostAlive` asks the OBJECT array, which a battle leaves alone -- but the SPRITE array it
    -- reuses, so the slot this would blank is whatever the battle put there. Found live
    -- 2026-08-19: the adapter was reloaded during a wild battle and the user's next words were
    -- "reloading the script mid fight made it look weird, removed the hp bar of the wild pokemon".
    -- That is our despawn write landing on a battle sprite.
    --
    -- **This is a SHIPPED bug, not a dev-loader one.** `resetBridge()` despawns every ghost when
    -- the bridge drops, and a bridge drop during a battle -- a core restart, a network blip -- is
    -- ordinary. Dropping the bookkeeping and touching nothing is correct anyway: the engine
    -- reclaims both the slot and the tiles when it tears the map down, which is exactly what the
    -- "not ours any more" case below has always relied on.
    if not inOverworld() then
        -- The tile range is REMEMBERED, not forgotten. Dropping it silently leaks those bits in
        -- the engine's own allocation bitmap: nothing frees them, the engine's later allocations
        -- have less VRAM to work with, and when it finally runs short its own NPCs render from
        -- whatever tiles it can get. That is what the user saw after a long session of reloads --
        -- *"a garbled 3rd ghost... has collision, and i can talk to it"*, which is not a ghost at
        -- all but a real NPC drawn with the wrong tiles.
        --
        -- It cannot be freed here: outside the overworld those tiles belong to the battle, and
        -- writing the bitmap is exactly the corruption the guard exists to prevent. So it is
        -- queued, and settled on the way back in, where the identity test can say whether the
        -- range is still ours to free or whether the engine has already reset the bitmap itself.
        local q = genderFrames.pendingTileFrees
        q[#q + 1] = { objId = g.objId, tileStart = g.tileStart, tileCount = g.tileCount }
        ghosts[playerId] = nil
        return
    end
    if ghostAlive(g) then
        despawnSurfBlob(g)
        despawnGhostShadow(g)
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

-- DEV ONLY. Forces every ghost to be drawn as a given graphicsId regardless of what the peer
-- reports, so the ASYMMETRIC case can be tested at all: loopback echoes your own state, so a peer
-- who is on a bike while you walk cannot otherwise be produced without a second machine. Unset in
-- normal use. Same env-var pattern as MESHGHOST_LOOPBACK_TRAIL above.
--   Brendan: 0 normal, 1 Mach Bike, 63 Acro Bike, 2 surfing, 137 fishing
--   May:    89 normal, 90 Mach Bike, 91 Acro Bike, 92 surfing, 138 fishing
-- Read as a GLOBAL first, then the environment. The global is what makes this usable during a
-- session: the dev loader loads its targets in order, so a one-line script that sets
-- MESHGHOST_FORCE_GHOST_GFX and is listed BEFORE the adapter changes the value on a reload --
-- whereas an environment variable would need the whole emulator restarted.
local FORCE_GHOST_GFX = tonumber(MESHGHOST_FORCE_GHOST_GFX
    or os.getenv("MESHGHOST_FORCE_GHOST_GFX") or "")

-- What a ghost SHOULD be drawn as. Applied at the decision site rather than inside spawnGhost, so
-- that "has the peer changed graphic?" compares like with like -- forcing it inside the spawn
-- meant the forced value never matched what the peer reported, and the ghost was torn down and
-- rebuilt every single frame.
-- OFF BY DEFAULT, and this is a deliberate gate rather than an oversight.
--
-- Switching a ghost to a peer's own graphic renders CORRUPTED for every special state, confirmed
-- on screen 2026-08-18. The cause is structural: normal Brendan/May is 16x32 with one OAM and
-- subsprite table, while both bikes, surfing, underwater and fishing are all **32 wide** with a
-- DIFFERENT OAM and a different subsprite table. This code copies both pointers but also forces
-- `subspriteTableNum = 0`, while the engine manages that field itself -- so the layout it draws
-- with does not match the tiles, and the ghost comes out as scrambled pieces.
--
-- Until that is solved, a peer's graphic is used only when it is the SAME graphic the local
-- player is using -- which changes nothing visually but keeps the wire format and the plumbing
-- live and exercised. Set MESHGHOST_GHOST_PEER_GFX to opt in and continue the investigation.
local PEER_GFX_ENABLED = MESHGHOST_GHOST_PEER_GFX or os.getenv("MESHGHOST_GHOST_PEER_GFX")

local function wantedGfx(remote)
    if FORCE_GHOST_GFX then return FORCE_GHOST_GFX end
    if PEER_GFX_ENABLED then return remote and remote.gfx or nil end
    return nil
end

-- TWO TIERS OF GHOST, and which peer gets which.
--
-- The user's rule, 2026-08-19: *"npc's always shown, ghosts try to fill, drawn otherwise"* and
-- *"i don't want things to pop in/out all the time. i want every player/ghost to be visible all
-- the time instead."* The engine holds 16 object events for the whole map while a screen shows
-- ~150 tiles, so "everyone visible" and "everyone spawned" cannot both be true. Hence two tiers:
-- spawn real object events while slots last, and DRAW the overflow with the pixel path this
-- adapter used before the spawn work existed. Design and its costs: agent_docs/ideas.md's
-- "Spawn to the game's cap, then DRAW above it"; the costs are also registered in BANDAGES.md.
--
-- Everything about the tiers lives on this one table rather than in half a dozen locals, because
-- this file's scope sits one or two names below Lua's hard ceiling of 200 locals per function --
-- past it the script does not misbehave, it fails to parse.
--
--   blockedFrame / lastLogFrame -- see spawnGhost's out-of-slots branch.
--   drawn        -- is the drawn overflow tier on (see FLAGS.md; off until occlusion is settled).
--   hysteresis   -- tiles of "stickiness" a spawned ghost keeps when ranked against a peer that
--                   is not spawned. Without it two peers at nearly equal distance swap tiers
--                   every few frames as either one drifts, and the swap is a despawn+respawn.
--   reserve      -- object slots never handed to a ghost, so the engine keeps somewhere to put a
--                   character of its OWN that scrolls into view. The map's cast comes first: that
--                   is the user's rule, and an NPC that fails to load is a bug in the game, not a
--                   missing ghost.
--   castMax      -- per area_id, the most game-owned objects ever seen active there. The count
--                   varies with the camera (measured 2026-08-19: Littleroot read 1, 2 and 3 at
--                   different spots), so budgeting against the CURRENT count would hand out slots
--                   that the engine wants back two steps later. The running maximum is the
--                   honest budget: it only ever gives away slots the map has never needed.
tiering = {
    slide = { step = 0, legs = 0, paused = 0 },
    blockedFrame = nil,
    lastLogFrame = nil,
    drawn = MESHGHOST_EMERALD_DRAWN_OVERFLOW or os.getenv("MESHGHOST_EMERALD_DRAWN_OVERFLOW"),
    hysteresis = 3,
    reserve = 1,
    castMax = {},
    -- MESHGHOST_EMERALD_ANIM_TRACE -- a PROBE, off unless asked for. It writes a per-frame line
    -- comparing the player's sprite animation state with each ghost's, and the real OAM entry
    -- both are drawn from. That trace is what finally located the fishing misalignment after two
    -- guessed fixes failed the same way, and bikes and surfing are the same class of state, so it
    -- is kept rather than deleted (adapters/_template/probes.md).
    --
    -- Deliberately NOT folded into MESHGHOST_COMPARE_TIERS, though it was written there: compare
    -- mode is the intended dev default for judging the drawn tier, and leaving per-frame file I/O
    -- inside it would tax every future comparison with the cost of a diagnostic nobody asked for
    -- -- the exact trap CLAUDE.md records. A field, not a top-level local: this chunk is at Lua's
    -- 200-local ceiling.
    animTrace = (MESHGHOST_EMERALD_ANIM_TRACE
        or os.getenv("MESHGHOST_EMERALD_ANIM_TRACE")) and true or false,
    animTraceBuf = nil,
}

-- WHERE THE GAME'S OWN UI IS, so the drawn tier can stay out of it.
--
-- A spawned ghost is hidden behind a text box by the engine, for free. A drawn one is painted
-- after the PPU has finished and would sit on top of the text the player is reading, which is why
-- the drawn tier shipped off until this existed.
--
-- THE SOURCE IS THE GAME'S OWN TILEMAP, not the LCD. The hardware route was tried first and is a
-- dead end: the GBA's window registers (WIN0H/WIN0V plus DISPCNT's enable bits) change every frame
-- during ordinary walking, so they describe the display rather than the panel
-- (probes/uiregion_probe.lua keeps that negative result; the same trap caught the Game Boy's
-- window layer on Crystal). Asking what the game DREW works, and was measured on 2026-08-19 with
-- probes/textbox_probe.lua:
--   * nothing open   -- BG0 is entirely EMPTY; the map lives on BG2/BG3.
--   * a text box     -- BG0 rows 14-19, every column: the bottom six rows, full width.
--                       (Talked to the NPC in the Littleroot house; corroborated on screen.)
--   * the START menu -- BG0 rows 0-13, right-hand columns only: the panel, and nothing else.
-- So BG0 is the UI layer and it is quiet until the game puts a panel on it. That is the whole
-- detector, and it is style- and revision-independent in the way tile IDs would not be: it asks
-- WHERE something was drawn, never WHICH tiles were drawn.
--
-- The tilemap's address comes from the background's own control register (BG0CNT, screen base
-- block in bits 8-12, 2KB units from VRAM), so no game symbol or decomp address is involved and
-- nothing here can go stale against a ROM revision.
local BG0CNT_ADDR = 0x04000008
local VRAM_ADDR = 0x06000000

-- Rebuilt every SCAN_EVERY_FRAMES frames and reused in between: a panel opening one frame late is
-- invisible, and scanning 20x30 cells every frame would be the expensive shape this project keeps
-- warning about. Rows are stored as {x1, x2} in SCREEN PIXELS -- per row, because the menu covers
-- different columns than the text box and a single rectangle would clip the wrong screen area.
tiering.panelRows = {}
tiering.panelScannedAt = nil
-- THE BANNER'S WINDOW IS RE-READ EVERY FRAME, the tilemap scan is not.
--
-- The scan is throttled to every fourth frame and needs two agreeing samples before it changes,
-- which is right for a flickery tilemap heuristic and wrong for a hardware rectangle the game
-- animates per frame. Applying the window inside the scan meant the banner's SHRINK reached our
-- clip up to eight frames late: measured, the banner cleared the ghost's row at f=265 while the
-- painted body stayed hidden through f=268, with the jump onto the blob at f=273 -- which is the
-- user's *"gets cut off slightly before it jumps onto the blob"*. So the scan caches raw rows and
-- the window intersection is applied to a copy on EVERY call.
tiering.applyShowMonWindow = function(rows)
    local showMon = nil
    for t = 0, 15 do
        local ta = 0x03005e00 + t * 0x28
        if r8(ta + 0x04) == 1 then
            local fn = r32(ta + 0x00)
            if fn == 0x080b8555 or fn == 0x080b88b5 then showMon = ta break end
        end
    end
    -- THE FRAME THE BANNER ENDS, THE CACHE IS A LIE. The tilemap scan is throttled to every
    -- fourth frame, and the banner's rows stay written in the tilemap until the game restores the
    -- background -- so for up to four frames after the effect's task is gone, the cached rows
    -- still claim full-width coverage while the window that used to trim them no longer exists.
    -- Everything painted in those rows is clipped to nothing: measured as a single isolated
    -- invisible frame three frames after the banner, which is the user's *"vanishes just
    -- slightly, barely noticable"* right before the ghost jumps onto the blob. Dropping the
    -- cache's timestamp forces a fresh scan on the very next call.
    if not showMon then
        if tiering.showMonWasLive then
            -- DROP the cached rows, do not merely schedule a rescan: invalidating the timestamp
            -- still returns the stale rows for THIS frame, which is the one-to-two frame blank
            -- the user sees. The banner's rows are stale by definition the moment its task is
            -- gone -- it is the only thing that wrote them -- so the honest answer for this frame
            -- is "no panel", and a real one (a text box) is picked up by the next scan.
            -- AND KEEP IGNORING THE TILEMAP FOR A FEW FRAMES. The banner's rows stay WRITTEN
            -- after its task is gone -- the game clears them in its own restore step -- so
            -- trusting the tilemap again immediately re-clips everything, which is why the blank
            -- survived as a single frame per cycle after the first attempt at this. Eight frames
            -- covers the restore twice over. Nothing else can legitimately draw a panel in that
            -- window: a text box needs a script, and the surf sequence runs none.
            tiering.showMonWasLive = nil
            tiering.panelScannedAt = nil
            tiering.panelRows, tiering.panelPrev = {}, {}
            tiering.panelBlankUntil = frameCounter + 8
            return {}
        end
        if tiering.panelBlankUntil and frameCounter < tiering.panelBlankUntil then
            tiering.panelScannedAt = nil
            return {}
        end
        return rows
    end
    tiering.showMonWasLive = true
    -- THE RESTORE STEPS ARE NOT COVERAGE. The effect's last steps put the banner away, and on
    -- its final frame the task RESETS its stored window to the full screen (measured: state 6,
    -- v=0..160) -- a reset, not a claim. Clipping to that blanked the painted ghost for exactly
    -- one frame, three frames before it jumps onto the blob, which is the user's *"vanishes just
    -- slightly, barely noticable"*. From RestoreBg onward there is no banner to hide behind, so
    -- there is no panel: sState is data[0] (field_effect.c:2552, sFieldMoveShowMonOutdoors's
    -- function table -- 5 is RestoreBg, 6 is End).
    if r16(showMon + 0x08) >= 5 then
        tiering.showMonWasLive = nil
        tiering.panelScannedAt = nil
        tiering.panelRows, tiering.panelPrev = {}, {}
        tiering.panelBlankUntil = frameCounter + 8
        return {}
    end
    local wh = r16(showMon + 0x08 + 1 * 2)
    local wv = r16(showMon + 0x08 + 2 * 2)
    local x1, x2 = (wh >> 8) & 0xff, (wh & 0xff) - 1
    local y1, y2 = (wv >> 8) & 0xff, (wv & 0xff) - 1
    local out = {}
    for row, span in pairs(rows) do
        local rTop, rBot = row * 8, row * 8 + 7
        if not (rBot < y1 or rTop > y2 or x2 < x1) then
            local a, b = span[1], span[2]
            if a < x1 then a = x1 end
            if b > x2 then b = x2 end
            if b >= a then out[row] = { a, b } end
        end
    end
    return out
end

tiering.scanPanel = function()
    local SCAN_EVERY_FRAMES = 4
    if tiering.panelScannedAt and frameCounter - tiering.panelScannedAt < SCAN_EVERY_FRAMES then
        return tiering.applyShowMonWindow(tiering.panelRows)
    end
    tiering.panelScannedAt = frameCounter

    local rows = {}
    -- Dev override: pretend the game drew a full-width panel from this row down, so the clipping
    -- path can be exercised without a real panel (FLAGS.md).
    local fake = tonumber(MESHGHOST_EMERALD_FAKE_PANEL_ROW
        or os.getenv("MESHGHOST_EMERALD_FAKE_PANEL_ROW") or "")
    if fake then
        for row = fake, 19 do rows[row] = { 0, 239 } end
        tiering.panelRows = rows
        return rows
    end

    local base = VRAM_ADDR + ((memory.read_u16_le(BG0CNT_ADDR) >> 8) & 0x1F) * 0x800
    for row = 0, 19 do
        local first, last
        for col = 0, 29 do
            if (memory.read_u16_le(base + (row * 32 + col) * 2) & 0x3FF) ~= 0 then
                first = first or col
                last = col
            end
        end
        -- A row is stored only if the game drew something in it, so the common case (no panel at
        -- all) leaves an empty table and costs the draw path one nil lookup per run.
        if first then rows[row] = { first * 8, last * 8 + 7 } end
    end
    -- ONLY ROWS PRESENT IN TWO CONSECUTIVE SCANS CLIP. Riding at speed, this scan flickered
    -- between "nothing" and "panel rows 0-4" every few samples -- the map-name banner's tilemap
    -- redraws seen mid-flight -- and those five rows are exactly the band a trailing ghost's hat
    -- occupies when the player rides DOWN (trailing UP-screen), which is why the drawn ghost's
    -- hat vanished only in that direction while every pixel-level instrument measured the paint
    -- complete: the clip ate it after emission, 248 runs counted. A REAL panel -- the text box,
    -- the START menu, the banner while actually displayed -- is rock-stable across scans, so
    -- requiring two in a row suppresses only the flicker, at the cost of one scan interval
    -- (4 frames) of clip latency when a real panel opens.
    local out = {}
    for row, span in pairs(rows) do
        if tiering.panelPrev and tiering.panelPrev[row] then out[row] = span end
    end
    -- ROWS 0-4 ON THE LEFT NEED A STREAK, not a time window. The only thing the game puts there
    -- is the map-name banner. A REAL banner is rock-stable in the tilemap for ~2 seconds; the
    -- mid-ride redraw flicker that was eating a trailing ghost's hat alternates within a few
    -- scans and never holds five in a row. A first attempt gated these rows to a window after a
    -- map change instead -- wrong, because riding away from a fresh crossing is exactly when the
    -- user tests, so the window re-admitted the flicker for their whole ride. The START menu also
    -- reaches these rows but on the RIGHT half; spans starting past midscreen are untouched.
    tiering.bannerStreak = tiering.bannerStreak or {}
    for row = 0, 4 do
        local leftSpan = rows[row] and rows[row][1] < 120
        tiering.bannerStreak[row] = leftSpan and (tiering.bannerStreak[row] or 0) + 1 or 0
        if out[row] and out[row][1] < 120 and tiering.bannerStreak[row] < 5 then
            out[row] = nil
        end
    end
    tiering.panelPrev = rows
    tiering.panelRows = out
    return tiering.applyShowMonWindow(out)
end

-- Say which renderer this session is running, once, at load. "Is the drawn tier on?" was
-- guessed at twice during its own bring-up because nothing on screen or in the log answered it.
console.log("MeshGhost: drawn overflow tier = " .. (tiering.drawn and "ON" or "off"))
if COMPARE_TIERS then
    console.log("MeshGhost: PROBE FLAG IN USE -- MESHGHOST_COMPARE_TIERS: the loopback ghost is "
        .. "rendered twice, spawned 2 tiles right and painted 2 tiles left. Dev only.")
end
if tiering.animTrace then
    console.log("MeshGhost: PROBE FLAG IN USE -- MESHGHOST_EMERALD_ANIM_TRACE: writing a per-frame "
        .. "player-vs-ghost animation trace to probes/animtrace.log. Dev only, and it costs a "
        .. "file write every 120 frames.")
end

-- How many object slots ghosts may hold on this map right now. Counted from the array itself
-- rather than from any table of ours: "active, and not carrying our localId" is the same test the
-- orphan sweep trusts, and it cannot drift from reality the way a bookkeeping count can.
tiering.budget = function(localAreaId)
    local cast = 0
    for i = 0, 15 do
        local a = objAddr(i)
        if (r8(a) & 0x01) == 1 and r8(a + 0x08) ~= GHOST_LOCAL_ID then cast = cast + 1 end
    end
    local seen = tiering.castMax[localAreaId] or 0
    if cast > seen then
        seen = cast
        tiering.castMax[localAreaId] = cast
    end
    local budget = 16 - seen - tiering.reserve
    if budget < 0 then budget = 0 end
    -- Dev override (FLAGS.md): cap how many peers may hold an object slot, so the DRAWN tier can
    -- be exercised without a crowd. Proving the panel clipping needs a drawn ghost and a text box
    -- in the same frame, and reaching the real cap means ~14 synthetic peers, which means a
    -- second relay and a load generator -- for a question one peer can answer. Set it to 0 and the
    -- loopback ghost itself becomes the drawn tier's problem. Deliberately re-read every call so
    -- it can be flipped mid-session by a one-line loader script.
    local cap = tonumber(MESHGHOST_EMERALD_MAX_SPAWNED
        or os.getenv("MESHGHOST_EMERALD_MAX_SPAWNED") or "")
    if cap and cap < budget then budget = cap end
    return budget
end

-- NEAREST WINS, not first to arrive. Join order is the worst possible answer -- it makes the
-- quality of a peer's ghost permanent and arbitrary -- while distance puts the engine's real
-- objects where the player is actually looking closely, and leaves the approximations out at the
-- edge of the screen where the difference is hardest to see. Returns the set of player_ids that
-- should hold an object slot this frame; everyone else in the area is the drawn tier's problem.
tiering.chooseSpawned = function(localAreaId, playerX, playerY)
    -- QUIET AFTER A STATE LOAD: the wire is stale by definition. The core keeps echoing the last
    -- local_state it received -- the PRE-load world -- until our first post-load send round-trips
    -- (2-4 frames), and acting on that echo re-created the pre-load ghost in full on the load
    -- tick itself: measured 2026-08-21, "surf blob for gfx 2" logged on the very frame of a
    -- water-to-grass load, then a swap back to a walker two frames later. That churn of
    -- alloc/free/swap against a just-rewound world is where this adapter's transition bugs live,
    -- and it is what the user kept catching as *"the OAM glitch if going from surfing and using a
    -- savestate back to land"*. Twelve frames of empty tiers is a fifth of a second, behind the
    -- load's own screen blink; the painted tier stays live, so nothing pops.
    if genderFrames.loadQuietUntil and frameCounter < genderFrames.loadQuietUntil then
        return {}
    end
    local budget = tiering.budget(localAreaId)
    local ranked = {}
    for playerId, remote in pairs(remotes) do
        -- A translated cross-map peer may stand up to 10 tiles past the edge (its existence
        -- margin), but a real OBJECT cannot: past the engine's 7-tile border its grid coordinate
        -- goes negative and a u16 write wraps it across the map. Outside the border it simply
        -- takes no slot -- it exists, and promotes to spawned at the border, before the screen.
        -- FAIL OPEN: until the self-location scan has produced real map dimensions, ourW/ourH are
        -- 0 and this gate would refuse EVERY spawn -- measured live as ghosts=0 with a same-map
        -- peer standing on the player. Cross-map peers cannot exist before the scan finishes
        -- (translation needs the same table), so the ungated case is exactly the old behaviour.
        local xmW, xmH = genderFrames.xmap.ourW, genderFrames.xmap.ourH
        if remote.areaId == localAreaId
            and (xmW == 0 or (remote.x >= -7 and remote.y >= -7
                and remote.x <= xmW + 6 and remote.y <= xmH + 6))
        then
            local dx, dy = remote.x - playerX, remote.y - playerY
            local d = math.sqrt(dx * dx + dy * dy)
            -- The hysteresis band, applied as a discount to whoever already has a slot: a peer
            -- must be MORE than this much closer to take one away, so a pair drifting past each
            -- other cannot trade tiers frame after frame.
            if ghosts[playerId] then d = d - tiering.hysteresis end
            ranked[#ranked + 1] = { id = playerId, d = d }
        end
    end
    table.sort(ranked, function(a, b)
        -- player_id as the tiebreak, so the order is stable rather than pairs()-random when two
        -- peers stand on the same tile -- an unstable order is a despawn/respawn every frame.
        if a.d == b.d then return a.id < b.id end
        return a.d < b.d
    end)
    local set = {}
    for i = 1, math.min(#ranked, budget) do set[ranked[i].id] = true end
    return set
end

local function spawnGhost(playerId, mapX, mapY, orientation, wantGfx)
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
        -- OUT OF SLOTS, and this is a normal state, not an error: the engine's object array holds
        -- 16 entries shared with every NPC, so a busy room simply offers more peers than the game
        -- can hold. Two things are therefore deliberate here.
        --
        -- ONE: the message is throttled. It used to print once per unplaceable peer per frame, and
        -- BizHawk's console.log is a GUI append -- measured 2026-08-19 with synthetic peers, 24
        -- peers in a 3-NPC town (13 ghosts placed, 11 refused) dropped the emulator from 60fps to
        -- 3, and 36 peers to 1. That is the adapter making the game unplayable to say "no" loudly,
        -- which is worse than any missing ghost.
        --
        -- TWO: the refusal is recorded, so syncRemoteGhosts can stop asking for the rest of this
        -- frame. Once one spawn has failed for want of a slot, every other spawn this frame will
        -- fail the same way -- the array does not grow mid-frame -- and each attempt re-scans both
        -- arrays before finding that out.
        tiering.blockedFrame = frameCounter
        if not tiering.lastLogFrame or frameCounter - tiering.lastLogFrame >= 300 then
            tiering.lastLogFrame = frameCounter
            console.log("MeshGhost: no free slot for a ghost (objects or sprites full) -- more "
                .. "peers here than this map can hold. Further refusals are not logged for 5s.")
        end
        return nil
    end

    local sb1 = r32(GSAVEBLOCK1PTR_ADDR)
    local playerGfx = r8(pObj + 0x05)
    local elevation = r8(pObj + 0x0b) & 0x0f
    -- DEV ONLY -- MESHGHOST_EMERALD_GHOST_ELEVATION: put the ghost on a different elevation from
    -- the player, which is how this game already lets a character be walked past rather than
    -- collided with. Requested for testing (user, 2026-08-19): a ghost two tiles away that blocks
    -- is a wall in the middle of whatever is being compared. Shipped default is unset, so a ghost
    -- keeps taking the player's own elevation and behaves exactly as before.
    --
    -- **A value, not a boolean, deliberately**: which elevation makes a character non-blocking is
    -- a fact about the game that this repo has not measured, and guessing one is how a plausible
    -- number gets written into an adapter. Setting it is the experiment -- try a value, walk into
    -- the ghost, and the answer is on screen in a second.
    local devElevation = tonumber(MESHGHOST_EMERALD_GHOST_ELEVATION
        or os.getenv("MESHGHOST_EMERALD_GHOST_ELEVATION") or "")
    if devElevation then elevation = devElevation & 0x0f end
    local gx, gy = mapX + MAP_OFFSET, mapY + MAP_OFFSET
    local dir = DIR_ID[orientation] or DIR_ID.south

    -- Use the PEER's graphic when we know it. Every player state -- both bikes, surfing,
    -- underwater, fishing -- is simply a different graphicsId, so this is what makes a ghost show
    -- what the peer is actually doing rather than what this machine's player is doing.
    local playerInfo = graphicsInfo(playerGfx)
    local graphicsId = wantGfx or playerGfx
    local info = graphicsInfo(graphicsId)
    -- The palette is the constraint. A ghost borrows the palette slot already loaded for the
    -- player, so a graphic is only safe to use if it wants the SAME palette tag. Every
    -- Brendan/May state shares one tag (OBJ_EVENT_PAL_TAG_BRENDAN / _MAY), so all of them work;
    -- anything else would draw in the player's colours, which is worse than not switching.
    if not info or not playerInfo or info.paletteTag ~= playerInfo.paletteTag then
        graphicsId = playerGfx
        info = playerInfo
    end
    if not info then
        -- Was a SILENT return, and it cost most of a session: peers received, area matched, slots
        -- free, camera settled, and no ghost and no message. A refusal the log never mentions is
        -- indistinguishable from a peer who is not there. Throttled with the same counter the
        -- out-of-slots refusal uses, for the same reason -- console.log is a GUI append.
        if not tiering.lastLogFrame or frameCounter - tiering.lastLogFrame >= 300 then
            tiering.lastLogFrame = frameCounter
            console.log(string.format("MeshGhost: refusing to spawn -- no usable graphics info "
                .. "for id %s (table at %08X). Further refusals are not logged for 5s.",
                tostring(graphicsId), GOBJECTEVENTGRAPHICSINFOPOINTERS_ADDR
                    + (genderFrames.romOffset or 0)))
        end
        return nil
    end

    local tileCount = info.tileCount
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

    -- The sprite. Start from the player's -- it is a live, engine-shaped object-event sprite, and
    -- copying gives correct values for fields we would otherwise have to invent (the template
    -- pointer, flags the engine set). Then replace everything that describes WHAT IS DRAWN with
    -- the chosen graphic's own entry, so a ghost on a bike is drawn as a bike rather than as
    -- whatever this machine's player happens to be.
    local src, dst = sprAddr(playerSprId), sprAddr(sprId)
    for off = 0, SPRITE_SIZE - 1 do w8(dst + off, r8(src + off)) end

    -- OAM: take ONLY the shape and size bits from the target graphic, leaving every other field
    -- as the live sprite already had it.
    --
    -- Copying the graphic's whole 8-byte template OAM was tried first and rendered as scrambled
    -- pieces, confirmed on screen 2026-08-18. That template also carries affine mode, object mode,
    -- mosaic, priority and a zeroed matrix/x/y, and overwriting the live values with them puts the
    -- sprite out of step with the engine's own per-frame OAM building. Skipping the copy entirely
    -- renders cleanly but at the wrong width, because the special-state graphics are 32 wide where
    -- the normal one is 16. Shape and size are the only fields that describe the new graphic's
    -- dimensions, so they are the only ones taken.
    --   attr0 bits 14-15 = shape, attr1 bits 14-15 = size (struct OamData, include/sprite.h)
    local attr2 = r16(dst + 0x04)
    w16(dst + 0x04, (attr2 & 0xfc00) | (tileStart & 0x03ff))
    if info.oam ~= 0 then
        w16(dst + 0x00, (r16(dst + 0x00) & 0x3fff) | (r16(info.oam + 0x00) & 0xc000))
        w16(dst + 0x02, (r16(dst + 0x02) & 0x3fff) | (r16(info.oam + 0x02) & 0xc000))
    end

    -- The four ROM pointers that say which pixels and which animations. These cannot be
    -- synthesised, only pointed at -- and pointing at the peer's graphic instead of copying the
    -- player's is the whole of this feature.
    w32(dst + 0x08, info.anims)
    w32(dst + 0x0c, info.images)
    w32(dst + 0x10, info.affineAnims)
    -- Subsprite tables, wired the way SetSubspriteTables does (sprite.c:1655): a graphic with
    -- tables gets SUBSPRITES_ON and table 0; one without gets subsprites off, or it would be
    -- drawn through the previous graphic's layout.
    w32(dst + 0x18, info.subspriteTables)
    -- PRESERVE THE SUBSPRITE TABLE NUMBER -- forcing 0 was one visible frame of scramble.
    --
    -- A 32-wide graphic is drawn through a subsprite table, and WHICH table is chosen by the
    -- ENGINE, per frame, from the object's elevation: sElevationToSubspriteTableNum
    -- (event_object_movement.c:7733-7745) -- ordinary ground is table 1, and table 0 in
    -- sOamTables_* is EMPTY. Writing 0 here left the PPU drawing the new 16-tile frame with no
    -- layout map for exactly one frame, until UpdateObjectEventElevationAndPriority chose the
    -- real table again -- one frame of scrambled pieces at every graphic change, which is both
    -- the user's *"grey/flash ish glitched sprite"* at the start of surfing (screenshot
    -- surf_005_f4183744, near-correct VRAM measured the same frame -- so layout, not pixels)
    -- and the mechanism behind FLAGS.md's "renders corrupted" note on this path. The elevation
    -- does not change with a graphic, so the number already on the sprite is the engine's own
    -- current answer: keep it.
    local keepSubNum = r8(dst + 0x42) & 0x3f
    w8(dst + 0x42, 0)
    if info.subspriteTables ~= 0 then
        w8(dst + 0x42, keepSubNum | (1 << 6)) -- engine's table, mode ON
    end
    -- centerToCornerVec, as TrySetupObjectEventSprite computes it from the graphic's dimensions.
    w8(dst + 0x28, (-(info.width // 2)) & 0xff)
    w8(dst + 0x29, (-(info.height // 2)) & 0xff)
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
        gfx = graphicsId, -- what this ghost is currently DRAWN as, so a change can be detected
        swapAt = frameCounter, -- a spawn is a swap for the restart cooldown; see animRestart
    }
    -- A state is its animation AND its extras: a surfing rider without the Pokemon underneath is
    -- half the state, and the missing half is the one a player notices first.
    -- NOT MID-MOUNT: this is the third and last blob-spawn site (the rebuild path lands here
    -- when the in-place swap cannot run), and it spawns at the glide position -- the LAND tile
    -- during a mount jump, like the other two sites before their gates. The jump block in
    -- syncGhost owns the mount blob, at the engine-held destination.
    local rAct = remotes[playerId] and remotes[playerId].act
    local midJump = rAct and rAct >= 0x3a and rAct <= 0x3d
    if SURFING_GFX[graphicsId] and not midJump then
        local blob = spawnSurfBlob(ghosts[playerId], mapX, mapY)
        console.log(string.format("MeshGhost: surf blob for gfx %d -> sprite %s",
            graphicsId, tostring(blob)))
    elseif UNDERWATER_GFX[graphicsId] then
        -- Underwater has no companion sprite at all -- the bobbing IS the state (see
        -- spawnUnderwaterBobber). A diver spawned without it hangs perfectly still in the water,
        -- which is the half a player notices first, exactly as a rider on nothing was for surfing.
        local bob = spawnUnderwaterBobber(ghosts[playerId])
        console.log(string.format("MeshGhost: underwater bobber for gfx %d -> sprite %s",
            graphicsId, tostring(bob)))
    end
    return ghosts[playerId]
end

-- ---------------------------------------------------------------------------------------------
-- The surf blob: a state is its animation AND whatever else the game spawns with it
--
-- Giving a ghost the surfing graphic renders a rider sitting on nothing, because the blue Pokemon
-- underneath is a SEPARATE sprite. HOW THE GAME DOES THIS -- the fieldEffectSpriteId link, why
-- UpdateSurfBlobFieldEffect drives a ghost's blob as happily as the player's, the data-slot map
-- and the subpriority -- is written up as game behaviour in documentation.md's surfing section.
-- Read that first; what follows here is only the provenance of the numbers this file needs.
--
-- Built from the field effect's own sprite template rather than copied from a live blob, because
-- no blob exists unless somebody is already surfing.
--   gFieldEffectObjectTemplate_SurfBlob  0850CBC4  (SpriteTemplate: tileTag 0x00, paletteTag
--     0x02, oam 0x04, anims 0x08, images 0x0C, affineAnims 0x10, callback 0x14)
--   UpdateSurfBlobFieldEffect            08155658  (+1 for Thumb)
-- Its data slots (field_effect_helpers.c:990): data[0] bob state, data[2] object event id,
-- data[3] velocity, data[6]/data[7] previous x/y. FldEff_SurfBlob seeds velocity and prev to -1,
-- sets coordOffsetEnabled, palette 0 and subpriority 150 -- all reproduced below.
local UPDATESURFBLOBFIELDEFFECT_CB = 0x08155658 + 1
local BOB_PLAYER_AND_MON = 1
local SURFBLOB_SUBPRIORITY = 150

-- Which graphics ids ride a blob. Surfing only: underwater uses a different mechanism
-- (StartUnderwaterSurfBlobBobbing on the player's own sprite), and is not handled here.
SURFING_GFX = { [2] = true, [92] = true } -- Brendan, May

-- MESHGHOST_EMERALD_NO_BLOB (probe): spawn ghosts, but give them no blob and no underwater
-- bobber. Exists to bisect a hard failure found 2026-08-21 -- diving with the adapter loaded
-- black-screened the GAME (its show-mon effect waited forever on a Pokemon sprite that had been
-- clobbered), and turning the spawned tier off entirely cleared it. These two are the only engine
-- SPRITES that tier creates, so this switch separates "a spawned ghost" from "the field effects
-- attached to it". Never ship it set: a surfing ghost without its blob is half a state.
spawnSurfBlob = function(g, mapX, mapY)
    if MESHGHOST_EMERALD_NO_BLOB then return nil end   -- surf blob only; see NO_BOBBER
    if COMPARE_TIERS then
        local who = debug.getinfo(2, "l")
        logFile(string.format("BLOB SPAWN from line %s at tile (%d,%d) f=%d",
            tostring(who and who.currentline), mapX, mapY, frameCounter))
    end
    local tmpl = GFIELDEFFECTTEMPLATE_SURFBLOB
    local oamPtr, animsPtr = r32(tmpl + 0x04), r32(tmpl + 0x08)
    local imagesPtr, affinePtr = r32(tmpl + 0x0c), r32(tmpl + 0x10)
    if oamPtr == 0 or imagesPtr == 0 then return nil end

    local sprId = findFreeSpriteSlot()
    if not sprId or sprId == g.sprId then return nil end
    -- The blob's frames are 32x32 -- 16 tiles, same as the rider's.
    local tileStart = allocSpriteTiles(16)
    if not tileStart then return nil end

    local d = sprAddr(sprId)
    for off = 0, SPRITE_SIZE - 1 do w8(d + off, 0) end
    for off = 0, 7 do w8(d + off, r8(oamPtr + off)) end
    -- tileNum, and the palette resolved from the template's tag rather than the engine's
    -- hardcoded 0 (FldEff_SurfBlob can hardcode it; it runs when its own slot is loaded, we do
    -- not). See genderFrames.blobPalette.
    w16(d + 0x04, (r16(d + 0x04) & 0x0c00) | (tileStart & 0x03ff)
        | ((genderFrames.blobPalette() & 0x0f) << 12))
    w32(d + 0x08, animsPtr)
    w32(d + 0x0c, imagesPtr)
    w32(d + 0x10, affinePtr)
    w32(d + 0x1c, UPDATESURFBLOBFIELDEFFECT_CB)

    -- Position. NOT the rider's formula: FldEff_SurfBlob uses SetSpritePosToOffsetMapCoords,
    -- which is SetSpritePosToMapCoords (event_object_movement.c:4801) plus (8,8). That helper
    -- subtracts BOTH gTotalCameraPixelOffset and gFieldCamera, where the rider's
    -- GetMapCoordsFromSpritePos subtracts only the former -- using the wrong one put the blob a
    -- tile below the ghost. The camera terms cancel while the camera is at rest, which is the
    -- only moment a ghost is placed anyway, but they are written out so the two stay
    -- distinguishable.
    local sb1 = r32(GSAVEBLOCK1PTR_ADDR)
    local dx = -rs16(GTOTALCAMERAPIXELOFFSETX_ADDR) - memory.read_s32_le(GFIELDCAMERA_X_ADDR)
    local dy = -rs16(GTOTALCAMERAPIXELOFFSETY_ADDR) - memory.read_s32_le(GFIELDCAMERA_Y_ADDR)
    local sx = (((mapX + MAP_OFFSET) - rs16(sb1 + 0x00)) << 4) + dx + 8
    local sy = (((mapY + MAP_OFFSET) - rs16(sb1 + 0x02)) << 4) + dy + 8
    w16(d + 0x20, sx) w16(d + 0x22, sy)
    -- centerToCornerVec, which a sprite gets from CreateSprite and this one was never given.
    -- The hardware draws an OBJ from its top-left; every sprite the engine makes carries
    -- -(width/2), -(height/2) so that its POSITION means its centre. Zeroing the struct and never
    -- filling this in put the blob a full tile down and to the right of the rider it is supposed
    -- to be under -- the "renders roughly half a tile down-right" that had been recorded as
    -- unexplained since 2026-08-18. Measured 2026-08-19 with probes/surfblob_probe.lua against
    -- the PLAYER's own blob, which reads 240,240 -- i.e. -16,-16 for a 32x32 frame, the same
    -- -(w/2) the rider's own spawn path computes.
    w8(d + 0x28, (-(SURFBLOB_FRAME_PX // 2)) & 0xff)
    w8(d + 0x29, (-(SURFBLOB_FRAME_PX // 2)) & 0xff)
    w8(d + 0x43, SURFBLOB_SUBPRIORITY)
    w16(d + 0x2e, 0)                       -- data[0]: bob state, set below
    w8(d + 0x2e, BOB_PLAYER_AND_MON)
    w16(d + 0x32, g.objId)                 -- data[2]: the object this blob follows -- the GHOST
    w16(d + 0x34, 0xffff)                  -- data[3]: velocity, seeded -1
    w16(d + 0x3a, 0xffff)                  -- data[6]: previous x, seeded -1
    w16(d + 0x3c, 0xffff)                  -- data[7]: previous y, seeded -1
    w8(d + 0x3e, 0x03)                     -- inUse | coordOffsetEnabled
    w8(d + 0x3f, 0x04)                     -- animBeginning

    -- Tell the object it owns this effect, the way the engine does.
    w8(objAddr(g.objId) + 0x1a, sprId)
    g.blobSprId, g.blobTileStart = sprId, tileStart
    g.blobSince = frameCounter -- age separates a mount's fresh blob from a dismount's old one
    return sprId
end

-- A REAL SHADOW SPRITE FOR A SPAWNED GHOST, replacing a painted one.
--
-- Two things a gui overlay can never do, both reported on screen 2026-08-20: sit UNDER the
-- character, and sit under the engine's own landing DUST -- *"dust is still hidden behind the
-- shadow for the spawned ghost"*. An overlay is painted after the frame is finished, so it is in
-- front of everything the hardware drew, always.
--
-- The engine's shadow is an ordinary sprite at subpriority 148, and the only reason the adapter
-- could not use it is `UpdateShadowFieldEffect`, which re-finds its object by localId -- and a
-- ghost wears LOCALID_PLAYER, so it would follow the player. That rules out the engine's UPDATE
-- routine, not its sprite: built here and driven from Lua, it is a real hardware sprite with real
-- depth. The same reasoning that made the surf blob work.
--
-- From FldEff_Shadow (src/field_effect_helpers.c:233-247) and UpdateShadowFieldEffect (:249-274):
--   * template chosen by the graphic's shadowSize (bits 4-5 of graphicsInfo +0x0C):
--     ShadowSmall 0850C9FC, Medium 0850CA14, Large 0850CA2C, ExtraLarge 0850CA44 (pokeemerald.map)
--   * subpriority 148, coordOffsetEnabled
--   * y offset = (height >> 1) - gShadowVerticalOffsets[shadowSize], offsets {4,4,4,16}
--   * each frame: priority follows the character's, x = character's x, y = character's y + offset
--     -- pos1 only, so the shadow stays on the ground while the character arcs on pos2.
-- Fields and globals rather than locals: this chunk is at Lua's hard 200-local ceiling, where one
-- more name is a parse failure and the adapter does not load at all.
genderFrames.shadowTemplates =
    { [0] = 0x0850c9fc, [1] = 0x0850ca14, [2] = 0x0850ca2c, [3] = 0x0850ca44 }

-- WHY THE FIRST ATTEMPT RESET THE GAME, and it was not the tile allocation this file suspected.
--
-- A sprite's callback was left at 0, on the reasoning that the engine's own would re-find the
-- object by localId and follow the player. `AnimateSprites` (sprite.c:308-322) calls
-- `sprite->callback(sprite)` for EVERY sprite with inUse set, with no null check -- the engine
-- never needs one, because `sDummySprite` (sprite.c:165) seeds `SpriteCallbackDummy` and
-- `CreateSpriteAt` (:556) always copies the template's. So a zero there is a call to 0x00000000,
-- which on a GBA is the BIOS reset vector: the game restarts, exactly as the user described it
-- (*"everytime i jump with the bike, the game restarts now"*), on the first frame after a hop.
--
-- The fix is the engine's own do-nothing callback rather than a guard of ours.
--   SpriteCallbackDummy  08007428  (pokeemerald.map:6220 and .sym; the two bytes there are
--                                   70 47 = `bx lr`, a function that returns and does nothing)
-- Checked at spawn time rather than trusted: on a relocated ROM (Archipelago) that address is
-- something else, and the whole point of this entry is that a wrong callback is a reset. If the
-- `bx lr` is not there the shadow sprite is simply not built and the painted fallback stays.
genderFrames.spriteCallbackDummy = 0x08007428 + 1 -- +1 selects Thumb

-- centerToCornerVec by OAM shape/size, sCenterToCornerVecTable (sprite.c:137-157) verbatim as
-- values, indexed shape*4 + size. The hardware draws an OBJ from its top-left and every sprite the
-- engine makes carries this, so that its POSITION means its centre; a sprite built by hand and
-- never given it lands half a frame down-right, which is the bug the surf blob already had.
-- The first version of the shadow guessed -16 or -8 from the frame's byte count, which is wrong
-- for three of the four shadow sizes -- the 16x8 medium one every bike uses included.
genderFrames.ctcVec = {
    [0] = { -4, -4 }, [1] = { -8, -8 }, [2] = { -16, -16 }, [3] = { -32, -32 },   -- square
    [4] = { -8, -4 }, [5] = { -16, -4 }, [6] = { -16, -8 }, [7] = { -32, -16 },   -- horizontal
    [8] = { -4, -8 }, [9] = { -4, -16 }, [10] = { -8, -16 }, [11] = { -16, -32 }, -- vertical
}

function spawnGhostShadow(g)
    if g.shadowSprId then return g.shadowSprId end
    local gi = g.gfx and graphicsInfo(g.gfx)
    if not gi or not gi.raw then return nil end
    local size = (r8(gi.raw + 0x0c) >> 4) & 0x03
    local tmpl = genderFrames.shadowTemplates[size]
    local oamPtr, animsPtr = r32(tmpl + 0x04), r32(tmpl + 0x08)
    local imagesPtr = r32(tmpl + 0x0c)
    if oamPtr == 0 or imagesPtr == 0 then return nil end

    -- THE CALLBACK IS CHECKED BEFORE ANYTHING IS BUILT, for the reason above: a wrong one is a
    -- reset, not a glitch, and a relocated ROM makes the address wrong without changing anything
    -- here. `bx lr` or no shadow sprite.
    if r16(genderFrames.spriteCallbackDummy - 1) ~= 0x4770 then
        if not genderFrames.shadowCbWarned then
            genderFrames.shadowCbWarned = true
            logFile("shadow sprite: SpriteCallbackDummy is not where this ROM keeps it -- "
                .. "staying on the painted shadow")
        end
        return nil
    end

    local sprId = findFreeSpriteSlot()
    if not sprId or sprId == g.sprId then return nil end
    -- The frame's own byte count, from struct SpriteFrameImage {const u8 *data; u16 size;}.
    local bytes = r16(imagesPtr + 4)
    local nTiles = math.max(1, bytes // 32)
    -- PROVE THE RANGE BEFORE WRITING INTO IT, once per session. The tile allocation was this
    -- file's own prime suspect for the reset, and while it turned out to be innocent, "log the
    -- byte count and the tile range and show they are sane" was the right instinct and costs one
    -- line. A shadow is 32 (8x8), 64 (16x8), 128 (32x8) or 1024 (64x32) bytes -- anything else
    -- means the SpriteFrameImage read is wrong and the copy below would run off its range.
    if bytes == 0 or bytes > 1024 or bytes % 32 ~= 0 then
        logFile(string.format("shadow sprite: refusing a %d-byte frame (images=%08x)",
            bytes, imagesPtr))
        return nil
    end
    local tileStart = allocSpriteTiles(nTiles)
    if not tileStart then return nil end
    if not genderFrames.shadowSizeLogged then
        genderFrames.shadowSizeLogged = true
        logFile(string.format("shadow sprite: size=%d, %d bytes, %d tiles at %d..%d (VRAM %08x)",
            size, bytes, nTiles, tileStart, tileStart + nTiles - 1, 0x06010000 + tileStart * 32))
    end

    local d = sprAddr(sprId)
    for off = 0, SPRITE_SIZE - 1 do w8(d + off, 0) end
    for off = 0, 7 do w8(d + off, r8(oamPtr + off)) end
    w16(d + 0x04, (r16(d + 0x04) & 0x0c00) | (tileStart & 0x03ff))
    w32(d + 0x08, animsPtr)
    w32(d + 0x0c, imagesPtr)
    w32(d + 0x10, r32(tmpl + 0x10))
    -- A DO-NOTHING CALLBACK, not none: the engine's own would bind by localId and find the player,
    -- and a zero is a jump to the reset vector. See the note above spawnGhostShadow.
    w32(d + 0x1c, genderFrames.spriteCallbackDummy)
    w8(d + 0x43, 148)         -- subpriority: under the character, above the ground
    -- centerToCornerVec from the OAM's own shape and size, the way CalcCenterToCornerVec does it.
    local ctc = genderFrames.ctcVec[(((r16(d + 0x00) >> 14) & 0x03) * 4)
        + ((r16(d + 0x02) >> 14) & 0x03)] or { -8, -4 }
    w8(d + 0x28, ctc[1] & 0xff)
    w8(d + 0x29, ctc[2] & 0xff)
    w8(d + 0x3e, 0x03)        -- inUse | coordOffsetEnabled
    w8(d + 0x3f, 0x04)
    g.shadowSprId, g.shadowTileStart, g.shadowTiles = sprId, tileStart, nTiles
    g.shadowDrop = (gi.height >> 1) - (genderFrames.shadowDrop[size] or 4)
    -- The pixels, now, rather than waiting for an engine copy that will never come.
    local src = r32(imagesPtr)
    if isRomPtr(src) then
        local dst = 0x06010000 + tileStart * 32
        for off = 0, bytes - 4, 4 do w32(dst + off, r32(src + off)) end
    end
    return sprId
end

function despawnGhostShadow(g)
    if not g.shadowSprId then return end
    local d = sprAddr(g.shadowSprId)
    w8(d + 0x3e, (r8(d + 0x3e) & ~0x01) | 0x04)
    -- Same forget-don't-free rule as freeGhostTiles, same reason, same date.
    if genderFrames.stateLoadPurge then
        g.shadowSprId, g.shadowTileStart, g.shadowTiles = nil, nil, nil
        return
    end
    -- Deferred like the blob's, one comment up: an engine sprite's queued VBlank copy outlives
    -- its despawn by a frame.
    if g.shadowTileStart then
        queueTileFree({ g = g, start = g.shadowTileStart, count = g.shadowTiles or 1,
            at = frameCounter })
    end
    g.shadowSprId, g.shadowTileStart, g.shadowTiles = nil, nil, nil
end

-- Driven from Lua every frame, exactly as UpdateShadowFieldEffect would have.
--
-- ON as of 2026-08-21, with the reset understood: it was the NULL callback, not the tile range.
-- The suspected cause was written down as the tile allocation -- a wrong byte count from the
-- template's SpriteFrameImage overrunning OBJ VRAM -- and that was a good guess about a bad
-- symptom and simply not what happened. The byte count is correct (64 for the 16x8 medium shadow
-- every bike asks for) and is now logged and range-checked at spawn anyway, because the check is
-- one line and the next hand-built sprite deserves it.
--
-- Two guessed fixes were NOT tried in a row here: the reset was traced to a specific line of the
-- engine (`AnimateSprites` calling a sprite's callback with no null check) before anything was
-- changed. `pitfalls.md`, 2026-08-21.
--
-- A field, not a local: this chunk is at Lua's 200-local ceiling.
genderFrames.shadowSpriteEnabled = true

function updateGhostShadow(g, jumping)
    if not genderFrames.shadowSpriteEnabled then return end
    if not jumping then
        if g.shadowSprId then
            w8(sprAddr(g.shadowSprId) + 0x3e, r8(sprAddr(g.shadowSprId) + 0x3e) | 0x04)
        end
        return
    end
    if not g.shadowSprId then spawnGhostShadow(g) end
    if not g.shadowSprId then return end
    local sd, cd = sprAddr(g.shadowSprId), sprAddr(g.sprId)
    w8(sd + 0x3e, r8(sd + 0x3e) & ~0x04)                       -- visible
    -- PRIORITY FOLLOWS THE CHARACTER'S, as UpdateShadowFieldEffect does -- and priority lives in
    -- OAM attribute 2 (bits 10-11 of +0x04), not attribute 0. The first version copied bits 8-9 of
    -- +0x00, which is affineMode: it wrote a harmless zero and the shadow's background priority
    -- never moved, so a shadow would have stayed in front of a bridge the ghost walked under.
    w16(sd + 0x04, (r16(sd + 0x04) & 0xf3ff) | (r16(cd + 0x04) & 0x0c00))
    w16(sd + 0x20, rs16(cd + 0x20))
    w16(sd + 0x22, rs16(cd + 0x22) + (g.shadowDrop or 12))
end

-- UNDERWATER: THE SAME IDEA AS THE BLOB, AND A COMPLETELY DIFFERENT MECHANISM.
--
-- Surfing puts a second sprite UNDER the rider. Diving does not: the character's own sprite is
-- made to bob, by a THIRD sprite that draws nothing at all. `PlayerAvatarTransition_Underwater`
-- (src/field_player_avatar.c:888-894) sets the underwater graphic and then calls
-- `StartUnderwaterSurfBlobBobbing(objEvent->spriteId)`, which creates an invisible dummy sprite
-- whose callback nudges the NAMED sprite's y2 up and down (src/field_effect_helpers.c:1150-1176):
-- +1 every fourth frame, the direction reversing every sixteenth. The result is a slow four-pixel
-- drift, and it is the whole of what "underwater" looks like when a character is standing still.
--
-- So a ghost gets one of those dummies pointed at ITSELF, and the engine bobs it for us -- the same
-- let-the-game-do-the-work move as handing the surf blob to UpdateSurfBlobFieldEffect, and for the
-- same reason: the phase, the amplitude and the timing are then the game's rather than a number
-- copied out of a comment.
--
-- It is recorded on `g.blobSprId` deliberately, even though it is not a blob. Every teardown path
-- this file has -- despawn, map change, a graphic change away from the water -- already goes
-- through despawnSurfBlob, and the one place that must NOT write a ghost's own pos2 (the peer's
-- offset mirror, further down) already declines when that field is set. A separate field would
-- need each of them taught about it, and the one that got missed would be a ghost left bobbing on
-- dry land.
--
--   SpriteCB_UnderwaterSurfBlob  08155850  (+1 for Thumb; a static, so pokeemerald.sym not .map)
--   gDummySpriteTemplate         082EC6AC  (pokeemerald.map)
--   struct SpriteTemplate: tileTag 0x00, paletteTag 0x02, oam 0x04, anims 0x08, images 0x0C,
--     affineAnims 0x10, callback 0x14 -- the same layout spawnSurfBlob reads.
--   Its data slots: data[0] the sprite id it bobs, data[1] the step (+1/-1), data[2] the timer.
UNDERWATER_GFX = { [111] = true, [112] = true } -- Brendan, May (verified.md's graphicsId table)
SPRITECB_UNDERWATERSURFBLOB_CB = 0x08155850 + 1
GDUMMYSPRITETEMPLATE = 0x082ec6ac

-- THE UNDERWATER BOB NEEDS NO MECHANISM OF OURS AT ALL, and two attempts at one were wrong in
-- different ways before this was seen.
--
-- Attempt one reproduced the engine's dummy sprite faithfully: a sprite holding ANOTHER sprite's
-- index, nudging its y2 every fourth frame. Faithful and unsafe -- when the named slot was reused
-- our bobber wrote into whatever landed there, and during a dive that is the show-mon's Pokemon
-- picture: a wrong sprite (*"an egg instead of sharpedo"*) and an effect stuck waiting for it, so
-- the screen stayed faded to black and the GAME was stuck. Bisected against the user's own dive.
--
-- Attempt two drove the same bob from Lua. Safe, but redundant and visibly wrong: the peer's own
-- sprite offset is ALREADY on the wire (`soy`) and already applied to a ghost that has no blob --
-- so the ghost got two writers on one field and jittered (*"moving really fast/weird"*).
--
-- The right answer is the one the surf blob taught: the PEER's own offset is the authority. A
-- diver's bob rides the wire for free, at the peer's phase, with nothing to leak or fight.
function spawnUnderwaterBobber(g)
    return nil
end

despawnSurfBlob = function(g)
    if not g.blobSprId then return end
    local d = sprAddr(g.blobSprId)
    w8(d + 0x3e, (r8(d + 0x3e) & ~0x01) | 0x04) -- inUse = 0, invisible = 1
    w32(d + 0x1c, 0)
    if genderFrames.stateLoadPurge then g.blobSprId, g.blobTileStart = nil, nil return end
    -- DEFERRED, and this one has the sharpest reason of all the deferrals: the blob is an ENGINE
    -- sprite whose animation re-copies its frame EVERY frame, through the sprite-copy queue that
    -- executes at VBlank. A copy queued during the previous frame's emulation still lands after
    -- this despawn -- so tiles freed here and re-claimed in the same tick get the blob's frame
    -- stamped over whatever the new owner just loaded. Found live 2026-08-21: at a dismount the
    -- hardware tier claimed the just-freed blob tiles for its walker body, and the body rendered
    -- as a corner of the blob until the next reload -- the user's *"oam & its reflection is
    -- glitching when going back to land"*.
    if g.blobTileStart then
        queueTileFree({ g = g, start = g.blobTileStart, count = 16, at = frameCounter })
    end
    g.blobSprId, g.blobTileStart = nil, nil
end

-- ObjectEventSetHeldMovement (event_object_movement.c:4870): three object fields plus the sprite's
-- action-function index. The engine plays out the whole tile -- animation, slide, coordinates.
local function requestAction(g, action)
    local a = objAddr(g.objId)
    w8(a + 0x1c, action)
    w8(a + 0x00, (r8(a + 0x00) | 0x40) & ~0x80) -- heldMovementActive = 1, finished = 0
    w16(sprAddr(g.sprId) + 0x32, 0) -- data[2] = sActionFuncId
    -- AND GIVE THE ANIMATION BACK, because we may have taken it.
    --
    -- Mirroring a HELD peer sets the sprite's animPaused bit, which is right while the peer stands
    -- still and disastrous the moment it moves: nothing here clears it, so the engine played the
    -- step -- position, timing, everything -- with the legs frozen. That is a character travelling
    -- without moving, and the user called it exactly: *"they are 'sliding/gliding' at some parts"*.
    -- It only showed after an idle spell, which is what made it look like a movement bug rather
    -- than an animation one.
    --
    -- Done here, at the one place every step goes through, rather than in the mirror -- the mirror
    -- deliberately does not run while a peer is moving, so it is the wrong place to undo something
    -- that matters only then. `enableAnim` is the game's own switch (TryEnableObjectEventAnim,
    -- src/event_object_movement.c:7335-7343): it clears animPaused and disableAnim, then clears
    -- itself.
    --
    -- ...UNLESS THE PEER IS FORBIDDEN ONE. A slide is a movement that does not animate, and this
    -- rescue is what stopped a ghost reproducing it: the peer holds disableAnim for the whole of
    -- an ice slide, we requested the matching WALK_FAST, and then handed the animation straight
    -- back, so the ghost strode across the ice the player glided over (user, 2026-08-21: the drawn
    -- and spawned copies *"are doing the 'walking' animation instead of freezing/holding the
    -- pose"*). The bit is set on the ghost instead, which is what the engine does to the player.
    --
    -- AND IT HAS TO COME BACK OFF, on the first step after the ice. disableAnim is sticky -- the
    -- engine only ever clears it through enableAnim -- so leaving it set once would cost the ghost
    -- its walk cycle for the rest of the session, which is a far worse bug than the one being
    -- fixed. Cleared here, at the same one place every step goes through, and with enableAnim set
    -- alongside so the sprite is un-paused the way TryEnableObjectEventAnim does it.
    if genderFrames.syncNoAnim then
        w8(a + 0x01, (r8(a + 0x01) | 0x04) & ~0x08)
    elseif (r8(a + 0x01) & 0x04) ~= 0 or (r8(sprAddr(g.sprId) + 0x2c) & 0x40) ~= 0 then
        w8(a + 0x01, (r8(a + 0x01) & ~0x04) | 0x08)
        g.animSetFor = nil -- the engine owns it again; the mirror must re-arm when it takes over
    end
end

-- A CHARACTER CAN FACE ONE WAY AND MOVE ANOTHER, and only the game says so.
--
-- Asking for a step also turns the ghost, which is right nearly always and wrong exactly where the
-- engine has taken the facing away from the movement. A muddy slope is that case:
-- ForcedMovement_MuddySlope sets `facingDirectionLocked` and pushes the rider SOUTH while they go
-- on facing NORTH (src/field_player_avatar.c:567-581) -- you watch yourself slide back down still
-- looking up the hill. Measured over 527 frames of it, 2026-08-20: the ghost's facing was south on
-- 181 of them while the player's never left north.
--
-- The peer already sends its facing, and its step direction is known here, so a disagreement
-- between the two IS the locked case -- no new wire field needed. The ghost is then given the
-- peer's facing and the engine's own lock bit, so the step cannot turn it back
-- (facingDirectionLocked, bit 0x02 of byte +0x01 -- include/global.fieldmap.h:204-211, the same
-- byte whose 0x08 is the enableAnim this file already uses).
-- GLOBAL, like drawRunList and swapGhostGraphicInPlace: this chunk is at Lua's hard 200-local
-- ceiling, and one more local here is a parse failure rather than a slow script.
function lockGhostFacing(g, remote, stepDir)
    local a = objAddr(g.objId)
    local want = DIR_ID[remote.orientation]
    if want and stepDir and want ~= stepDir then
        w8(a + 0x18, (r8(a + 0x18) & 0xf0) | want)
        w8(a + 0x01, r8(a + 0x01) | 0x02)
    elseif (r8(a + 0x01) & 0x02) ~= 0 then
        -- Released the moment they agree again, or the ghost would face one way for ever.
        w8(a + 0x01, r8(a + 0x01) & ~0x02)
    end
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
--
-- WITH A WATCHDOG, because an action that never finishes strands the ghost for the rest of the
-- session: no step is issued while it is busy, so it stops following entirely. Seen twice on the
-- Acro Bike -- the in-place wheelie poses are HOLDS that run until something ends them, and at
-- least one action issued after a jump never reports finished at all.
--
-- No legitimate movement outlasts this: an ordinary step is 16 frames, the fastest is 4, a ledge
-- jump about 24. Sixty is generous enough that it can only catch something genuinely stuck, and it
-- LOGS the action id when it fires -- a watchdog that hides the fault it catches would just move
-- the bug somewhere quieter.
local function ghostIsIdle(g)
    local a = objAddr(g.objId)
    local b0 = r8(a + 0x00)
    local active = (b0 >> 6) & 0x01
    local finished = (b0 >> 7) & 0x01
    if active == 1 and finished == 1 then
        clearHeldMovement(g)
        g.busySince = nil
        return true
    end
    if active == 1 then
        g.busySince = g.busySince or frameCounter
        if frameCounter - g.busySince > 60 then
            logFile(string.format(
                "MeshGhost: a ghost was stuck %d frames in movement action 0x%02X -- freeing it",
                frameCounter - g.busySince, r8(a + 0x1c)))
            clearHeldMovement(g)
            g.busySince = nil
            return true
        end
        return false
    end
    g.busySince = nil
    return true
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

-- LOAD THE FIRST FRAME OURSELVES, so a new graphic is never worn over the old graphic's pixels.
--
-- Measured, per frame, across a rod being cast (probes/tilewatch, 2026-08-19):
--
--   f=11  ghost gfx=0    tile=44  pixels=250A6BD5   -- walker
--   f=12  ghost gfx=137  tile=44  pixels=250A6BD5   -- fishing SHAPE, walker PIXELS
--   f=13  ghost gfx=137  tile=44  pixels=AD0B1438   -- fishing pixels arrive
--
-- The engine's own tile copy is queued and executes at the next VBlank, so there is always exactly
-- one frame where the sprite has the new graphic's 32-wide shape and the previous graphic's
-- content. That single frame is the snap: the user, with the painted copy beside it as the
-- control, *"it still snaps compared to the drawn & player"* -- and the painted copy cannot show
-- it, because it decodes from ROM every frame and has no VRAM waiting to be filled.
--
-- So the pixels are written at the moment the graphic is applied -- the same bytes the engine will
-- copy a frame later, from the same place: images[frame] resolved through the graphic's own
-- animation table. Nothing here races the engine; it simply gets there first.
--
-- A GLOBAL because this chunk is at Lua's 200-local ceiling.
-- WHO CALLED, logged on change (COMPARE_TIERS only): five sites call this, and a pixel state that
-- oscillates every frame means two of them disagree. Naming the writer beats a tenth theory.
-- AN ANIMATION NUMBER BELONGS TO A GRAPHIC. Mirroring the peer's `sanim` onto a ghost is only
-- meaningful while the two are wearing the SAME graphic: every special state has its own animation
-- table, of its own length, so a number that means "surfing, facing south" on the peer indexes past
-- the end of a walker's table -- or, worse, lands on a real but unrelated animation.
--
-- This is the pair that goes incoherent during a transition, and it is not hypothetical: measured
-- 2026-08-21 at the start of surfing, the ghost held gfx 3 (the field-move pose) while being fed
-- anim 20 (surfing) -- the graphic swap and the animation mirror are applied by different code on
-- different frames, so for a handful of frames the ghost is dressed in one graphic and posed from
-- another. Both self-drawn tiers show it in their own way and the spawned one drew rubbish.
--
-- Standing aside for those frames costs nothing: the engine animates the ghost's own action
-- meanwhile, and the swap arrives a frame or two later with the right frame loaded by its own path.
-- A nil `remote.gfx` means the peer never told us -- the pair cannot be incoherent, so mirror.
-- NO ENGINE ANIMATION RESTART NEAR A GRAPHIC SWAP -- the restart's frame copy is the tear.
--
-- The chain, closed by subtraction on 2026-08-21 after six narrower fixes each failed on screen:
-- with the peer-graphic path off (no swaps) the scramble never occurs; with swaps on and ONLY the
-- engine's animation restarts suppressed, it never occurs either -- while every boundary-time
-- instrument (sprite struct, hardware OAM, VRAM-vs-ROM, allocation bitmap) read clean throughout,
-- and a write-watch put BIOS CpuSet bursts inside the ghost's tiles on exactly the scramble
-- frames. That is a MID-FRAME copy tearing the sprite while the PPU scans it: asking the engine
-- to restart an animation makes it re-copy the frame on its own clock, during active display,
-- right after the tile range has moved -- when old and new bytes differ the most. Our own copies
-- run at the Lua tick, between frames, and cannot tear.
--
-- SUPPRESSED ONLY NEAR A SWAP, not always: fishing's cast is engine-animated and user-confirmed
-- 1:1, and its animation changes arrive with no graphic change -- the cooldown leaves it exactly
-- as it was. 30 frames covers the measured +2..3-frame tear window ten times over. Within the
-- window the ghost stays paused and the wire mirror's boundary-time loads carry the pose;
-- requestAction un-pauses a stepping ghost as always.
--
-- MESHGHOST_EMERALD_NO_ANIM_RESTART (probe) forces the suppression EVERYWHERE, which is the
-- subtraction experiment this was proven with; never ship it set.
-- SIX FRAMES, NOT THIRTY. The measured tear window is the OAM pipeline's ~2 frames plus the
-- swap's own; thirty was a lazy 10x margin, and the margin itself was visible: a 16-frame pose
-- (the field-move stance at surf start) spent its whole life inside the cooldown with the sprite
-- paused, so the ghost held frame 0 and then the engine sprinted through the rest when it woke.
-- The user: *"the drawn ghost does the starting surf animation a tiny bit slow"* -- the painted
-- copy reads its frame from that same paused sprite in compare mode, so it showed the stall too.
-- Measured: player 0/0..0/4 in 16 frames, copies 25 frames and skipping three.
ANIM_RESTART_COOLDOWN = 6
function animRestartBlocked(g)
    return MESHGHOST_EMERALD_NO_ANIM_RESTART
        or (g and g.swapAt and frameCounter - g.swapAt < ANIM_RESTART_COOLDOWN) or false
end
function animRestart(d, g)
    if animRestartBlocked(g) then
        w8(d + 0x2c, r8(d + 0x2c) | 0x40)          -- stay paused; our loads carry the pose
        w8(d + 0x3f, r8(d + 0x3f) & ~0x14)
    else
        w8(d + 0x3f, (r8(d + 0x3f) | 0x04) & ~0x10)
    end
end

function animBelongsToGhost(g, remote)
    return remote.gfx == nil or g.gfx == nil or remote.gfx == g.gfx
end

function loadGhostFrameNow(g, info, animNum, animIdx)
    if COMPARE_TIERS then
        local who = debug.getinfo(2, "l")
        local k = string.format("%s:%s/%s", who and who.currentline or "?",
            tostring(animNum), tostring(animIdx))
        if k ~= genderFrames.lastLoadLog then
            genderFrames.lastLoadLog = k
            logFile("FRAME LOAD from line " .. k)
        end
    end
    if not info or info.anims == 0 or info.images == 0 or not g.tileStart then return end
    -- A FRAME THAT CANNOT BE RESOLVED MUST STILL LEAVE PIXELS BEHIND.
    --
    -- This is called from the graphic swap, immediately after a FRESH tile range has been claimed
    -- and the sprite pointed at it -- so returning early here does not leave the ghost looking as
    -- it did a moment ago, it leaves it drawing from VRAM nobody has written: grey rubbish. The
    -- user, watching the surf start: *"the spawned ghost glitch out sometimes when starting surf,
    -- like a grey/glitched sprite"*, and SOMETIMES is the tell -- it depends on which animation
    -- the peer happened to be in when its graphic changed.
    --
    -- Why it fails at all: the peer's animation number belongs to the graphic the peer had. Every
    -- special state has its OWN anim table, and they are not the same length -- the field-move
    -- graphic uses sAnimTable_FieldMove where a walker uses sAnimTable_Standard -- so a peer
    -- carrying anim 20 into a graphic with a handful of animations indexes past the end of the
    -- table and reads whatever ROM sits after it. Measured 2026-08-21: the ghost held anim 20/4
    -- while wearing gfx 3.
    --
    -- The fallback is the graphic's own first frame, which every graphic has. A ghost briefly
    -- facing the wrong way is a small, legible wrongness; a grey block is not.
    local function resolve(an, ai)
        local animPtr = r32(info.anims + (an or 0) * 4)
        if not isRomPtr(animPtr) then return nil end
        local frame = r32(animPtr + (ai or 0) * 4) & 0xFFFF
        local p = r32(info.images + frame * 8)
        if not isRomPtr(p) then return nil end
        return p
    end
    local src = resolve(animNum, animIdx) or resolve(0, 0)
    if not src then return end
    -- OBJ VRAM, 32 bytes per 4bpp tile. info.size is the graphic's own byte count, so this copies
    -- exactly one frame and never spills into a neighbour's range.
    local dst = 0x06010000 + g.tileStart * 32
    for off = 0, info.size - 4, 4 do w32(dst + off, r32(src + off)) end
    -- A frame copy is info.size/4 read+write pairs -- 128 of each for a 32x32 graphic. Cheap once
    -- and ruinous per frame, so it must stay on a CHANGE and never become per-frame work.
    -- Measured 2026-08-20 in ordinary play: 1 per 300 frames.
end

-- CHANGE A GHOST'S GRAPHIC IN PLACE. The rebuild is the glitch.
--
-- Evidence, not preference: the artifact appears at BOTH graphic changes -- picking the rod up and
-- putting it away -- on the spawned tier only, while the painted copy is perfect through both
-- (user, 2026-08-19: *"it snaps a bit at the start, and towards the end it snaps + looks really
-- glitch"*). The painted copy decodes from ROM every frame and is never rebuilt; the spawned one
-- is destroyed and re-created, and that is the one thing they do not share.
--
-- What a rebuild costs, all of it avoidable: the object is cleared and re-initialised, a new
-- sprite slot is taken (draw order can change), a new tile range is allocated, and every field the
-- engine had settled -- position, pos2, animation phase, ground-effect state -- is rebuilt from
-- scratch in one frame. Patching instead touches only what describes the GRAPHIC and leaves the
-- rest exactly where the engine had it.
--
-- Falls back to the rebuild if it cannot do the whole job, because a half-applied graphic (new
-- shape, old tiles) is worse than a rebuild.
-- WHAT THE HARDWARE IS ACTUALLY TOLD TO DRAW -- used only by the animation trace above, which is
-- off unless MESHGHOST_EMERALD_ANIM_TRACE is set. Scans the 128 OAM entries (0x07000000, 8 bytes
-- apart) for the one using the ghost's tile range and the one using the player's, and reports
-- their raw screen x/y plus shape/size bits.
--
-- This is the ground truth that every sprite struct field only FEEDS, and reading it is what ended
-- HOLD A PEER'S POSE, rather than restart its animation.
--
-- A peer standing still does not report "idle": it reports the animation it last played, the
-- command index it stopped on, and animPaused -- e.g. facing north after a step, `sanim=5 sidx=3`
-- with the pause bit set, which resolves to the standing picture. Reproducing that is three
-- writes, and NONE of them is animBeginning: setting that restarts the animation from command 0,
-- which is a ghost walking on the spot.
--
-- Extracted 2026-08-21 because two paths need it and only one had it. The steady-state mirror held
-- the pose correctly; the SPAWN path wrote animNum alone and set animBeginning, so a ghost came
-- into the world mid-stride and only corrected itself once the peer moved and the mirror took
-- over. The user: *"the spawned ghost spawns in with the wrong pose, gets fixed after moving
-- around."*
--
-- THE MIRROR STILL CARRIES ITS OWN COPY of this, deliberately not folded in yet: that path is
-- confirmed on screen and was left untouched while the spawn fix was being judged. Folding it in
-- is the next edit here, and until it happens the two must be changed together -- which is the
-- exact divergence this extraction exists to end.
--
-- THE FLIP COMES WITH IT, and that is not optional here: east is the WEST artwork with the OAM's
-- horizontal flip, and that flip is normally applied by AnimCmd_frame as an animation ADVANCES.
-- A held sprite never advances, so nothing would ever set it.
function applyHeldPose(g, remote)
    if not (remote.spaused and remote.sanim and remote.sidx) then return false end
    if COMPARE_TIERS and (frameCounter - (genderFrames.poseLogAt or 0)) >= 60 then
        genderFrames.poseLogAt = frameCounter
        -- What the ghost's own tiles actually HOLD, read back out of VRAM: which rows carry ink.
        -- The standing frame and a mid-stride frame do not have their art on the same rows, so
        -- this says which picture is really on screen rather than which one was asked for.
        local fr, lr = nil, nil
        if g.tileStart then
            for row = 0, 31 do
                local tr, ly = row // 8, row % 8
                local ink = false
                for tc = 0, 1 do
                    local t = g.tileStart + tr * 2 + tc
                    for byte = 0, 3 do
                        if r8(0x06010000 + t * 32 + ly * 4 + byte) ~= 0 then ink = true break end
                    end
                    if ink then break end
                end
                if ink then
                    if not fr then fr = row end
                    lr = row
                end
            end
        end
        local gi3 = graphicsInfo(g.gfx)
        local img = "?"
        if gi3 and gi3.anims ~= 0 then
            local ap3 = r32(gi3.anims + remote.sanim * 4)
            if isRomPtr(ap3) then img = tostring(r32(ap3 + remote.sidx * 4) & 0xffff) end
        end
        local dd2 = sprAddr(g.sprId)
        logFile(string.format(
            "GHOSTPOSE f=%d want=%s/%s img=%s | ghost anim=%d/%d paused=%s tileStart=%s "
            .. "artRows=%s..%s oamTile=%d",
            frameCounter, tostring(remote.sanim), tostring(remote.sidx), img,
            r8(dd2 + 0x2a), r8(dd2 + 0x2b), tostring((r8(dd2 + 0x2c) & 0x40) ~= 0),
            tostring(g.tileStart), tostring(fr), tostring(lr),
            r16(dd2 + 0x04) & 0x3ff))
    end
    -- The peer's pose is only meaningful while the ghost wears the peer's graphic; see
    -- animBelongsToGhost. Holding a pose from the wrong animation table is how a ghost ends up
    -- displaying a frame that does not exist.
    if not animBelongsToGhost(g, remote) then return false end
    local d = sprAddr(g.sprId)
    local settled = r8(d + 0x2a) == remote.sanim and r8(d + 0x2b) == remote.sidx
        and (r8(d + 0x2c) & 0x40) ~= 0
    if settled and (g.heldCopiedAt or 0) + 3 < frameCounter then
        return true                      -- already held exactly here; writing again restarts it
    end
    w8(d + 0x2a, remote.sanim)
    w8(d + 0x2b, remote.sidx)
    w8(d + 0x2c, r8(d + 0x2c) | 0x40)
    -- CLEAR animBeginning AND animEnded, which is the half of "hold this pose" that was missing.
    --
    -- The fields alone are not the pose. With animBeginning still set -- and it IS set, because a
    -- ghost's sprite is copied from the player's and the restart path elsewhere sets it -- the
    -- engine runs the animation once more before it honours animPaused, and an animation that
    -- runs COPIES ITS FRAME into the object's tiles. So the ghost ended up with the right numbers
    -- and command 0's picture: fields saying "standing north", pixels showing a stride. Measured
    -- 2026-08-21 with the GHOSTPOSE trace -- `want=5/3 img=1` against `artRows=11..31`, where
    -- image 1's own art is rows 10..30 -- after the user reported *"the spawned ghost spawns in
    -- with the wrong pose, gets fixed after moving around"*: moving hands the animation back, the
    -- engine advances it properly, and the tiles come good on their own.
    --
    -- Bits 0x04 (animBeginning) and 0x10 (animEnded) at +0x3F, the exact pair StartSpriteAnim
    -- sets (pokeemerald src/sprite.c:1346-1351) -- cleared here rather than set.
    w8(d + 0x3f, r8(d + 0x3f) & ~0x14)
    -- THE OAM BIT ONLY, NEVER `sprite->hFlip`: SetSpriteOamFlipBits is `hFlip ^ sprite->hFlip`, so
    -- the struct field is a BASE the animation command's own flip is XORed against. Setting both
    -- reads correct only while the sprite stays paused and inverts the moment it advances.
    local hgi = graphicsInfo(g.gfx)
    if hgi and hgi.anims ~= 0 then
        local hap = r32(hgi.anims + remote.sanim * 4)
        if isRomPtr(hap) then
            local hfl = ((r32(hap + remote.sidx * 4) >> 22) & 1) == 1
            w16(d + 0x02, hfl and (r16(d + 0x02) | 0x1000) or (r16(d + 0x02) & 0xefff))
        end
    end
    -- AND THE PIXELS LAST, so the copy lands after everything that could have moved them. Held
    -- for a few frames past the write (heldCopiedAt above) because the engine's own sprite update
    -- runs between our ticks: one copy can still be overwritten by the update that follows it,
    -- and re-asserting for three frames costs three frame copies once per stop, not per frame.
    loadGhostFrameNow(g, hgi, remote.sanim, remote.sidx)
    if not settled then g.heldCopiedAt = frameCounter end
    g.animSetFor = remote.sanim
    return true
end

-- the fishing investigation: pos2, animNum and animCmdIndex all agreed with each other for frames
-- in which the OAM x moved 8px and back. If a snap exists, it is visible here, on an exact frame,
-- by an exact number of pixels.
function oamEntryFor(ghostTile, playerTile)
    local gout, pout = "-", "-"
    for i = 0, 127 do
        local a0 = r16(0x07000000 + i * 8)
        if (a0 & 0x0300) ~= 0x0200 then -- skip disabled (bit 9 set without affine)
            local a2 = r16(0x07000000 + i * 8 + 4)
            local t = a2 & 0x3ff
            local a1 = r16(0x07000000 + i * 8 + 2)
            local e = string.format("x=%d y=%d sh=%d sz=%d",
                a1 & 0x1ff, a0 & 0xff, (a0 >> 14) & 3, (a1 >> 14) & 3)
            if ghostTile and t == ghostTile then gout = e end
            if playerTile and t == playerTile then pout = e end
        end
    end
    return "gOAM[" .. gout .. "] pOAM[" .. pout .. "]"
end

-- THE FISHING OFFSET IS COMPUTED, NOT COPIED. The fishing sprite's frames are not all aligned the
-- same inside their 32-wide canvas, so the game re-derives the sprite offset from the frame being
-- DISPLAYED, every frame: AlignFishingAnimationFrames (pokeemerald src/field_player_avatar.c:
-- 2045-2078) reads anims[animNum][animCmdIndex].type -- for a frame command that is its image
-- index -- and sets x2=8 for images 1/2/3 (-8 facing west, DIR_WEST=3 per
-- include/constants/global.h:140), y2=-8 for image 5, y2=8 for images 10/11.
--
-- Copying the player's offset over the wire was therefore wrong by construction: the ghost's
-- animation lags the player's, so it kept receiving the offset for a frame it was not yet
-- showing. Measured at every cast end in one trace -- the wire honestly said sox=0 (the player's
-- new frame) while the ghost still displayed the old one, and the OAM x moved 8px for exactly
-- those frames. The player and the drawn tier never move because for both of them offset and
-- image change together; this gives the spawned ghost the same property, from the same rule,
-- driven by its OWN animCmdIndex.
-- The rule itself, shared by BOTH tiers: given an anims table and a frame within it, the shift
-- that frame needs. One implementation, because the defect all day has been two consumers of the
-- same state disagreeing about which frame it belongs to.
function fishingFrameShift(anims, animNum, idx, facingWest)
    if not anims or anims == 0 then return 0, 0 end
    local animPtr = r32(anims + animNum * 4)
    if animPtr == 0 then return 0, 0 end
    local t = r16(animPtr + idx * 4)
    -- ANIMCMD_END (-1) means the index sits one past the last frame; the game steps back one.
    if t == 0xffff and idx > 0 then t = r16(animPtr + (idx - 1) * 4) end
    if t == 1 or t == 2 or t == 3 then
        if facingWest then return -8, 0 end
        return 8, 0
    elseif t == 5 then
        return 0, -8
    elseif t == 10 or t == 11 then
        return 0, 8
    end
    return 0, 0
end

function alignFishingGhost(g)
    local d = sprAddr(g.sprId)
    local x2, y2 = fishingFrameShift(r32(d + 0x08), r8(d + 0x2a), r8(d + 0x2b),
        (r8(objAddr(g.objId) + 0x18) & 0x0f) == 3)
    w16(d + 0x24, x2 & 0xffff)
    w16(d + 0x26, y2 & 0xffff)
end

-- The two graphics the rule belongs to (pokeemerald include/constants/event_objects.h:144-145).
function isFishingGfx(gfx) return gfx == 137 or gfx == 138 end

-- EVERY action that leaves the ground, which is more than a ledge hop.
-- The shadow was written for ledge hops and gated on their four action ids, so the Acro Bike --
-- whose whole point is hopping -- got none of it (user, 2026-08-20: *"no shadow still"*).
--   0x0C..0x0F JUMP_2_*  ·  0x42..0x45 JUMP_*  ·  0x46..0x4D JUMP_IN_PLACE_*
--   0x70..0x73 ACRO_WHEELIE_HOP_FACE_*  ·  0x74..0x7B ACRO_WHEELIE_HOP/JUMP_*
-- (include/constants/event_object_movement.h)
--
-- 0x42..0x45 JUMP_* IS THE ACRO BIKE'S SIDE HOP, and the range used to start at 0x46 -- four ids
-- too high, so the one Acro move that is neither a wheelie nor a ledge got no shadow and no dust
-- on ANY tier (user, 2026-08-21: *"none of the ghosts have a shadow or dust, when doing the side
-- hop"*). It does not look like a wheelie action and it is not one: `AcroBikeTransition_SideJump`
-- (src/bike.c:639-664) calls `GetJumpMovementAction`, i.e. the plain JUMP_* family, which is why
-- reading the ACRO_* block alone could never have found it.
--
-- 0x70..0x73 was missed on the first pass, and the omission had a precise symptom: those are the
-- hops that leave the ground WITHOUT changing tile, so the ghost hopped -- the arc is on its sprite
-- -- with no shadow under it, while the travelling hops had one. The user, 2026-08-20: *"they are
-- not showing shadow/dust properly ... when they are idle/not moving a tile vs when they are
-- moving"*. A range that reads as "the moving ones" is exactly where an in-place variant hides.
function isJumpAction(act)
    return act ~= nil and ((act >= 0x0c and act <= 0x0f)
        or (act >= 0x42 and act <= 0x4d)
        or (act >= 0x70 and act <= 0x7b))
end

-- Mach and Acro, both genders: Brendan 1/63, May 90/91 (verified.md's graphicsId table).
function isBikeGfx(gfx)
    return gfx == 1 or gfx == 63 or gfx == 90 or gfx == 91
end

function swapGhostGraphicInPlace(g, graphicsId, sanim, sox, soy, sidx, spaused, wireX, wireY)
    local info = graphicsInfo(graphicsId)
    if not info or not ghostAlive(g) then return false end
    -- Allocate before freeing: nothing runs between these writes, and a failed allocation must
    -- leave the sprite pointing at a range it still owns.
    local tileStart = allocSpriteTiles(info.tileCount)
    if not tileStart then return false end
    -- THE OLD RANGE IS FREED LATER, NOT NOW -- the hardware is still drawing from it.
    --
    -- Measured 2026-08-21, hardware OAM dumped per frame across a graphic swap: for TWO frames
    -- after this function runs, the entries at 0x07000000 still carry the OLD tile number (the
    -- OAM the PPU shows lags the sprite struct by the buffer-build/VBlank-copy pipeline). Freed
    -- immediately, those two frames draw whatever the engine loads into the reclaimed range next
    -- -- harmless most of the time, and exactly wrong during the start of surfing, where the
    -- show-mon effect is loading a full Pokemon picture into OBJ VRAM that instant: the ghost
    -- renders scrambled pieces of the incoming picture for a frame. Whether the allocator lands
    -- there varies run to run, which is why the user saw it "every 2-3 savestate reloads".
    --
    -- Queued with the ghost that owns it, and the service point frees only while that ghost is
    -- still ITSELF alive (identity, not slot state) -- a world rebuild between queue and free
    -- means the engine reset the bitmap and the bits are not ours to touch, the same rule every
    -- other free in this file follows.
    if g.tileStart then
        queueTileFree({ g = g, start = g.tileStart, count = g.tileCount, at = frameCounter })
    end

    w8(objAddr(g.objId) + 0x05, graphicsId)

    local d = sprAddr(g.sprId)
    w16(d + 0x04, (r16(d + 0x04) & 0xfc00) | (tileStart & 0x03ff))
    if info.oam ~= 0 then
        -- Shape and size only -- the rest of a template OAM puts a live sprite out of step with
        -- the engine's own per-frame building, which spawnGhost records at length.
        w16(d + 0x00, (r16(d + 0x00) & 0x3fff) | (r16(info.oam + 0x00) & 0xc000))
        w16(d + 0x02, (r16(d + 0x02) & 0x3fff) | (r16(info.oam + 0x02) & 0xc000))
    end
    w32(d + 0x08, info.anims)
    w32(d + 0x0c, info.images)
    w32(d + 0x10, info.affineAnims)
    w32(d + 0x18, info.subspriteTables)
    -- Preserve the engine-chosen subsprite table number; forcing 0 (the empty table) scrambled
    -- one frame at every graphic change. Full reasoning at spawnGhost's identical write.
    local keepSubNum = r8(d + 0x42) & 0x3f
    w8(d + 0x42, 0)
    if info.subspriteTables ~= 0 then w8(d + 0x42, keepSubNum | (1 << 6)) end
    w8(d + 0x28, (-(info.width // 2)) & 0xff)
    w8(d + 0x29, (-(info.height // 2)) & 0xff)
    -- Start the new graphic's animation, and put its first frame in the new tiles NOW: the
    -- engine's own copy is queued to the next VBlank, which is one frame of the old pixels worn
    -- through the new shape.
    w8(d + 0x2a, sanim or 0)
    w8(d + 0x2b, 0)
    -- ARRIVE PAUSED WHEN THE PEER IS PAUSED. animBeginning starts the new graphic's animation, and
    -- for a peer standing still that is a walk or pedal cycle played out of nowhere between the
    -- transition and the settle -- the user, after the settle fix landed: *"its doing a animation
    -- in between, its supposed to stay static"*. A moving peer's swap (a rod cast, a ride) still
    -- wants the animation started, so this is gated on the peer's own paused bit rather than
    -- removed. spaused is nil for pre-upgrade peers, and nil keeps the old behaviour.
    -- NEVER animBeginning AT A SWAP -- the engine's restart copy is the one mid-frame writer we
    -- control, and it is both redundant and the prime tearing suspect.
    --
    -- Setting animBeginning asks the engine to restart the animation, which re-copies the frame
    -- into the tiles from ITS OWN clock -- mid-frame, during active display, while the PPU may be
    -- scanning those very tiles. Our own copy (loadGhostFrameNow, below and at every mirror site)
    -- runs at the Lua tick, between frames, which cannot tear. The write-watch put BIOS CpuSet
    -- bursts inside the ghost's range on exactly the frames the user sees a one-frame scrambled
    -- sprite at the start of surfing (2026-08-21); everything at frame BOUNDARIES measured clean
    -- across five different instruments, which is what mid-frame tearing looks like from outside.
    --
    -- So a swap arrives PAUSED with its frame already in VRAM, for moving peers too: the anim
    -- mirror above drives the pose from the wire (and now agrees on the graphic, so it is
    -- coherent), and a stepping ghost is un-paused by requestAction's enableAnim on its next
    -- order, exactly as after a settle.
    w8(d + 0x2c, r8(d + 0x2c) | 0x40)
    w8(d + 0x3f, r8(d + 0x3f) & ~0x14)
    -- AND THE SPRITE OFFSET, IN THE SAME BATCH AS THE SHAPE. These two belong to each other: a
    -- fishing frame is 32 wide and sits on its tile only because the game's task offsets it by 8,
    -- so a frame drawn with the new shape and the old offset is a frame drawn half a tile to the
    -- side. Applying the offset from the mirror block instead left exactly that gap -- the mirror
    -- runs earlier in the same frame, so the offset could never land before the shape did.
    --
    -- Measured across a cast: the ghost took the fishing graphic on one frame with pos2 still 0,0
    -- and only reached 8,0 two frames later, then the same in reverse when the rod was put away.
    -- That is both halves of *"it snaps at the start & at the end"* -- an 8px step out and back,
    -- at each end of the swap. Nothing else moved: position and coords were constant throughout.
    g.gfx, g.tileStart, g.tileCount = graphicsId, tileStart, info.tileCount
    g.swapAt = frameCounter -- opens the animation-restart cooldown; see animRestart
    if isFishingGfx(graphicsId) then
        alignFishingGhost(g)
    else
        if sox then w16(d + 0x24, sox & 0xffff) end
        if soy then w16(d + 0x26, soy & 0xffff) end
    end
    g.animSetFor = nil -- a new graphic always re-issues its animation, whatever the number was
    -- THE PEER'S FRAME INDEX, not a hardcoded 0 -- and this is the whole of the wrong-pose bug.
    --
    -- The held-pose mirror loads the peer's exact frame and then STOPS, because a held pose is set
    -- once. This ran afterwards and overwrote it with frame 0 of the same animation, and since a
    -- held sprite is paused, nothing ever repainted it again: the ghost sat on the bike's first
    -- standing frame while the peer stood on its second, for as long as they stood there.
    --
    -- Traced by logging both loads and where each wrote: the held load fired ONCE with sidx=1 to
    -- tile 76, the sprite drew from tile 76, and the pixels there were frame 0's. Only one caller
    -- passes a literal 0.
    loadGhostFrameNow(g, info, sanim or 0, sidx or 0)
    w8(sprAddr(g.sprId) + 0x2b, sidx or 0)

    -- AND THE COMPANION SPRITE THE STATE OWNS. A surfing player is a rider AND the blue Pokemon
    -- underneath (documentation.md's surfing section) -- one state, two sprites -- and only
    -- spawnGhost knew that. Every way a peer actually ENTERS the water comes through here instead:
    -- they were already spawned as a walker, so the graphic is patched rather than rebuilt, and
    -- the blob was never created. Seen on screen 2026-08-19 -- *"both of the ghosts don't have the
    -- 'blue fish' they are riding on while surfing"* -- with the log showing the ghost correctly
    -- wearing gfx 2 and animating, and no blob line ever printed.
    --
    -- Both directions, because getting OFF the water is the same swap in reverse: a blob left
    -- behind keeps following the object it names (data[2] is the ghost) and would swim along under
    -- a peer who is walking down a road.
    if SURFING_GFX[graphicsId] then
        if not g.blobSprId then
            -- AT THE WIRE TILE, NOT THE GHOST'S. On a mount the swap lands a beat before the
            -- ghost performs its jump (the swap-pending gate orders them), so the ghost's own
            -- coords still name the LAND tile -- and the mount blob is deliberately inert
            -- (BOB_NONE, see the park logic), so a blob born on land WAITED on land while the
            -- ghost jumped past it into the water: the user, *"the spawned ghosts blob is not in
            -- the water, its on the land while the ghost is jumping out into the water"*. The
            -- wire tile IS the jump's destination -- the game writes the destination into the
            -- player's coords as the jump begins -- so it is the blob's birthplace, exactly as
            -- SurfFieldEffect_JumpOnSurfBlob spawns the real one at tDestX/tDestY.
            -- NOT during a mount jump: the wire position is the sender's SMOOTHED glide, still
            -- naming the land tile when this swap fires, and the ghost's own coords are also
            -- still the land tile (its jump has not been issued yet -- the swap-pending gate
            -- orders swap first). Both authorities lie here. The mount-jump block in syncGhost
            -- spawns the blob instead, once the ENGINE has accepted the ghost's jump and moved
            -- its coords to the destination -- the only moment the destination is readable.
            if not (g.jsActive and not g.jsDismount) then
                local a = objAddr(g.objId)
                spawnSurfBlob(g, wireX or (rs16(a + 0x10) - MAP_OFFSET),
                    wireY or (rs16(a + 0x12) - MAP_OFFSET))
            end
        end
    elseif UNDERWATER_GFX[graphicsId] then
        -- Diving is a WARP, so a peer normally arrives already underwater and gets its bobber from
        -- the spawn path -- but the swap path has to cover it too, for the same reason the blob
        -- does: a peer already spawned as a walker has its graphic patched rather than rebuilt.
        if not g.blobSprId then spawnUnderwaterBobber(g) end
    else
        despawnSurfBlob(g)
    end
    return true
end

-- One remote, one frame. Spawn if missing, step it if it moved one tile, teleport if it jumped,
-- and turn it on the spot otherwise.
local function syncGhost(playerId, remote)
    -- The peer's disableAnim, parked where requestAction can see it. On the table rather than
    -- threaded through nine call sites, and rather than a new local -- this chunk is at Lua's
    -- 200-local ceiling. syncGhost runs one peer at a time and synchronously, so the value is
    -- always the one belonging to the ghost being moved.
    genderFrames.syncNoAnim = remote.noanim
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
        -- new map's sprites now own. Drop the record, free nothing. The blob went the same way:
        -- it lives in the same sprite array the engine reset.
        --
        -- SAID OUT LOUD, throttled: this is the one place a ghost can vanish and reappear without
        -- anything being wrong, and doing it silently means a user report of *"the spawned ghost
        -- disappears sometimes, but very rarely"* has nothing in the log to match against. One line
        -- per second at most, and it names which of the two it was -- the map id moving says a load,
        -- the map id holding still says a cull.
        if not tiering.lastReclaimFrame or frameCounter - tiering.lastReclaimFrame > 60 then
            tiering.lastReclaimFrame = frameCounter
            -- logFile, NOT console.log (2026-08-20): a BizHawk console line is a GUI append,
            -- measured earlier as heavy enough to drop the emulator to single-digit fps in bulk --
            -- and reclaims cluster around seams and doors, exactly where the user then reported
            -- consistent lag and a console "all the time". The record survives in the log file.
            logFile(string.format(
                "MeshGhost: the engine reclaimed %s's ghost slot (%s) -- respawning.",
                tostring(playerId), inOverworld() and "cull or map load" or "not the overworld"))
        end
        ghosts[playerId] = nil
        g = nil
        -- SWEEP HERE, at the moment an orphan can be created.
        --
        -- The record has just been dropped because the engine reclaimed the slot -- but if the
        -- engine only PARTLY reclaimed it (the object still active, still wearing our localId,
        -- while its sprite link changed) then it is orphaned as of this line: no longer tracked,
        -- and still drawn. The periodic sweep would find it up to a second later, and the
        -- transition sweep already ran earlier this tick while the record still existed, so it
        -- spared it. That gap is what the user saw: *"i did briefly see a 2nd ghost after exiting
        -- out from my inventory/bag"*.
        --
        -- Sweeping now closes it to zero frames, because the very next thing this function does is
        -- spawn the replacement.
        sweepOrphanGhosts()
    end
    if not g then
        -- Nothing to spawn into: a peer this frame already found the object array full, and it
        -- cannot empty mid-frame. Skipping the rest is what keeps a room bigger than the map from
        -- costing a full array re-scan per unplaceable peer per frame.
        if tiering.blockedFrame == frameCounter then return end
        -- Placement is only exact on a settled camera; a frame's wait is free.
        -- DO NOT SPAWN WHAT THE ENGINE WILL IMMEDIATELY CULL (2026-08-20). The engine removes
        -- object events that fall outside its view of the camera, and a peer trailing far enough
        -- behind -- or parked on the far side of a seam -- sits permanently outside it. Spawning
        -- such a peer starts a loop: spawn, engine culls, respawn next frame, cull again -- VRAM
        -- tile allocation and sprite setup every cycle, plus a log line per reclaim. Measured on
        -- the fps ride: 16 reclaims clustered at the route's two seam crossings, with worst
        -- frames of 217ms landing in this section, felt as *"lagging in 2 places consistently"*.
        --
        -- The gate is a conservative SUBSET of the visible screen (15x10 tiles): spawn only a
        -- peer within +/-8 x and +/-7 y of the local player. Inside that, the engine keeps the
        -- object; outside it, the peer was invisible either way -- the difference is that we no
        -- longer pay for a ghost nobody could see. It comes into view, it spawns, one time.
        local pvX = rs16(objAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05)) + 0x10) - MAP_OFFSET
        local pvY = rs16(objAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05)) + 0x12) - MAP_OFFSET
        if math.abs(targetX - pvX) > 8 or math.abs(targetY - pvY) > 7 then return end
        if cameraIsSettled() then
            local wantNow = wantedGfx(remote)
            spawnGhost(playerId, targetX, targetY, remote.orientation, wantNow)
            -- EVERY path that gives a ghost a graphic must also give it that graphic's state.
            --
            -- The offset and the animation were applied in the graphic-SWAP path only, and a ghost
            -- is usually re-created through THIS one instead: the engine reclaims its slot when a
            -- menu closes, so the peer's rod arrives on a brand-new sprite that never saw the
            -- swap. Measured with a probe loaded BEFORE the adapter, which is the only way to see
            -- what the engine left rather than what we just wrote: two frames of the fishing
            -- graphic at pos2 0,0 -- drawn 8px left -- and then a snap into place. Every earlier
            -- probe read our own write back and reported a perfect 8.
            local ng = ghosts[playerId]
            if ng then
                local d = sprAddr(ng.sprId)
                -- A PEER THAT IS STANDING STILL IS HELD, NOT RESTARTED. Without this a ghost
                -- arrived mid-stride and stayed there until the peer moved and the steady-state
                -- mirror below took over -- which is exactly how it was reported.
                if not applyHeldPose(ng, remote) and remote.sanim then
                    w8(d + 0x2a, remote.sanim)
                    animRestart(d, ng)
                end
                -- After the animation write, so the offset is computed from the frame the ghost
                -- will actually show.
                if isFishingGfx(wantNow) then
                    alignFishingGhost(ng)
                else
                    if remote.sox then w16(d + 0x24, remote.sox & 0xffff) end
                    if remote.soy then w16(d + 0x26, remote.soy & 0xffff) end
                end
                loadGhostFrameNow(ng, graphicsInfo(wantNow), remote.sanim, remote.sidx)
            end
        end
        return
    end

    -- MIRROR THE PEER'S SPRITE ANIMATION, for the states the engine will not drive for us.
    --
    -- Adopting a peer's graphicsId gives a ghost the rod; the game's fishing TASK is what makes it
    -- fish, and a ghost has no task. So the animation number travels with the state and is applied
    -- here, imitating StartSpriteAnim (pokeemerald src/sprite.c:1346-1351: set animNum, set
    -- animBeginning, clear animEnded -- bits 0x04 and 0x10 of the flags byte at +0x3F per
    -- include/sprite.h:227-232). Written only on a CHANGE, so it costs a comparison per frame.
    --
    -- Only while the peer is idle, deliberately: a walking ghost's animation belongs to the engine
    -- step we asked for, and two things writing animNum would fight. Fishing, surfing on the spot
    -- and standing poses are exactly the cases the engine is not already animating.
    -- ONLY FOR GRAPHICS THE ENGINE IS NOT ALREADY DRIVING. The walking graphic (BRENDAN_NORMAL 0,
    -- MAY_NORMAL 89 -- pokeemerald include/constants/event_objects.h:7,96) is animated by the
    -- movement actions we request: steps, turns, bumps. Writing animNum over the top of those left
    -- the ghost stuck in whatever pose the collision landed on -- the user, after this shipped:
    -- *"the spawned ghost's facing animations are wrong now, its stuck in the wrong pose after
    -- turning directions"*, and again after running. Two things writing one field.
    --
    -- A fishing rod, a bike or a surfboard is the opposite case: the engine has no action of ours
    -- driving it, so without this the ghost holds the animation's first frame forever. So the rule
    -- is exactly that -- mirror the peer's animation only where nothing else is doing it.
    --
    -- EXCEPT WHEN THE PEER IS FORBIDDEN AN ANIMATION, where "the engine is already driving it" is
    -- precisely what has stopped being true. On an ice slide the peer holds one frame while
    -- crossing tiles; requestAction now sets disableAnim on the ghost so the engine stops
    -- animating it, and that leaves the ghost frozen on whatever frame it happened to be on --
    -- measured mid-slide: the player held 10/0 while its copy sat on 10/2. Freezing the WRONG
    -- frame is not the fix, so the mirror takes over for exactly this case and holds the peer's.
    local engineDrivesAnim = (remote.gfx == nil or remote.gfx == 0 or remote.gfx == 89)
        and not remote.noanim
    -- AND ONLY ONCE THE GHOST IS ACTUALLY WEARING THAT GRAPHIC. An offset describes a shape: 8px
    -- is what keeps a 32-wide fishing frame on its tile, and it is simply wrong for the 16-wide
    -- walker. The peer's graphic is held six frames on the way out (it has to be -- the sender
    -- measures an unsettled state otherwise), but the offset and the animation are not, so for a
    -- frame the wire says "walking graphic, fishing offset". Applying that drew the ghost half a
    -- tile to the side and then snapped it back as the swap landed -- measured: pos2 8,0 with
    -- gfx 0 at f=2474, gfx 137 at f=2475.
    --
    -- Matching on the ghost's own graphic is what makes the two arrive together, and it needs no
    -- guess about timing: the swap applies both in one batch, and this block only maintains them
    -- afterwards.
    -- ...EXCEPT WHEN NOTHING IS DRIVING IT. "The engine animates the walking graphic" holds only
    -- while one of our movement actions is running. A ghost standing still on foot has none, and
    -- the last thing to touch its animation may have been a different graphic entirely -- so it
    -- keeps whatever frame it was left on. Measured at the last commit, standing: the ghost held
    -- exactly the ROM frame for index 0 while the player stood on index 1.
    --
    -- "Nothing is running" is the held-movement bit, NOT the action id: movementActionId keeps the
    -- last action's number long after it finished, so a settled ghost reads 0x00 and never NONE.
    if PEER_GFX_ENABLED and remote.sanim and g.gfx == remote.gfx
        and (not engineDrivesAnim
            or (remote.spaused and (r8(objAddr(g.objId)) & 0x40) == 0))
        -- ...unless the peer is on a BIKE, where the engine's own choice is provably wrong.
        --
        -- Letting the engine animate a moving ghost is right for the WALKING graphic: the movement
        -- action we request carries the matching walk cycle, and mirroring on top of it put two
        -- writers on one field and left ghosts stuck in a pose after a turn. A bike is the
        -- opposite. Measured with MESHGHOST_EMERALD_ANIM_TRACE at top speed, 2026-08-20:
        --
        --   f=597  P.anim=4/0 | R.sanim=4/0 | G.anim=8/3
        --   f=605  P.anim=4/1 | R.sanim=4/1 | G.anim=8/3   <- ten frames on one frame
        --
        -- The player rides on animation 4; the action-derived animation for that graphic is 8,
        -- which runs to its last frame and holds there while the ghost keeps moving. A character
        -- travelling with its legs stopped is exactly what the user reported as *"sliding/gliding
        -- at top speed"*. The peer was sending the right number the whole time.
        --
        -- So on a bike the peer's number wins even while moving. The number ONLY -- no
        -- animBeginning, no enableAnim -- so the engine keeps advancing the frames at its own rate
        -- and there is still only one thing driving them.
        and (remote.anim ~= "walking" and remote.anim ~= "running" or isBikeGfx(remote.gfx))
        -- AND NOT WHILE THE PEER IS MOVING AT ALL. The pose string only ever says "walking" or
        -- "running", so it cannot describe a bike -- a riding peer falls through it and the mirror
        -- writes animNum while the engine is also animating the step we asked for. Two writers on
        -- one field is the exact shape that left a ghost *"stuck in the wrong pose after turning
        -- directions"* during the fishing work.
        --
        -- gPlayerAvatar.bikeSpeed answers it directly: PLAYER_SPEED_STANDING is 0, anything above
        -- is movement the engine is already driving on our side (include/bike.h:16-25). Peers that
        -- do not send it (an older adapter) keep the previous behaviour.
        --
        -- THE BIKE ESCAPE HOLDS ONLY WHILE THE PEER IS ACTUALLY RIDING, 2026-08-20. It was written
        -- for a peer at a sustained top speed, and unqualified it also fired for a peer who had
        -- already STOPPED while the ghost was still finishing its catch-up step: the mirror then
        -- wrote the peer's standing animation onto a ghost the engine was mid-step animating, and
        -- the two alternated frame by frame -- the ghost cycling through a whole walk cycle for one
        -- tile. The user: *"when moving a single tile, its 'over animating', the characther is not
        -- supposed to wiggle from just 1 step, only when constantly biking in 1 direction"*.
        -- Measured in the tile log as the ghost's animation number flipping between the moving
        -- family and the standing one on consecutive frames.
        --
        -- `bikeSpeed` cannot answer this: it is the Mach Bike's acceleration counter and stays 0 on
        -- the Acro all the way (verified.md). The peer's own movementActionId can -- a rider sends
        -- a movement action while riding and a FACE action the moment they stop.
        and (remote.pspeed == nil or remote.pspeed == 0
            or (isBikeGfx(remote.gfx) and remote.act and remote.act > 0x03 and remote.act ~= 0xff))
        -- THE BIKE ESCAPE COVERS JUMPS TOO, and excluding them was a mistake that took three
        -- passes to see. It was excluded on the reasoning that a ghost trails the peer by a
        -- bounce, so mirroring the peer's CURRENT hop animation would dress it in a facing its
        -- body had not reached yet -- which is a statement about POSITION, and this writes an
        -- ANIMATION NUMBER.
        --
        -- What it actually did was remove the only writer that can turn a ghost mid-hop. A held B
        -- is one repeating action, so the engine never re-reads a direction on its own; and
        -- `ghostIsIdle` is false for the whole of a continuous hop, so every other path that could
        -- have issued a turn is closed at the same time. The result is a ghost locked to whichever
        -- way it set off -- the user, after each of the three attempts that followed: *"the ghost
        -- get stuck facing with the direction it starts the jumping with"*.
        --
        -- The peer's own animation number IS the 1:1 answer: it is the number the peer's game is
        -- displaying this frame, direction included, and copying it is what every other state on
        -- this tier already does. Number only, as ever -- no animBeginning, no enableAnim -- so
        -- the engine keeps advancing the frames and there is still one thing driving them.
        and (ghostIsIdle(g)
            or (isBikeGfx(remote.gfx) and remote.act and remote.act > 0x03
                and remote.act ~= 0xff)) then
        local d = sprAddr(g.sprId)
        -- SET THE ANIMATION, DO NOT RE-SET IT. The engine advances a ghost's animation perfectly
        -- well on its own -- measured: 3/0, 3/1, 3/2 with its pixels tracking the player's a beat
        -- later. What it cannot survive is being restarted: writing animNum with animBeginning
        -- every time the peer's number changes puts it back to the first frame before it can play
        -- one, which is what *"it gets stuck in an animation instead of doing the animation"* is.
        --
        -- So the number is written only when the ghost is not already playing that animation, and
        -- the engine is left to run it. Stepping it frame by frame from the peer was tried and was
        -- worse -- *"it looks really bad/off"* -- because two things were then advancing it.
        -- Compared against what we LAST SET, never against the sprite's live value: the engine
        -- moves that on every frame it animates, so testing it means re-issuing the same animation
        -- forever. The fishing sequence really does move through several animations, and each one
        -- should start exactly once.
        -- RE-ARM WHENEVER THE ENGINE HAS PAUSED IT, not only when the number changes. The engine
        -- re-pauses the sprite every time the ghost goes back to a plain standing graphic, and
        -- `animSetFor` remembers the number across that. So a SECOND cast of the same rod matched
        -- the remembered number, skipped the enable, and held one pose for the whole state --
        -- measured: at the revert the paused bit came back on (0x2C = 0xcd) with animSetFor still
        -- 3, and the next cast of animation 3 never re-enabled. The condition is therefore about
        -- what the sprite IS, not what we last told it.
        if (r8(d + 0x2c) & 0x40) ~= 0 then g.animSetFor = nil end

        -- IS THE PEER'S ANIMATION EVEN RUNNING? A number and a frame do not describe a sprite on
        -- their own; the third part is whether it is playing, and the overworld PAUSES an idle
        -- character's sprite.
        --
        -- Handing every mirrored state to the engine is right for fishing, where the game's own
        -- task really is animating the player, and wrong for anything a character can simply SIT
        -- in. Measured 2026-08-19: the player's own Mach Bike idles at anim 7 frame 3 with
        -- animPaused SET, while a spawned ghost given the same number pedalled on the spot.
        --
        -- So a held peer is reproduced as held: its exact frame index, the paused bit set, and its
        -- pixels loaded -- because a paused sprite is never going to copy them itself. No
        -- animBeginning here, which would reset the index to 0 and show the wrong frame of the
        -- loop.
        if COMPARE_TIERS and genderFrames.lastSp ~= tostring(remote.spaused) then
            genderFrames.lastSp = tostring(remote.spaused)
            logFile("WIRE spaused -> " .. genderFrames.lastSp .. " (act=" .. tostring(remote.act) .. ")")
        end
        -- THE FIELD-MOVE POSE JOINS THE BIKES HERE, and the reason is the same one written above
        -- for bikes: the engine's own choice is wrong for this graphic. The pose (gfx 3/93, the
        -- stance at the start of surfing) keeps ONE animation and advances only its command
        -- index, 0/0 through 0/4 in 16 frames, driven by the game's field-move task. A ghost has
        -- no such task, so nothing here moved it -- every other path keys on the animation NUMBER
        -- changing -- and the pose fell to the engine's free-running playback at its own command
        -- durations: 25 frames, skipping steps, which the painted copy shows too because in
        -- compare mode it reads its frame from this sprite. The user: *"the drawn ghost does the
        -- starting surf animation a tiny bit slow"*.
        --
        -- Narrow on purpose: bikes and this pose only. Surfing and fishing are confirmed 1:1 on
        -- their current paths and are not disturbed.
        if (isBikeGfx(remote.gfx) or remote.gfx == 3 or remote.gfx == 93)
            and not remote.spaused then
            -- Number only, and only when it differs: restarting here would reset the cycle every
            -- time the peer's animation ticked, which is the "stuck on frame 0" failure from the
            -- fishing work wearing different clothes.
            --
            -- AND THE PIXELS WITH IT, on that same change. A new animation number says which frames
            -- the ghost SHOULD be showing; it puts none of them in VRAM. An object event's tiles
            -- are copied when its animation ADVANCES, and a hop's frames are held for many frames
            -- at a time -- so a peer turning mid-hop got the right number immediately and the old
            -- direction's artwork until the engine happened to step the animation. That is the
            -- whole of *"its turning a bit slow"* (user, 2026-08-21), and it is the same
            -- one-frame-late copy the settle path and the held path each already fix in their own
            -- branch; this is the third and last place that needed it.
            --
            -- ON THE CHANGE ONLY. A frame copy is info.size/4 read+write pairs -- 128 of them for
            -- a 32x32 graphic -- and loadGhostFrameNow's own header is blunt that it is cheap once
            -- and ruinous per frame. Gated on the number actually differing, this runs once per
            -- turn, not once per frame.
            -- NEVER DRESS A GHOST IN A DIRECTION ITS BODY IS NOT PERFORMING.
            --
            -- A peer turning mid-hop changes its animation number instantly, but the ghost's own
            -- ACTION cannot change until its current bounce ends -- so copying the number straight
            -- across leaves it hopping one way while wearing the artwork for another. Measured
            -- with probes/facing_probe.lua, 2026-08-21, three frames of it every single turn:
            --   P face=up act=75 anim=21 | G face=right act=77 anim=21
            -- the ghost travelling RIGHT under 0x77 while showing the UP hop. That is the *"extra
            -- animation before swapping facing direction"*.
            --
            -- The first attempt at this silenced the mirror for every jump, which removed the only
            -- writer that could turn a ghost at all and cost four passes to see. The honest rule is
            -- narrower: mirror freely while the two are performing the SAME action -- that is what
            -- keeps a pedal cycle in step -- and stand aside while they disagree, leaving the engine
            -- to animate the hop the ghost is actually doing. They re-converge a frame later when
            -- the ghost adopts the peer's action, and the engine sets that animation itself.
            local agrees = not isJumpAction(remote.act)
                or r8(objAddr(g.objId) + 0x1c) == remote.act
            -- MIRROR THE PAIR, NOT JUST THE NUMBER. A pose that keeps one animation and advances
            -- only its command index -- the field-move pose is exactly that, 0/0 through 0/4 --
            -- changed nothing here, because the test was on `animNum` alone. That was invisible
            -- while the engine animated the ghost itself; it stopped being invisible when the
            -- post-swap cooldown started holding the sprite PAUSED to stop it tearing, since
            -- then NOBODY advanced the pose: the ghost sat on frame 0 and jumped to 4, and the
            -- painted twin -- which reads its frame from this sprite in compare mode -- showed
            -- the same stall as *"the drawn ghost does the starting surf animation a tiny bit
            -- slow"*. Measured: the player stepped 0/0..0/4 in 16 frames, the copies took 25 and
            -- skipped three.
            --
            -- The index is written only while restarts are blocked. Outside the cooldown the
            -- engine owns that field and advances it itself; writing it there would be two
            -- writers on one field, which this file has paid for before.
            local pairKey = (remote.sanim or 0) * 256 + (remote.sidx or 0)
            if agrees and animBelongsToGhost(g, remote) and g.animPairFor ~= pairKey then
                g.animPairFor = pairKey
                w8(d + 0x2a, remote.sanim)
                if animRestartBlocked(g) then w8(d + 0x2b, remote.sidx or 0) end
                loadGhostFrameNow(g, graphicsInfo(g.gfx), remote.sanim, remote.sidx or 0)
            end
            -- AND UN-PAUSE IT, because setting a number on a paused sprite changes nothing.
            -- The peer is not paused (checked above), so the ghost should not be either -- but the
            -- engine pauses an object's sprite whenever it settles, and on the Acro Bike that left
            -- the ghost moving with its legs stopped: measured `paused=232` of 252 stepping frames
            -- while it rode. requestAction hands the animation back the same way when it issues a
            -- step; this covers the frames between steps.
            if (r8(d + 0x2c) & 0x40) ~= 0 then
                w8(objAddr(g.objId) + 0x01, r8(objAddr(g.objId) + 0x01) | 0x08)
            end
        elseif remote.spaused and remote.sidx then
            -- THE HELD POSE, through the one helper both this path and the spawn path use. It was
            -- written out here and only here, which is how the spawn path came to restart the
            -- animation instead of holding it (2026-08-21). Everything that used to be inline --
            -- the change test, the three writes, the OAM flip a held sprite never gets from an
            -- advancing animation, the frame copy and the animSetFor bookkeeping -- is in
            -- applyHeldPose now, unchanged.
            if COMPARE_TIERS then
                logFile(string.format("HELD LOAD: g.gfx=%s live=%d sanim=%s sidx=%s tileStart=%s"
                    .. " oamTile=%d", tostring(g.gfx), r8(objAddr(g.objId) + 0x05),
                    tostring(remote.sanim), tostring(remote.sidx), tostring(g.tileStart),
                    r16(sprAddr(g.sprId) + 0x04) & 0x3ff))
            end
            applyHeldPose(g, remote)
        elseif g.animSetFor ~= remote.sanim and animBelongsToGhost(g, remote) then
            w8(d + 0x2a, remote.sanim)
            animRestart(d, g)
            -- AND ASK THE ENGINE TO ACTUALLY PLAY IT. Setting the animation number alone is not
            -- enough, and this is the thing two earlier attempts both missed: the overworld PAUSES
            -- an idle object event's sprite, so the ghost held the animation's first frame for the
            -- entire cast. Measured across one: the ghost sat at 3/0 for 256 frames and then 11/0
            -- for the rest, while the player's own frame index cycled 0, 1, 3 throughout.
            --
            -- Done through the game's own switch rather than by clearing the paused bit ourselves.
            -- `enableAnim` (include/global.fieldmap.h:1, byte +0x01 bit 0x08) is what the engine
            -- reads in TryEnableObjectEventAnim (src/event_object_movement.c:7335-7343): it clears
            -- animPaused AND disableAnim, then clears itself. So one write per animation start
            -- hands the whole thing back to the engine, which is what makes the frames advance at
            -- the game's own rate instead of one we would have had to invent.
            -- Gated on the same swap cooldown as animRestart: enableAnim clears animPaused, and
            -- an un-paused ghost inside the tear window puts the engine's mid-frame frame copies
            -- right back. animSetFor stays nil while blocked, so the whole start re-runs -- with
            -- the engine allowed in -- on the first anim change past the window.
            if not animRestartBlocked(g) then
                w8(objAddr(g.objId) + 0x01, r8(objAddr(g.objId) + 0x01) | 0x08)
                g.animSetFor = remote.sanim
            end
        end

        -- AND THE SPRITE OFFSET THE TASK APPLIES. Measured: the engine sets the fishing player's
        -- pos2 to 8,0, which is what keeps the character on its tile inside a 32-wide frame. Our
        -- ghost has no fishing task to do that, so it sat half a tile to the side from the moment
        -- it picked up the rod -- *"both ghosts move while fishing"*, reported repeatedly while
        -- every position measurement said the ghost was exactly where it should be. It was: the
        -- OFFSET was missing, not the position.
        if isFishingGfx(g.gfx) then
            -- Owned by the BuildOamBuffer hook when it is active (registered at the bottom of
            -- this file): a write from HERE lands between emulated frames, and the engine then
            -- advances the animation before building OAM -- so image and offset change on
            -- different frames and the ghost flicks 8px at every alignment change. Measured:
            -- pos2 constant at 8 while OAM x went 144, 136, 144 on consecutive frames.
            if not tiering.fishAlignActive then alignFishingGhost(g) end
        elseif g.blobSprId then
            -- THE BOB IS THE ENGINE'S, so do not write over it. A surf blob set to
            -- BOB_PLAYER_AND_MON drives the RIDER's pos2 as well as its own -- that is the whole
            -- of the up-and-down on the water -- and it is already pointed at this ghost. Writing
            -- the peer's own offset here would put two things on one field, the same shape as the
            -- animNum fight that left a ghost stuck in a pose: our write lands between frames and
            -- the engine's lands during one, so the ghost would bob at the peer's phase, our
            -- phase, or neither. The peer's bob is not wanted anyway -- the ghost has a real blob
            -- of its own now, and it should ride its own.
        else
            if remote.sox then w16(d + 0x24, remote.sox & 0xffff) end
            if remote.soy then w16(d + 0x26, remote.soy & 0xffff) end
        end
    end

    -- UNDERWATER THE BOB IS A POSITION, NOT AN ANIMATION -- so it is applied even while moving.
    --
    -- The mirror above deliberately stands aside for a WALKING peer: its animation is the engine's
    -- to drive, and mirroring on top of that put two writers on one field. But the peer's sprite
    -- OFFSET is not an animation, and underwater it is the whole of the bob -- the game drives it
    -- with a dummy sprite we deliberately do not reproduce (spawnUnderwaterBobber's header). With
    -- the offset trapped inside that gate, a diver bobbed while idle and went rigid the moment it
    -- moved: the user, *"they stay static and don't bob while moving around"*.
    --
    -- Only underwater, and only when nothing else owns the field: a surf blob drives its rider's
    -- pos2 itself, and a walking ghost on land has no offset to carry.
    if g.gfx and UNDERWATER_GFX[g.gfx] and not g.blobSprId and remote.soy then
        local dw = sprAddr(g.sprId)
        w16(dw + 0x26, remote.soy & 0xffff)
        if remote.sox then w16(dw + 0x24, remote.sox & 0xffff) end
    end

    -- SLIDE COUNTER, kept rather than temporary: between them these two numbers found the paused
    -- sprite on the Mach Bike, the frozen legs on the Acro Bike, and the stranded ghost -- three
    -- faults no position or speed reading could see. A moving character with `paused` high is
    -- sliding, and that is invisible in any other measurement. "Sliding" is a character whose position advances while its legs
    -- do not, and no position counter can see it. Per second: frames the ghost was mid-step, how
    -- many of those changed its animCmdIndex, and how many it spent PAUSED while moving.
    if tiering.slide then
        local gd = sprAddr(g.sprId)
        local idx = r8(gd + 0x2b)
        if not ghostIsIdle(g) then
            tiering.slide.step = tiering.slide.step + 1
            if g.lastIdx ~= nil and g.lastIdx ~= idx then
                tiering.slide.legs = tiering.slide.legs + 1
            end
            if (r8(gd + 0x2c) & 0x40) ~= 0 then
                tiering.slide.paused = tiering.slide.paused + 1
            end
        end
        g.lastIdx = idx
    end

    -- THE ANIMATION-ALIGNMENT TRACE (probe, off by default -- MESHGHOST_EMERALD_ANIM_TRACE).
    --
    -- One line per frame carrying the PLAYER's sprite animation state and the GHOST's TOGETHER,
    -- plus the real OAM entry each is drawn from. Both halves on one line is the whole point: the
    -- fishing misalignment was two consumers disagreeing about which frame a value belonged to,
    -- and that is invisible in any trace that follows one of them at a time. The OAM columns are
    -- what settled it -- every struct field agreed with every other while the pixels on screen
    -- did not.
    --
    -- Buffered and flushed in batches, never console.log: per-frame console output visibly lags
    -- the game, and even a per-frame io.open is a probe heavy enough to change what it measures.
    if tiering.animTrace then
        local pd = sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04))
        local gd = sprAddr(g.sprId)
        tiering.animTraceBuf = tiering.animTraceBuf or {}
        do
            tiering.animTraceBuf[#tiering.animTraceBuf + 1] = string.format(
                "f=%d P.gfx=%s P.anim=%d/%d P.2c=%02x P.fl=%02x P.pos2=%d,%d | R.gfx=%s R.sanim=%s/%s R.anim=%s R.act=%s R.sox=%s | G.gfx=%s G.anim=%d/%d G.2c=%02x G.fl=%02x G.pos2=%d,%d G.setFor=%s | idle=%s | G.pos1=%d,%d G.crd=%d,%d R.xy=%.3f,%.3f objdir=%d act=%d | %s",
                frameCounter, tostring(localGraphicsId()),
                r8(pd + 0x2a), r8(pd + 0x2b), r8(pd + 0x2c), r8(pd + 0x3f), rs16(pd + 0x24), rs16(pd + 0x26),
                tostring(remote.gfx), tostring(remote.sanim), tostring(remote.sidx),
                tostring(remote.anim), tostring(remote.act), tostring(remote.sox),
                tostring(g.gfx), r8(gd + 0x2a), r8(gd + 0x2b), r8(gd + 0x2c), r8(gd + 0x3f),
                rs16(gd + 0x24), rs16(gd + 0x26), tostring(g.animSetFor),
                tostring(ghostIsIdle(g)),
                rs16(gd + 0x20), rs16(gd + 0x22),
                rs16(objAddr(g.objId) + 0x10) - MAP_OFFSET,
                rs16(objAddr(g.objId) + 0x12) - MAP_OFFSET,
                remote.x, remote.y,
                r8(objAddr(g.objId) + 0x18) & 0x0f,
                r8(objAddr(g.objId) + 0x1c),
                oamEntryFor(g.tileStart, r16(pd + 0x04) & 0x3ff))
        end
        if #tiering.animTraceBuf >= 120 then
            local tf = io.open(SCRIPT_DIR .. "probes/animtrace.log", "a")
            if tf then
                tf:write(table.concat(tiering.animTraceBuf, string.char(10)) .. string.char(10))
                tf:close()
            end
            tiering.animTraceBuf = {}
        end
    end
    -- Never interrupt a half-played step -- EXCEPT for a pending graphic change that is not
    -- fishing. The deferral was measured in for the rod (the engine owns the sprite offset
    -- mid-step, and a mid-step rod swap drew 8px off for three frames), but it costs up to a
    -- whole step of latency, and on a mount that is the spawned ghost visibly changing AFTER the
    -- painted one -- the user, with the pose war finally won: *"its doing the mount/dismount
    -- slower than the drawn ghost & player"*. A bike's and a walker's plain frames carry no
    -- offset, so for them the measured fault cannot occur and the swap may land mid-step; the
    -- swap branches below return on their own, so nothing past them runs while busy.
    -- PARK THE BLOB THE MOMENT A DISMOUNT IS ON THE WIRE -- before the busy guard, every frame,
    -- idempotently. The first version wrote BOB_JUST_MON only where the jump is ISSUED, and a
    -- ghost that happens to be busy that frame skips the issue -- the glide then walks it ashore
    -- with the blob still in PLAYER_AND_MON, following. The engine re-reads the state every
    -- frame, so writing it every frame of the jump costs nothing and depends on no timing.
    --
    -- MOUNT AND DISMOUNT SHARE THE ACTION IDS, and the discriminator is NOT the blob's age --
    -- that was the second version, ">30 frames old", and the user's quick load-and-jump beat it
    -- (*"the blob still follows it onto land"* with a blob ~20 frames old). The honest test is
    -- ORDER, the same order the game itself has: a mount CREATES its blob after the jump is
    -- already underway, a dismount's blob exists before the jump begins. So the edge of the
    -- action records whether a blob was already there, and that verdict holds for the action's
    -- whole lifetime.
    local inJs = remote.act and remote.act >= 0x3a and remote.act <= 0x3d
    if inJs and not g.jsActive then
        g.jsActive, g.jsDismount = true, g.blobSprId ~= nil
    elseif not inJs then
        -- The jump ended. A MOUNT's blob spent the jump inert (below); hand it to the engine
        -- now, exactly when PlayerAvatarTransition_Surfing does for the player's own.
        if g.jsActive and not g.jsDismount and g.blobSprId then
            local bd = sprAddr(g.blobSprId)
            w8(bd + 0x2e, (r8(bd + 0x2e) & 0xf0) | 1) -- BOB_PLAYER_AND_MON
        end
        g.jsActive, g.jsDismount = nil, nil
    end
    -- A MOUNT'S BLOB IS BORN HERE, once the engine holds the ghost's jump. InitJump writes the
    -- destination into the object's coords as the jump begins, so "the ghost's movementActionId
    -- is the jump" is exactly when its coords stop lying about where the blob belongs -- the
    -- swap-time spawn used the wire's smoothed position and put the blob on the LAND tile, where
    -- BOB_NONE then faithfully kept it (*"its still on the grass... then teleports when the
    -- spawned ghost actually gets onto the water"*).
    if inJs and not g.jsDismount and not g.blobSprId and g.gfx and SURFING_GFX[g.gfx] then
        local ja = objAddr(g.objId)
        local heldAct = r8(ja + 0x1c)
        if heldAct >= 0x3a and heldAct <= 0x3d then
            local bid = spawnSurfBlob(g, rs16(ja + 0x10) - MAP_OFFSET, rs16(ja + 0x12) - MAP_OFFSET)
            -- RE-PLACE FROM THE RIDER'S SPRITE. spawnSurfBlob's screen math carries the two
            -- camera terms that only cancel while the camera is AT REST -- documentation.md's own
            -- warning on this exact sprite -- and a mount jump is precisely when the camera is
            -- moving, so the blob landed a tile ashore of its correct water tile (logged born at
            -- the right tile while the user watched it sit on the grass). The engine's own
            -- placement is rider + (0, +8), measured 2026-08-19, and the rider's sprite position
            -- is engine-maintained against the live camera every frame -- so it cannot be stale.
            -- pos2 (the arc) is deliberately NOT copied: the blob waits flat on the water.
            if bid then
                -- Plus the jump's own one-tile step: at the accept frame the rider's sprite is
                -- still AT the land tile (the sprite animates across, it does not snap), and the
                -- destination is one tile along the jump's direction -- which the action id
                -- carries (JUMP_SPECIAL_DOWN..RIGHT, 0x3A..0x3D).
                local dxs = { [0x3a] = 0, [0x3b] = 0, [0x3c] = -TILE, [0x3d] = TILE }
                local dys = { [0x3a] = TILE, [0x3b] = -TILE, [0x3c] = 0, [0x3d] = 0 }
                local gs2, bd2 = sprAddr(g.sprId), sprAddr(bid)
                w16(bd2 + 0x20, (rs16(gs2 + 0x20) + (dxs[heldAct] or 0)) & 0xffff)
                w16(bd2 + 0x22, (rs16(gs2 + 0x22) + (dys[heldAct] or 0) + 8) & 0xffff)
            end
        end
    end
    if inJs and g.blobSprId then
        local bd = sprAddr(g.blobSprId)
        if g.jsDismount then
            w8(bd + 0x2e, (r8(bd + 0x2e) & 0xf0) | 2) -- BOB_JUST_MON: park in the water
        else
            -- A MOUNT'S BLOB IS INERT UNTIL THE RIDER LANDS ON IT. The game's own mount creates
            -- the blob at the destination and never sets a bob state during the jump --
            -- FldEff_SurfBlob leaves data[0] at BOB_NONE, and in that state UpdateBobbingEffect
            -- does nothing at all, so the blob waits in the water while the rider arcs onto it;
            -- BOB_PLAYER_AND_MON only arrives with the avatar transition at the end
            -- (field_effect.c:3042-3056, field_effect_helpers.c:1107-1135). Ours went straight
            -- to PLAYER_AND_MON, whose position sync dragged the blob along the rider's arc --
            -- the user: *"the drawn ghost jumps with the blob onto the water, instead of jumping
            -- from the grass onto the blob in the water"* (and the spawned did the same, less
            -- visibly). Our ghost's jump sets its object coords to the destination at the start,
            -- so the blob is already spawned at the right tile -- it just has to sit still.
            w8(bd + 0x2e, r8(bd + 0x2e) & 0xf0)    -- BOB_NONE: wait at the destination
        end
    end
    if not ghostIsIdle(g) then
        local pending = wantedGfx(remote)
        if not (pending and g.gfx and pending ~= g.gfx
            and not isFishingGfx(pending) and not isFishingGfx(g.gfx)) then
            return
        end
    end

    -- The graphic swap waits for the step to END, below this guard rather than above it.
    --
    -- A peer's state arrives while the ghost may still be mid-stride: its walk is engine-driven and
    -- takes 16 frames from when we asked for it, so a rod that arrives partway through lands on a
    -- WALKING ghost. The player can never do that -- you cannot start fishing mid-step -- and it
    -- has a mechanical consequence too: the engine owns pos2 for the duration of a step, so the
    -- peer's own sprite offset is overwritten every frame until the step finishes. Measured with a
    -- probe loaded before the adapter: three frames of the fishing graphic at pos2 0,0, drawn 8px
    -- left, ending exactly when the step did.
    --
    -- Waiting costs at most one step. It buys a ghost that stops, then fishes, like the player.
    -- The peer changed what they are: got on a bike, started surfing, cast a rod. Patched in place
    -- where possible -- position, pos2 and the engine's own settled state all survive, so there is
    -- no frame where the ghost is missing, doubled, or wearing the previous graphic's pixels.
    local wantNow = wantedGfx(remote)
    -- A GRAPHIC CHANGE ENDS IN A SETTLE, BOTH DIRECTIONS. The frame the swap loads is sampled from
    -- the wire mid-transition and can be a stride; every field-level correction attempted against
    -- that (six across one afternoon) either lost a tug-of-war or was judged against the wrong
    -- bytes. The user's own observation is the mechanism: *"it does get the correct/proper pose if
    -- you mount/dismount and then move 1 tile afterwards"* -- a step makes the ENGINE set the
    -- pose. The settle is a zero-motion step, so ask for it and let the game do the part only it
    -- does correctly. Static, not walk-in-place: nobody pedals or paces getting on or off a bike.
    if COMPARE_TIERS and remote.gfx ~= g.gfxWireSeen then
        g.gfxWireSeen = remote.gfx
        logFile(string.format("f=%d GFX on wire -> %s (ghost wears %s, idle=%s)",
            frameCounter, tostring(remote.gfx), tostring(g.gfx), tostring(ghostIsIdle(g))))
    end
    if wantNow and g.gfx and wantNow ~= g.gfx then
        if COMPARE_TIERS then logFile(string.format("f=%d emu=%d SWAP %s -> %s", frameCounter, emu.framecount(), tostring(g.gfx), tostring(wantNow))) end
        -- NO SETTLE FOR THE FIELD-MOVE POSE. The settle is a zero-motion step that makes the
        -- engine set a pose properly, and it is right for a state a peer STAYS in -- a bike, a
        -- rod, a surfboard. The field-move stance is not one of those: it is a 16-frame transient
        -- the game plays and leaves, and the settle's own step keeps the ghost BUSY for its whole
        -- duration -- which returns out of this function every frame, before the animation mirror
        -- that would have driven the peer's frames. So the pose fell to the engine's free-running
        -- playback at its own command durations: 25 frames instead of 16, skipping steps, which
        -- the painted copy shows too because in compare mode it reads its frame from this very
        -- sprite. The user: *"the drawn ghost does the starting surf animation a tiny bit slow"*.
        -- Measured with a gate trace: every mirror condition passed and the wire delivered all
        -- four steps on time -- the mirror was simply never reached.
        if not (wantNow == 3 or wantNow == 93) then
            g.needsSettle = true
            g.settleStatic = true
        end
        g.frameFor = nil
    end
    if wantNow and g.gfx and wantNow ~= g.gfx
        and swapGhostGraphicInPlace(g, wantNow, remote.sanim, remote.sox or 0, remote.soy or 0,
            remote.sidx, remote.spaused,
            -- targetX/Y, not raw wire: the loopback ghost stands offset from the player, and its
            -- blob must be born at ITS destination, not the player's.
            targetX, targetY)
    then
        -- No offset write here: swapGhostGraphicInPlace set it in the same batch as the shape,
        -- from the right source for the graphic. Writing the wire value on top of that -- which
        -- this path did until 2026-08-19 -- put the PLAYER'S current frame's offset onto the
        -- ghost's several-frames-older one, an 8px flash on the exact frame of every swap.
        return
    end

    -- The peer changed what they are: got on a bike, started surfing, cast a rod. A graphic swap
    -- means different images, animations, OAM shape and tile count, so the sprite is rebuilt
    -- rather than patched -- the same thing the engine does when the player's own state changes.
    local want = wantedGfx(remote)
    if want and g.gfx and want ~= g.gfx and cameraIsSettled() then
        local a = objAddr(g.objId)
        local atX, atY = rs16(a + 0x10) - MAP_OFFSET, rs16(a + 0x12) - MAP_OFFSET
        despawnGhost(playerId)
        spawnGhost(playerId, atX, atY, remote.orientation, want)
        -- The new sprite's tiles are whatever was in that range; fill them with the frame the
        -- engine is about to copy, so no frame is drawn with the old graphic's pixels.
        local ng = ghosts[playerId]
        if ng then loadGhostFrameNow(ng, graphicsInfo(want), remote.sanim, remote.sidx) end
        -- SWEEP IN THE SAME FRAME. despawnGhost only clears a slot it can still prove is ours
        -- (ghostAlive), and when that proof fails it deliberately touches nothing -- correct, but
        -- it leaves the old object active while the new one already exists. Captured in the
        -- fishing log: slot14 and slot15 both live across the swap, until the once-a-second sweep
        -- caught it. Sweeping here closes that window to the frame it happens in, which is what
        -- the user was seeing as the ghost "moving" when it casts a rod.
        sweepOrphanGhosts()
        -- AND APPLY THE PEER'S SPRITE OFFSET IN THE SAME FRAME. This path returns before the
        -- mirroring block below, so without this the ghost spends a frame at pos2 0,0 with its new
        -- 32-wide graphic -- half a tile off -- and then snaps into place when the next update
        -- arrives. The rebuild is already a visible cut; adding a snap to it is what
        -- *"looks a bit snappy and they also briefly move"* is made of.
        if ng then
            local nd = sprAddr(ng.sprId)
            if remote.sanim then
                w8(nd + 0x2a, remote.sanim)
                animRestart(nd, ng)
                -- And let the engine play it -- a rebuilt ghost is paused exactly like a swapped
                -- one, and without this it holds the first frame for the whole state.
                if not animRestartBlocked(ng) then
                    w8(objAddr(ng.objId) + 0x01, r8(objAddr(ng.objId) + 0x01) | 0x08)
                    ng.animSetFor = remote.sanim
                end
            end
            if isFishingGfx(ng.gfx) then
                alignFishingGhost(ng)
            else
                if remote.sox then w16(nd + 0x24, remote.sox & 0xffff) end
                if remote.soy then w16(nd + 0x26, remote.soy & 0xffff) end
            end
        end
        return
    end


    -- A LEDGE HOP, BEFORE ANY STEP LOGIC LOOKS AT THE DISTANCE.
    --
    -- Two earlier attempts failed and the capture says why. First: "the peer moved two tiles in
    -- one update" -- it never does. The engine advances the tile counter ONE TILE AT A TIME
    -- through a hop (measured: coords 16,18 -> 16,19 -> 16,20 while act stayed 12), and the core's
    -- interpolation smooths it further. Second: the same test as an `elseif` after the one-tile
    -- branch -- unreachable, because a one-tile delta is exactly what a hop looks like every
    -- frame, so the walk branch always matched first and the ghost walked down the ledge.
    --
    -- What the peer sends is the ENGINE'S OWN INTENTION: movementActionId, which is
    -- JUMP_2_DOWN/UP/LEFT/RIGHT (0xC..0xF) for the whole hop. Acting on that has to come first,
    -- because by the time distance is being measured the hop is indistinguishable from walking.
    --
    -- Issued ONCE per hop: the action stays set for the whole jump, and re-issuing it every frame
    -- would send the ghost hopping across the map. The latch clears when the peer stops reporting
    -- a jump, so the next ledge is a fresh one.
    -- ACTIONS THE PEER PERFORMS THAT NO AMOUNT OF WATCHING POSITIONS CAN RECOVER.
    --
    -- A ledge hop was the first of these: two tiles and an arc, indistinguishable from walking by
    -- the time distance is being measured. The Acro Bike is a whole family of them, and they share
    -- the property that made the ledge hop impossible to infer -- they happen ON THE SPOT. A bunny
    -- hop, a standing wheelie, popping into or out of one: the tile never changes, so every branch
    -- below sees "the peer did not move" and falls through to turning the ghost on the spot. The
    -- user, riding one: *"the spawned ghost is turning, while im jumping around on it"*, and
    -- *"not supposed to turn facing direction that way"*.
    --
    -- So the peer's own movementActionId is performed verbatim for all of them
    -- (include/constants/event_object_movement.h):
    --   0x0C..0x0F  JUMP_2_*                 ledge hops
    --   0x46..0x4D  JUMP_IN_PLACE_*          the bunny hop, including the two-way variants
    --   0x64..0x83  ACRO_*                   wheelie face/pop/end/hop/jump/in-place/move
    --
    -- LATCHED ON THE VALUE, not on a boolean: a hop is a one-shot and a standing wheelie is a HOLD,
    -- and issuing either one twice restarts it. Re-issuing only when the action CHANGES covers both
    -- without needing to know which is which.
    -- HALF OF THEM MOVE A TILE, and holding those stops the ghost following at all -- reported
    -- immediately: *"the ghosts are not following me when im jumping and moving"*. Reading the
    -- block as one range was the mistake; it interleaves in-place and travelling actions:
    --   IN PLACE  0x46..0x4D jump in place · 0x64..0x73 wheelie face/pop/end/hop-face
    --             0x7C..0x7F wheelie in place
    --   TRAVELS   0x0C..0x0F ledge jump · 0x74..0x7B wheelie hop/jump · 0x80..0x83 pop-wheelie move
    -- An in-place action is mirrored and HELD, because nothing else will move the ghost and the
    -- position logic below would turn it instead. A travelling one is mirrored once and then left
    -- to the ordinary step logic, which is what keeps the ghost following.
    -- THE WHEELIE POSES ARE MIRRORED AGAIN, 2026-08-20, after the reason they were dropped turned
    -- out not to be true. They had been excluded because the watchdog in ghostIsIdle kept freeing
    -- 0x69, 0x6B and 0x6D at its 60-frame limit, and the guess written here was that they need the
    -- acro state the engine keeps on the PLAYER, which a ghost has none of.
    --
    -- Measured instead of guessed (probes/wheelie_watch.lua and probes/wheelie_ghost.lua, both in
    -- verified.md). On the player every one of these actions completes -- 0x6B ran nine frames and
    -- reported finished. On a GHOST they complete too, in eleven frames, under every condition the
    -- hang was blamed on: sitting idle, issued on top of a step already running, and with the
    -- sprite's paused bit set or cleared. Nothing reproduced the hang, so what caused it was
    -- something else in the state of that session, and the same day's paused-sprite and
    -- graphic-swap fixes are the candidates.
    --
    -- CORRECTED 2026-08-20: this comment used to add "and in all four directions including the
    -- exact ids the watchdog had been freeing". That was never measured. The probe's issuing line
    -- ignored each condition's action id and re-derived it from the ghost's own facing, so all six
    -- "directions" issued the same id -- which is why all six finished in exactly eleven frames.
    -- A mismatched direction remains UNTESTED. `probes/wheelie_ghost.lua`'s header carries the
    -- detail and the fix.
    --
    -- The watchdog stays exactly as it is: it costs nothing, it logs what it frees, and it is the
    -- reason this was diagnosable at all. If the hang comes back, it will say so by name.
    -- RELEASE THE SIDE-HOP FACING LOCK THE MOMENT THE PEER STOPS SIDE HOPPING.
    --
    -- It was released only once the ghost stood still on its target tile, which is too late: a peer
    -- who hops sideways and then rides on leaves the ghost MOVING with facing still pinned, and
    -- `SetObjectEventDirection` refuses to write facingDirection while the bit is set -- so the
    -- ghost carried the hop's facing through the steps that followed and only caught up when it
    -- finally stopped. The user, 2026-08-21: *"while jumping and then moving, the spawned ghost is
    -- changing the direction a bit slow"*.
    --
    -- The engine releases it on the input tick AFTER the jump, not when the player next stands
    -- still (`AcroBikeHandleInputSidewaysJump`, src/bike.c:518-523) -- so the peer's action leaving
    -- the side-hop range is the matching moment here. Only OUR lock is cleared: `lockGhostFacing`
    -- uses the same bit for the move-one-way-face-another case and manages its own lifecycle per
    -- step, and this runs before that so it can re-assert it in the same frame if it still applies.
    if g.sideHopLock and not (remote.act and remote.act >= 0x42 and remote.act <= 0x45) then
        local sa = objAddr(g.objId)
        w8(sa + 0x01, r8(sa + 0x01) & ~0x02)
        g.sideHopLock = nil
    end

    local inPlace = remote.act and (
        (remote.act >= 0x46 and remote.act <= 0x4d)
        or (remote.act >= 0x64 and remote.act <= 0x73)
        or (remote.act >= 0x7c and remote.act <= 0x7f))
    -- THE TRAVELLING BLOCK RUNS TO 0x8B, not 0x83. Cut short, the wheelie MOVE and END_WHEELIE
    -- MOVE actions fell through to an ordinary walk: the ghost kept up -- its coordinates track the
    -- peer's throughout, measured -- but rode along without the wheelie or the hop, which is what
    -- "not doing it like the player" looks like from the chair.
    --   0x74..0x7B WHEELIE_HOP/JUMP · 0x80..0x83 POP_WHEELIE_MOVE
    --   0x84..0x87 WHEELIE_MOVE     · 0x88..0x8B END_WHEELIE_MOVE
    -- 0x42..0x45 JUMP_* -- THE SIDE HOP -- IS PERFORMED VERBATIM, like a ledge hop.
    --
    -- It was in neither list, so the ghost never performed it: it simply STEPPED to the tile the
    -- peer had hopped to. That is why it had no dust. The engine raises landing dust from a jump
    -- FINISHING (`UpdateJumpAnim` sets landingJump, and GroundEffect_JumpLandingDust reads the
    -- object's coords), and a ghost that walks the tile never finishes a jump, so there was nothing
    -- to raise it -- measured 2026-08-21 with probes/shadowdust_probe.lua over a run of side hops:
    -- 19 dust sprites, every one of them at dx=0, i.e. the player's own and none for the ghost.
    --
    -- Performing the action is also the right fix rather than painting a puff ourselves, and for
    -- the standing reason on this project: let the game do the work. The ghost hops, so the engine
    -- gives it the arc, the dust and the landing -- and the painted tiers, which are pinned to that
    -- sprite, then record their puff where the ghost actually lands instead of where it was still
    -- catching up to. That is the same *"not supposed to trail/be after you"* the user reported,
    -- fixed at its cause instead of by an offset.
    --
    -- Verbatim rather than animation-only (the acroBase treatment below): like a ledge hop this
    -- covers real ground in one arc that no ordinary step reproduces, and the position logic agrees
    -- with it afterwards.
    -- 0x3A..0x3D JUMP_SPECIAL -- THE HOP ONTO THE WATER -- is here for the same reason the side
    -- hop is: it covers a tile in one arc that no ordinary step reproduces, and it is the whole
    -- difference between a peer who STARTS SURFING and one who slides onto the sea.
    --
    -- The game's own sequence (src/field_effect.c:3018-3056): field-move pose, show the Pokemon,
    -- and only then set the surfing graphic AND issue
    -- ObjectEventSetHeldMovement(GetJumpSpecialMovementAction(dir)) while creating the surf blob
    -- at the DESTINATION tile. Measured live 2026-08-21 on the player's own object event: gfx 0 ->
    -- 3 with act=0x39 (START_ANIM_IN_DIRECTION, the pose), then gfx=2 with act=0x3A and pos2 y=-4,
    -- the arc itself. The ghost read act=0x00/0xFF throughout, because 0x3A fell through every
    -- list here -- so it popped from standing on land to surfing and then glided down a tile. The
    -- user, watching all three tiers: *"its just the starting surf -> going to surf part that is
    -- weird"*.
    local travels = remote.act and (
        (remote.act >= 0x0c and remote.act <= 0x0f)
        or (remote.act >= 0x3a and remote.act <= 0x3d)
        or (remote.act >= 0x42 and remote.act <= 0x45)
        or (remote.act >= 0x74 and remote.act <= 0x7b)
        or (remote.act >= 0x80 and remote.act <= 0x8b))
    -- One line per CHANGE of the peer's action, with what the ghost is doing at that moment. Three
    -- edits have now been made to the Acro handling without once looking at what the peer actually
    -- sends, which is the guessing this project has a rule against.
    if COMPARE_TIERS and g.lastAct ~= remote.act then
        g.lastAct = remote.act
        -- The SENT graphic beside the RECEIVED one: `gfx=nil` on the wire while the player is
        -- visibly on a bike means the two disagree, and only printing both says which end is wrong.
        logFile(string.format("ACT sending gfx=%s | peer=%s -> ghost act=%d idle=%s inPlace=%s "
            .. "travels=%s gfx=%s pos2=%d,%d",
            string.format("%s (confirmed=%s objId=%d raw=%d sent=%s pending=%s ticks=%s)",
                tostring(localGraphicsId()), tostring(avatarAddrConfirmed),
                r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05),
                r8(GOBJECTEVENTS_ADDR + avatarAddrOffset
                    + r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05) * OBJECTEVENT_SIZE + 0x05),
                tostring(genderFrames.sentGfx), tostring(genderFrames.pendingGfx),
                tostring(genderFrames.pendingTicks)),
            tostring(remote.act), r8(objAddr(g.objId) + 0x1c), tostring(ghostIsIdle(g)),
            tostring(inPlace and true or false), tostring(travels and true or false),
            tostring(remote.gfx), rs16(sprAddr(g.sprId) + 0x24), rs16(sprAddr(g.sprId) + 0x26)))
    end
    -- A TRAVELLING ACTION MOVES THE GHOST ITSELF, so issuing it verbatim AND letting the step
    -- logic run is two things moving one character -- the ghost lurching about while the painted
    -- copy, which is driven only by the position stream, looked correct (user, 2026-08-20: *"the
    -- spawned ghost is moving weird ... the drawn one looks fine"*). That comparison is the whole
    -- diagnosis: same data in, one tier fine, so the fault is in what the spawned tier DOES with it.
    --
    -- A ledge hop is the exception and stays verbatim: it covers two tiles in one arc that no step
    -- can reproduce, and the position logic agrees with it afterwards.
    --
    -- Every other travelling Acro action is used for its ANIMATION only: the step below asks for
    -- the same family in the direction the ghost actually needs to go. The families are four
    -- consecutive actions in DIR order starting at a multiple of four (0x74 hop, 0x78 jump, 0x80
    -- pop-wheelie move, 0x84 wheelie move, 0x88 end-wheelie move), so the family base is act & 0xFC.
    local acroBase = nil
    if travels and remote.act >= 0x74 then acroBase = remote.act & 0xfc end
    if acroBase then travels = false end

    -- A POSE IS A HOLD, AND A HOLD HAS TO BE RELEASED.
    --
    -- The in-place Acro actions are not one-shots: a standing wheelie holds until something ends
    -- it. Issued to a ghost and then left, the object never reports finished, so `ghostIsIdle` is
    -- false for ever, no further step is ever requested, and the ghost simply stops following --
    -- with its sprite paused the whole time, which is what `paused=300 of 300` in the status line
    -- was saying. The peer moving on is the signal to let go.
    if not (inPlace or travels) then
        if g.jumped then clearHeldMovement(g) end
        g.jumped = nil
    end
    -- A REPEATED one-shot has to re-fire. Latching on the value alone means a peer hopping on the
    -- spot over and over reports the same action id throughout, so the ghost hopped ONCE and then
    -- stood there -- which is also why its landing dust appeared only when it was travelling
    -- (user, 2026-08-20). Clearing the latch once the ghost is idle again lets each hop be its own
    -- hop, while a HELD pose (a standing wheelie) still issues once because the ghost never goes
    -- idle underneath it.
    if inPlace and g.jumped == remote.act and ghostIsIdle(g) then g.jumped = nil end
    -- AN IN-PLACE POSE MUST NEVER COST THE GHOST A STEP IT OWES.
    --
    -- This branch issues the peer's action and RETURNS, so no step is taken that frame -- which is
    -- right for a pose and wrong whenever the ghost still has ground to cover. The wheelie poses
    -- were folded back into `inPlace` earlier today and brought that straight back: a peer who pops
    -- a wheelie and rides on reports a new pose id repeatedly, the branch fires on each one, and
    -- the ghost never steps. *"If i wheelie, and move 1 tile, the ghosts are not following me"* --
    -- the same shape as the older *"the ghosts are not following me when im jumping and moving"*,
    -- which is why the poses were dropped the first time.
    --
    -- The guard further down already says it: being AT the target tile is the honest test for
    -- "there is nothing to do but pose". Applied here too, so a pose is issued only when the ghost
    -- is where it belongs, and otherwise the step logic below runs and covers the tile first.
    -- Travelling actions are unaffected -- they move the ghost themselves.
    if inPlace and not travels
        and (targetX ~= rs16(objAddr(g.objId) + 0x10) - MAP_OFFSET
            or targetY ~= rs16(objAddr(g.objId) + 0x12) - MAP_OFFSET)
    then
        inPlace = false
    end
    -- LATCH ONLY WHAT ACTUALLY LANDED.
    --
    -- `g.jumped` records "this peer action has been performed", and it used to be set at the
    -- moment of asking. A ghost mid-bounce is not listening: the engine is playing out the
    -- current jump and the movementActionId written underneath it is picked up only when that
    -- finishes -- so an order given mid-arc is dropped, while the latch remembers it as done and
    -- nothing ever re-sends it. On a held B, where the peer's action changes ONLY in its
    -- direction, that is a ghost frozen in whichever way it first set off: the user, twice, and
    -- precisely the second time -- *"the ghost get stuck facing with the direction it starts the
    -- jumping with, even if the player swaps direction while jumping afterwards"*. The facing
    -- probe measured the same thing from the other end: the ghost held act=72 for seven state
    -- changes after the peer went to 73, then adopted it the moment its bounce ended.
    --
    -- So the latch is set only when the ghost was actually free to take the order. Busy, it is
    -- left alone and the same order is re-sent next frame, which costs nothing and lands on the
    -- first frame the engine is listening. The branch still returns either way -- a pose must not
    -- also spend a step -- so nothing else about this path changes.
    -- NEVER START AN ACTION ON A GRAPHIC THAT IS ABOUT TO BE REPLACED.
    --
    -- The engine chooses an animation for the action it is given, and it chooses it for whatever
    -- graphic the sprite is wearing at that instant. Issue the surf jump one frame before the
    -- surfing graphic lands and it sets the jump's animation number on the field-move sprite,
    -- whose table is shorter and has no such entry -- one frame of a frame that does not exist,
    -- which is visible: *"a weird grey/flashing glitched sprite"*. Measured as `anim=20/4 gfx=3`
    -- by probes/dive_probe.lua's VRAM-against-ROM check, one frame before every swap.
    --
    -- The send side was fixed first (the graphic and the action now leave together), and a single
    -- frame of skew survived it, so this is the belt to that braces.
    --
    -- GATED ON A PENDING SWAP, not on the two graphics simply matching. With the peer-graphic path
    -- off -- the shipped default -- a ghost wears the LOCAL player's graphic, so "they differ" is
    -- the normal state and gating on it would silently stop a peer on a bike ever hopping. What
    -- matters is narrower: are we about to change this ghost's graphic? Then wait one frame.
    local swapPending = (function()
        local w = wantedGfx(remote)
        return w ~= nil and g.gfx ~= nil and w ~= g.gfx
    end)()
    if (inPlace or travels) and g.jumped ~= remote.act and not swapPending then
        if ghostIsIdle(g) then
            g.jumped = remote.act
            g.needsSettle = nil
            -- A SIDE HOP TRAVELS WITHOUT TURNING, and the lock is how the engine says so.
            --
            -- `InitJump` opens with SetObjectEventDirection(objectEvent, direction)
            -- (event_object_movement.c:5436), so performing JUMP_LEFT turns the character to face
            -- left -- which is right for a ledge hop and wrong for this, the one move whose whole
            -- character is hopping sideways while still looking where you were. The engine's own
            -- answer is to set facingDirectionLocked FIRST: `AcroBikeTransition_SideJump`
            -- (src/bike.c:662-664) locks, then issues the jump, and SetObjectEventDirection
            -- (:2361-2371) then writes movementDirection while leaving facingDirection alone.
            -- Issuing the action without the lock gave the ghost the turn the player never makes
            -- -- the user, 2026-08-21: *"its supposed to keep looking forward during the side hop,
            -- not turn to face towards where the side hop goes"*.
            --
            -- Released by the standing-on-target branch below, which is the same moment
            -- `AcroBikeHandleInputSidewaysJump` (:518-523) clears it for the player and re-asserts
            -- the facing it preserved.
            -- objAddr directly: the function's own `a` is declared further down, and reaching
            -- for it here would read a nil GLOBAL -- the forward-reference trap this file has
            -- already been bitten by three times.
            if remote.act >= 0x42 and remote.act <= 0x45 then
                local ja = objAddr(g.objId)
                w8(ja + 0x01, r8(ja + 0x01) | 0x02)
                g.sideHopLock = true
            end
            -- A DISMOUNT PARKS THE BLOB BEFORE THE JUMP, exactly as the game does it.
            --
            -- Task_StopSurfingInit (field_player_avatar.c:1662-1674) sets the blob to
            -- BOB_JUST_MON and only then issues the jump; in that state UpdateBobbingEffect
            -- (field_effect_helpers.c:1107-1135) keeps the blob bobbing IN PLACE and stops
            -- copying the rider's position -- which is the whole of "the blob stays in the
            -- water while you jump ashore". We never sent that state, so a ghost's blob rode
            -- ashore under it: the user, with slot 2 re-aimed at this exact transition, *"the
            -- blob follows them onto land... the blob is supposed to stay in the water"*.
            -- Filmed on the player's own blob during the repro: data[0] low nibble 1 -> 2 on
            -- the dismount frame, position parked.
            --
            -- Distinguishing a dismount from a MOUNT (same action ids): a mount's blob is
            -- created moments before its jump, a dismount's has been alive the whole surf.
            -- No restore is needed -- every dismount ends in the walker graphic, whose swap
            -- despawns the blob, exactly as Task_WaitStopSurfing destroys the game's own.
            if remote.act >= 0x3a and remote.act <= 0x3d and g.blobSprId
                and g.blobSince and frameCounter - g.blobSince > 30 then
                local bd = sprAddr(g.blobSprId)
                w8(bd + 0x2e, (r8(bd + 0x2e) & 0xf0) | 2) -- BOB_JUST_MON (field_effect_helpers.h)
            end
            requestAction(g, remote.act)
        end
        return
    end

    local dir = DIR_ID[remote.orientation] or DIR_ID.south

    -- Trust the engine's own coordinates rather than our record of them: it owns the object once
    -- a step is under way, and a step that got cancelled would otherwise leave us out of sync.
    local a = objAddr(g.objId)
    local curX = rs16(a + 0x10) - MAP_OFFSET
    local curY = rs16(a + 0x12) - MAP_OFFSET
    local dx, dy = targetX - curX, targetY - curY

    -- HOLD AN IN-PLACE POSE ONLY WHEN THE GHOST IS WHERE IT BELONGS.
    --
    -- The hold exists so a standing wheelie is not turned or stepped out of underneath. But a peer
    -- riding an Acro Bike reports the in-place hop actions (0x70..0x73) WHILE TRAVELLING between
    -- tiles too, and holding on those stopped the ghost following at all -- reported twice, and the
    -- second time it was genuinely this rather than my own input probe fighting the pad.
    --
    -- Being at the target tile is the honest test for "there is nothing to do but pose". With a
    -- tile still to cover, the step logic below must run whatever pose the peer is in.
    -- WHICH BRANCH DECIDED, once a second. Three edits have been made to this path on reports
    -- alone; the question "why did the ghost not move" has a finite set of answers and this prints
    -- which one it was.
    if COMPARE_TIERS and frameCounter % 15 == 0 then
        logFile(string.format("HOP act=%s inPlace=%s travels=%s latch=%s d=%d,%d idle=%s "
            .. "ghostAct=%d held=%02X orient=%s gFace=%d",
            tostring(remote.act), tostring(inPlace and true or false),
            tostring(travels and true or false), tostring(g.jumped), dx, dy,
            tostring(ghostIsIdle(g)), r8(a + 0x1c), r8(a + 0x00),
            tostring(remote.orientation), r8(a + 0x18) & 0x0f)
            .. string.format(" | peer=%.2f,%.2f ghost=%d,%d | gfx ghost=%s peer=%s want=%s",
                remote.x, remote.y, curX, curY, tostring(g.gfx), tostring(remote.gfx),
                tostring(wantedGfx(remote))))
    end
    -- A HOPPING GHOST MUST STILL BE ABLE TO TURN.
    --
    -- The pose hold below returns without issuing anything, which is right for a peer holding a
    -- standing wheelie and wrong the moment they turn while still holding it. On the Acro Bike a
    -- held B is ONE repeating action, so a peer who spins on the spot mid-hop changes only the
    -- DIRECTION of that action -- and with the ghost already at the target tile, every branch
    -- below is skipped and it keeps hopping the way it first set off. The user, who pinned this
    -- down exactly, 2026-08-21: *"the ghost get stuck facing with the direction it starts the
    -- jumping with, even if the player swaps direction while jumping afterwards"*, and it is what
    -- the facing probe measured as the ghost holding act=72 for seven state changes after the
    -- peer had gone to 73.
    --
    -- Re-issuing the peer's own action is the whole fix: its id already encodes the direction, so
    -- the ghost performs the same hop the peer is performing, facing the same way. Guarded on the
    -- ghost being IDLE so a bounce already in flight is never interrupted mid-arc, and on the
    -- facing actually disagreeing so a held pose is still issued exactly once.
    -- ANY jump, not just the in-place ones: a travelling hop reaches here too the moment the ghost
    -- has caught up, and the branch below would then spend a separate TURN action to change its
    -- facing. A hop already carries its own direction -- the id IS the direction -- so turning
    -- first and hopping second is one animation the peer never performs, seen as *"doing an extra
    -- animation as well before swapping facing direction when jumping and moving around"* (user,
    -- 2026-08-21). Re-issuing the peer's own action is both the turn and the hop, in one.
    -- A PEER WHO IS STILL HOPPING HAS A GHOST THAT IS STILL HOPPING.
    --
    -- The wheelie-hop families are handled as animation-only (`acroBase` below), which means the
    -- ghost performs them only as part of covering a tile. Caught up with the peer, it therefore
    -- stopped bouncing altogether and waited for ground to cross -- and since a turn can only be
    -- adopted when an action is issued, the turn waited for that step too. Measured with
    -- probes/facing_probe.lua, 2026-08-21:
    --   f=240 P=77 G=73   f=243 P=77 G=FF   f=251 P=77 G=77
    -- the ghost IDLE at 243 with nothing to do, adopting only at 251. Eleven frames, none of them
    -- the wire, and it reads as *"turning around a bit slow while jumping around"*.
    --
    -- The rule this restores is the plain one: anything the player can do, a ghost does too. A peer
    -- hopping on the spot is hopping, so the ghost hops -- issued afresh each time it comes free,
    -- which keeps its bounces in step with the peer's instead of on a grid of its own, and makes a
    -- direction change land on the very next bounce exactly as it does for the player.
    if isJumpAction(remote.act) and dx == 0 and dy == 0 then
        if ghostIsIdle(g) then
            g.jumped = remote.act
            requestAction(g, remote.act)
        end
        return
    end
    if inPlace and dx == 0 and dy == 0 then return end

    if dx == 0 and dy == 0 then
        -- RELEASE THE FACING LOCK ONCE THERE IS NOWHERE TO GO.
        --
        -- `lockGhostFacing` sets the engine's own facingDirectionLocked whenever a peer moves one
        -- way while facing another, and clears it on the next step where the two agree. The Acro
        -- Bike's SIDE HOP is that case by definition -- it travels sideways without turning -- so
        -- it reliably leaves the lock set, and a peer who then just turns on the spot issues no
        -- step at all: nothing reaches the release, `SetObjectEventDirection` (:2361-2371) refuses
        -- to write facingDirection while the bit is set, and the ghost is frozen facing the way it
        -- hopped. The user, 2026-08-21: *"after doing a side hop, the spawned ghost facing
        -- direction gets stuck until you move a tile"* -- moving a tile being the one thing that
        -- reached the release.
        --
        -- Standing on the target tile means there is no movement left for the lock to protect, so
        -- this is the honest place to drop it. The engine does the same for the player: the lock
        -- bike.c sets for the hop is released when the hop resolves, not held until they walk.
        if (r8(a + 0x01) & 0x02) ~= 0 then w8(a + 0x01, r8(a + 0x01) & ~0x02) end
        -- A RIDER DOES NOT WALK IN PLACE. `FACE_ACTION` is walk-in-place-fast on purpose, because
        -- that is how a walking player turns -- but a rider turns as part of moving, and standing
        -- still on a bike is the STATIC pose: the player's own object reports 0x00..0x03 the whole
        -- time it is stopped on the Acro Bike (probes/wheelie_watch.lua, 2026-08-20).
        --
        -- So every turn and every settle was spending a walk-in-place animation the player never
        -- performed, and a single tile costs two of them -- one to turn, one to settle. Measured
        -- with probes/onestep.lua: one tile east cost the player ONE action and two frames of the
        -- pedal cycle, and the ghost three actions and four frames. The user: *"when moving a
        -- single tile, its 'over animating', the characther is not supposed to wiggle from just 1
        -- step, only when constantly biking in 1 direction"*.
        if (r8(a + 0x18) & 0x0f) ~= dir then
            requestAction(g, (isBikeGfx(remote.gfx) and FACE_STILL_ACTION or FACE_ACTION)[dir])
            g.stillSince = nil
            return
        end
        -- Facing is already right and the peer has not moved. If they are nonetheless REPORTING
        -- movement, they are walking into something -- so bump, the way the player does.
        local moving = (remote.anim == "walking" or remote.anim == "running")
        if not moving then
            g.stillSince = nil
            -- SETTLE A GHOST THAT WAS RUNNING. We drive a run by issuing a run action per tile;
            -- when the peer stops we simply stop issuing them, and the engine leaves the object on
            -- whatever frame the last one ended on -- so the ghost stands there in a running pose.
            -- The player never looks like that because the game returns them to standing itself.
            -- Found by the user 2026-08-19 in the side-by-side, and it is the SPAWNED half that
            -- was wrong for once: *"the injected/spawned ghost gets stuck in a wrong pose/sprite
            -- after stopping after a run, the drawn one looks fine"*.
            --
            -- Asking the engine to face the way it already faces is how the game itself settles a
            -- character, so the standing frame comes from the same place every other pose does.
            if g.needsSettle then
                g.needsSettle = nil
                g.frameFor = nil
                -- The static pose on a bike, for the reason given at the turn above: a rider that
                -- settles with walk-in-place pedals once more for no reason. And after a GRAPHIC
                -- CHANGE for any graphic -- nobody paces while getting on or off a bike.
                if COMPARE_TIERS and g.settleStatic then logFile(string.format("f=%d SETTLE fires", frameCounter)) end
                requestAction(g, ((g.settleStatic or isBikeGfx(remote.gfx))
                    and FACE_STILL_ACTION or FACE_ACTION)[dir])
                g.settleStatic = nil
                -- THE STANDING ANIMATION GOES WITH THE SETTLE. The settle is itself an action, and
                -- for the eight frames it runs the ghost is not idle -- so the mirror below is
                -- blocked and the engine goes on advancing whatever was playing, which on a bike is
                -- the pedal cycle. Two more frames of pedalling, every stop, on top of the ones the
                -- step already cost. Handing it the peer's number here (the number ONLY, no
                -- animBeginning -- restarting an animation is its own old bug) leaves the engine
                -- advancing a standing animation instead of a rolling one, and there is still just
                -- one thing driving it.
                if remote.sanim and animBelongsToGhost(g, remote) then
                    w8(sprAddr(g.sprId) + 0x2a, remote.sanim)
                end
            end
            -- AND THE PIXELS HAVE TO FOLLOW THE POSE. Settling sets the animation the ghost should
            -- be showing; it does not put that frame's IMAGE anywhere. An object event's frames are
            -- copied into its own OBJ VRAM range when its animation ADVANCES, and a ghost standing
            -- still advances nothing -- so it reported the standing frame and went on displaying
            -- the last rolling one it had been given. The user, 2026-08-20, on the Acro Bike:
            -- *"it looks as if its tilted while idle, due to the 'while moving' animation making
            -- the sprite move a bit back/forth left/right while pedaling"*, and *"it looked good
            -- for a sec there when you swapped/reload... after moving and going idle again its
            -- still tilted"* -- good exactly while the spawn path's own frame copy was fresh.
            --
            -- Invisible to every trace this adapter had, because every FIELD agreed: player and
            -- ghost both on animation 4/3, unchanged for 180 frames. It took reading the two tile
            -- ranges (probes/posediff.lua) to see 120 of 512 bytes differing underneath.
            --
            -- Copy the frame the PEER is actually displaying, which is the 1:1 answer rather than
            -- the nearest one, and do it ON A CHANGE ONLY: a frame copy is 128 read+write pairs
            -- and loadGhostFrameNow's own note is that it is cheap once and ruinous per frame.
            --
            -- AND ONLY ONCE THE ENGINE HAS LET GO. A peer stopping does not stop the GHOST: it is
            -- still a step or two behind and keeps being given catch-up steps, and every one of
            -- those advances the animation and copies a rolling frame over ours. Measured, which
            -- is the only reason this was found -- the first version of this copy landed while the
            -- ghost was still catching up and read `differing: 0`, then the engine's own next step
            -- put it back to 152 and the key said the work was already done. The user saw exactly
            -- that: *"it still looks wrong directly after stopping from having moved, it only
            -- looks correct after stopping and then changing a facing direction"* -- a turn being
            -- the next thing that happened to give the tiles one last correct copy.
            --
            -- movementActionId back to NONE is the engine saying it has nothing left to run, so it
            -- is the earliest moment a copy cannot be overwritten. Until then the key is cleared,
            -- so the copy re-arms after every action rather than counting itself already done.
            if r8(a + 0x1c) ~= MOVEMENT_ACTION_NONE then
                g.frameFor = nil
            elseif remote.sanim and g.gfx and animBelongsToGhost(g, remote) then
                local key = remote.sanim * 8 + (remote.sidx or 0)
                if g.frameFor ~= key then
                    g.frameFor = key
                    loadGhostFrameNow(g, graphicsInfo(g.gfx), remote.sanim, remote.sidx)
                end
            end
            return
        end
        g.stillSince = g.stillSince or frameCounter
        -- NOT ON A BIKE. `BUMP_ACTION` is the walk-in-place SLOW shuffle a walker does against a
        -- wall (`PlayerNotOnBikeCollide` -- the name says it), and a rider does not do it. Given to
        -- a ghost on a bike it reads as the sprite twitching backwards for a moment: the user,
        -- 2026-08-20, *"the spawned one actually flips the sprite in reverse for a bit for some
        -- reason"*, and the log had it as action 0x1B on the ghost while the peer was riding.
        --
        -- Third member of the same family of bugs today, after FACE_ACTION and the walk step: a
        -- constant chosen for a walker, correct there, wrong the moment the peer is on a bike.
        -- Standing still is closer to 1:1 than performing an animation the player cannot perform;
        -- what a blocked RIDER actually does is unmeasured, and is registered in unverified.md
        -- rather than guessed at here.
        if frameCounter - g.stillSince >= BUMP_AFTER_FRAMES and not isBikeGfx(remote.gfx) then
            requestAction(g, BUMP_ACTION[dir])
        end
        return
    end
    g.stillSince = nil

    -- PLAYER_SPEED_* -> the game's own action for that speed, shared by the step below and the
    -- catch-up path further down so both move at the peer's pace.
    --   FAST -> WALK_FAST 0x15, FASTER/FASTEST -> WALK_FASTER 0x2D
    --   (include/constants/event_object_movement.h:108,132; sMachBikeSpeedCallbacks is
    --   PlayerWalkNormal/Fast/Faster against speeds NORMAL/FAST/FASTEST, src/bike.c:75-111.)
    local base = nil
    if remote.pspeed == 2 then base = 0x15
    elseif remote.pspeed == 3 or remote.pspeed == 4 then base = 0x2d end
    -- FORCED MOVEMENT: bikeSpeed is ZERO while the game is pushing you, so the field above cannot
    -- describe it and the peer's own action must. On a muddy slope below top speed,
    -- ForcedMovement_MuddySlope (src/field_player_avatar.c:567-581) calls
    -- Bike_UpdateBikeCounterSpeed(0) and then pushes the rider south with PlayerWalkFast -- so
    -- bikeSpeed reads 0 while the character is visibly moving fast. Measured over 527 frames of
    -- slide-back, 2026-08-20: the peer reported action 21 (WALK_FAST south) on 416 of them while
    -- the ghost used WALK_NORMAL throughout, sliding at half the peer's pace.
    --
    -- The action is the RIGHT source here and the wrong one for ordinary riding (it is transient,
    -- and sampling it at 20Hz missed the fast action 6 times in 10). So it is a fallback, not a
    -- replacement: the stable field first, the action only when the field says "standing still"
    -- and the action says otherwise.
    if not base and remote.act then
        if remote.act >= 0x2d and remote.act <= 0x30 then base = 0x2d
        elseif remote.act >= 0x15 and remote.act <= 0x18 then base = 0x15
        -- THE ACRO BIKE RIDES ON "RIDE WATER CURRENT", which is not a joke and not a walk:
        -- AcroBikeTransition_Moving calls PlayerRideWaterCurrent for ordinary movement
        -- (pokeemerald src/bike.c:546-570), so a peer riding one reports 0x29..0x2C
        -- (include/constants/event_object_movement.h:128-131).
        --
        -- Nothing else in this file recognised that family, so the speed lookup found nothing and
        -- the ghost WALKED after a peer riding a bike: measured `pspeed0` and `walk/run` on every
        -- step, with the gap reaching four tiles -- past the three-tile chase limit, so it was
        -- placed instead of walked, over and over. That is the constant teleporting.
        --
        -- gPlayerAvatar.bikeSpeed stays 0 here because it belongs to the MACH bike's acceleration
        -- counter; the Acro Bike has no such ramp. So this family IS the speed for that bike, and
        -- the ghost performs the same action rather than a walk of its own.
        elseif remote.act >= 0x29 and remote.act <= 0x2c then base = 0x29 end
    end

    if math.abs(dx) + math.abs(dy) == 1 then
        local stepDir
        if dx == 1 then stepDir = DIR_ID.east
        elseif dx == -1 then stepDir = DIR_ID.west
        elseif dy == 1 then stepDir = DIR_ID.south
        else stepDir = DIR_ID.north end
        -- HOW FAST, TAKEN FROM THE PEER'S OWN ACTION rather than guessed from a pose.
        --
        -- A walk/run pair cannot describe a bike. The Mach Bike accelerates through THREE speeds --
        -- sMachBikeSpeedCallbacks is PlayerWalkNormal, PlayerWalkFast, PlayerWalkFaster
        -- (pokeemerald src/bike.c:75-80) -- and its top speed is the fastest movement in the game,
        -- faster than running. A ghost stepping at walk pace after a peer at that speed falls a
        -- tile behind per step, until the distance trips the "more than a tile out" branch and it
        -- is PLACED. That is what *"the ghosts are teleporting around after me"* is made of: not a
        -- position bug, a speed one.
        --
        -- So the speed comes from `movementActionId`, which the peer already sends because the
        -- ledge hop needed it -- the engine's own statement of what it is doing. The DIRECTION
        -- stays ours (we know it from the tile delta, and the peer's action may be a turn or NONE
        -- mid-step); only the speed class is adopted, and the ghost then performs the game's own
        -- action for that speed. Bases from include/constants/event_object_movement.h:95,108,132:
        -- WALK_NORMAL 0x08, WALK_FAST 0x15, WALK_FASTER 0x2D, each DOWN/UP/LEFT/RIGHT consecutive
        -- in DIR_ID order -- the same layout every other action table here relies on.
        local running = (remote.anim == "running")
        -- A GHOST THAT OWES A TILE ON A BIKE MUST RIDE IT, NOT WALK IT.
        --
        -- `acroBase` is taken from the peer's CURRENT action, and a ghost is usually a step behind:
        -- by the time it covers the tile, the peer has moved on to ending the wheelie or to
        -- standing, so there is no acro action left to copy and the ghost falls through to a plain
        -- WALK. Measured on one tile of wheelie ride: the player rode it with action 0x84 and the
        -- ghost walked it with 0x08 -- a walk step is also twice as long as a ride step, so the
        -- ride animation ran across the whole of it. The user: the spawned ghost is *"doing the
        -- while cosntantly riding animation instead of just the small wiggle"*.
        --
        -- Remembering the last acro family the peer actually used, and reusing it for as long as
        -- the peer is on a bike, means the ghost performs the game's own riding action for the
        -- tiles it owes -- the same shape as the drawn tier remembering the peer's last moving
        -- animation number, and for exactly the same reason.
        -- A HOP IS NEVER REMEMBERED AS "how this peer rides".
        --
        -- `lastAcroBase` exists so a ghost that owes a tile keeps RIDING rather than falling back
        -- to a walk. But it used to remember whichever acro family came last, including the two
        -- hop families -- so a single wheelie hop made every catch-up step afterwards a hop, and
        -- the ghost bounced (and puffed landing dust) across ground the peer was riding flat.
        -- The user, 2026-08-21: *"the spawned ghost is also 'jumping/doing the dust' when just
        -- riding left/right on the bike normally"*.
        --   0x74..0x7B  WHEELIE_HOP / WHEELIE_JUMP  -- one-off, never a riding style
        --   0x80..0x8B  POP_WHEELIE_MOVE / WHEELIE_MOVE / END_WHEELIE_MOVE  -- how a peer rides
        -- Only the second group is worth remembering; the first is an event that happened once.
        if acroBase and acroBase >= 0x80 then g.lastAcroBase = acroBase end
        -- WHAT THE PEER IS DOING NOW BEATS WHAT IT WAS DOING BEFORE.
        --
        -- The remembered family is a fallback for the frames where the peer's own action says
        -- nothing useful -- it has finished its step and gone back to standing while the ghost is
        -- still covering the tile it owes. It is NOT a description of how this peer rides, and
        -- using it in preference to the peer's live action meant one wheelie ride dressed every
        -- ordinary step afterwards in a wheelie: the user, 2026-08-21, *"its also doing some
        -- wheelie animations when just riding the bike normally left/right now"*.
        --
        -- `base` is derived from the peer's CURRENT movementActionId, so wherever it exists it is
        -- the better answer and the memory must stand aside. The memory is also dropped outright
        -- once the peer is plainly riding some other way, so it cannot come back later.
        if base then
            g.lastAcroBase = nil
        elseif not acroBase and isBikeGfx(remote.gfx) then
            acroBase = g.lastAcroBase
        end
        if acroBase then
            requestAction(g, acroBase + (stepDir - 1))
        elseif base then
            requestAction(g, base + (stepDir - 1))
        else
            requestAction(g, (running and RUN_ACTION or WALK_ACTION)[stepDir])
        end
        -- Remembered so the stop above can settle it: a run leaves the object on a running frame
        -- and only an explicit action brings it back to standing. A walk does not need this --
        -- the user's own test was exact about that, "it does idle->walk fine".
        --
        -- A BIKE NEEDS IT TOO, 2026-08-20, and for the same reason a run does: a walk's last frame
        -- IS the standing frame, which is why walking never needed settling, and a bike's is not.
        -- It was missed because the flag was set from `running`, and a riding peer reports its
        -- pose as "walking" -- the wire's pose string has only those two words, so no bike can
        -- ever set it. The user, on the side-by-side: the spawned ghost idle on the bike was
        -- *"using the animation/pose that is supposed to happen while actively moving"*, and sat
        -- visibly offset with it, because the bike's moving frame is a different width from its
        -- standing one.
        g.needsSettle = (running or isBikeGfx(remote.gfx)) or nil
        -- The engine owns the tiles again for the length of the step, so the settled-frame copy
        -- above must be re-armed: without this a second stop finds its key unchanged and skips.
        g.frameFor = nil
        lockGhostFacing(g, remote, stepDir)
    elseif frameCounter - (genderFrames.xmap.rebasedAt or -99) <= 3 then
        -- A SEAM CROSSING IS MID-FLIGHT. The engine rebases every live object one frame AFTER the
        -- map key flips (measured, probes/coordwatch.log: NPCs at y=6 read y=146 a frame later),
        -- and our own rebase lands the frame OF the flip -- so for a beat the ghost reads a whole
        -- map-height out of place while being exactly where it belongs. Acting on that with the
        -- teleport below would move it, and then the engine's shift would move it AGAIN. Coast
        -- for the handful of frames the two rebases need to both land.
        return
    else
        -- More than a tile out. This branch was written for a warp or a dropped packet -- cases
        -- where the ghost is somewhere it has no business being and the only honest answer is to
        -- put it right. It was also catching something entirely different: a peer simply moving
        -- faster than one tile per step.
        --
        -- At Mach Bike top speed the ghost settles about two tiles back -- the interpolation delay
        -- made visible -- and a one-tile step cannot close that against a peer travelling at the
        -- same speed, so the gap sat at 2 and this branch fired again and again. Measured over 300
        -- frames of riding: PLACED=13, every one of them dist2, against 54 correctly-sped steps.
        -- That is what *"they are still teleporting a tiny bit"* is.
        --
        -- So a SHORT gap is walked, not placed. The ghost trails a couple of tiles while the peer
        -- is at speed and closes it the moment they slow or stop, which is what a person follows
        -- like -- and never snaps. A long gap is still a warp and still gets placed.
        local far = math.abs(dx) + math.abs(dy)
        if far <= 3 then
            -- Dominant axis: with the gap this small the peer is on a line, and stepping the long
            -- side first is what keeps a diagonal-looking approach from zig-zagging.
            local sd
            if math.abs(dx) >= math.abs(dy) then
                sd = dx > 0 and DIR_ID.east or DIR_ID.west
            else
                sd = dy > 0 and DIR_ID.south or DIR_ID.north
            end
            requestAction(g, (acroBase and (acroBase + (sd - 1)))
                or (base and (base + (sd - 1)))
                or ((remote.anim == "running") and RUN_ACTION or WALK_ACTION)[sd])
            lockGhostFacing(g, remote, sd)
            return
        end
        -- Walking it there would fall further behind every frame, so place it -- but only once the
        -- camera has settled, for the same reason as spawning.
        if not cameraIsSettled() then return end
        teleportGhost(g, targetX, targetY)
        if (r8(a + 0x18) & 0x0f) ~= dir then requestAction(g, FACE_ACTION[dir]) end
    end
end

-- A SHADOW UNDER A JUMPING GHOST. Registered as a bandage in BANDAGES.md -- this is our art,
-- not the game's, and the reason is worth stating exactly.
--
-- The engine DOES create a shadow for any object's ledge hop (InitJumpRegular ->
-- DoShadowFieldEffect). It binds it with StartFieldEffectForObjectEvent, which passes the
-- object's localId and then re-finds the object every frame via GetObjectEventIdByLocalIdAndMap.
-- Our ghosts wear LOCALID_PLAYER (0xFF), so that lookup returns the PLAYER: the ghost's jump
-- spawns a shadow under the player instead of under the ghost.
--
-- Wearing that id is not an accident and is not negotiable -- GetInteractedObjectEventScript
-- returns NULL for any object with LOCALID_PLAYER, which is exactly what makes a ghost
-- non-interactable using the engine's own check rather than a guard of ours. Giving ghosts their
-- own id would fix the shadow and re-open the script lookup that has no template behind it, a
-- NULL dereference the decomp itself marks as a known bug and the cause of the slot-machine bug
-- the user already hit. The user's call, 2026-08-19: draw it ourselves, the same way the drawn
-- tier compensates for what the hardware cannot do.
--
-- The one thing borrowed from the engine is the part that matters: a jumping sprite carries its
-- ARC in pos2.y (+0x26), so taking the sprite's position WITHOUT that term is the ground it left,
-- exactly. The shadow therefore sits still on the tile while the ghost rises and falls over it,
-- with no arc maths of ours to drift.
-- LEARN THE GAME'S OWN SHADOW, then draw that. The ellipse below is only the fallback.
--
-- Three rounds of "is it too big / too dark / too high" said the same thing each time: an
-- approximation of someone else's art is judged against the original, and loses. The original is
-- readable -- a shadow is an ordinary sprite, so when the LOCAL player hops a ledge there is one
-- on screen with its own images pointer and palette. Learned once per session, decoded with the
-- same run path the drawn tier uses for peer graphics, and drawn for every ghost thereafter.
--
-- Identified by what it is rather than by an address: in use, 16x8 (shape 1, size 0 -- the
-- SHADOW_SIZE_M template the player's graphics info asks for), sitting near the player, while the
-- player is mid-jump. That is the same discipline as every other lookup here: describe the thing,
-- do not memorise where it lives.
-- GLOBAL, like drawRunList above: this chunk is at Lua's hard 200-local ceiling, and a helper
-- that is called once a frame is a better use of the remaining budget than a name.
function learnShadowArt()
    if genderFrames.shadowArt ~= nil then return end
    local pObj = objAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05))
    local act = r8(pObj + 0x1c)
    if act < 0x0c or act > 0x0f then return end
    local ps = sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04))
    local px = rs16(ps + 0x20)
    for i = 0, 63 do
        local d = sprAddr(i)
        if (r8(d + 0x3e) & 0x01) == 1
            and ((r16(d + 0x00) >> 14) & 3) == 1 and ((r16(d + 0x02) >> 14) & 3) == 0
            and math.abs(rs16(d + 0x20) - px) < 40 then
            local images = r32(d + 0x0c)
            if isRomPtr(images) then
                local pixels = r32(images)
                if isRomPtr(pixels) then
                    local slot = (r16(d + 0x04) >> 12) & 0x0f
                    local pal = {}
                    for k = 0, 15 do
                        local c = r16(0x05000200 + slot * 32 + k * 2)
                        pal[k] = (0xFF << 24) | (expand5to8(c & 0x1F) << 16)
                            | (expand5to8((c >> 5) & 0x1F) << 8) | expand5to8((c >> 10) & 0x1F)
                    end
                    -- 16x8, two 8x8 4bpp tiles side by side, built into runs like every other
                    -- decoded frame here.
                    local runs = {}
                    for y = 0, 7 do
                        local x = 0
                        while x < 16 do
                            local b = r8(pixels + (x // 8) * 32 + y * 4 + ((x % 8) // 2))
                            local idx = (x % 2 == 0) and (b & 0x0F) or ((b >> 4) & 0x0F)
                            if idx ~= 0 then
                                local x2 = x
                                while x2 + 1 < 16 do
                                    local nb = r8(pixels + ((x2 + 1) // 8) * 32 + y * 4
                                        + (((x2 + 1) % 8) // 2))
                                    local ni = ((x2 + 1) % 2 == 0) and (nb & 0x0F)
                                        or ((nb >> 4) & 0x0F)
                                    if ni ~= idx then break end
                                    x2 = x2 + 1
                                end
                                runs[#runs + 1] = { y = y, x1 = x, x2 = x2, color = pal[idx] }
                                x = x2 + 1
                            else
                                x = x + 1
                            end
                        end
                    end
                    if #runs > 0 then
                        genderFrames.shadowArt = runs
                        console.log("MeshGhost: learned the game's own jump shadow ("
                            .. #runs .. " runs) -- ghosts now use it instead of an ellipse.")
                    end
                end
            end
            return
        end
    end
end

-- Draw one shadow at a character's un-arced position. `sx`,`sy` are that character's sprite
-- position in SCREEN space; the sprite box's top-left is x-8, y-4 (the shadow sprite's own c2c),
-- and the shadow sits 12px below the character's y -- all measured, see BANDAGES.md.
-- gShadowVerticalOffsets (src/field_effect_helpers.c:220) -- indexed by the graphic's shadowSize,
-- which is bits 4-5 of graphicsInfo +0x0C.
-- A FIELD, not a local: this chunk is at Lua's hard 200-local ceiling and one more is a parse
-- failure, which is how the adapter silently fails to load.
genderFrames.shadowDrop = { [0] = 4, [1] = 4, [2] = 4, [3] = 16 }

-- WHERE THE GAME PUTS A SHADOW, rather than where ours was tuned to sit.
--
-- FldEff_Shadow sets sYOffset = (graphicsInfo->height >> 1) - gShadowVerticalOffsets[shadowSize]
-- and UpdateShadowFieldEffect then draws at the character's sprite y PLUS that -- the sprite's
-- pos1, deliberately, so the shadow stays on the ground while the character arcs away on pos2.
--
-- Our own copy used a flat +12 measured against a ledge hop, which is close for a walker and wrong
-- for anything else -- reported on the Acro Bike as *"the drawn ghosts shadow is not properly
-- alligned"*. Computed from the graphic instead: the frame's top-left plus the graphic's height,
-- less the shadow's own offset, less the shadow sprite's 4px half-height.
function shadowTopFor(info, frameTopY)
    local size = 0
    if info and info.raw then size = (r8(info.raw + 0x0c) >> 4) & 0x03 end
    local h = (info and info.height) or FRAME_HEIGHT_PX
    return frameTopY + h - (genderFrames.shadowDrop[size] or 4) - 4
end

function drawOneShadow(sx, sy, dim)
    local left, top = sx - 8, sy
    if genderFrames.shadowArt then
        drawRunList(genderFrames.shadowArt, 16, false, left, top, nil, dim)
    else
        -- Until a shadow has been seen to learn from: the measured ink extent, 16x5 at rows 3..7.
        gui.drawEllipse(left, top + 3, 16, 5, 0x00000000, 0xFF000000)
    end
end

local function drawGhostShadows()
    learnShadowArt()
    for playerId, g in pairs(ghosts) do
        local remote = remotes[playerId]
        if ghostAlive(g) and not (remote and isJumpAction(remote.act)) then
            updateGhostShadow(g, false)
            -- THE ENGINE'S OWN DUST, once the shadow under the ghost is a real sprite.
            --
            -- This used to paint dust ON TOP OF the painted shadow, deliberately: an overlay is
            -- drawn after the hardware has finished, so our shadow covered the engine's puff and
            -- the only way to see one was to paint that too. With a real shadow sprite at
            -- subpriority 148 there is nothing in front of the dust any more, and the painted copy
            -- is a second puff over the top of a working one.
            --
            -- THAT THE ENGINE MAKES ONE FOR A GHOST AT ALL was an assumption this file recorded
            -- and nobody had checked. It is now measured (`probes/shadowdust_probe.lua`,
            -- 2026-08-21): a dust sprite on the engine's own UpdateJumpImpactEffect callback,
            -- 32px to the side, i.e. under the GHOST rather than the player. Unlike the shadow,
            -- FldEff_JumpLandingDust takes coordinates (event_object_movement.c:7994-8001) instead
            -- of binding by localId, so wearing LOCALID_PLAYER never mattered to it.
            --
            -- noteLanding is still CALLED either way: it is what latches the landing frame, and
            -- the painted tier below reads the same record.
            local f = genderFrames.noteLanding(playerId, false, remote and remote.act)
            if f and not genderFrames.shadowSpriteEnabled then
                local d = sprAddr(g.sprId)
                local runs = genderFrames.dustRuns(f)
                if runs then
                    drawRunList(runs, TILE, false,
                        rs16(d + 0x20) + rs16(GSPRITECOORDOFFSETX_ADDR) - 8,
                        rs16(d + 0x22) + rs16(GSPRITECOORDOFFSETY_ADDR) + 8, nil, 1)
                end
            end
        end
        if remote and isJumpAction(remote.act) and ghostAlive(g) then
            local d = sprAddr(g.sprId)
            local sx = rs16(d + 0x20) + rs16(GSPRITECOORDOFFSETX_ADDR)
            -- Deliberately WITHOUT pos2 (+0x24/+0x26): that carries the jump arc, and the shadow
            -- belongs on the ground the character left -- which is what the game does, its shadow
            -- sprite reading pos2 0,0 while the character mid-hop reads 0,-6.
            local sy = rs16(d + 0x22) + rs16(GSPRITECOORDOFFSETY_ADDR)
            updateGhostShadow(g, true)
            if not genderFrames.shadowSpriteEnabled then
                local size = 0
                local gi = g.gfx and graphicsInfo(g.gfx)
                if gi and gi.raw then size = (r8(gi.raw + 0x0c) >> 4) & 0x03 end
                local h = (gi and gi.height) or FRAME_HEIGHT_PX
                drawOneShadow(sx, sy + (h >> 1) - (genderFrames.shadowDrop[size] or 4) - 4, 1)
            end
            genderFrames.noteLanding(playerId, true, remote.act)
        end
    end
end

-- spawnSet names the peers entitled to an object slot this frame (tiering.chooseSpawned). A peer
-- that loses its place does NOT vanish -- the drawn tier picks it up in the same frame, which is
-- the whole point of the split.
-- MESHGHOST_EMERALD_NO_COLLISION: a ghost you can walk through, using the engine's own rule.
--
-- THE ENGINE DOES HAVE A SWITCH FOR THIS, and this file said twice that it did not -- *"there is
-- no flag in this engine to switch collision off, it is purely positional"*. That was wrong, and
-- it cost two rounds of positional hacks that each broke the ghost's movement.
--
-- DoesObjectCollideWithObjectAt (pokeemerald src/event_object_movement.c:4724-4742) only reports a
-- collision when the two objects' ELEVATIONS are compatible, and AreElevationsCompatible (:7789)
-- is three lines:
--
--     if (a == ELEVATION_TRANSITION || b == ELEVATION_TRANSITION) return TRUE;  // 0 collides
--     if (a != b) return FALSE;                                                 // different: no
--     return TRUE;
--
-- So two NON-ZERO, DIFFERENT elevations do not collide at all. That is the mechanism, and it is
-- the game's own: it is how a bridge and the water under it hold two characters on one tile.
--
-- WHY IT LOOKED LIKE ELEVATION DID NOT WORK. The earlier attempt set 0, 1 and 15 and found all
-- three still blocked, and concluded elevation was not the mechanism. The missing piece is
-- ObjectEventUpdateElevation (:7759-7771): the engine REWRITES currentElevation from the map tile
-- whenever an object moves. Set once, it was reset within a step to whatever the ghost was
-- standing on -- which is the same terrain the player is on, hence equal, hence colliding. The
-- value was never wrong; it just did not survive.
--
-- So it is re-applied every frame, and chosen against the player's CURRENT elevation rather than
-- fixed, so it can never accidentally match: the player is 3 on land and 1 while surfing
-- (ELEVATION_DEFAULT/ELEVATION_SURF, include/global.fieldmap.h:16-19).
--
-- ONLY currentElevation, which is the LOW nibble of +0x0B. The HIGH nibble is previousElevation,
-- and that is what SetObjectSubpriorityByElevation draws with (:7776) -- leaving it alone means
-- the ghost keeps its exact draw order behind and in front of scenery. Collision changes;
-- rendering does not.
--
-- A transition frame still collides (the player's own elevation reads 0 while stepping between
-- levels, and the rule above says 0 collides with everything). That is the engine's behaviour for
-- every character, so a ghost sharing it is correct rather than a limit.
local function freeGhostCollision()
    if tiering.noCollision == nil then
        tiering.noCollision = (MESHGHOST_EMERALD_NO_COLLISION
            or os.getenv("MESHGHOST_EMERALD_NO_COLLISION")) and true or false
        if tiering.noCollision then
            console.log("MeshGhost: PROBE FLAG IN USE -- MESHGHOST_EMERALD_NO_COLLISION: ghosts "
                .. "are walk-through (elevation made incompatible with the player's). Dev only.")
        end
    end
    if not avatarAddrConfirmed then return end

    local pObj = r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05)
    if pObj > 15 then return end
    local pe = r8(objAddr(pObj) + 0x0b) & 0x0f
    -- Non-zero and never equal to the player's, whatever the player is standing on.
    local want = (pe == 3) and 4 or 3

    for _, g in pairs(ghosts) do
        if ghostAlive(g) then
            local a = objAddr(g.objId)
            local cur = r8(a + 0x0b)
            if tiering.noCollision and (cur & 0x0f) ~= want then
                w8(a + 0x0b, (cur & 0xf0) | want)
            end
            -- SHIPPED BEHAVIOUR from here down, not the dev flag above -- this loop runs for
            -- every ghost regardless of MESHGHOST_EMERALD_NO_COLLISION.
            --
            -- hasShadow STAYS SET on a ghost (byte +0x02 bit 6), and this is the fix for the green
            -- flicker near a hopping ghost (user, 2026-08-21: *"a 'green' spot ... same shape as
            -- the shadows"*). A ghost's jump runs DoShadowFieldEffect
            -- (event_object_movement.c:8768-8775), which spawns FLDEFF_SHADOW bound by localId --
            -- and a ghost wears LOCALID_PLAYER, so the effect re-finds the PLAYER, sees its
            -- hasShadow clear, and FieldEffectStops itself within a frame or two. In that frame it
            -- is a real 16x8 sprite at an uninitialised position whose VRAM copy has not landed
            -- yet, i.e. a shadow-shaped patch of whatever pixels were left in that tile range --
            -- green, on a grass map. The probe caught it as one-frame shadow.M entries at
            -- dy=-768 (shadowdust_probe, 2026-08-21). DoShadowFieldEffect's own gate is the
            -- object's hasShadow flag, so holding it set means the engine never spawns the doomed
            -- effect at all -- the engine's own switch, not a hook. Re-applied per frame because
            -- the jump-landing ground effects clear it (:5535 and friends); our real shadow sprite
            -- is what actually appears under the ghost.
            w8(a + 0x02, r8(a + 0x02) | 0x40)
        end
    end
end

local function syncRemoteGhosts(localAreaId, spawnSet)
    for playerId in pairs(ghosts) do
        local remote = remotes[playerId]
        -- Gone, somewhere else, or demoted to the drawn tier. area_id is opaque and compared by
        -- equality only.
        if not remote or remote.areaId ~= localAreaId or not spawnSet[playerId] then
            -- WHICH condition, on the record: the seam-crossing pop despawns followers while a
            -- static cross-map peer sails through, and the three reasons here need telling apart.
            if COMPARE_TIERS then
                logFile(string.format("f=%d DESPAWN %s: remote=%s areaId=%s vs local=%s inSet=%s",
                    frameCounter, tostring(playerId), tostring(remote ~= nil),
                    tostring(remote and remote.areaId), tostring(localAreaId),
                    tostring(spawnSet[playerId] ~= nil)))
            end
            despawnGhost(playerId)
        end
    end
    for playerId, remote in pairs(remotes) do
        if remote.areaId == localAreaId and spawnSet[playerId] then
            syncGhost(playerId, remote)
        end
    end
    -- SAY IT OUT LOUD IF TWO PEERS EVER SHARE ONE OBJECT AGAIN.
    --
    -- The claim check in findFreeObjectSlot/findFreeSpriteSlot is what stops this happening; this
    -- is what proves it stopped, and what names it immediately if some other path re-creates it.
    -- A shared slot is otherwise invisible in the log and reads on screen as a ghost blinking
    -- between two places -- diagnosed 2026-08-20 only by watching one object slot alternate.
    -- Throttled to once a second: a real collision persists, so nothing is missed by not
    -- repeating it 60 times, and this runs on the adapter's hot path.
    if not tiering.lastSlotAudit or frameCounter - tiering.lastSlotAudit >= 60 then
        tiering.lastSlotAudit = frameCounter
        local seenObj, seenSpr = {}, {}
        for playerId, g in pairs(ghosts) do
            if seenObj[g.objId] then
                console.log(string.format(
                    "MeshGhost: BUG -- %s and %s both hold object slot %d; one ghost will blink "
                    .. "between two places until this is fixed.", tostring(seenObj[g.objId]),
                    tostring(playerId), g.objId))
            elseif seenSpr[g.sprId] then
                console.log(string.format(
                    "MeshGhost: BUG -- %s and %s both hold sprite slot %d.",
                    tostring(seenSpr[g.sprId]), tostring(playerId), g.sprId))
            end
            seenObj[g.objId] = playerId
            seenSpr[g.sprId] = playerId
        end
    end
    freeGhostCollision()
end

-- THE FRAME'S SCREEN ANCHOR, shared by both non-engine tiers.
--
-- Extracted from drawRemotes 2026-08-21, unchanged, when the hardware-sprite tier arrived and
-- needed the same numbers. It has to be shared rather than copied: the calibration is STATEFUL
-- (tiering.anchor*/origin* survive between frames and are only refreshed when the player is
-- standing still on a tile-aligned camera), so a second copy would keep its own anchor and the two
-- tiers would place the same peer in two different places. It also has to be callable when the
-- DRAWN tier is off entirely, which is the shipping default -- otherwise the anchor is never
-- calibrated at all and every hardware sprite lands at the wrong offset.
--
-- ONCE PER FRAME, AND THE CACHE IS LOAD-BEARING. The first version of this said it was idempotent
-- and could simply be called from both tiers. That was wrong, and it produced a real defect: the
-- calibration counts how many consecutive frames the player has stood on the same tile, and only
-- refreshes the anchor once that count passes four. Called twice a frame the counter advances twice
-- as fast, so the anchor refreshes while the player is mid-step -- exactly the one-tile spike the
-- "stand still first" guard below exists to prevent.
--
-- The symptom was the hardware ghost drifting 2-3px a frame and then jumping about two tiles back,
-- while the painted copy beside it sat perfectly still. User, 2026-08-21: *"its also lagging
-- behind"*. Found from probes/tier_compare.log rather than by eye -- the painted copy is PINNED to
-- the spawned ghost's own sprite in compare mode, so it could not show the fault at all, and only
-- the third column made it visible.
--
-- So the state advances once per frame and every later caller gets the same four numbers back.
--
-- A GLOBAL because this chunk is at Lua's 200-local ceiling.
function anchorFrame(localAreaId, playerScreenX, playerScreenY, playerMapX, playerMapY)
    if tiering.anchorAt == frameCounter and tiering.anchorCache then
        local c = tiering.anchorCache
        return c[1], c[2], c[3], c[4]
    end
    local sb1 = r32(GSAVEBLOCK1PTR_ADDR)
    local camPixX = rs16(GTOTALCAMERAPIXELOFFSETX_ADDR)
    local camPixY = rs16(GTOTALCAMERAPIXELOFFSETY_ADDR)
    if sb1 ~= 0 then
        local camX, camY = camPixX, camPixY
        -- ONLY CALIBRATE WHILE THE PLAYER IS STANDING STILL.
        --
        -- Measured with both ghosts logged per frame: the spawned ghost moves a clean -2.0 px
        -- every frame while ours went -0.67, -0.67, -0.67, +2.0, -0.67 -- oscillating -- even
        -- though the glide itself was perfectly smooth at -0.167 tiles a frame throughout. So the
        -- jitter was never in the ghost; it was in this anchor.
        --
        -- The cause is the tile counter's other habit: moving in the positive direction it flips
        -- to the DESTINATION tile the instant a step begins, a whole tile ahead of the picture.
        -- Calibrating whenever the camera happened to be tile-aligned sometimes sampled exactly
        -- that moment, and put a one-tile spike into the anchor once per step.
        --
        -- A stationary player cannot have a step in flight, so the two cannot disagree. The
        -- constant only has to be caught once per map -- it does not decay -- and standing still
        -- for four frames happens constantly in normal play.
        local tx, ty = rs16(sb1 + 0x00), rs16(sb1 + 0x02)
        if tiering.lastTileX ~= tx or tiering.lastTileY ~= ty then
            tiering.lastTileX, tiering.lastTileY, tiering.tileStill = tx, ty, 0
        else
            tiering.tileStill = (tiering.tileStill or 0) + 1
        end
        local settled = (tiering.tileStill or 0) >= 4
        local fresh = tiering.anchorX == nil or tiering.anchorArea ~= localAreaId
        -- playerScreenY READS pos2, which while anyone is surfing is the BOB. Anything that wants
        -- a fixed tile grid has to have that term removed, or the grid rises and falls with the
        -- character a few pixels at a time -- which is what cut the drawn reflection two or three
        -- rows early. Captured here, at the same moment as the anchor it belongs to, because pos2
        -- is only knowable then; the bobbing copy is left exactly as it was, since placing a ghost
        -- against the player's actual sprite is what it is for.
        -- TWO terms have to come off this before it can anchor a TILE GRID, and both are
        -- properties of the player's current GRAPHIC rather than of the map.
        --
        -- pos2 is the first: while anyone is surfing it carries the bob, so the grid rises and
        -- falls with the character.
        --
        -- centerToCornerVec is the second, and it is the one that survived a whole investigation.
        -- playerScreenPos returns the FRAME's top-left, which is the anchor plus -(width/2). A
        -- walking player is 16 wide so that term is -8; a SURFING one is 32 wide, so it is -16.
        -- The grid was therefore 8px too far left for exactly as long as the player was surfing,
        -- which is exactly when a reflection is being judged -- and it let the mask permit 8px of
        -- ledge and grass down the left of a shoreline tile. Measured 2026-08-19: the grid put
        -- metatile 184 at x 72..87 while the screen has it at 80..95.
        --
        -- Vertically the same term is -16 for both graphics, which is why the vertical edge was
        -- correct throughout and only the side ever looked wrong -- and why this hid so well.
        --
        -- Normalised to the walker's own centring so the grid means the same thing whatever the
        -- player happens to be riding.
        local pspr = sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04))
        if fresh or (settled and camX % 16 == 0) then
            tiering.anchorX, tiering.originX = tx + camX / 16, playerScreenX
            tiering.originXStill = playerScreenX - rs16(pspr + 0x24)
                - memory.read_s8(pspr + 0x28) - (FRAME_WIDTH_PX // 2)
        end
        if fresh or (settled and camY % 16 == 0) then
            tiering.anchorY, tiering.originY = ty + camY / 16, playerScreenY
            tiering.originYStill = playerScreenY - rs16(pspr + 0x26)
                - memory.read_s8(pspr + 0x29) - (FRAME_HEIGHT_PX // 2)
        end
        tiering.anchorArea = localAreaId
        playerMapX = tiering.anchorX - camX / 16
        playerMapY = tiering.anchorY - camY / 16
    end
    tiering.anchorAt = frameCounter
    tiering.anchorCache = { camPixX, camPixY, playerMapX, playerMapY }
    return camPixX, camPixY, playerMapX, playerMapY
end

-- ================= TIER TWO: HARDWARE SPRITES THE PPU DRAWS FOR US =================
--
-- A peer the engine had no object slot for is given a real GBA hardware sprite instead of being
-- painted over the finished frame. The emulated PPU then draws it, which is where every advantage
-- comes from: background priority (a house roof and a text box hide it, for free), the live OBJ
-- palette (it dims with fades, caves and weather, for free), and real compositing.
--
-- WHERE THE ENTRIES GO, and why this is not a trick played on the engine.
-- Emerald keeps a shadow copy of all 128 hardware sprite entries inside gMain, rebuilds it once a
-- frame, and transfers the WHOLE thing to the hardware every VBlank. Its layout pass stops at
-- gOamLimit -- 64 on the overworld -- and so does the tail loop that blanks what it did not use, so
-- entries 64..127 are never written or cleared by the per-frame path while still being transferred.
-- The game itself relies on that: its wireless-link indicator lives at entry 125 for exactly this
-- reason. documentation.md describes the pipeline; the 2026-08-21 ADR in architecture.md records why
-- this and not per-scanline multiplexing (short version: BizHawk has no scanline hook, and with 5
-- entries used on a normal map there is no sprite-count limit to beat).
--
-- MEASURED, standing still with the crowd on screen (verified.md 2026-08-21): 56 hardware sprites
-- cost nothing against a bare-emulator control -- 60.0 avg either way -- while painting the same 56
-- costs 39.6. Spawned at its cap AND this tier at its ceiling together, 67 characters, still 60.0.
--
-- WHAT IT DOES NOT GET, so nobody expects it: no collision, no engine animation, no walking, and it
-- loses overlap ties to the engine's own sprites because those sit at lower entry numbers. It
-- replaces the DRAWN tier, never the spawned one.
-- ON THE TABLE, NOT IN LOCALS -- and this is not a style choice. Five constants and one helper as
-- file-scope locals pushed this chunk past Lua's hard ceiling of 200 locals per function, which does
-- not misbehave at runtime: the script fails to PARSE. Caught by bizhawk-syntax-check.lua the first
-- time this tier was compiled, 2026-08-21, exactly as the tiering table's own header warns.
tiering.hw = {
    on = MESHGHOST_EMERALD_HW_OVERFLOW or os.getenv("MESHGHOST_EMERALD_HW_OVERFLOW"),
    base = 0x030022f8 + 64 * 8, -- gMain.oamBuffer[64]; gMain 0x030022c0 + 0x038 (verified.md)
    slots = 56,                 -- entries 64..119. 120..127 is margin: 125 is the game's own.
    -- THREE POOLS, BECAUSE DEPTH HERE IS THE ENTRY NUMBER AND NOTHING ELSE.
    --
    -- A raw OAM entry has no subpriority: the hardware draws a lower-numbered entry IN FRONT. The
    -- engine expresses the same order with subpriorities on its own sprites -- landing dust 135,
    -- the character, then its shadow at 148, measured 2026-08-21 -- and back-to-front is exactly
    -- shadow, character, dust. So the slot a thing gets IS its depth, and the pools have to be laid
    -- out in that order rather than handed out first-come.
    --
    -- The engine's own back-to-front order, measured 2026-08-21 from the subpriorities it gives
    -- these sprites: reflection 152, surf blob 150, shadow 148, the character, landing dust 135.
    -- Five pools, laid out in that order, because the slot number IS the depth here.
    --
    -- The cost is honest, and it is a real cost: bodies hold 26 of the 56 entries, so this tier
    -- tops out at 26 peers rather than 56. Every one of these ceilings is LOGGED when it bites
    -- rather than silently truncated, which is how the ripple pool was sized correctly.
    --
    -- TWELVE RIPPLES, NOT EIGHT, and that number came from the game rather than from taste. The
    -- measurement is one ripple per tile stepped with an 80-frame life, and surfing crosses a tile
    -- in 8 frames -- so a steady trail is TEN live at once. Eight was tried first and the pool
    -- reported itself full at nine within a minute of real surfing; the user saw exactly what the
    -- arithmetic predicts: *"the OAM is leaving a gap in its ripples, when going in 1 distance for
    -- a while."* Twelve leaves two of headroom over the steady state. A second surfer still
    -- overflows it, and still says so in the log.
    --
    -- Still above what has been measured for bodies: the fill-the-screen run put 56 characters up
    -- and OBJ TILES ran out long before entries did.
    dustFirst = 0, dustLast = 3,        -- in front of everything of ours
    bodyFirst = 4, bodyLast = 29,
    shadowFirst = 30, shadowLast = 33,
    blobFirst = 34, blobLast = 37,
    rippleFirst = 38, rippleLast = 49,
    reflFirst = 50, reflLast = 55,      -- behind everything of ours
    fxTiles = {},               -- "shadow:<size>" / "dust:<frame>" -> { start, tiles }
    puffs = {},                 -- live dust-trail puffs: { at, bx, by, slot }
    ripples = {},               -- live water-trail ripples: { at, bx, by, slot }
    -- gDummyOamData, the engine's own "hidden" encoding: off-screen, 8x8, priority 3. Releasing with
    -- the engine's value rather than zeroes leaves a slot indistinguishable from one never used.
    d0 = 0x00a0, d1 = 0x0130, d2 = 0x0c00,
    -- Compare-mode nudge, in tiles, relative to the SPAWNED ghost -- which is the reference the
    -- other two tiers are judged against.
    --
    -- Default -6,0: these are relative to the SPAWNED ghost, which stands at (+2, 0) from the
    -- player, and the PAINTED copy is at (-2, 0) -- so this puts the hardware copy two tiles to
    -- the LEFT of the painted one, all three in the player's own row.
    --
    -- It was 0,-2 -- stacked directly over the spawned ghost -- until the surf blob and the
    -- reflection landed on this tier (2026-08-21) and there was suddenly something UNDER each
    -- character to look at: two tiles of separation put every copy's blob and reflection on top
    -- of the one below it. Three tiles up was tried next and read fine on its own; a ROW is what
    -- makes the two self-drawn tiers comparable to each other, which is the comparison that
    -- actually matters now that they carry the same effects. The user, on the water at
    -- Sootopolis: *"can you move the OAM to be 2 tiles to the left, of the drawn ghost. easier to
    -- spot the reflection change there"*.
    cmpDX = tonumber(MESHGHOST_EMERALD_HW_COMPARE_DX or "") or -6,
    cmpDY = tonumber(MESHGHOST_EMERALD_HW_COMPARE_DY or "") or 0,
    byPeer = {},   -- player_id -> { slot, tileStart, tileCount, gfx, animNum, animIdx }
    slotUsed = {}, -- slot -> player_id
    area = nil,    -- the area those tile allocations belong to
    placed = 0,    -- how many were actually written last frame, for the status line
}

-- RELEASE IS NOT OPTIONAL. Nothing in the engine's per-frame path clears entries 64..127, so one
-- left behind is a body frozen on screen until the next scene change -- the same leak class this
-- file already documents for the bridge socket, spawned ghosts and the log handle.
--
-- freeTiles is false on a map change: the engine's own ResetSpriteData has already run
-- FreeSpriteTileRanges by then, and clearing bits we no longer own would free somebody else's
-- sprite. Same identity-first rule despawnGhost follows, for the same reason.
function hwRelease(playerId, freeTiles)
    local rec = tiering.hw.byPeer[playerId]
    if not rec then return end
    local a = tiering.hw.base + rec.slot * 8
    -- +0/+2/+4 only. The engine's affine-matrix pass owns +6 on all 128 entries every frame.
    w16(a + 0, tiering.hw.d0)
    w16(a + 2, tiering.hw.d1)
    w16(a + 4, tiering.hw.d2)
    if freeTiles ~= false and rec.tileStart then
        -- DEFERRED, like the spawned tier's swap frees, for the same measured reason: the
        -- hardware OAM shows the old tile number for ~2 more frames after a release, so an
        -- immediate free lets the next allocation write into tiles still on screen -- the
        -- user's *"oam & its reflection is glitching when going back to land"*, where the
        -- dismount's graphic change is exactly a release-and-reacquire. Entries are stamped
        -- with the tier's area; the service point frees them only while that area still
        -- stands, the same forget-don't-free rule as everywhere else.
        queueTileFree({ hwArea = tiering.hw.area, start = rec.tileStart,
            count = rec.tileCount, at = frameCounter })
    end
    -- The shadow and dust entries go back with the body. Their TILES do not: those ranges are
    -- shared by every peer on this tier and only the area change below owns them.
    for which, slot in pairs(rec.fx or {}) do
        hwFxHide(rec, which)
        tiering.hw.slotUsed[slot] = nil
    end
    tiering.hw.slotUsed[rec.slot] = nil
    tiering.hw.byPeer[playerId] = nil
end

function hwReleaseAll(freeTiles)
    for playerId in pairs(tiering.hw.byPeer) do hwRelease(playerId, freeTiles) end
    -- Same rule the per-peer ranges follow: on a map change the engine's ResetSpriteData has
    -- already freed every range, so the records are dropped without clearing bits we no longer own.
    if freeTiles ~= false then
        for _, t in pairs(tiering.hw.fxTiles) do
            if t.start then
                for i = t.start, t.start + t.tiles - 1 do setTileAllocated(i, false) end
            end
        end
    end
    tiering.hw.fxTiles = {}
    -- BLANK THE ENTRY, not just the bookkeeping. Nothing in the engine's per-frame path touches
    -- entries 64..127, so a puff slot released without writing the dummy encoding leaves a puff
    -- painted on screen until the next scene change -- which is exactly the leak this tier's own
    -- header warns about, and it showed the first time every ghost was dropped at once (user,
    -- 2026-08-21: *"the 'dust' from the OAM got stuck on the screen when you unloaded all
    -- ghosts"*). Freeing a slot and clearing its entry are one action, never two.
    for _, puff in ipairs(tiering.hw.puffs) do
        if puff.slot then
            local a = tiering.hw.base + puff.slot * 8
            w16(a + 0, tiering.hw.d0)
            w16(a + 2, tiering.hw.d1)
            w16(a + 4, tiering.hw.d2)
            tiering.hw.slotUsed[puff.slot] = nil
        end
    end
    tiering.hw.puffs = {}
    tiering.hw.ripples = {}
    tiering.hw.area = nil
    tiering.hw.placed = 0
end

-- Claim a slot and a VRAM tile range for one peer. Tiles come from the GAME's own allocation bitmap
-- (allocSpriteTiles above, which imitates the engine's AllocSpriteTiles against the same bytes), so
-- nothing here depends on a hardcoded VRAM address -- which is precisely the fragility that had this
-- whole approach filed as too risky until 2026-08-21.
--
-- Returns nil when OBJ VRAM has no run long enough, and that is a real outcome on a busy map rather
-- than a theoretical one: it is the fall-through that hands the peer to the painted tier.
-- A GLOBAL, for the 200-local reason above.
function hwAcquire(playerId, info)
    local slot
    for i = tiering.hw.bodyFirst, tiering.hw.bodyLast do
        if not tiering.hw.slotUsed[i] then slot = i break end
    end
    if not slot then return nil end
    local tileStart = allocSpriteTiles(info.tileCount)
    if not tileStart then return nil end
    local rec = {
        slot = slot, tileStart = tileStart, tileCount = info.tileCount,
        gfx = nil, animNum = nil, animIdx = nil,
    }
    tiering.hw.slotUsed[slot] = playerId
    tiering.hw.byPeer[playerId] = rec
    -- One line per acquire (rare: spawns and graphic changes only). Exists because the
    -- water-to-grass savestate glitch outlived the blind OAM sweep, so which tiles this tier
    -- holds AFTER a load, and when it took them, has to be readable next to the probe logs.
    logFile(string.format("hw acquire: %s slot=%d tiles=%d..%d f=%d emu=%d",
        tostring(playerId), slot, tileStart, tileStart + info.tileCount - 1,
        frameCounter, emu.framecount()))
    return rec
end

-- A SHADOW AND LANDING DUST FOR THE HARDWARE TIER.
--
-- It had neither, and the user said so with all three renderers side by side (2026-08-21: *"OAM
-- don't have a shadow at all, or dust"*). The spawned tier gets both from the engine; the painted
-- tier draws both itself. This tier writes OAM entries, so it does what an OAM entry can do: two
-- more entries, pointed at the field effect's own artwork in ROM.
--
-- ONE TILE RANGE PER EFFECT FRAME, SHARED BY EVERY PEER. A shadow has one frame and the dust has
-- three, so four ranges of two tiles each cover the whole tier no matter how many peers are
-- hopping -- a peer's entry just points at whichever frame its own puff is up to. Per-peer ranges
-- would be the obvious build and would cost tiles proportional to the crowd for pixels that are
-- byte-for-byte identical.
--
-- THE PALETTE IS RESOLVED, NOT COPIED FROM A NEIGHBOUR. The painted tier reads its dust palette off
-- a live dust sprite, which works only because the engine happens to have one up at the same
-- moment; an overflow peer landing with nobody else on screen has no such neighbour. The engine's
-- own answer is `IndexOfSpritePaletteTag`, a scan of `sSpritePaletteTags` for the template's tag,
-- and that array is readable:
--   sSpritePaletteTags 03000CF0, 16 x u16   (pokeemerald.sym; a static, so no .map entry)
--   FLDEFF_PAL_TAG_GENERAL_0 0x1004         (include/constants/field_effects.h:112) -- the dust's
-- The shadow templates ask for TAG_NONE, so `CreateSpriteAt` (sprite.c:584) leaves paletteNum at
-- whatever the OAM template carries, which is 0 -- and copying the template's first two halfwords
-- reproduces that without knowing it.
-- WHAT PRIORITY OUR ENTRIES NEED TO BE SEEN AT ALL.
--
-- This tier holds OAM entries 64+, and among sprites of the SAME priority the lower entry number
-- wins -- so it loses every overlap to the engine's own sprites. Underwater that becomes fatal:
-- the game lays a full-screen grid of 64x64 semi-transparent sprites over the scene (measured
-- live: entries 4..23, five columns by four rows, priority 2, covering every pixel), and the
-- engine's characters sit at entries 0..3, ABOVE it by the same index rule. Our entries sit
-- below it, so nothing this tier drew could appear -- the user, after a long hunt: *"OAM shows
-- while surfing, its only invisible underwater"*.
--
-- RAISING OUR PRIORITY MAKES US VISIBLE AND UGLY, so this tier stands down underwater instead.
--
-- Priority is compared before the index, so priority 1 (or 0) does put our entries above the fog
-- and the ghost appears. It also drags a 32x32 WHITE BOX with it, at either priority: a
-- semi-transparent sprite blends with the layer beneath it, cannot blend against another SPRITE,
-- and gives up and draws OPAQUE wherever ours is in the way -- so the fog turns solid over our
-- sprite's whole rectangle. The user, on sight: *"has a weird square/outline around it... looks
-- like a fog/smoke background, a square that follows the OAM ghost"*.
--
-- Nothing available from entries 64+ wins this: the fog is the engine's own, at indices we cannot
-- get beneath (its 4..23 are rebuilt from the engine's sprite list every frame). So underwater
-- this tier declines and its peers fall to the PAINTED one, which is drawn after the frame and
-- subject to none of this. Coverage is unchanged; only which renderer draws them changes.
-- MESHGHOST_EMERALD_HW_PRIORITY (probe) overrides it, and also suppresses the stand-down below, so
-- the "raise the priority above the sheet" option can be LOOKED AT rather than argued about. The
-- underwater measurement that closed it off was taken underwater; fog is a second configuration of
-- the same idea and does not have to behave the same way. Never ship it set.
function hwSpritePriority()
    return tonumber(MESHGHOST_EMERALD_HW_PRIORITY or "") or 2
end

-- IS THE ENGINE CURRENTLY LAYING A SEMI-TRANSPARENT SHEET OVER THE SCREEN?
--
-- The condition that defeats this tier, asked directly rather than inferred from where the player
-- is. A sprite in objMode 1 (attr0 bits 10-11) is semi-transparent, and the engine only ever uses
-- a lot of them at once to cover the screen -- fog, and the underwater haze. Two separate bugs
-- came from testing for the PLACE instead: underwater was fixed by name, and Mt Pyre's fog then
-- reproduced it exactly on dry land.
--
-- COST, because a per-frame scan of OAM is the shape this project has been bitten by before
-- (`_template/probes.md`): attr0 ONLY, so 64 halfword reads rather than 192, and only every 8th
-- frame with the answer latched between. Weather fades in over seconds; nothing needs it sooner,
-- and the tier switch itself is a whole frame's work when it happens.
--
-- The threshold is 4. The engine's own incidental semi-transparent sprites are one or two at a
-- time; a screen cover is twelve or more (measured: 12 in Mt Pyre's fog, 20 underwater).
genderFrames.semiTransparentScanAt, genderFrames.semiTransparentCover = -100, false
genderFrames.screenCoveredBySemiTransparentSprites = function()
    if frameCounter - genderFrames.semiTransparentScanAt < 8 then
        return genderFrames.semiTransparentCover
    end
    genderFrames.semiTransparentScanAt = frameCounter
    local n = 0
    for e = 0, 63 do
        if (r16(0x07000000 + e * 8) & 0x0c00) == 0x0400 then
            n = n + 1
            if n >= 4 then break end
        end
    end
    genderFrames.semiTransparentCover = n >= 4
    return genderFrames.semiTransparentCover
end

function hwPaletteSlotForTag(tag)
    for i = 0, 15 do
        if r16(0x03000cf0 + i * 2) == tag then return i end
    end
    return nil
end

-- Load one frame of a field effect into OBJ VRAM once, and hand back the tiles it lives in.
-- A FAILURE IS CACHED TOO, and that is not a detail -- it is what stopped this costing the frame
-- rate. `allocSpriteTiles` imitates the engine's own allocator: it walks the 1024-tile OBJ bitmap
-- looking for a free run, so a FAILED call is the most expensive call it can make. Uncached, a
-- tier that cannot get two tiles retried that full walk for every live puff and every jumping
-- ghost, every frame -- and OBJ tiles are exactly what runs out first with three tiers up, so the
-- failing case is the normal case on a busy map, not a rare one. The user, with tonight's build:
-- *"feels like its chugging at like 1fps"*; the committed build with none of it was smooth, which
-- is the A/B that placed it here rather than in any of the drawing.
--
-- Negative entries are retried on a slow clock so a map that frees tiles later still gets its
-- effects, and cleared wholesale on the area change like the positive ones.
function hwFxTiles(key, imagesPtr, frameIdx)
    local rec = tiering.hw.fxTiles[key]
    if rec then
        if rec.start then return rec.start end
        if frameCounter - rec.failedAt < 300 then return nil end
    end
    local e = imagesPtr + frameIdx * 8
    local src, bytes = r32(e), r16(e + 4)
    -- The same range check the shadow sprite got, for the same reason: a wrong SpriteFrameImage
    -- read turns the copy below into a write over somebody else's tiles.
    if not isRomPtr(src) or bytes == 0 or bytes > 1024 or bytes % 32 ~= 0 then return nil end
    local nTiles = bytes // 32
    local start = allocSpriteTiles(nTiles)
    if not start then
        tiering.hw.fxTiles[key] = { start = false, failedAt = frameCounter }
        return nil
    end
    local dst = 0x06010000 + start * 32
    for off = 0, bytes - 4, 4 do w32(dst + off, r32(src + off)) end
    tiering.hw.fxTiles[key] = { start = start, tiles = nTiles }
    return start
end

-- An entry from the pool that puts this effect at the right depth. Held for as long as the peer is
-- on this tier: the alternative is claiming and releasing one every hop, and a slot that changes
-- number changes depth, which is the one thing these pools exist to keep still.
function hwFxSlot(playerId, rec, which)
    rec.fx = rec.fx or {}
    if rec.fx[which] then return rec.fx[which] end
    -- Each effect draws from the pool that puts it at the right depth; dust is the exception and
    -- belongs to the puff pool in hwPuffTick, which is per-puff rather than per-peer.
    local first, last = tiering.hw.shadowFirst, tiering.hw.shadowLast
    if which == "blob" then
        first, last = tiering.hw.blobFirst, tiering.hw.blobLast
    elseif which == "refl" then
        first, last = tiering.hw.reflFirst, tiering.hw.reflLast
    end
    for i = first, last do
        if not tiering.hw.slotUsed[i] then
            tiering.hw.slotUsed[i] = playerId
            rec.fx[which] = i
            return i
        end
    end
    return nil
end

function hwFxHide(rec, which)
    local slot = rec.fx and rec.fx[which]
    if not slot then return end
    local a = tiering.hw.base + slot * 8
    w16(a + 0, tiering.hw.d0)
    w16(a + 2, tiering.hw.d1)
    w16(a + 4, tiering.hw.d2)
end

-- WHAT A SURFING PEER IS BESIDES A RIDER: the Pokemon underneath, and the reflection in the water.
--
-- The user, comparing all three tiers on the water at Sootopolis, 2026-08-21: *"OAM is missing
-- water reflections & the water blob."* Both were built for the painted tier and neither reached
-- this one -- a rider on this tier sat on open water casting nothing. The spawned tier has always
-- had both, because the engine makes them: `FldEff_SurfBlob` spawns a real companion sprite and
-- `SetUpReflection` a real reflection sprite, and a spawned ghost is just another object event.
--
-- Both are ONE OAM ENTRY EACH here, which is what makes them cheap enough to want:
--
--   THE BLOB is the field effect's own sprite template read out of ROM -- four animations, one
--   frame each, one per facing, east being west mirrored (the provenance is with
--   `runsForSurfBlob`, which resolves the same frame for the painted tier). Its tiles are copied
--   once per image and SHARED by every peer riding one, because hwFxTiles caches on the key. It
--   sits at the rider's position plus (0, +8), measured against the game's own pair rather than
--   guessed (probes/surfblob_probe.lua, 2026-08-19).
--
--   THE REFLECTION costs no tiles at all: it is the body's own frame, already in VRAM, drawn a
--   second time through a different palette. That is exactly what the engine does -- same tiles,
--   vertically flipped, priority 3, and `gReflectionEffectPaletteMap` for the colours -- and it
--   is why this tier gets for free the one thing the painted tier had to work for: PRIORITY. A
--   priority-3 entry is clipped by the water for us, so there is no reflectiveSpans lookup here
--   and no reflection creeping onto the bank.
--
--   THE RIPPLE IS THE HARDWARE'S, not ours. SetUpReflection does not use the flip bits: it makes
--   the reflection an AFFINE sprite through OAM matrix 0, or matrix 1 when the character is
--   mirrored (src/field_effect_helpers.c:66-68). Those matrices hold d = -256 (the vertical flip)
--   and an `a` breathing between 252 and 260, which is the sideways shimmer. The engine keeps
--   them updated every frame, so pointing our entry at the same matrix is not an imitation of the
--   ripple -- it IS the ripple, with no phase of our own to drift.
--
--   Guarded, because those matrices are only maintained while the engine has a reflection of its
--   own up. If matrix 0 is not holding a vertical flip, the entry falls back to the plain flip
--   bit: a reflection that does not shimmer, rather than a sprite drawn through a stale matrix.
function hwDrawSurf(playerId, rec, remote, info, sx, sy, arcY, hFlip)
    -- THE BLOB -- surfing only, because a blob IS surfing.
    if remote.gfx and SURFING_GFX[remote.gfx] then
        -- PARKED DURING A JUMP, like the game's own. On a dismount the engine sets the blob to
        -- BOB_JUST_MON and it stops following the rider (field_effect_helpers.c:1124-1133) --
        -- the rider arcs ashore, the blob stays in the water. This tier rebuilt the blob at the
        -- body's position every frame, so it rode the arc onto the grass (*"the blob follows
        -- them onto land"*). While the peer's action is a JUMP_SPECIAL, the blob is drawn at the
        -- position it held on the last non-jumping frame -- camera-anchored the way the ripple
        -- trail already is, since the camera moves during the jump.
        -- STICKY once the jump begins: the action ends a beat before the graphic flips (the
        -- wire's pair debounce), and releasing the park in that gap drew the blob at the body's
        -- landing tile for those frames -- the user's *"blob flash slightly at the landing"*.
        -- The park holds until the surf graphic itself ends, exactly when the game's blob dies.
        -- Bob-with-the-rider outside a jump, park through both kinds of jump: a dismount holds
        -- the pre-jump park, a MOUNT parks at the destination (body-sans-arc plus one tile along
        -- the jump's direction). The painted tier carries the same logic; an earlier edit patched
        -- only that tier -- its two-part patch failed after the first half -- and the user's
        -- next report named the missed one exactly: *"the blob is still following the OAM"*.
        local jumping = remote.act and remote.act >= 0x3a and remote.act <= 0x3d
        if jumping and not rec.blobParkHold then
            if rec.blobPark then
                rec.blobParkHold, rec.blobParkKind = true, "dismount"
            else
                local jdx = ({ [0x3c] = -TILE, [0x3d] = TILE })[remote.act] or 0
                local jdy = ({ [0x3a] = TILE, [0x3b] = -TILE })[remote.act] or 0
                rec.blobPark = { sx + jdx - rs16(GSPRITECOORDOFFSETX_ADDR),
                    sy - arcY + jdy + 8 - rs16(GSPRITECOORDOFFSETY_ADDR) }
                rec.blobParkHold, rec.blobParkKind = true, "mount"
                if COMPARE_TIERS then
                    logFile(string.format(
                        "HW MOUNT PARK at (%d,%d) act=%02X sx=%d sy=%d arc=%d f=%d",
                        rec.blobPark[1], rec.blobPark[2], remote.act, sx, sy, arcY,
                        frameCounter))
                end
            end
        end
        -- A MOUNT'S PARK ENDS WITH ITS JUMP -- body and blob are at the same tile then, so the
        -- handover is seamless -- while a DISMOUNT'S holds until the graphic flips (that beat is
        -- the flash the hold exists for). Releasing both on the graphic was the first version,
        -- and after a mount it simply never released: *"the blob is not following OAM and DRAWN
        -- while surfing now"*, the blob left parked at the mount tile.
        if not jumping and rec.blobParkHold and rec.blobParkKind == "mount" then
            rec.blobParkHold, rec.blobParkKind = nil, nil
        end
        local bx, by = sx, sy + 8
        if rec.blobParkHold and rec.blobPark then
            bx = rec.blobPark[1] + rs16(GSPRITECOORDOFFSETX_ADDR)
            by = rec.blobPark[2] + rs16(GSPRITECOORDOFFSETY_ADDR)
        elseif not jumping then
            rec.blobPark = { bx - rs16(GSPRITECOORDOFFSETX_ADDR),
                by - rs16(GSPRITECOORDOFFSETY_ADDR) }
        end
        local facing = genderFrames.dirOf[remote.orientation] or 1
        local imageIndex = genderFrames.blobDirImage[facing] or 0
        local imgs = r32(GFIELDEFFECTTEMPLATE_SURFBLOB + 0x0c)
        local bpal = hwPaletteSlotForTag(r16(GFIELDEFFECTTEMPLATE_SURFBLOB + 0x02))
            or genderFrames.blobPaletteSlot
        local bstart = isRomPtr(imgs) and hwFxTiles("blob:" .. imageIndex, imgs, imageIndex)
        local bslot = bstart and hwFxSlot(playerId, rec, "blob")
        if bslot then
            local o = r32(GFIELDEFFECTTEMPLATE_SURFBLOB + 0x04)
            local a = tiering.hw.base + bslot * 8
            w16(a + 0, (r16(o + 0x00) & 0xff00) | (by & 0xff))
            w16(a + 2, (r16(o + 0x02) & 0xfe00) | (bx & 0x1ff) | (facing == 4 and 0x1000 or 0))
            w16(a + 4, (bstart & 0x3ff) | (hwSpritePriority() << 10) | ((bpal & 0x0f) << 12))
        else
            hwFxHide(rec, "blob")
        end
    else
        rec.blobPark, rec.blobParkHold, rec.blobParkKind = nil, nil, nil
        hwFxHide(rec, "blob")
    end

    -- THE REFLECTION -- for ANY peer standing on reflective ground, which is the engine's own
    -- rule and not a surfing one. Gating it on surfing was the painted tier's mistake too, and
    -- the user found the case both of them excluded on the same day: a ghost on the grass at the
    -- water's edge casts no reflection while the player beside it does.
    --
    -- The tile is asked WHERE THIS TIER DRAWS, not where the peer is -- in compare mode the two
    -- are deliberately several tiles apart, and asking about the peer authorises a reflection on
    -- dry land. Its own previous-tile store, rather than the painted tier's: the two tiers are
    -- drawing the same peer in different places, so they cannot share an answer about ground.
    local rpal, rkind
    local gbX, gbY = genderFrames.gridBase()
    if gbX then
        -- The painted tier's formula, unchanged, because that one is calibrated and confirmed on
        -- screen: the frame's own left edge, and the tile below its middle.
        tiering.hwLastTile = tiering.hwLastTile or {}
        local hgx = math.floor((sx - gbX) / TILE)
        local hgy = math.floor((sy - arcY + TILE - gbY) / TILE)
        rpal, rkind = genderFrames.reflectPalFor(tiering.hwLastTile, playerId, remote.areaId,
            hgx, hgy,
            ((info.width or FRAME_WIDTH_PX) + 8) >> 4,
            ((info.height or FRAME_HEIGHT_PX) + 8) >> 4,
            info.paletteSlot)
        -- Published for the painted tier's log, which runs later in the same frame: the two tiers
        -- ask the SAME function, so when their answers differ the difference is in the inputs, and
        -- these are the inputs.
        if COMPARE_TIERS then
            -- WHAT THE PAINTED TIER'S CLIP WOULD SAY AT THIS TIER'S OWN POSITION. The two copies
            -- stand in different columns, so comparing their reflections directly compares two
            -- pieces of shoreline as much as two renderers. This asks the painted tier's mask
            -- about the HARDWARE copy's tile -- where the framebuffer can be read for what the
            -- hardware actually drew -- so mask and hardware are finally answering about the same
            -- ground. Compare mode only, and it costs one span build for one peer.
            local hry = sy + (info.height or FRAME_HEIGHT_PX) - 2 - 2 * arcY
            local hwet = genderFrames.reflectiveSpans(sx, hry,
                info.width or FRAME_WIDTH_PX, info.height or FRAME_HEIGHT_PX, "reflection")
            local lo, hi = nil, nil
            if hwet then
                for y2, l in pairs(hwet) do
                    if #l > 0 then
                        if not lo or y2 < lo then lo = y2 end
                        if not hi or y2 > hi then hi = y2 end
                    end
                end
            end
            -- THE HARDWARE'S OWN ART ROWS, read back out of the tiles this tier copied into
            -- VRAM. The painted tier decodes the same picture from ROM; if the two disagree about
            -- which rows of the frame carry ink, then one of the two decodes is wrong, and that
            -- is a different bug from anything about reflections. 16 wide = 2 tiles across,
            -- 32 tall = 4 down, 4bpp, 32 bytes a tile, tiles in reading order.
            local firstRow, lastRow = nil, nil
            if rec.tileStart then
                for row = 0, 31 do
                    local tr, ly = row // 8, row % 8
                    local ink = false
                    for tc = 0, 1 do
                        local t = rec.tileStart + tr * 2 + tc
                        for byte = 0, 3 do
                            if r8(0x06010000 + t * 32 + ly * 4 + byte) ~= 0 then
                                ink = true
                                break
                            end
                        end
                        if ink then break end
                    end
                    if ink then
                        if not firstRow then firstRow = row end
                        lastRow = row
                    end
                end
            end
            tiering.hwReflDbg = string.format("hwArtRows=%s..%s ",
                tostring(firstRow), tostring(lastRow)) .. string.format(
                "tile=%d,%d wh=%d,%d pal=%s reflBox=%d..%d maskOpens=%s..%s", hgx, hgy,
                ((info.width or FRAME_WIDTH_PX) + 8) >> 4,
                ((info.height or FRAME_HEIGHT_PX) + 8) >> 4, tostring(rpal),
                math.floor(hry), math.floor(hry) + (info.height or FRAME_HEIGHT_PX) - 1,
                tostring(lo), tostring(hi))
        end
    end
    -- A RIPPLE PER TILE STEPPED. The store above stamps the frame the tile changed on, so the
    -- reflection's own bookkeeping answers "did this peer just step" for free -- and it answers it
    -- about the tile THIS tier drew on, which is the one the trail belongs to.
    if genderFrames.rippleDue(tiering.hwLastTile or {}, playerId,
        remote.gfx and SURFING_GFX[remote.gfx]) then
        local w = info.width or FRAME_WIDTH_PX
        local h = info.height or FRAME_HEIGHT_PX
        tiering.hw.ripples[#tiering.hw.ripples + 1] = {
            at = frameCounter,
            bx = sx + (w >> 1) - 8 - rs16(GSPRITECOORDOFFSETX_ADDR),
            by = sy - arcY + h - 10 - rs16(GSPRITECOORDOFFSETY_ADDR),
        }
    end

    local rslot = rpal and rec.tileStart and hwFxSlot(playerId, rec, "refl")
    if not rslot then
        hwFxHide(rec, "refl")
        return
    end
    -- GetReflectionVerticalOffset is the graphic's own height minus two, and the engine negates
    -- the main sprite's y2 for the reflection -- so the gap between a character and its image is
    -- that offset MINUS TWICE the bob, and the two separate as the rider rises. `sy` already
    -- carries the bob, which is why it comes off twice here and not once.
    local ry = sy + (info.height or FRAME_HEIGHT_PX) - 2 - 2 * arcY
    local t0, t1 = 0x8000, 0x8000
    if info.oam ~= 0 then t0, t1 = r16(info.oam + 0x00), r16(info.oam + 0x02) end
    local a = tiering.hw.base + rslot * 8
    -- gOamMatrices entry: a +0, b +2, c +4, d +6. d is the vertical flip the engine keeps there.
    --
    -- ON ICE THE ENGINE TAKES THE PLAIN-FLIP PATH ITSELF, so the matrix is not ours to borrow:
    -- SetUpReflection only sets ST_OAM_AFFINE_NORMAL when stillReflection is FALSE, and
    -- GroundEffect_IceReflection passes TRUE (src/field_effect_helpers.c:47-68). Pointing an ice
    -- reflection at matrix 0 gave it the water shimmer, which the user saw straight away in
    -- Shoal Cave: *"the OAM & DRAWN ghost reflections are wobbling/moving. they are supposed to
    -- stay static while on ice"*. Same else-branch the stale-matrix guard already falls back to.
    local m = hFlip and 1 or 0
    if rkind ~= "ice" and rs16(genderFrames.oamMatricesAddr + m * 8 + 6) < -128 then
        -- ST_OAM_AFFINE_NORMAL: attr0 bits 8-9 = 01, attr1 bits 9-13 = the matrix index. The
        -- flip bits do not exist in this mode -- the matrix carries both flips.
        w16(a + 0, (t0 & 0xfc00) | 0x0100 | (ry & 0xff))
        w16(a + 2, (t1 & 0xc000) | (m << 9) | (sx & 0x1ff))
    else
        w16(a + 0, (t0 & 0xff00) | (ry & 0xff))
        w16(a + 2, (t1 & 0xc000) | (hFlip and 0x1000 or 0) | 0x2000 | (sx & 0x1ff))
    end
    w16(a + 4, (rec.tileStart & 0x3ff) | (3 << 10) | ((rpal & 0x0f) << 12))
    -- Published for the painted tier's comparison log, which runs later in the same frame. The
    -- two tiers use the same formula; if their reflections do not land on the same row, one of
    -- them is not being given the same inputs, and that is a different bug from a wrong formula.
    if COMPARE_TIERS then tiering.hwBodyY, tiering.hwReflY = sy, ry end
end

-- `sx`,`sy` are the body entry's top-left as written this frame, and `arcY` is the hop the body is
-- carrying: both effects belong on the GROUND the peer left, so the arc comes back off. That is
-- the same term the engine drops by driving its shadow from pos1 while the character rides pos2,
-- and the same one the painted tier subtracts.
function hwDrawFx(playerId, rec, remote, info, sx, sy, arcY, hFlip)
    local w, h = info.width or FRAME_WIDTH_PX, info.height or FRAME_HEIGHT_PX
    local groundY = sy - arcY
    local jumping = isJumpAction(remote.act) or false

    hwDrawSurf(playerId, rec, remote, info, sx, sy, arcY, hFlip)

    local size = 1
    if info.raw and info.raw ~= 0 then size = (r8(info.raw + 0x0c) >> 4) & 0x03 end
    local tmpl = genderFrames.shadowTemplates[size]
    local start = jumping and tmpl and hwFxTiles("shadow:" .. size, r32(tmpl + 0x0c), 0)
    local slot = start and hwFxSlot(playerId, rec, "shadow")
    if slot then
        local o = r32(tmpl + 0x04)
        -- shadowTopFor's arithmetic, in top-left terms: the character's own half-height, less the
        -- graphic's shadow offset, less the shadow sprite's 4px half-height.
        local hy = groundY + h - (genderFrames.shadowDrop[size] or 4) - 4
        local hx = sx + (w >> 1) - 8
        local a = tiering.hw.base + slot * 8
        w16(a + 0, (r16(o + 0x00) & 0xff00) | (hy & 0xff))
        w16(a + 2, (r16(o + 0x02) & 0xfe00) | (hx & 0x1ff))
        w16(a + 4, (start & 0x3ff) | (hwSpritePriority() << 10))
    else
        hwFxHide(rec, "shadow")
    end

    -- The same landing latch both other tiers read, so all three puff on the same frame -- and
    -- like the painted tier's, the puff is a TRAIL entry: it is born on the landing edge, records
    -- where the ground was, and hwPuffTick below plays it out on that spot while the body hops on.
    local _, landedNow = genderFrames.noteLanding(playerId, jumping, remote.act)
    if landedNow then
        tiering.hw.puffs[#tiering.hw.puffs + 1] = {
            at = frameCounter,
            bx = sx + (w >> 1) - 8 - rs16(GSPRITECOORDOFFSETX_ADDR),
            by = groundY + h - 8 - rs16(GSPRITECOORDOFFSETY_ADDR),
        }
    end
end

-- Play out every live puff at its own recorded spot, camera-anchored the same way the painted
-- trail is. Slots come from the dust pool ON DEMAND, one per live puff rather than one per peer:
-- a 24-frame animation against a 16-frame bounce means two puffs overlap briefly, and per-peer
-- ownership could only ever show one. More live puffs than pool slots drops the OLDEST -- it has
-- the least animation left to show.
function hwPuffTick()
    local puffs = tiering.hw.puffs
    if #puffs == 0 then return end
    local offX, offY = rs16(GSPRITECOORDOFFSETX_ADDR), rs16(GSPRITECOORDOFFSETY_ADDR)
    local imgs = r32(genderFrames.dustTemplate + 0x0c)
    local pal = hwPaletteSlotForTag(0x1004)
    local o = r32(genderFrames.dustTemplate + 0x04)
    for pi = #puffs, 1, -1 do
        local puff = puffs[pi]
        local f = genderFrames.dustFrameAt(frameCounter - puff.at)
        local start = f and pal and isRomPtr(imgs) and hwFxTiles("dust:" .. f, imgs, f)
        if not start then
            if puff.slot then
                local a = tiering.hw.base + puff.slot * 8
                w16(a + 0, tiering.hw.d0) w16(a + 2, tiering.hw.d1) w16(a + 4, tiering.hw.d2)
                tiering.hw.slotUsed[puff.slot] = nil
            end
            table.remove(puffs, pi)
        else
            if not puff.slot then
                for i = tiering.hw.dustFirst, tiering.hw.dustLast do
                    if not tiering.hw.slotUsed[i] then
                        tiering.hw.slotUsed[i] = "puff"
                        puff.slot = i
                        break
                    end
                end
            end
            if not puff.slot then
                table.remove(puffs, pi) -- pool exhausted: iteration is newest-first, this is oldest
            else
                local a = tiering.hw.base + puff.slot * 8
                local dx, dy = puff.bx + offX, puff.by + offY
                if dx + 16 <= 0 or dx >= 240 or dy + 8 <= 0 or dy >= 160 then
                    w16(a + 0, tiering.hw.d0) w16(a + 2, tiering.hw.d1) w16(a + 4, tiering.hw.d2)
                else
                    w16(a + 0, (r16(o + 0x00) & 0xff00) | (dy & 0xff))
                    w16(a + 2, (r16(o + 0x02) & 0xfe00) | (dx & 0x1ff))
                    w16(a + 4, (start & 0x3ff) | (hwSpritePriority() << 10) | (pal << 12))
                end
            end
        end
    end
end

-- Play out every live ripple where it was dropped, camera-anchored exactly as the dust trail is.
-- Slots come from the ripple pool ON DEMAND, one per live ripple rather than one per peer: an
-- 80-frame life against a tile stepped every 8 frames means ten are alive at a steady pace, and
-- per-peer ownership could only ever show one of them.
--
-- MORE LIVE RIPPLES THAN POOL SLOTS DROPS THE OLDEST -- it has the least animation left to show --
-- AND SAYS SO. A tier that quietly shows eight of ten reads as "covered everything" when it did
-- not, which is the one thing a ceiling must never do.
function hwRippleTick()
    local list = tiering.hw.ripples
    if #list == 0 then return end
    local offX, offY = rs16(GSPRITECOORDOFFSETX_ADDR), rs16(GSPRITECOORDOFFSETY_ADDR)
    local imgs = r32(genderFrames.rippleTemplate + 0x0c)
    local pal = hwPaletteSlotForTag(r16(genderFrames.rippleTemplate + 0x02))
    local o = r32(genderFrames.rippleTemplate + 0x04)
    for ri = #list, 1, -1 do
        local rip = list[ri]
        local f = genderFrames.rippleFrameAt(frameCounter - rip.at)
        local start = f and pal and isRomPtr(imgs) and hwFxTiles("ripple:" .. f, imgs, f)
        if not start then
            if rip.slot then
                local a = tiering.hw.base + rip.slot * 8
                w16(a + 0, tiering.hw.d0) w16(a + 2, tiering.hw.d1) w16(a + 4, tiering.hw.d2)
                tiering.hw.slotUsed[rip.slot] = nil
            end
            table.remove(list, ri)
        else
            if not rip.slot then
                for i = tiering.hw.rippleFirst, tiering.hw.rippleLast do
                    if not tiering.hw.slotUsed[i] then
                        tiering.hw.slotUsed[i] = "ripple"
                        rip.slot = i
                        break
                    end
                end
            end
            if not rip.slot then
                -- Iteration is newest-first, so this is the oldest live ripple.
                if not tiering.hw.rippleDropAt
                    or frameCounter - tiering.hw.rippleDropAt >= 300 then
                    tiering.hw.rippleDropAt = frameCounter
                    console.log(string.format(
                        "MeshGhost: hardware ripple pool full (%d slots); dropping the oldest of "
                        .. "%d live ripples.",
                        tiering.hw.rippleLast - tiering.hw.rippleFirst + 1, #list))
                end
                table.remove(list, ri)
            else
                local a = tiering.hw.base + rip.slot * 8
                local dx, dy = rip.bx + offX, rip.by + offY
                if dx + genderFrames.rippleFramePx <= 0 or dx >= 240
                    or dy + genderFrames.rippleFramePx <= 0 or dy >= 160 then
                    -- GIVE THE SLOT BACK, not just the pixels. A ripple that has scrolled off
                    -- screen is invisible either way, but holding its entry starves the ones still
                    -- in view -- and a trail is exactly the thing whose oldest members leave the
                    -- screen first while newer ones are still being made.
                    w16(a + 0, tiering.hw.d0) w16(a + 2, tiering.hw.d1) w16(a + 4, tiering.hw.d2)
                    tiering.hw.slotUsed[rip.slot] = nil
                    rip.slot = nil
                else
                    w16(a + 0, (r16(o + 0x00) & 0xff00) | (dy & 0xff))
                    w16(a + 2, (r16(o + 0x02) & 0xfe00) | (dx & 0x1ff))
                    w16(a + 4, (start & 0x3ff) | (hwSpritePriority() << 10) | (pal << 12))
                end
            end
        end
    end
end

-- How many more peers this tier can take right now. Entries are never the binding limit (56 of them
-- against a handful of peers); OBJ TILES are, which is why exhaustion is discovered at acquire time
-- rather than predicted here.
tiering.hwBudget = function()
    if not tiering.hw.on then return 0 end
    local free = 0
    for i = 0, tiering.hw.slots - 1 do if not tiering.hw.slotUsed[i] then free = free + 1 end end
    return free
end

-- THE LADDER'S MIDDLE RUNG. Given the peers the engine could not take, pick the nearest ones this
-- tier has room for; everyone left over is the painted tier's problem.
--
-- Same nearest-wins ranking and same hysteresis as chooseSpawned, and for the same reason: without
-- the band two peers at nearly equal distance swap tiers every few frames -- and here a swap costs a
-- tile reallocation and a VRAM copy rather than merely a different renderer.
tiering.chooseHardware = function(localAreaId, playerX, playerY, spawnSet)
    local set = {}
    if not tiering.hw.on then return set end
    -- Same post-load quiet as chooseSpawned, same reason, same measurement.
    if genderFrames.loadQuietUntil and frameCounter < genderFrames.loadQuietUntil then
        return set
    end
    -- WHERE THE ENGINE HAS TILED THE SCREEN WITH SEMI-TRANSPARENT SPRITES, THIS TIER CANNOT DRAW
    -- CLEANLY -- see hwSpritePriority for the full reasoning and the measurements. Its peers become
    -- the painted tier's, which is drawn after the frame and unaffected by any of it.
    --
    -- ASKED AS A QUESTION ABOUT THE SCREEN, NOT ABOUT THE PLACE. This began as an underwater test,
    -- because underwater was where it was found. Mt Pyre's fog then did exactly the same thing on
    -- dry land -- the user: *"the OAM ghost is invisible as soon as the fog appears"*, and no white
    -- box, because here we are simply behind it rather than fighting it. Measured on the exterior
    -- (`dev-scripts/fog2.log`, 2026-08-21): entries 3..17 hold twelve 64x64 sprites in objMode 1
    -- at priority 2, on a 64px grid covering the screen, with the player at entry 1 and ours at 68.
    -- Same priority, so the tie goes to the lower entry: the fog draws over us and under the
    -- player. Identical in shape to the underwater grid, which makes "underwater" the wrong
    -- predicate -- weather is not a place, and the next such effect would have been a third bug.
    if not MESHGHOST_EMERALD_HW_PRIORITY
        and genderFrames.screenCoveredBySemiTransparentSprites() then
        if next(tiering.hw.byPeer) then hwReleaseAll(false) end
        return set
    end
    local ranked = {}
    for playerId, remote in pairs(remotes) do
        -- The loopback ghost is the one peer allowed into every tier at once, and only in compare
        -- mode -- that is the whole point of compare mode. Everyone else lands here exactly when the
        -- engine had no room for them.
        local alsoSpawned = COMPARE_TIERS and playerId:match("%-ghost$") ~= nil
        if remote.areaId == localAreaId
            and (alsoSpawned or not (spawnSet and spawnSet[playerId]))
        then
            local dx, dy = remote.x - playerX, remote.y - playerY
            local d = math.sqrt(dx * dx + dy * dy)
            if tiering.hw.byPeer[playerId] then d = d - tiering.hysteresis end
            ranked[#ranked + 1] = { id = playerId, d = d }
        end
    end
    table.sort(ranked, function(a, b)
        if a.d == b.d then return a.id < b.id end
        return a.d < b.d
    end)
    -- Peers that already hold a slot keep it; the free-slot count is what the newcomers share.
    local room = tiering.hwBudget()
    for i = 1, #ranked do
        local id = ranked[i].id
        if tiering.hw.byPeer[id] then
            set[id] = true
        elseif room > 0 then
            set[id] = true
            room = room - 1
        end
    end
    return set
end

-- Write this frame's entries. Runs after the spawned tier and before the painted one, so the painted
-- tier can be told to skip whoever landed here.
function renderHardwareGhosts(localAreaId, playerMapX, playerMapY, hwSet)
    tiering.hw.placed = 0
    -- THE EARLY RETURNS BELOW MUST NOT STRAND A LIVE PUFF. A trail outlives the bounce that made
    -- it, so switching the tier off -- or crossing onto a ROM it does not engage on -- can happen
    -- with puffs still on screen, and every path out of this function has to leave OAM clean.
    if not tiering.hw.on or avatarAddrOffset ~= 0 then
        if #tiering.hw.puffs > 0 then hwReleaseAll(true) end
        return
    end
    if not next(hwSet) and (not tiering.hw.lastEmpty
        or frameCounter - tiering.hw.lastEmpty > 300) then
        tiering.hw.lastEmpty = frameCounter
        logFile("hw tier: on, but no peer was assigned to it this frame")
    end
    -- (VANILLA ONLY: gMain's address comes from our own build of the decomp and an Archipelago ROM
    -- relocates code and data -- the same gate the fishing hook uses. Checked at the top, with the
    -- puff cleanup, so a patched ROM cannot strand one.)

    -- A MAP CHANGE INVALIDATES EVERY TILE ALLOCATION. The engine runs ResetSpriteData on a map load,
    -- which frees all sprite tile ranges and hands them to the new map's NPCs. Ours went with them,
    -- so the records are dropped WITHOUT clearing bits we no longer own.
    if tiering.hw.area ~= localAreaId then
        hwReleaseAll(false)
        tiering.hw.area = localAreaId
    end

    -- Anyone no longer in the set gives their slot and tiles back this frame, not eventually.
    for playerId in pairs(tiering.hw.byPeer) do
        if not hwSet[playerId] or not remotes[playerId] then hwRelease(playerId, true) end
    end

    -- The dust trail outlives the bounce that made it, so it is ticked here rather than inside
    -- any one peer's placement -- a peer who leaves the tier mid-puff still gets the tail of it.
    hwPuffTick()
    hwRippleTick()

    local playerScreenX, playerScreenY = playerScreenPos()
    local camPixX, camPixY, pmX, pmY = anchorFrame(localAreaId, playerScreenX, playerScreenY,
        playerMapX, playerMapY)
    playerMapX, playerMapY = pmX, pmY

    for playerId in pairs(hwSet) do
        local remote = remotes[playerId]
        local info = remote and graphicsInfo(remote.gfx or 0)
        if info then
            local rec = tiering.hw.byPeer[playerId]
            -- A GRAPHIC CHANGE IS A DIFFERENT TILE COUNT. A walker is 8 tiles and a bike or a surf
            -- blob is 16, so keeping the old range would either waste half of it or overrun the
            -- neighbour's. Release and re-acquire, which is cheap here precisely because there is no
            -- engine state to rebuild -- the expensive version of this is what
            -- swapGhostGraphicInPlace exists to avoid on the SPAWNED tier.
            if rec and rec.gfx ~= nil and rec.gfx ~= remote.gfx then
                hwRelease(playerId, true)
                rec = nil
            end
            if not rec then rec = hwAcquire(playerId, info) end
            -- WHY NOTHING APPEARED, said once every 5 seconds rather than never. A tier that
            -- silently renders nobody is indistinguishable from one that is switched off, and that
            -- cost a whole test cycle on 2026-08-21. Throttled to the file, never the console.
            if not rec and (not tiering.hw.lastWhy
                or frameCounter - tiering.hw.lastWhy > 300) then
                tiering.hw.lastWhy = frameCounter
                logFile(string.format(
                    "hw tier: no slot/tiles for %s (free slots=%d, wanted %d tiles, gfx=%s)",
                    tostring(playerId), tiering.hwBudget(), info.tileCount, tostring(remote.gfx)))
            end
            if rec then
                -- WHERE ON SCREEN. The same origin + delta + camera-pixel form the painted tier
                -- uses, and it is already the sprite's TOP-LEFT in screen pixels -- which is exactly
                -- what a hardware entry's x/y mean, so no conversion is involved.
                local glideX = remote.gX or remote.x
                local glideY = remote.gY or remote.y
                -- PINNED TO THE SPAWNED GHOST IN COMPARE MODE -- the same rule the painted copy has
                -- always had, adopted 2026-08-21 after not having it produced a false verdict
                -- against this tier twice in one evening.
                --
                -- WHY PINNING IS THE ONLY HONEST COMPARISON. The glide pipeline carries a
                -- DELIBERATE trailing delay (genderFrames.drawnDelay -- it reproduces the distance
                -- the engine's own step machine trails by), so a compare copy placed from the glide
                -- is 8 frames behind the reference BY DESIGN. Standing still the two align to the
                -- pixel; moving, the gap opens to the delay times the speed -- measured on the ride
                -- as 0px for 1243 frames and up to ~30px mid-run, which the user, twice, correctly
                -- reported as *"trailing behind/not following properly"*. That is the POSITION
                -- pipeline showing through, not the renderer under test -- the painted copy hides
                -- the identical behaviour by never using its own position at all in compare mode.
                -- Pinning both copies to the spawned sprite removes position from the comparison
                -- entirely, which is the point: what remains different on screen is the RENDERER --
                -- facing, pose, palette, occlusion -- and nothing else.
                local cmpPin = COMPARE_TIERS and playerId:match("%-ghost$") and ghosts[playerId]
                if cmpPin then
                    local gs = sprAddr(cmpPin.sprId)
                    local px = rs16(gs + 0x20) + rs16(gs + 0x24) + memory.read_s8(gs + 0x28)
                        + rs16(GSPRITECOORDOFFSETX_ADDR)
                    local py = rs16(gs + 0x22) + rs16(gs + 0x26) + memory.read_s8(gs + 0x29)
                        + rs16(GSPRITECOORDOFFSETY_ADDR)
                    local a = tiering.hw.base + rec.slot * 8
                    local sx = px + (tiering.hw.cmpDX or 0) * TILE
                    local sy = py + (tiering.hw.cmpDY or 0) * TILE
                    local t0, t1 = 0x8000, 0x8000
                    if info.oam ~= 0 then t0, t1 = r16(info.oam + 0x00), r16(info.oam + 0x02) end
                    local flip = 0
                    local aptr = r32(info.anims + (remote.sanim or 0) * 4)
                    if isRomPtr(aptr)
                        and ((r32(aptr + (remote.sidx or 0) * 4) >> 22) & 1) == 1 then
                        flip = 0x1000
                    end
                    local an, ai = remote.sanim or 0, remote.sidx or 0
                    if rec.gfx ~= remote.gfx or rec.animNum ~= an or rec.animIdx ~= ai then
                        loadGhostFrameNow(rec, info, an, ai)
                        if COMPARE_TIERS then
                            logFile(string.format(
                                "HW LOAD gfx=%s an=%s/%s tiles=%s..%s f=%d emu=%d",
                                tostring(remote.gfx), tostring(an), tostring(ai),
                                tostring(rec.tileStart),
                                tostring(rec.tileStart and rec.tileStart + rec.tileCount - 1),
                                frameCounter, emu.framecount()))
                        end
                        rec.gfx, rec.animNum, rec.animIdx = remote.gfx, an, ai
                    end
                    w16(a + 0, (t0 & 0xff00) | (sy & 0xff))
                    w16(a + 2, (t1 & 0xfe00) | (sx & 0x1ff) | flip)
                    w16(a + 4, (rec.tileStart & 0x3ff) | (hwSpritePriority() << 10)
                        | ((info.paletteSlot or 0) << 12))
                    -- The pin copies the spawned sprite's pos2, so the hop arc is in `sy` here and
                    -- has to come back off for the two ground effects.
                    hwDrawFx(playerId, rec, remote, info, sx, sy, rs16(gs + 0x26), flip ~= 0)
                    tiering.hw.placed = tiering.hw.placed + 1
                    if COMPARE_TIERS then tiering.hwLastX, tiering.hwLastY = sx, sy end
                    goto hwNextPeer
                end
                -- THE LOOPBACK GHOST STANDS BESIDE THE PLAYER, NOT ON THEM. Same offset the other
                -- two tiers apply, and it exists for the same reason: a dev ghost echoing the
                -- player's own state renders exactly on top of them, where nothing about it can be
                -- judged. Two tiles to the side and it can be compared frame by frame -- and, the
                -- reason it was needed on 2026-08-21, it can be WALKED somewhere: a fixed synthetic
                -- peer cannot be taken behind a building to check occlusion, and the loopback one
                -- goes wherever the player goes.
                if playerId:match("%-ghost$") then
                    if COMPARE_TIERS then
                        -- THREE-WAY COMPARE: the same peer rendered by all three tiers at once --
                        -- spawned 2 tiles right, painted 2 tiles left, and this one wherever the
                        -- offsets below put it. The user's call, 2026-08-21: *"i want to compare all
                        -- 3 to each other. only testing OAM alone is dumb"*, and they are right --
                        -- "is it choppy" is not a question a single renderer can answer, because the
                        -- peer's position pipeline is shared by all three and would look identical
                        -- in each.
                        --
                        -- DEFAULT: two tiles ABOVE the spawned ghost -- same column, one body up.
                        -- The spawned copy is the reference every other tier is judged against, so
                        -- this one is parked directly over it: same x, so a horizontal difference
                        -- is a misalignment rather than the offset, and clear vertical air so both
                        -- are fully visible at once.
                        --
                        -- OVERLAPPING THEM EXACTLY WAS TRIED AND IS WRONG, 2026-08-21. The idea was
                        -- that a hardware entry always loses an overlap tie, so a matched pair would
                        -- show one ghost and a mismatch would peek out. The user, immediately: *"no
                        -- its sitting right on top of the spawned one... useless for testing if they
                        -- are directly on top of each other"*. They are right and the reasoning was
                        -- backwards -- a renderer you cannot SEE cannot be compared, and the failure
                        -- being looked for (choppiness, a frame of lag, a wrong pose) is a property
                        -- of motion that a peek-out cannot express.
                        --
                        -- tiering.hw.cmpDX/cmpDY move it from a loader script without restarting.
                        glideX = glideX + LOOPBACK_GHOST_OFFSET_TILES_X + (tiering.hw.cmpDX or 0)
                        glideY = glideY + LOOPBACK_GHOST_OFFSET_TILES_Y + (tiering.hw.cmpDY or 0)
                    else
                        glideX = glideX + LOOPBACK_GHOST_OFFSET_TILES_X
                        glideY = glideY + LOOPBACK_GHOST_OFFSET_TILES_Y
                    end
                end
                local sx = (tiering.originX or playerScreenX)
                    + (glideX - (tiering.anchorX or playerMapX)) * TILE + camPixX
                local sy = (tiering.originY or playerScreenY)
                    + (glideY - (tiering.anchorY or playerMapY)) * TILE + camPixY
                sx, sy = math.floor(sx + 0.5), math.floor(sy + 0.5)
                -- THE PEER'S OWN HOP, off the wire (2026-08-21). The glide pipeline above carries
                -- position and nothing else, so an overflow peer used to SLIDE over a ledge with
                -- its shadow pinned under its feet, while the pinned compare copy a few lines up
                -- arced correctly from the spawned sprite -- which is exactly why compare mode
                -- could never show it. `soy` is the peer's sprite pos2.y, already on the wire for
                -- the surf bob; the same number is the jump arc, and the painted tier now takes it
                -- from the same place. Taken verbatim here, fishing included: this tier draws the
                -- peer's own frame from its own OAM template and re-derives no alignment of its
                -- own, so the engine's whole vertical offset is exactly what it wants.
                local arc = remote.soy or 0
                sy = sy + arc

                -- OFF SCREEN GETS THE HIDDEN ENTRY, NOT A WRAPPED ONE. An entry's x is 9 bits and
                -- its y is 8, so a peer at x = -900 does not vanish, it reappears somewhere absurd.
                -- The engine's own dummy encoding is what "not drawn" looks like here.
                local a = tiering.hw.base + rec.slot * 8
                if sx + (info.width or FRAME_WIDTH_PX) <= 0 or sx >= 240
                    or sy + (info.height or FRAME_HEIGHT_PX) <= 0 or sy >= 160 then
                    w16(a + 0, tiering.hw.d0)
                    w16(a + 2, tiering.hw.d1)
                    w16(a + 4, tiering.hw.d2)
                    hwFxHide(rec, "shadow")
                    hwFxHide(rec, "dust")
                else
                    -- THE GRAPHIC'S OWN OAM TEMPLATE, copied rather than reconstructed. Its first
                    -- two halfwords already carry the correct shape and size for this character;
                    -- building them by hand would be re-deriving something the ROM states. Same move
                    -- spawnSurfBlob makes with the same pointer.
                    local t0, t1 = 0x8000, 0x8000 -- 16x32, the walker's shape/size, as the fallback
                    if info.oam ~= 0 then t0, t1 = r16(info.oam + 0x00), r16(info.oam + 0x02) end

                    -- THE PIXELS, only on a change: a frame copy is info.size/4 read+write pairs,
                    -- cheap once and ruinous per frame. The peer's own animation number and frame
                    -- index are used directly, so what is on screen is the frame the peer's game is
                    -- actually showing rather than one this adapter re-derived.
                    local an, ai = remote.sanim or 0, remote.sidx or 0
                    if rec.gfx ~= remote.gfx or rec.animNum ~= an or rec.animIdx ~= ai then
                        loadGhostFrameNow(rec, info, an, ai)
                        if COMPARE_TIERS then
                            logFile(string.format(
                                "HW LOAD gfx=%s an=%s/%s tiles=%s..%s f=%d emu=%d",
                                tostring(remote.gfx), tostring(an), tostring(ai),
                                tostring(rec.tileStart),
                                tostring(rec.tileStart and rec.tileStart + rec.tileCount - 1),
                                frameCounter, emu.framecount()))
                        end
                        rec.gfx, rec.animNum, rec.animIdx = remote.gfx, an, ai
                    end

                    -- FACING IS IN THE ANIMATION COMMAND, NOT IN THE FRAME. Emerald has no
                    -- east-facing artwork: east is the WEST frames with the hardware's horizontal
                    -- flip set, which is why animNum 2 serves both directions. The flip lives at
                    -- bit 22 of the animation command word -- the same bit the painted tier reads
                    -- for the same reason -- and an entry that ignores it shows a character facing
                    -- the wrong way exactly half the time. User, 2026-08-21, comparing the three
                    -- tiers: *"OAM is facing left, whenever i face right"*.
                    --
                    -- Bit 12 of the second halfword is hFlip when the entry is not affine, which is
                    -- ours: the template's affine bits are copied unchanged and overworld characters
                    -- are never affine.
                    local flip = 0
                    local aptr = r32(info.anims + an * 4)
                    if isRomPtr(aptr) and ((r32(aptr + ai * 4) >> 22) & 1) == 1 then
                        flip = 0x1000
                    end
                    w16(a + 0, (t0 & 0xff00) | (sy & 0xff))
                    w16(a + 2, (t1 & 0xfe00) | (sx & 0x1ff) | flip)
                    -- Priority and palette buy the occlusion and the fades. Priority 2 is ordinary
                    -- ground, which is what the engine gives its own overworld characters; the
                    -- palette slot comes from the graphic's own descriptor, not from anything ours.
                    w16(a + 4, (rec.tileStart & 0x3ff) | (hwSpritePriority() << 10)
                        | ((info.paletteSlot or 0) << 12))
                    -- The arc is in `sy` now, so it comes back off for the two ground effects --
                    -- the same contract the pinned path above uses.
                    hwDrawFx(playerId, rec, remote, info, sx, sy, arc, flip ~= 0)
                    tiering.hw.placed = tiering.hw.placed + 1
                    -- Published for the three-way compare log in drawRemotes, which runs after this
                    -- in the same frame. Where the OTHER two tiers put the same peer is already on
                    -- that line; without this one there is no way to tell "the hardware tier lags"
                    -- from "the peer's position pipeline lags and all three inherit it".
                    if COMPARE_TIERS then
                        tiering.hwLastX, tiering.hwLastY = sx, sy
                        -- The formula's four inputs, so a drift can be attributed to one of them
                        -- rather than argued about. Compare mode only.
                        tiering.hwDbg = string.format("gX=%.3f anch=%s orig=%s cam=%d",
                            glideX, tostring(tiering.anchorX), tostring(tiering.originX), camPixX)
                    end
                end
            end
        end
        ::hwNextPeer::
    end
end

-- skipSpawned, when given, names the peers the ENGINE is already drawing as real object events.
-- Drawing those again would paint a flat copy on top of the engine's own animated one -- so the
-- drawn tier renders exactly the peers the spawned tier could not take.
-- compareOnly: draw NOTHING except the loopback ghost. That is the MESHGHOST_COMPARE_TIERS case
-- where the overflow tier itself is off -- the comparison ghost is wanted, a painted crowd is not.
local function drawRemotes(localAreaId, playerMapX, playerMapY, skipSpawned, compareOnly)
    -- The GBA's visible display. Hardware geometry, identical on every cartridge -- not a fact
    -- about this game. Declared inside this function on purpose: the main chunk is at Lua's hard
    -- ceiling of 200 locals, and a local inside a function is counted against the function.
    local SCREEN_WIDTH_PX, SCREEN_HEIGHT_PX = 240, 160
    -- Where the painted comparison copy goes: the other side of the player from the spawned one.
    -- Where the painted comparison copy stands, in tiles from the player. Settable, because the
    -- three copies stand in three columns and a shoreline is not a straight line: to tell "this
    -- renderer is wrong" from "this copy is standing further from the water", the two copies have
    -- to be put on the SAME TILE and compared there. -4 lines it up with the hardware copy.
    local COMPARE_DRAWN_OFFSET_TILES_X =
        tonumber(MESHGHOST_EMERALD_DRAWN_COMPARE_DX or "") or -2
    -- THE ENGINE HIDES ITS OWN PLAYER DURING A DOOR/WARP TRANSITION -- so we hide ours, but only
    -- once the fade has actually finished.
    --
    -- Entering a house, the engine sets the invisible bit (0x04) on the PLAYER's own sprite flags
    -- (+0x3e) for the whole transition -- 44 frames before the map id even changes, cleared once
    -- the new map is up (probes/turn_and_door_probe.lua). Cutting the ghost on that alone worked,
    -- and looked worse than the exit case, which the scene-brightness scaling below carries: the
    -- user, comparing them, *"leaving the house even looks better than entering the house"* --
    -- because leaving FADES the ghost out with everything else while entering snapped it away.
    --
    -- So the hard cut is kept as a backstop for the part of the transition where there is nothing
    -- on screen at all, and the fade does the visible work. Same rule as ever: while the game will
    -- not draw its own player, there is nobody for a ghost to stand beside.
    local playerSprite = sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04))
    local playerHidden = (r8(playerSprite + 0x3e) & 0x04) ~= 0

    -- HOW BRIGHT IS THE SCENE RIGHT NOW? Measured from the hardware palette, once per frame.
    --
    -- The pixels this tier draws were decoded from the CARTRIDGE's palette and cached, so they are
    -- always full brightness -- while everything the PPU draws is dimmed by whatever fade, cave or
    -- night the game has applied to palette RAM. That is why the drawn ghost shone through a house
    -- EXIT (the fade-in) even after the entry case was fixed: leaving, the engine leaves the
    -- player's sprite visible and simply fades the screen, so there is no invisible flag to catch.
    --
    -- The comparison is like for like: the LIVE OBJ palette the player's own sprite is using
    -- (palette RAM at 0x05000200, GBA hardware, the same footing as the BGnCNT read that finds the
    -- tilemaps) against the ROM palette that same character was decoded from. What the hardware
    -- did to those sixteen colours is what it did to every character on screen, so doing the same
    -- to ours is what "the same lighting" means. It costs 32 reads a frame and nothing per peer.
    --
    -- A RATIO IS THE WRONG SHAPE, and that is a fix rather than a refinement (2026-08-21).
    -- The engine's fades are `BlendPalette`: every colour moves a fraction of the way toward one
    -- target colour, c -> c + (target - c) * coeff/16 (pokeemerald src/palette.c). A scalar
    -- brightness ratio can only ever express the case where that target is BLACK -- and a cave
    -- mouth fades to WHITE. Measured across a real cave entry with probes/cavewarp_probe.lua: the
    -- OBJ palette's channel sum climbs 747 -> 1488 (sixteen colours, all channels at 31: pure
    -- white) over fourteen frames and stays there for the ~65 frames of the transition, while the
    -- ratio reads 1.99, clamps to 1, and reports a perfectly normal scene. So the painted copy
    -- kept drawing at full colour over a screen that had washed out to white, which is what the
    -- user saw: *"when going inside a cave, the drawn ghost stays on the screen for a bit too
    -- long."* The spawned and hardware tiers were unaffected because both are drawn by the PPU
    -- from that same live palette.
    --
    -- So fit the BLEND instead of a ratio: live = a*rom + b over all 48 channel values, which is
    -- exactly the line BlendPalette produces (a = 1 - coeff/16, b = target * coeff/16) and which
    -- covers fading to black, to white, a cave's tint, weather and night with one expression.
    -- `dim` keeps its meaning as the multiplier; `genderFrames.tintAdd` carries the additive term
    -- (that table, not `tiering`, because drawRunList is defined above `local tiering` and would
    -- otherwise resolve it to a nil global -- the trap this file already carries a note about).
    local dim = 1
    do
        local ps = sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04))
        local slot = (r16(ps + 0x04) >> 12) & 0xF
        local romPal = GOBJECTEVENTPAL_BRENDAN_ADDR + (genderFrames.romOffset or 0)
        local sb2 = r32(GSAVEBLOCK2PTR_ADDR)
        if sb2 ~= 0 and r8(sb2 + 0x08) == 1 then
            romPal = GOBJECTEVENTPAL_MAY_ADDR + (genderFrames.romOffset or 0)
        end
        local sx, sy, sxx, sxy, syy = 0, 0, 0, 0, 0
        local xs, ys = {}, {}
        for i = 0, 15 do
            local c = r16(0x05000200 + slot * 32 + i * 2)
            local o = r16(romPal + i * 2)
            for s = 0, 10, 5 do
                local x, y = (o >> s) & 0x1F, (c >> s) & 0x1F
                local k = #xs + 1
                xs[k], ys[k] = x, y
                sx, sy = sx + x, sy + y
            end
        end
        local nPts = #xs
        local mx, my = sx / nPts, sy / nPts
        for i = 1, nPts do
            local dx, dy = xs[i] - mx, ys[i] - my
            sxx, sxy, syy = sxx + dx * dx, sxy + dx * dy, syy + dy * dy
        end
        local a, b
        if syy < 1e-6 then
            -- Every live colour is the same one: the fade has run all the way to its target, so
            -- the ghost is that flat colour too -- white on white, black on black, invisible
            -- either way, which is precisely what the player sees of everything else.
            a, b = 0, my
        elseif sxx > 1e-6 and sxy * sxy > 0.9 * sxx * syy then
            a = sxy / sxx
            b = my - a * mx
        end
        -- No affine relation at all means the slot is not holding the palette we think it is --
        -- mid-map-load, or reallocated to something else. Trust the cartridge rather than paint a
        -- ghost in colours nothing on screen is using.
        if not a then
            a, b = 1, 0
        end
        if a > 1 then a = 1 elseif a < 0 then a = 0 end
        -- 0..31 palette units up to the 0..255 the run colours are cached in.
        b = b * (255 / 31)
        if b > 255 then b = 255 elseif b < 0 then b = 0 end
        dim, genderFrames.tintAdd = a, b
    end
    -- The backstop: hidden player AND a screen that has already gone dark. Either alone is a
    -- state the ghost should still be drawn in -- a dark cave is dim with the player visible, and
    -- the first frames of a door are hidden while the scene is still bright and fading.
    if playerHidden and dim < 0.15 then
        tiering.painted = 0
        return
    end

    local playerScreenX, playerScreenY = playerScreenPos()
    local panelRows = tiering.scanPanel()

    -- ANCHOR ON THE ENGINE'S OWN SCROLL, NOT ON OUR ESTIMATE OF THE PLAYER.
    --
    -- A drawn ghost is placed relative to the local player, and it used to be placed against the
    -- adapter's SMOOTHED estimate of the player while being drawn at the player's real pixel
    -- position -- a mismatch the file has carried a note about since 2026-08-14. It is invisible
    -- until the player moves, which is why three attempts at fixing the GHOST's movement all
    -- failed: the ghost's movement was never the problem.
    --
    -- MEASURED, over ~1000 frames of running in every direction (probes/turn_and_door_probe.lua):
    --
    --   * The player NEVER MOVES ON SCREEN. Its screen position is constant and its sprite's own
    --     sub-tile offset (pos2) is 0 in every single sample. All the motion is the camera's.
    --   * gTotalCameraPixelOffset moves exactly 2px per frame while running, DOWN as the player
    --     moves right/down and UP as it moves left/up. So the player's continuous position is
    --     C - camPix/16 for some per-map constant C, exactly, with nothing estimated.
    --   * The TILE COUNTER cannot supply the sub-tile part, and this is where the first attempt
    --     went wrong in one direction only. Moving negative the counter flips 2px into the step;
    --     moving POSITIVE it flips to the DESTINATION tile immediately, a whole tile ahead of what
    --     is on screen. Reconstructing the phase from it was therefore right going one way and a
    --     full tile out going the other -- the user, exactly: *"looks horrible when running up or
    --     right, down/left seems fine"*.
    --
    -- So the tile counter is used for one thing only: calibrating C at a moment when the two
    -- cannot disagree -- when camPix is a whole number of tiles, the player is aligned on its tile
    -- and the counter is unambiguous. That happens once per tile of movement, so C is never stale.
    -- The shared anchor (function above): same numbers the hardware tier places against.
    local camPixX, camPixY, pmX, pmY = anchorFrame(localAreaId, playerScreenX, playerScreenY,
        playerMapX, playerMapY)
    playerMapX, playerMapY = pmX, pmY

    -- Counted and published (tiering.painted) rather than inferred: "assigned to the drawn tier"
    -- and "actually painted this frame" differ by everyone the off-screen cull skipped, and only
    -- the second one answers "is every peer I can see actually being shown".
    local painted = 0
    for playerId, remote in pairs(remotes) do
        -- The loopback ghost is the one peer allowed to be in BOTH tiers at once, and only in
        -- compare mode: everyone else is painted exactly when the engine had no room for them.
        local isLoopback = playerId:match("%-ghost$") ~= nil
        local wanted
        if compareOnly then
            wanted = isLoopback
        else
            wanted = (COMPARE_TIERS and isLoopback) or not (skipSpawned and skipSpawned[playerId])
        end
        if remote.areaId == localAreaId and wanted then
            -- Tile-paced, not sample-paced: the peer's TILE is the target, and the walk between
            -- tiles is the game's own 16/8 frames rather than however far the last packet moved.
            -- RAW, not rounded to a tile: the core hands us a continuous position and rounding
            -- it here was the first step in every model that then had to re-invent the motion.
            local glideX, glideY = glideRemote(remote, remote.x, remote.y)
            -- ONE CAMERA COUNTER, NOT TWO. The obvious form of this line -- the player's screen
            -- position plus the tile delta -- mixes gSpriteCoordOffset (inside playerScreenPos)
            -- with gTotalCameraPixelOffset (inside the anchor), and the two are not written at
            -- the same point in the frame. Measured: that put a ±2px flip on the ghost EVERY
            -- FRAME, which is exactly one camera step, oscillating 40 -> 42 -> 40 -> 42.
            --
            -- The player's screen position never changes while walking (measured: constant to the
            -- pixel over 240 frames), so it does not need reading per frame at all. Captured with
            -- the anchor, at the same standing-still moment, it becomes a constant origin -- and
            -- then the only thing that moves per frame is the camera, on its own clock, alone.
            -- COMPARE MODE: pin the painted copy to the SPAWNED one's own position.
            --
            -- The two renderers cannot be made to move identically, and chasing that was costing
            -- the user run after run. The spawned ghost's timing comes from the engine's step
            -- scheduler -- when it starts a step, how long it holds it -- and we do not drive that
            -- scheduler; ours comes from when packets land. Average lag can be matched (and is),
            -- smoothness can be matched (and is), the walk cadence can be matched (and is), but
            -- the SHAPE of the engine's starts and stops cannot be, short of reimplementing its
            -- scheduler and hoping it stays in phase -- which five separate attempts say it will
            -- not.
            --
            -- So in compare mode the painted copy is placed from the spawned ghost's own sprite,
            -- mirrored to the other side. The two are then pixel-locked BY CONSTRUCTION, and every
            -- difference that remains is a RENDERING difference -- occlusion, a cave's darkness, a
            -- water reflection, palette, clipping -- which is what this mode exists to show, and
            -- what the user asked for when they asked for it. Real overflow peers, which have no
            -- spawned copy by definition, keep the filter above.
            local screenX, screenY
            local pinned = COMPARE_TIERS and ghosts[playerId]
            -- HOW FAR OFF THE GROUND THIS PEER IS, in pixels, negative upward -- a ledge hop, a
            -- side hop, a bunny hop, or the surf blob's bob. Kept separately from the position so
            -- the shadow and the dust below can be put on the GROUND the character left rather
            -- than under its feet in mid-air.
            --
            -- IT HAS TWO SOURCES AND USED TO HAVE ONE, which is why nobody saw this (2026-08-21).
            -- A pinned copy reads it from the spawned sprite the engine is arcing for us. An
            -- OVERFLOW peer -- one with no spawned counterpart, which is every peer in a real
            -- crowd -- has no such sprite, and its position comes from the glide pipeline, which
            -- carries no hop. So this tier drew a peer SLIDING across a ledge, and skipped its
            -- shadow entirely, in exactly the case compare mode cannot show: compare mode pins.
            -- The peer's own `pos2.y` has been on the wire as `soy` since the surf bob needed it,
            -- so the arc was already arriving and only this tier was throwing it away.
            local arc = 0
            if pinned then
                local gs = sprAddr(pinned.sprId)
                arc = rs16(gs + 0x26)
                -- While the spawned sprite wears a fishing graphic, its pos2 is the alignment
                -- for ITS current frame -- and this tier paints the WIRE's frame, which can be a
                -- different one. Inheriting that offset re-created today's whole defect class in
                -- the painted copy: right image, someone else's alignment. So the pinned position
                -- takes only the sprite's true anchor, and the paint code below adds the shift
                -- for the exact frame it draws, from the same shared rule.
                local pinnedAlignX = rs16(gs + 0x24)
                if isFishingGfx(pinned.gfx) then pinnedAlignX, arc = 0, 0 end
                screenX = rs16(gs + 0x20) + pinnedAlignX + memory.read_s8(gs + 0x28)
                    + rs16(GSPRITECOORDOFFSETX_ADDR)
                    + (COMPARE_DRAWN_OFFSET_TILES_X - LOOPBACK_GHOST_OFFSET_TILES_X) * TILE
                screenY = rs16(gs + 0x22) + arc + memory.read_s8(gs + 0x29)
                    + rs16(GSPRITECOORDOFFSETY_ADDR)
            end

            local unpinnedX = (tiering.originX or playerScreenX)
                + (glideX - (tiering.anchorX or playerMapX)) * TILE + camPixX
            local unpinnedY = (tiering.originY or playerScreenY)
                + (glideY - (tiering.anchorY or playerMapY)) * TILE + camPixY
            if not pinned then
                -- The peer's own pos2.y, straight off the wire: the same quantity the pinned
                -- branch reads out of the spawned sprite, for a peer that has no spawned sprite.
                --
                -- EXCEPT WHILE FISHING, and for the same reason the pinned branch drops it there:
                -- a rod's pos2 is not a hop, it is the engine's ALIGNMENT for the frame being
                -- shown, and this tier re-derives that itself a few lines down
                -- (`fishingFrameShift`) for the exact frame it paints. Taking both would apply the
                -- alignment twice -- and once with the wrong frame's value, which is the defect
                -- class the fishing work spent a whole session on.
                arc = (not isFishingGfx(remote.gfx)) and (remote.soy or 0) or 0
                screenX, screenY = unpinnedX, unpinnedY + arc
            end
            -- The pinned branch already carries the mirror to the other side of the player, so the
            -- loopback nudge below would apply it twice.
            if isLoopback and not pinned then
                screenX = screenX + (COMPARE_TIERS and COMPARE_DRAWN_OFFSET_TILES_X
                    or LOOPBACK_GHOST_OFFSET_TILES_X) * TILE
                screenY = screenY + LOOPBACK_GHOST_OFFSET_TILES_Y * TILE
            end

            -- OFF-SCREEN PEERS COST NOTHING. A peer in this area can be anywhere on a map far
            -- larger than the 240x160 the player can see, and drawing one at x = -900 is work
            -- whose entire result is clipped away by the emulator. This is what makes the drawn
            -- tier scale with what is VISIBLE rather than with room size -- the spawned tier gets
            -- the same for free, because the engine culls its own objects.
            -- The walk cycle advances only for peers that are actually drawn, which is why the
            -- cull wraps the animation too rather than just the blit: a peer off screen has no
            -- frame anyone can see, and stepping its timer would be work with no output.
            if screenX + FRAME_WIDTH_PX > 0 and screenX < SCREEN_WIDTH_PX
                and screenY + FRAME_HEIGHT_PX > 0 and screenY < SCREEN_HEIGHT_PX then
                local dirInfo = DIRECTION_ANIM[remote.orientation] or DIRECTION_ANIM.south
                local frameIndex, pose
                -- MOVEMENT IS A POSITION FACT, NOT A TAG. A forced move -- a cutscene, an NPC
                -- pushing you, a scripted walk -- does not put the game in runningState 2, so the
                -- anim tag says "idle" while the peer is plainly crossing tiles. The engine walks
                -- a spawned ghost from the movement itself and does not care what we called it;
                -- the drawn tier believed the tag, so it slid. User, 2026-08-19, watching both:
                -- *"the drawn one was sliding"*, *"normal ghost was walking properly"*.
                --
                -- The glide already knows: it is mid-step exactly while the peer is crossing from
                -- one tile to the next, which is the same question with an answer that cannot be
                -- mislabelled.
                local gliding = remote.gMoved
                -- AND IT OUTLASTS THE PEER'S OWN FLAG, because this tier is not where the peer is.
                --
                -- The wire says "unfrozen" the instant the player's slide ends, but the painted
                -- copy is still GLIDING across the ground that slide covered. Releasing on the
                -- flag handed those catch-up frames back to the derived cycle, which duly played a
                -- stride the player never played -- the user, watching the stop: the drawn ghost
                -- *"is doing like 1 extra animation or something when stopping after gliding on
                -- the ice"*. It is conspicuous here and nowhere else precisely because the player
                -- animates through an ordinary stop and does not animate through this one.
                --
                -- So the freeze is latched to the GLIDE rather than to the flag, and the frame it
                -- holds is remembered at the same moment: by the time the ghost is finishing the
                -- slide, the peer has already moved on to its idle frame, and that is not the
                -- picture this copy should be wearing while it is still moving.
                if remote.noanim then
                    remote.noanimImg = genderFrames.peerImageIndex(remote) or remote.noanimImg
                elseif not gliding then
                    remote.noanimImg = nil
                end
                if remote.noanim or remote.noanimImg then
                    -- A MOVEMENT THAT DOES NOT ANIMATE, so the derived cycle is the wrong source.
                    --
                    -- This tier works out its own frame from distance travelled, which is right
                    -- whenever moving and animating are the same thing. On an ice slide they are
                    -- not: the peer crosses tiles holding ONE frame. Derived, that reads as
                    -- walking -- and the user saw exactly that next to a correct hardware copy.
                    --
                    -- Freezing whatever frame this tier was on would swap one wrong picture for
                    -- another; the peer's own is the only right one. Measured mid-slide,
                    -- 2026-08-21: the peer held anim 11/0, which resolves to image 7 -- east's
                    -- steps[1] -- while this tier was drawing image 2, the standing frame. Same
                    -- index space, so the peer's number drops straight in and the existing
                    -- east/west hFlip still applies.
                    pose = "walk"
                    frameIndex = remote.noanimImg or dirInfo.idle
                    remote.lastAnim = remote.anim
                    remote.lastOrientation = remote.orientation
                    -- The derived cycle is measured in distance travelled, and none of the
                    -- distance covered while frozen was walked. Left standing, it hands the next
                    -- ordinary step a cycle already part-way through -- the same extra stride,
                    -- moved one step later instead of removed.
                    remote.gDist = 0
                elseif remote.anim == "walking" or remote.anim == "running" or gliding then
                    pose = (remote.anim == "running") and "run" or "walk"
                    -- BY DISTANCE, NOT BY TIME. advanceAnim counts frames, which is right for a
                    -- peer whose movement we are not also interpolating -- but a drawn ghost's
                    -- glide can take longer than a tile's worth of frames whenever it is catching
                    -- up, and a time-driven cycle then plays extra strides for a single step. The
                    -- user, watching one tile at a time next to the engine's own ghost: the drawn
                    -- one is *"moving/animating a bit too much when walking single tiles"*.
                    --
                    -- The engine advances a pose every 8 pixels -- half a tile -- so tying the
                    -- cycle to distance travelled makes one tile exactly two poses, always, and
                    -- makes a catching-up ghost animate faster rather than longer, which is what
                    -- covering more ground actually looks like.
                    if remote.lastOrientation ~= remote.orientation then
                        remote.gDist = 0
                        remote.lastOrientation = remote.orientation
                    end
                    remote.lastAnim = remote.anim
                    frameIndex = dirInfo.steps[
                        (math.floor((remote.gDist or 0) * 2) % #dirInfo.steps) + 1]
                else
                    -- A TURN IN PLACE IS AN ANIMATION, NOT A NEW STATIC FRAME.
                    --
                    -- The user, comparing the two renderers side by side (2026-08-19): the drawn
                    -- one *"only faces the direction, it does not animate/move the legs"*. The
                    -- engine gives a spawned ghost a dedicated turn animation -- probe numbers
                    -- 8-11, one per direction, against 0-3 standing and 4-7 walking -- and it
                    -- lasts **exactly 8 frames, 92 times out of 92, zero variance**
                    -- (probes/turn_and_door_probe.lua). Eight frames is also exactly one
                    -- WALK_POSE_DURATIONS hold, so what the engine plays is one stride of the new
                    -- direction before settling: that is what is reproduced here.
                    --
                    -- The turn arrives as `anim=idle` with a new orientation, because the game
                    -- reports runningState 1 for it and the classifier calls anything that is not
                    -- 2 idle. That is why this lives in the idle branch rather than the walk one.
                    if remote.lastOrientation ~= remote.orientation then
                        remote.turnUntil = frameCounter + WALK_POSE_DURATIONS[1]
                    end
                    remote.animTimer = 0
                    remote.animStepIndex = 1
                    remote.lastAnim = remote.anim
                    remote.lastOrientation = remote.orientation
                    pose = "walk" -- idle frames (0-2) only exist in the walk/Normal pic table
                    if remote.turnUntil and frameCounter < remote.turnUntil then
                        frameIndex = dirInfo.steps[1]
                    else
                        frameIndex = dirInfo.idle
                    end
                end

                -- COMPARE_TIERS measurement: the two renderers of the SAME peer, side by side,
                -- to a FILE, buffered, flushed once a second (a per-frame console.log lagged the
                -- game once already). Five attempts at the drawn tier's movement have each been
                -- judged by eye; this logs where each ghost actually is, per frame, so the sixth
                -- is aimed at a number. Off unless the compare flag is set.
                local g = ghosts[playerId]
                if COMPARE_TIERS and g and tiering.moveLog then
                    local gs = sprAddr(g.sprId)
                    tiering.moveLog[#tiering.moveLog + 1] = string.format(
                        "f=%d spawned=%d,%d drawn=%.2f,%.2f peer=%.2f,%.2f glide=%.3f,%.3f "
                            .. "player=%.3f,%.3f step=%s",
                        frameCounter,
                        rs16(gs + 0x20) + rs16(gs + 0x24) + memory.read_s8(gs + 0x28)
                            + rs16(GSPRITECOORDOFFSETX_ADDR),
                        rs16(gs + 0x22) + rs16(gs + 0x26) + memory.read_s8(gs + 0x29)
                            + rs16(GSPRITECOORDOFFSETY_ADDR),
                        screenX, screenY, remote.x, remote.y,
                        remote.gX or -1, remote.gY or -1, playerMapX, playerMapY,
                        tostring(remote.gStepping))
                    -- WHICH FRAME THIS TIER CHOSE, and the distance it chose it from. The drawn
                    -- tier's cycle is driven by distance travelled rather than by time, so "it is
                    -- not animating over one tile" is a question about `gDist` -- and without both
                    -- numbers on the line there is no way to tell a cycle that never advanced from
                    -- one that advanced and picked the same frame twice. Added 2026-08-20, when the
                    -- user found the drawn ghost still for a single tile at half speed.
                    tiering.moveLog[#tiering.moveLog] = tiering.moveLog[#tiering.moveLog]
                        .. string.format(" | pose=%s frame=%s gDist=%.3f gMoved=%s gfx=%s "
                            .. "sanim=%s/%s hw=%s,%s",
                            tostring(pose), tostring(frameIndex), remote.gDist or -1,
                            tostring(remote.gMoved), tostring(remote.gfx),
                            tostring(remote.sanim), tostring(remote.sidx),
                            tostring(tiering.hwLastX), tostring(tiering.hwLastY))
                        .. " | " .. tostring(tiering.hwDbg)
                end
                -- THE SHADOW GOES DOWN FIRST, because paint order IS depth on this tier.
                --
                -- The engine's own shadow is a sprite at subpriority 148, which puts it UNDER the
                -- character. Ours is painted onto the finished frame, so drawing it after the
                -- character put it in front of one -- *"the shadow should be below the drawn &
                -- spawn, right now it shows infront for both of them unlike the player"* (user,
                -- 2026-08-20). For a painted ghost the fix is only the order; for the SPAWNED one
                -- it is not fixable this way at all, since no overlay can go behind a hardware
                -- sprite -- that needs a real shadow sprite, the way the surf blob is real.
                --
                -- screenX/screenY are the FRAME's top-left, so the character's own anchor is
                -- +8,+16 from it, and the arc comes off because a shadow belongs on the ground the
                -- character left rather than under its feet in mid-air.
                if isJumpAction(remote.act) then
                    -- CENTRED ON THE GRAPHIC, not on a walker. screenX + 8 is the middle of the
                    -- 16-wide gender frame, and a bike, a surfboard or a rod is 32 wide -- so on
                    -- any of those the shadow sat 8px left of the character (user, 2026-08-20:
                    -- *"its a bit to the left"*). The same half-width that centres the character's
                    -- own frame centres its shadow.
                    --
                    -- The arc comes off so the shadow stays on the ground the character left, and
                    -- the drop is the graphic's own rather than a constant.
                    local sgi = remote.gfx and graphicsInfo(remote.gfx) or nil
                    local halfW = (sgi and sgi.width or FRAME_WIDTH_PX) >> 1
                    -- screenX, not screenX + cx: cx belongs to the peer-graphic branch further
                    -- down and is not in scope here -- referencing it read a nil GLOBAL and threw
                    -- once per frame. In the pinned case it is zero in any event.
                    drawOneShadow(screenX + halfW,
                        shadowTopFor(sgi, screenY - arc), dim)
                end

                -- A peer wearing its OWN graphic -- bike, surf, fishing -- is drawn from that
                -- graphic's own frames. Only when it differs from the plain walker (0), so the
                -- ordinary case keeps the cached gender path and costs nothing extra.
                local drew = false
                -- A PEER'S CURRENT FRAME IS THE WRONG FRAME WHILE THIS TIER IS STILL CROSSING.
                --
                -- This path paints whatever animation the peer is on right now, which is correct
                -- for a state they hold -- fishing, surfing, standing. It is wrong for a single
                -- step: the peer crosses the tile in about six frames and is back to standing long
                -- before the drawn ghost, whose glide takes ~23, has finished the same tile. So it
                -- glides across wearing the standing frame and never animates at all. The user,
                -- 2026-08-20, watching at half speed: *"the drawn ghost is not doing the animation
                -- when moving 1 tile"*. Measured in probes/tier_compare.log: the peer sent 9/0,
                -- 9/1 for six frames and then 5/1, while `gMoved` stayed true for 23 more.
                --
                -- The cached gender path never had this problem because it drives its cycle from
                -- DISTANCE rather than from the peer's tag -- the same fix, applied here. The
                -- moving animation NUMBER cannot be hardcoded, though: it is 8..11 on the Acro
                -- Bike against 4..7 for a walker, and every graphic may differ. So the peer's own
                -- last moving number is remembered and re-used, which needs no table at all.
                if (remote.anim == "walking" or remote.anim == "running") and remote.sanim then
                    remote.lastMoveAnim = remote.sanim
                end
                -- FROM THE START OF THIS STEP, not from an absolute distance. The rate was right
                -- first time -- half a tile per pose, two poses per tile, which is what the player
                -- does -- but the PHASE was whatever the running total happened to land on. A ride
                -- animation is four poses alternating a neutral frame with two different pedal
                -- frames, so a tile beginning on an odd index shows two pedal frames back to back:
                -- *"the drawn ghost wiggle twice for a single tile, its only supposed to do it
                -- once"*. Measured on the player, one tile is index 0 then 1 -- it always starts
                -- from the beginning of the cycle, so the ghost must too.
                -- EVERY CHANGE OF THE PEER'S GRAPHIC ON THE WIRE. The fallback log below covers a
                -- peer whose graphic could not be DECODED; it says nothing about a peer whose
                -- graphic arrived as the walker in the first place, and those look identical on
                -- screen -- a rider suddenly on foot. Ruling the second one out needs the value
                -- itself, per change, which is cheap.
                if COMPARE_TIERS and remote.gfxWas ~= remote.gfx then
                    logFile(string.format("WIRE gfx %s -> %s (anim=%s sanim=%s/%s act=%s)",
                        tostring(remote.gfxWas), tostring(remote.gfx), tostring(remote.anim),
                        tostring(remote.sanim), tostring(remote.sidx), tostring(remote.act)))
                    remote.gfxWas = remote.gfx
                end
                if remote.gMoved and not remote.gMovedPrev then remote.gDistBase = remote.gDist end
                remote.gMovedPrev = remote.gMoved
                --
                -- ONLY WHEN THE PEER HAS ALREADY STOPPED. This exists for the gap between a peer
                -- finishing a step and this tier finishing the same step; while the peer is still
                -- moving, or hopping, its own frame is the truthful one and substituting a
                -- remembered riding number throws away whatever it is really doing. Worse, an
                -- animation number and an index that were never paired may not resolve at all, and
                -- an unresolved frame falls through to the cached WALKER below -- a Brendan on
                -- foot. The user, hopping along on the Acro Bike: *"the drawn ghost is getting of
                -- their bike all the time visually"*.
                --
                -- ONE CYCLE PER STEP, not the peer's own frames and then a second cycle. Limiting
                -- the substitution to "the peer has stopped" split a single tile in two: the peer's
                -- indices played while it was still moving, and the distance-driven cycle then
                -- started over for the rest of the glide -- *"the drawn ghost = double animatin,
                -- supposed to be 1"*. Distance drives the whole step, which is what the cached
                -- walker path has always done and why it never had this.
                --
                -- A HOP OR A JUMP IS EXEMPT, and that is the reason the narrower condition was
                -- tried first: those have their own animation that distance cannot stand in for,
                -- and substituting over them is what made a hopping peer look like it dismounted.
                -- The families are the peer's own action ids (constants/event_object_movement.h):
                -- 0x46..0x4D jump in place, 0x70..0x7B wheelie hop and jump.
                local drawAnim, drawIdx = remote.sanim, remote.sidx
                if remote.gMoved and remote.lastMoveAnim
                    and not (remote.act and ((remote.act >= 0x46 and remote.act <= 0x4d)
                        or (remote.act >= 0x70 and remote.act <= 0x7b)))
                then
                    drawAnim = remote.lastMoveAnim
                    drawIdx = math.floor(((remote.gDist or 0) - (remote.gDistBase or 0)) * 2) % 4
                end
                if PEER_GFX_ENABLED and remote.gfx and remote.gfx ~= 0 and remote.sanim then
                    -- PINNED MEANS PINNED, animation included. The pin locks POSITION to the
                    -- spawned sprite while the frame index still came from the wire at delivery
                    -- rate -- so at Mach top speed the painted twin strobed across pedal frames
                    -- the spawned one plays at 60fps, and ride frames sit a pixel or two taller
                    -- than their neighbours: *"the top of the hat goes away ... especially
                    -- noticable when riding fast downwards"*. Every other suspect measured
                    -- innocent first: occlusion kept all 384 top pixels, the screen edge was
                    -- never nearer than y=28, the ROM art has full hats, and the walker fallback
                    -- never fired. In compare mode the spawned sprite's LIVE animation fields are
                    -- the same source its pixels come from, so the twin shows the exact frame.
                    if pinned then
                        local ps2 = sprAddr(pinned.sprId)
                        drawAnim, drawIdx = r8(ps2 + 0x2a), r8(ps2 + 0x2b)
                    end
                    local runs, info, gfxFlip, imgIdx =
                        genderFrames.runsForPeerGfx(remote.gfx, drawAnim, drawIdx)
                    -- NEVER LET A SUBSTITUTED FRAME COST THE GRAPHIC. Falling through to the
                    -- cached walker is the right answer when a peer's graphic cannot be decoded at
                    -- all; it is the wrong one when only the frame we substituted failed, because
                    -- the peer's own frame was there the whole time. Retry with it before giving
                    -- up, so the worst case is a stale pose rather than a peer who appears to
                    -- dismount.
                    if not runs and drawAnim ~= remote.sanim then
                        runs, info, gfxFlip, imgIdx =
                            genderFrames.runsForPeerGfx(remote.gfx, remote.sanim, remote.sidx)
                    end
                    if runs and info then
                        -- CENTRE IT LIKE THE ENGINE DOES. A fishing or biking frame is 32 wide
                        -- where a walker is 16, and the engine does not shift its position for
                        -- that -- it sets centerToCornerVec = -(width >> 1) and lets the hardware
                        -- draw from the centre. Painting a wider frame from the walker's top-left
                        -- puts it half the difference off, which is what the user saw: the drawn
                        -- ghost *"moves back a bit"* on casting while the player does not move.
                        -- Same arithmetic, applied where we draw.
                        -- The centring is only ours to do when the position was computed from
                        -- TILES. A pinned position is copied from the spawned sprite and already
                        -- carries that sprite's centerToCorner -- which IS the engine's centring
                        -- for a wide frame -- so applying it again put the painted copy 8px left
                        -- of the spawned one, in steady state, for every wide graphic.
                        local cx, cy = 0, 0
                        if not pinned then
                            cx = (FRAME_WIDTH_PX >> 1) - (info.width >> 1)
                            cy = (FRAME_HEIGHT_PX >> 1) - (info.height >> 1)
                        end
                        -- The shift for the frame THIS tier paints, from the shared rule --
                        -- image and alignment from the same wire sample, atomically, which is
                        -- what the game itself guarantees on screen.
                        if isFishingGfx(remote.gfx) and remote.sanim and remote.sidx then
                            local fx2, fy2 = fishingFrameShift(info.anims, remote.sanim,
                                remote.sidx, remote.orientation == "west")
                            cx, cy = cx + fx2, cy + fy2
                        end

                        -- BEHIND THE CHARACTER, IN PAINT ORDER: the engine expresses depth with
                        -- priority and subpriority, and this tier has neither -- what it has is
                        -- the order the calls are made in. Reflection first (priority 3,
                        -- subpriority 152), then the blob (150), then the rider. Getting this
                        -- backwards would put a reflection over the character that casts it.

                        -- THE REFLECTION IN THE WATER. The same frame, decoded once more in the
                        -- mapped palette, drawn upside down height-2 pixels lower --
                        -- SetUpReflection and GetReflectionVerticalOffset, cited where
                        -- reflectionPalette is defined.
                        --
                        -- FOR ANY PEER ON REFLECTIVE GROUND, not only a surfing one (2026-08-21).
                        -- This used to be inside the surfing gate, with a note saying a peer
                        -- standing beside water is reflected too but that the tile lookup did not
                        -- exist yet. It does exist -- `hasReflection` below is the engine's own
                        -- test and was written for this block -- so the gate was simply left too
                        -- tight, and the user found the case it excluded: *"the drawn ghost, and
                        -- probably the OAM, don't have a reflection in the water while standing on
                        -- grass/next to water."* The ground test is the whole gate now; surfing
                        -- keeps only what is genuinely surfing-specific, which is the blob.
                        do
                            -- THE BOB, WHICH IS ONE TERM AND EXPLAINS TWO SYMPTOMS.
                            --
                            -- A surf blob set to BOB_PLAYER_AND_MON moves its RIDER's pos2 as
                            -- well as its own -- measured equal on the same frame, `blob.pos2=0,-3
                            -- | rider.pos2=0,-3` (probes/surfblob_probe.lua) -- and the engine
                            -- gives the reflection the NEGATED value (`y2 = -mainSprite->y2`,
                            -- pokeemerald src/field_effect_helpers.c:145). So the gap between a
                            -- character and its reflection is not the vertical offset alone, it is
                            -- that offset MINUS TWICE the bob: they separate as the rider rises
                            -- and close as it falls.
                            --
                            -- Leaving the term out therefore drew the reflection both slightly
                            -- too high AND perfectly still -- *"the reflection is slightly
                            -- offset/does not wobble"*, which reads as two faults and is one.
                            --
                            -- Where the bob comes from depends on which position this tier is
                            -- painting at. A pinned copy takes it from the spawned sprite, where
                            -- the engine has already applied it; an overflow peer has no spawned
                            -- counterpart, so its own sample carries it and the rider (and its
                            -- blob, which bobs by the same amount) is shifted here to match.
                            -- The position above already carries this on BOTH paths, so it is
                            -- not added again here; it stays named because the reflection's
                            -- separation is the offset MINUS TWICE the bob, below.
                            local bob = arc

                            -- DOES THIS GHOST HAVE A REFLECTION AT ALL -- the engine's own test,
                            -- on the tiles below the character rather than the one it is on.
                            --
                            -- ASKED WHERE THE GHOST IS DRAWN, not where the peer is, and that
                            -- distinction is the whole of the last bug. In compare mode the
                            -- painted copy is deliberately offset a couple of tiles from the peer,
                            -- so a peer out on a pond has its drawn twin standing on the grass
                            -- beside it -- and the gate, asked about the PEER, happily authorised a
                            -- reflection there. It then showed wherever the bank's art happened to
                            -- live in the bottom layer, which reads as *"still showing a bit
                            -- outside the water"*.
                            --
                            -- What settled it was moving the SPAWNED ghost onto that same grass and
                            -- photographing it (a spawned ghost is engine-drawn, so a screenshot
                            -- sees it): the engine gave it no reflection at all. Not a clipped one
                            -- -- none. `hasReflection` is false off reflective ground, so the
                            -- sprite is never created.
                            local gbX, gbY = genderFrames.gridBase()
                            local rpal, rkind2
                            if gbX then
                                local ggx = math.floor((screenX - gbX) / TILE)
                                local ggy = math.floor((screenY - bob + TILE - gbY) / TILE)
                                -- The ground test, the expiring previous tile and the palette
                                -- map all live in reflectPalFor now -- three callers share them.
                                tiering.lastTile = tiering.lastTile or {}
                                rpal, rkind2 = genderFrames.reflectPalFor(tiering.lastTile, playerId,
                                    remote.areaId, ggx, ggy,
                                    (info.width + 8) >> 4, (info.height + 8) >> 4,
                                    info.paletteSlot)
                            end
                            local rruns = rpal and genderFrames.runsFromImages(
                                string.format("r%d:%d:%d", remote.gfx, imgIdx, rpal),
                                info.images, info.width, info.height, imgIdx, rpal)
                            local rtop = screenY + cy + info.height - 2 - 2 * bob
                            if COMPARE_TIERS then
                                local ck = string.format("%d:%d:%s:%s", math.floor(screenY + cy),
                                    math.floor(rtop), tostring(tiering.hwBodyY),
                                    tostring(tiering.hwReflY))
                                if genderFrames.reflCmpKey ~= ck then
                                    genderFrames.reflCmpKey = ck
                                    logFile(string.format(
                                        "REFL CMP painted body=%d refl=%d | hw body=%s refl=%s "
                                        .. "| h=%d bob=%d arc=%d cy=%d",
                                        math.floor(screenY + cy), math.floor(rtop),
                                        tostring(tiering.hwBodyY), tostring(tiering.hwReflY),
                                        info.height, bob, arc, cy))
                                end
                            end
                            -- ONLY OVER WATER. The engine gets this from OAM priority; we have to
                            -- ask the map. Computed here rather than inside the draw so it is one
                            -- lookup grid for the whole reflection instead of one per run.
                            local wet = rruns and genderFrames.reflectiveSpans(
                                screenX + cx, rtop, info.width, info.height, "reflection")
                            -- Once a second: where this ghost stands, and every tile its
                            -- reflection is allowed to paint over, with that tile's behaviour.
                            -- Painting over a non-water behaviour is a bug; painting only over
                            -- water behaviours means the leak is art INSIDE a water tile, which is
                            -- a different problem with a different answer.
                            if rruns then
                                drawRunList(rruns, info.width, gfxFlip, screenX + cx, rtop,
                                    panelRows, dim, info.height,
                                    genderFrames.reflectionXScale(rkind2), wet)
                            end
                            -- THE WATER TRAIL, behind the rider and in front of the reflection,
                            -- which is the engine's own order (subpriority 151 against 152 and
                            -- 150). A ripple per tile stepped; the reflection's previous-tile
                            -- store above has already stamped the frame the tile changed on, so
                            -- that is what "did this peer just step" is read from -- and it is
                            -- about the tile THIS tier drew on, which is the one the trail
                            -- belongs to.
                            --
                            -- A TRAIL ENTRY, not a follower: a ripple is born where the character
                            -- was, stays there while the character rides on, and is anchored on
                            -- gSpriteCoordOffset -- position minus the offset at birth, plus the
                            -- offset at draw -- so it stays glued to its water through any scroll.
                            -- Exactly the landing dust's arithmetic, for exactly its reason.
                            tiering.ripples = tiering.ripples or {}
                            local rlist = tiering.ripples[playerId]
                            if not rlist then rlist = {} tiering.ripples[playerId] = rlist end
                            if genderFrames.rippleDue(tiering.lastTile, playerId,
                                remote.gfx and SURFING_GFX[remote.gfx]) then
                                rlist[#rlist + 1] = { at = frameCounter,
                                    bx = screenX + cx + (info.width >> 1) - 8
                                        - rs16(GSPRITECOORDOFFSETX_ADDR),
                                    by = screenY + cy - arc + info.height - 10
                                        - rs16(GSPRITECOORDOFFSETY_ADDR) }
                            end
                            for pi = #rlist, 1, -1 do
                                local rip = rlist[pi]
                                local rf = genderFrames.rippleFrameAt(frameCounter - rip.at)
                                local rruns2 = rf and genderFrames.rippleRuns(rf)
                                if not rruns2 then
                                    table.remove(rlist, pi)
                                else
                                    drawRunList(rruns2, genderFrames.rippleFramePx, false,
                                        rip.bx + rs16(GSPRITECOORDOFFSETX_ADDR),
                                        rip.by + rs16(GSPRITECOORDOFFSETY_ADDR),
                                        panelRows, dim)
                                end
                            end

                            -- AND THE POKEMON BEING RIDDEN -- this part IS surfing-only, which is
                            -- why the gate moved down here rather than away. Measured against the
                            -- game's own pair rather than guessed: the blob's sprite sits at the
                            -- rider's position plus (0, +8), with the same centerToCorner, so in
                            -- top-left terms it is eight pixels lower and not moved sideways at
                            -- all (probes/surfblob_probe.lua, 2026-08-19).
                            local bruns, bflip
                            if not SURFING_GFX[remote.gfx] then
                                remote.blobParkPx, remote.blobParkHold, remote.blobParkKind =
                                    nil, nil, nil
                            end
                            if SURFING_GFX[remote.gfx] then
                                bruns, bflip = genderFrames.runsForSurfBlob(
                                    genderFrames.dirOf[remote.orientation] or 1)
                            end
                            if bruns then
                                -- Parked during a JUMP_SPECIAL, mirroring the game's
                                -- BOB_JUST_MON -- full reasoning at the hardware tier's twin.
                                -- Sticky like the hardware tier's, one comment up there.
                                -- Bob-with-the-rider and the mount park: the hardware tier's
                                -- twin comment carries the reasoning.
                                local bjumping = remote.act
                                    and remote.act >= 0x3a and remote.act <= 0x3d
                                if bjumping and not remote.blobParkHold then
                                    if remote.blobParkPx then
                                        remote.blobParkHold, remote.blobParkKind =
                                            true, "dismount"
                                    else
                                        local jdx = ({ [0x3c] = -TILE,
                                            [0x3d] = TILE })[remote.act] or 0
                                        local jdy = ({ [0x3a] = TILE,
                                            [0x3b] = -TILE })[remote.act] or 0
                                        remote.blobParkPx = {
                                            screenX + cx + jdx
                                                - rs16(GSPRITECOORDOFFSETX_ADDR),
                                            screenY + cy + jdy + 8 - (arc or 0)
                                                - rs16(GSPRITECOORDOFFSETY_ADDR) }
                                        remote.blobParkHold, remote.blobParkKind =
                                            true, "mount"
                                    end
                                end
                                -- Mount parks end with the jump; the hardware twin says why.
                                if not bjumping and remote.blobParkHold
                                    and remote.blobParkKind == "mount" then
                                    remote.blobParkHold, remote.blobParkKind = nil, nil
                                end
                                local pbx, pby = screenX + cx, screenY + cy + 8
                                if remote.blobParkHold and remote.blobParkPx then
                                    pbx = remote.blobParkPx[1] + rs16(GSPRITECOORDOFFSETX_ADDR)
                                    pby = remote.blobParkPx[2] + rs16(GSPRITECOORDOFFSETY_ADDR)
                                elseif not bjumping then
                                    remote.blobParkPx = {
                                        pbx - rs16(GSPRITECOORDOFFSETX_ADDR),
                                        pby - rs16(GSPRITECOORDOFFSETY_ADDR) }
                                end
                                drawRunList(bruns, SURFBLOB_FRAME_PX, bflip, pbx,
                                    pby, panelRows, dim, nil, nil,
                                    genderFrames.reflectiveSpans(pbx, pby,
                                        SURFBLOB_FRAME_PX, SURFBLOB_FRAME_PX, "sprite"))
                            end
                        end

                        -- HIDDEN BY THE MAP, the way a spawned ghost is for free. A painted
                        -- character is put on top of the finished frame, so without this it walks
                        -- OVER the roof edges and tree tops that the engine draws above sprites --
                        -- reported on screen 2026-08-20: *"the drawn ghost not hiding behind
                        -- buildings"*. The mask is the same machinery as the reflection's, asked
                        -- the question for a priority-2 sprite instead of a priority-3 one.
                        local occl = genderFrames.reflectiveSpans(screenX + cx, screenY + cy,
                            info.width, info.height, "sprite")
                        -- THE HAT ROWS' VERDICT, on change only (COMPARE_TIERS): how many pixels
                        -- of the frame's top 8 rows survive occlusion, and which metatile the top
                        -- row overlaps. The hat vanishing intermittently at speed is either this
                        -- mask eating those rows (position-correlated: the id says over WHAT) or
                        -- it is not occlusion at all -- one number decides.
                        if COMPARE_TIERS then
                            local topKept = -1
                            if occl then
                                topKept = 0
                                for py = math.floor(screenY + cy), math.floor(screenY + cy) + 7 do
                                    for _, s in ipairs(occl[py] or {}) do
                                        topKept = topKept + s[2] - s[1] + 1
                                    end
                                end
                            end
                            local gbX, gbY = genderFrames.gridBase()
                            local mid = "?"
                            if gbX then
                                mid = tostring(genderFrames.metatileAt(
                                    math.floor((screenX + cx + 8 - gbX) / TILE),
                                    math.floor((screenY + cy - gbY) / TILE)))
                            end
                            local info2 = graphicsInfo(remote.gfx)
                            local cmdRaw = 0
                            if info2 and info2.anims ~= 0 then
                                local ap = r32(info2.anims + (drawAnim or 0) * 4)
                                if isRomPtr(ap) then cmdRaw = r32(ap + (drawIdx or 0) * 4) end
                            end
                            local minRy, nRuns = 99, 0
                            if runs then
                                for _, rr in ipairs(runs) do
                                    nRuns = nRuns + 1
                                    if rr.y < minRy then minRy = rr.y end
                                end
                            end
                            local k = string.format("%s:%d:%s:%s:%s:%d", tostring(playerId), topKept,
                                mid, tostring(drawAnim), tostring(drawIdx), minRy)
                            if genderFrames.hatLogKey ~= k then
                                genderFrames.hatLogKey = k
                                logFile(string.format(
                                    "f=%d emu=%d HAT %s topKept=%d y=%d anim=%s/%s minRy=%d panels=%s clipped=%d",
                                    frameCounter, emu.framecount(), tostring(playerId), topKept,
                                    math.floor(screenY + cy), tostring(drawAnim),
                                    tostring(drawIdx), minRy,
                                    (function() local c = 0 local rws = {}
                                        if panelRows then for rw in pairs(panelRows) do c = c + 1 rws[#rws+1] = rw end end
                                        table.sort(rws)
                                        return c .. ":" .. table.concat(rws, ",") end)(),
                                    genderFrames.clippedRuns or 0))
                            end
                        end
                        -- INVISIBLE PAINTS ARE THE VANISH. The gap detector proved the body is
                        -- PAINTED on every frame of the user-reported disappearance -- so the
                        -- question is not "did we paint" but "did any span survive the clips".
                        -- Snapshot the span counter around the body's own paint; zero survivors
                        -- logs the frame with what the panel scanner believed, on the emulator's
                        -- frame clock so it lays against the screenshots.
                        local spansBefore = MG_SPANS or 0
                        drawRunList(runs, info.width, gfxFlip, screenX + cx, screenY + cy,
                            panelRows, dim, nil, nil, occl)
                        if COMPARE_TIERS and playerId:match("%-ghost$")
                            and (MG_SPANS or 0) == spansBefore and #runs > 0 then
                            local pr = {}
                            if panelRows then
                                for rw, sp in pairs(panelRows) do
                                    pr[#pr + 1] = string.format("%d:%d-%d", rw, sp[1], sp[2])
                                end
                            end
                            table.sort(pr)
                            logFile(string.format(
                                "BODY INVISIBLE f=%d emu=%d runs=%d y=%d panels=[%s]",
                                frameCounter, emu.framecount(), #runs,
                                math.floor(screenY + cy), table.concat(pr, " ")))
                        end
                        drew = true
                        MG_BODY_PAINTED = true -- gap detector: the BODY, not a reflection/shadow
                    end
                end
                if not drew then
                    -- SAY WHEN THIS HAPPENS. Falling back to the cached walker while the peer is
                    -- on a bike, surfing or fishing IS the peer appearing to dismount, and it is
                    -- silent -- the tier simply paints a different character and carries on. Two
                    -- separate guesses were made at which state triggers it before this line
                    -- existed; the log names the state instead. COMPARE_TIERS only, throttled,
                    -- because a fallback that fires every frame must not also write every frame.
                    if COMPARE_TIERS and remote.gfx and remote.gfx ~= 0
                        and (not remote.fellBackAt or frameCounter - remote.fellBackAt >= 30)
                    then
                        remote.fellBackAt = frameCounter
                        logFile(string.format(
                            "DRAWN FELL BACK TO THE WALKER: gfx=%s sanim=%s/%s anim=%s act=%s "
                            .. "gMoved=%s lastMove=%s orient=%s",
                            tostring(remote.gfx), tostring(remote.sanim), tostring(remote.sidx),
                            tostring(remote.anim), tostring(remote.act), tostring(remote.gMoved),
                            tostring(remote.lastMoveAnim), tostring(remote.orientation)))
                    end
                    -- (The MASK/RUNS instrumentation that lived here found the seam-crossing
                    -- frame-killer and came out once the lesson was in pitfalls.md -- every stage
                    -- of this paint path measured innocent; the tick was dying before it ran.)

                    -- THE REFLECTION, FIRST, because paint order is depth on this tier.
                    --
                    -- A peer on foot with no special graphic comes down this path, and until
                    -- 2026-08-21 it had no reflection code at all -- the whole of *"the drawn
                    -- ghost don't have its reflection when standing on grass, close to water"*.
                    -- Everything here is the peer-graphic path's, with the walker's own frame:
                    -- the ground test, the flip, the vertical offset of height-2, the ripple from
                    -- the engine's own matrix, and the clip to water.
                    local wgi = graphicsInfo(remote.gfx or 0)
                    local wgbX, wgbY = genderFrames.gridBase()
                    if wgbX and wgi then
                        tiering.lastTile = tiering.lastTile or {}
                        local wpal, wkind = genderFrames.reflectPalFor(tiering.lastTile, playerId,
                            remote.areaId,
                            math.floor((screenX - wgbX) / TILE),
                            math.floor((screenY - arc + TILE - wgbY) / TILE),
                            (FRAME_WIDTH_PX + 8) >> 4, (FRAME_HEIGHT_PX + 8) >> 4,
                            wgi.paletteSlot)
                        local wruns = wpal and genderFrames.walkerReflectRuns(
                            remote.gender, pose, frameIndex, wpal)
                        local wtop = screenY + FRAME_HEIGHT_PX - 2 - 2 * arc
                        -- The water clip, computed once so the log below can report what it kept.
                        -- This tier has no OAM priority, so where the hardware tier is clipped by
                        -- the water for free, this one has to ask the map -- and "the reflection
                        -- vanishes entirely one tile from the shore, where the other tiers still
                        -- show the hat" is exactly the shape of a clip that kept nothing.
                        local wwet = genderFrames.reflectiveSpans(screenX, wtop,
                            FRAME_WIDTH_PX, FRAME_HEIGHT_PX, "reflection")
                        -- COMPARE_TIERS only, on CHANGE only: what the ground test decided and
                        -- where it was asked. A reflection that does not appear is either a gate
                        -- that said no or a decode that returned nothing, and those two have
                        -- different fixes -- this line says which, without another guess.
                        if COMPARE_TIERS then
                            local wk = string.format("%s:%s:%s:%s:%d,%d", tostring(playerId),
                                tostring(wpal), tostring(wruns ~= nil),
                                tostring(wwet and next(wwet) ~= nil),
                                math.floor((screenX - wgbX) / TILE),
                                math.floor((screenY - arc + TILE - wgbY) / TILE))
                            -- On CHANGE, and also once every two seconds regardless: a
                            -- change-keyed line can only ever catch the moment something moved,
                            -- and the question here is what the STEADY state looks like while a
                            -- ghost stands still.
                            if genderFrames.wReflKey ~= wk
                                or (frameCounter - (genderFrames.wReflAt or 0)) >= 120 then
                                genderFrames.wReflKey = wk
                                genderFrames.wReflAt = frameCounter
                                logFile(string.format(
                                    "WALKER REFL %s pal=%s kind=%s runs=%s tile=%d,%d gfx=%s pose=%s/%s"
                                    .. " | painted body=%d refl=%d | hw body=%s refl=%s arc=%d"
                                    .. " | wetRows=%d wetPx=%d | wh=%d,%d | HW %s",
                                    tostring(playerId), tostring(wpal), tostring(wkind),
                                    wruns and #wruns or -1,
                                    math.floor((screenX - wgbX) / TILE),
                                    math.floor((screenY - arc + TILE - wgbY) / TILE),
                                    tostring(remote.gfx),
                                    -- The painted tier's OWN frame choice against the peer's
                                    -- actual one, which is what the hardware tier draws. If these
                                    -- differ the two tiers are showing different pictures, and a
                                    -- picture whose art sits a row higher loses the bottom row of
                                    -- its reflection to the shore.
                                    -- The painted tier's own frame INDEX against the image the
                                    -- peer's animation command actually resolves to. The other two
                                    -- tiers draw the peer's picture; this one derives its own, and
                                    -- two pictures of the same walk cycle do not have their art on
                                    -- the same rows -- which is one row of reflection at a shore.
                                    tostring(pose) .. "/" .. tostring(frameIndex)
                                        .. " peerAnim=" .. tostring(remote.sanim)
                                        .. "/" .. tostring(remote.sidx)
                                        .. " peerImg=" .. (function()
                                            local gi2 = graphicsInfo(remote.gfx or 0)
                                            if not gi2 or gi2.anims == 0 then return "?" end
                                            local ap = r32(gi2.anims + (remote.sanim or 0) * 4)
                                            if not isRomPtr(ap) then return "?" end
                                            return tostring(r32(ap + (remote.sidx or 0) * 4)
                                                & 0xffff)
                                        end)(), "",
                                    math.floor(screenY), math.floor(wtop),
                                    tostring(tiering.hwBodyY), tostring(tiering.hwReflY), arc,
                                    (function()
                                        if not wwet then return -1 end
                                        local n2 = 0
                                        for _ in pairs(wwet) do n2 = n2 + 1 end
                                        return n2
                                    end)(),
                                    (function()
                                        if not wwet then return -1 end
                                        local px = 0
                                        for _, l in pairs(wwet) do
                                            for _, sp in ipairs(l) do
                                                px = px + sp[2] - sp[1] + 1
                                            end
                                        end
                                        return px
                                    end)(),
                                    (FRAME_WIDTH_PX + 8) >> 4, (FRAME_HEIGHT_PX + 8) >> 4,
                                    tostring(tiering.hwReflDbg))
                                    .. (function()
                                        -- WHICH rows survive, not how many. A reflection is
                                        -- flipped, so the box's BOTTOM rows carry the hat -- the
                                        -- sliver that should still show one tile from the shore.
                                        -- A count cannot tell "kept the wrong half" from "kept
                                        -- too little", and those have different fixes.
                                        if not wwet then return " | wetRange=nil" end
                                        local lo, hi = nil, nil
                                        for y2, l in pairs(wwet) do
                                            if #l > 0 then
                                                if not lo or y2 < lo then lo = y2 end
                                                if not hi or y2 > hi then hi = y2 end
                                            end
                                        end
                                        -- And where the frame's own ink is, in the same box.
                                        local ilo, ihi = nil, nil
                                        if wruns then
                                            for _, rr in ipairs(wruns) do
                                                local yy = wtop + (FRAME_HEIGHT_PX - rr.y)
                                                if not ilo or yy < ilo then ilo = yy end
                                                if not ihi or yy > ihi then ihi = yy end
                                            end
                                        end
                                        -- AND THE TILES THEMSELVES. Everything above says the
                                        -- mask is the thing that is wrong; this says WHICH tile
                                        -- and by how much, which is the only question left.
                                        -- Per grid row of the reflection box: the metatile id,
                                        -- its layerType, and how many of its sixteen rows the
                                        -- mask calls open.
                                        local tiles = {}
                                        local gbx2, gby2 = genderFrames.gridBase()
                                        if gbx2 then
                                            local gx2 = math.floor((screenX - gbx2) / TILE)
                                            local gy0 = math.floor((wtop - gby2) / TILE)
                                            local gy1 = math.floor(
                                                (wtop + FRAME_HEIGHT_PX - 1 - gby2) / TILE)
                                            for gy2 = gy0, gy1 do
                                                local id2 = genderFrames.metatileAt(gx2, gy2)
                                                local m2 = id2
                                                    and genderFrames.coverMask(id2, "reflection")
                                                local openRows = 0
                                                if type(m2) == "table" then
                                                    for rr = 0, 15 do
                                                        if (m2[rr] or 0xffff) ~= 0xffff then
                                                            openRows = openRows + 1
                                                        end
                                                    end
                                                end
                                                tiles[#tiles + 1] = string.format(
                                                    "gy%d id=%s lt=%s open=%d/16", gy2,
                                                    tostring(id2),
                                                    tostring(genderFrames.layerTypeOf
                                                        and genderFrames.layerTypeOf(id2)),
                                                    openRows)
                                            end
                                        end
                                        -- HOW MANY PIXELS ACTUALLY SURVIVE, run by run against
                                        -- the kept spans. Ranges overlapping is not the same as
                                        -- pixels landing: the ink's last row and the water's first
                                        -- row can be the same row and still share no COLUMN.
                                        local painted = 0
                                        if wruns and wwet then
                                            for _, rr in ipairs(wruns) do
                                                local yy = wtop + (FRAME_HEIGHT_PX - rr.y)
                                                local l = wwet[yy]
                                                if l then
                                                    local ax1 = screenX + rr.x1
                                                    local ax2 = screenX + rr.x2
                                                    if dirInfo.hFlip then
                                                        ax1 = screenX + FRAME_WIDTH_PX - 1 - rr.x2
                                                        ax2 = screenX + FRAME_WIDTH_PX - 1 - rr.x1
                                                    end
                                                    for _, sp in ipairs(l) do
                                                        local lo2 = math.max(ax1, sp[1])
                                                        local hi2 = math.min(ax2, sp[2])
                                                        if hi2 >= lo2 then
                                                            painted = painted + hi2 - lo2 + 1
                                                        end
                                                    end
                                                end
                                            end
                                        end
                                        return string.format(
                                            " | paintedPx=" .. painted ..
                                            " | wetRange=%s..%s inkRange=%s..%s box=%d..%d | %s",
                                            tostring(lo), tostring(hi), tostring(ilo),
                                            tostring(ihi), math.floor(wtop),
                                            math.floor(wtop) + FRAME_HEIGHT_PX - 1,
                                            table.concat(tiles, " ; "))
                                    end)())
                            end
                        end
                        if wruns then
                            drawRunList(wruns, FRAME_WIDTH_PX, dirInfo.hFlip, screenX, wtop,
                                panelRows, dim, FRAME_HEIGHT_PX,
                                genderFrames.reflectionXScale(wkind), wwet)
                        end
                    end

                    drawSpriteFrame(remote.gender, pose, frameIndex, dirInfo.hFlip, screenX,
                        screenY, panelRows, dim,
                        genderFrames.reflectiveSpans(screenX, screenY,
                            FRAME_WIDTH_PX, FRAME_HEIGHT_PX, "sprite"))
                    MG_BODY_PAINTED = true -- gap detector: the walker-fallback body counts too
                end
                -- OVER the character, which is the whole point: the engine's grass sprite sits
                -- above the object it belongs to. Drawn on the ghost's OWN tile -- the bottom tile
                -- of its frame -- for both draw paths, since a peer in grass may be on foot or on
                -- a bike.
                do
                    -- ON THE TILE GRID, not on the ghost. A grass sprite belongs to a TILE and a
                    -- character walks through it; drawing it at the ghost's own frame made it
                    -- travel along with them, so mid-step it sat across the character in the wrong
                    -- place -- *"not being drawn properly when moving in tall grass"*. Standing
                    -- still it looked right, which is exactly why it survived the first check.
                    --
                    -- The character's feet span two tiles mid-step, so both are considered: each
                    -- grass tile the ghost's bottom row overlaps is drawn at ITS OWN screen
                    -- position, and the ghost passes through whichever it is actually on.
                    local gbX2, gbY2 = genderFrames.gridBase()
                    if gbX2 then
                        local footY = screenY + FRAME_HEIGHT_PX - TILE
                        -- The rustle belongs to the tile the ghost has just STEPPED ON, so the
                        -- clock starts when its tile changes. Every other grass tile it overlaps
                        -- is settled, which is what standing grass looks like.
                        local onX = math.floor((screenX + (FRAME_WIDTH_PX >> 1) - gbX2) / TILE)
                        local onY = math.floor((footY + (TILE >> 1) - gbY2) / TILE)
                        -- THE TILE BEING ENTERED **AND** THE ONE BEING LEFT.
                        --
                        -- Neither extreme was right. Painting every tile the frame overlapped hid
                        -- the ghost from both sides while it walked (*"popping in/out"*); painting
                        -- only the tile it stands on made the grass jump from one tile to the next
                        -- at the midpoint of every step (*"it moves between tiles weird"*). The
                        -- engine does neither: stepping into grass spawns a NEW sprite on the new
                        -- tile while the old one stays where it is and finishes settling, so for
                        -- the length of a step there are two.
                        --
                        -- Each carries its own entry frame, so the one being entered rustles while
                        -- the one being left completes its own animation and is dropped once it has
                        -- settled. Oldest first, so the newer grass paints over it.
                        -- COVER THE TILES THE FEET ACTUALLY OVERLAP, one row only.
                        --
                        -- Three versions and each failed differently, which is what finally named
                        -- the rule. Locking the grass to the ghost made it travel along (*"not
                        -- drawn properly when moving"*). Every tile the whole 16x32 FRAME touched
                        -- covered the character from above as well (*"popping in/out"*). One tile
                        -- chosen by the ghost's centre jumps at the midpoint of a step, leaving the
                        -- leading half bare -- *"shown slightly when going between the tall grass
                        -- tiles"*, because the engine puts grass on the tile being ENTERED at the
                        -- START of the step while a centre-based test flips halfway through.
                        --
                        -- The feet are what stands in grass, so the span of the FOOT BOX is the
                        -- honest answer: one tile row, however many columns those 16 pixels reach
                        -- into. Aligned that is one tile; mid-step it is two, side by side, exactly
                        -- covering the character.
                        --
                        -- Each tile keeps its own entry time, so a tile just stepped onto rustles
                        -- while one being left is further through its own animation.
                        tiering.grassTiles = tiering.grassTiles or {}
                        local seen = tiering.grassTiles[playerId] or {}
                        -- EVERY TILE THE CHARACTER STANDS IN, ALL IN FRONT.
                        --
                        -- Standing still that is one tile and the head shows above it, which is
                        -- right. MID-STEP the character spans two, and the grass covers all of
                        -- them -- the user, after a version that drew only one of the pair in
                        -- front: *"now i see the bottom/legs when its going up, top/head when going
                        -- down. the grass is supposed to hide it"*.
                        --
                        -- Two earlier readings of this were wrong in opposite directions: "the
                        -- lower tile is in front" (true only because the capture happened while
                        -- walking down) and then "the tile being entered is in front" (which still
                        -- leaves the other half of the character bare). Walking through tall grass
                        -- obscures a character, and that is the whole of the rule.
                        local r0 = math.floor((footY - gbY2) / TILE)
                        local r1 = math.floor((footY + TILE - 1 - gbY2) / TILE)
                        -- BOUNDED AT THE FOOT BOX, and this is the confirmed answer rather than a
                        -- setting: grass never rises above the character's feet, standing or
                        -- mid-step. Both tiles the feet span are drawn, so nothing shows through
                        -- between them, and neither can reach the body or the head.
                        --
                        -- It was reached as the reference end of a binary test -- deliberately too
                        -- little coverage, to tell "the clip is not working" from "the clip is set
                        -- wrong" after adjusting the number twice produced no visible change. It
                        -- turned out to be correct. Two rounds of reasoning about which pixel rows
                        -- ought to be covered were beaten by one deliberately-wrong build.
                        genderFrames.drawGrassRows(playerId, gbX2, gbY2, screenX, footY,
                            r0, r1, panelRows, dim, footY)
                        -- LANDING DUST, after the grass so it is not buried by it.
                        do
                            -- A TRAIL, NOT A FOLLOWER. The engine's dust belongs to the TILE the
                            -- landing happened on: the character hops away and the puff stays and
                            -- finishes where it was born. Drawing the puff at the ghost's current
                            -- position -- what this block did first -- made it travel along under
                            -- the character, so a peer hopping across the map left no trail at all
                            -- (user, 2026-08-21). So each landing records where it happened, and
                            -- every live puff is drawn at ITS OWN spot until its animation ends.
                            --
                            -- Anchored on gSpriteCoordOffset, the term the engine itself adds to a
                            -- coordOffsetEnabled sprite to ride the camera: position minus the
                            -- offset now, plus the offset at draw time, keeps a puff glued to its
                            -- tile through any scroll -- the same arithmetic drawGhostShadows uses
                            -- to place the spawned tier's effects.
                            --
                            -- CENTRED ON THE GRAPHIC'S OWN WIDTH, the same fix the shadow needed:
                            -- at screenX alone the 16-wide puff sat 8px left of a 32-wide bike
                            -- (user, 2026-08-21: *"off center and to far to the left"*).
                            local _, landedNow = genderFrames.noteLanding(playerId,
                                isJumpAction(remote.act) or false, remote.act)
                            local offX = rs16(GSPRITECOORDOFFSETX_ADDR)
                            local offY = rs16(GSPRITECOORDOFFSETY_ADDR)
                            tiering.puffs = tiering.puffs or {}
                            local plist = tiering.puffs[playerId]
                            if not plist then plist = {} tiering.puffs[playerId] = plist end
                            if landedNow then
                                local pgi = remote.gfx and remote.gfx ~= 0
                                    and graphicsInfo(remote.gfx) or nil
                                local halfW = ((pgi and pgi.width) or FRAME_WIDTH_PX) >> 1
                                -- THE ARC COMES OFF, the same term the shadow beside it drops.
                                -- Dust belongs to the GROUND the character landed on, and a
                                -- pinned copy carries the spawned sprite's hop in pos2 -- so
                                -- recording the puff at the raw screenY pinned it to wherever the
                                -- body happened to be in its arc, which is highest at the moment
                                -- a bounce ends and the next begins. Hopping in place made that
                                -- obvious because nothing else moved: the user, 2026-08-21,
                                -- *"the dust is a bit to high up on the drawn ghost when jumping
                                -- in place without moving"*. Height from the graphic's own
                                -- descriptor for the same reason the width is.
                                local fullH = (pgi and pgi.height) or FRAME_HEIGHT_PX
                                plist[#plist + 1] = { at = frameCounter,
                                    bx = screenX + halfW - 8 - offX,
                                    by = screenY - arc + fullH - 8 - offY }
                            end
                            for pi = #plist, 1, -1 do
                                local puff = plist[pi]
                                local pf = genderFrames.dustFrameAt(frameCounter - puff.at)
                                local druns = pf and genderFrames.dustRuns(pf)
                                if druns then
                                    drawRunList(druns, TILE, false, puff.bx + offX,
                                        puff.by + offY, panelRows, dim)
                                elseif not pf then
                                    table.remove(plist, pi)
                                end
                            end
                        end

                        -- The covered set is rebuilt each frame, so a tile that stops being
                        -- covered and is stepped onto again rustles afresh.

                    end
                end
                -- The painted copy gets a shadow too, on the same terms as the spawned one: only
                -- while the peer reports a jump, and on the ground it left rather than under its
                -- feet -- which is what subtracting the arc does. Compare mode only, because that
                -- is where the painted ghost HAS an arc (it copies the spawned sprite's); a real
                -- overflow peer slides across a ledge and has no ground to separate from.
                painted = painted + 1
            end
        end
        -- A remote in a different area is deliberately not drawn at all --
        -- area_id is opaque and compared by equality only
        -- (agent_docs/contract.md); this is not the same as despawning it.
    end
    tiering.painted = painted

    -- Flush the comparison samples once a second. Buffered on purpose: the writes are what cost,
    -- not the reads, and this file learned that the expensive way earlier the same day.
    if COMPARE_TIERS then
        tiering.moveLog = tiering.moveLog or {}
        if #tiering.moveLog >= 60 then
            local f = io.open(SCRIPT_DIR .. "probes/tier_compare.log", "a")
            if f then
                local NL = string.char(10)
                f:write(table.concat(tiering.moveLog, NL), NL)
                f:close()
            end
            tiering.moveLog = {}
        end
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
-- A SAVESTATE LOAD REPLACES THE WORLD UNDERNEATH US, and nothing in the game says so.
--
-- Everything this adapter holds about the engine -- which object slots our ghosts live in, which
-- OBJ tile ranges we allocated, which hardware OAM entries we own -- describes the machine as it
-- was. A state load rewinds all three at once: the engine's tile-allocation bitmap goes back to
-- what it held when the state was saved, while our record of what we own does not. From that frame
-- on we are writing sprite frames into tiles the engine has since given to something else, and
-- drawing our own from the same range -- which is exactly what the user saw, twice, with the
-- hardware tier: *"the OAM gets weird after save states"*, then *"the OAM sprite broke completely
-- now after a save state"*.
--
-- IT IS A SHIPPED BUG, NOT A DEV ONE. Loading a state is ordinary BizHawk use, not something only
-- an agent driving a test does -- the same reasoning that made despawnGhost's out-of-overworld
-- guard a shipped fix rather than a loader one.
--
-- THE TELL IS THE EMULATOR'S OWN FRAME COUNTER, not anything in the game: this runs once per
-- emulated frame, so the count advances by exactly one. A load makes it jump -- backwards to an
-- earlier state, or forwards to a later one. Anything that is not "one more than last time" means
-- the world was replaced.
--
-- THE RESPONSE IS TO FORGET, NOT TO CLEAN UP. Freeing "our" tiles here would clear bits in a
-- bitmap that is now somebody else's -- the identity-first rule despawnGhost already follows for a
-- map load, for the same reason and with the same silent consequence. So: release the hardware
-- tier without freeing (hwReleaseAll(false)), drop every ghost record (despawnGhost's own identity
-- test then declines to touch a slot that is no longer ours), and throw away the queued tile frees,
-- which name ranges from a world that no longer exists. Everything is re-acquired from scratch on
-- the next frame, against the bitmap the engine actually has now.
-- GLOBAL, like hwRelease and swapGhostGraphicInPlace: this chunk sits at Lua's hard ceiling of 200
-- locals per function, and one more file-scope local here is a PARSE failure, not a slow script.
-- Adding it as a local is exactly how this landed the first time (2026-08-21).
function detectStateLoad()
    local fc = emu.framecount()
    local last = genderFrames.lastEmuFrame
    genderFrames.lastEmuFrame = fc
    if last == nil or fc == last + 1 then return end
    -- A small forward jump is ordinary (a dropped tick, the emulator catching up); a big one, or
    -- any backwards step, is a different world.
    if fc > last and fc <= last + 10 then return end
    logFile(string.format("state load detected: emu frame %d -> %d; dropping every ghost, "
        .. "hardware entry and tile claim rather than freeing them", last, fc))
    pcall(hwReleaseAll, false)
    -- AND EVERY ENTRY IN OUR OAM RANGE, not only the ones our bookkeeping names. The load rewinds
    -- gMain.oamBuffer to the SAVE-TIME session's contents, which can hold entries in slots our
    -- current records never claimed -- nothing of the engine's clears 64..127, so such an entry
    -- stays on screen drawing from tiles the fresh session reuses: garbage that survives until
    -- something overwrites that slot. The user's narrowing found it: *"only when using savestate
    -- from water to grass"* -- the water-time roster used more slots (blob, ripples) than the
    -- grass-time one re-claims, and the leftovers are the glitch. Sweep the whole range blind.
    pcall(function()
        for slot = 0, tiering.hw.slots - 1 do
            local a = tiering.hw.base + slot * 8
            w16(a + 0, tiering.hw.d0)
            w16(a + 2, tiering.hw.d1)
            w16(a + 4, tiering.hw.d2)
        end
    end)
    -- The sweep may still WRITE the restored orphan objects and sprites -- identity says they are
    -- ours-shaped and deactivating them is right -- but every tile FREE under it is suppressed:
    -- the bitmap it would edit belongs to the restored session. See freeGhostTiles.
    genderFrames.stateLoadPurge = true
    pcall(despawnAllGhosts)
    genderFrames.stateLoadPurge = nil
    genderFrames.pendingTileFrees = {}
    genderFrames.deferredTileFrees = {}
    tiering.hw.fxTiles, tiering.hw.puffs, tiering.hw.ripples = {}, {}, {}
    tiering.hw.area = nil
    -- AND THE ORPHAN FIELD-EFFECT SPRITES, which no other sweep can see. pitfalls.md wrote this
    -- one down this morning as a dev artefact -- "a savestate load orphans field-effect sprites,
    -- and the orphan sweep cannot see them: a blob has no object event" -- and it stopped being
    -- an artefact the moment a state was saved MID-SURF with a ghost up: every load of it
    -- restores that session's ghost blob, alive, following object 15. It rides invisibly under
    -- the fresh ghost's own blob all surf, and when THAT blob despawns at a dismount the orphan
    -- keeps following the walker ashore, forever -- the user's *"still keeps its blob on when it
    -- lands"*, drawn as a 32-wide blob behind a perfectly correct walker while every struct we
    -- log read clean. Kill every blob/bobber whose followed object is not the PLAYER's -- the
    -- player's own is the engine's business, and our ghosts' get respawned fresh anyway.
    pcall(function()
        local playerObj = r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05)
        local playerSpr = r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04)
        for sid = 0, 63 do
            local d = sprAddr(sid)
            local cb = r32(d + 0x1c)
            -- A blob follows an OBJECT id in data[2]; the underwater bobber follows a SPRITE id
            -- in data[0] (field_effect_helpers.c's two #define blocks).
            -- Blobs only: we no longer create underwater bobbers as sprites, but the PLAYER's
            -- own is still the engine's and must never be touched.
            local foreign = (cb == UPDATESURFBLOBFIELDEFFECT_CB and r16(d + 0x32) ~= playerObj)
            if (r8(d + 0x3e) & 0x01) == 1 and foreign then
                w8(d + 0x3e, (r8(d + 0x3e) & ~0x01) | 0x04)
                w32(d + 0x1c, 0)
                logFile(string.format("state load: killed orphan blob/bobber sprite %d "
                    .. "(followed obj %d)", sid, r16(d + 0x32)))
            end
        end
    end)
    -- No spawned or hardware ghost until the wire has echoed a post-load state; see chooseSpawned.
    genderFrames.loadQuietUntil = frameCounter + 12
end

local function runFrame()
    frameCounter = frameCounter + 1
    detectStateLoad()
    -- Swap-time tile frees, six frames late -- three times the measured two-frame OAM lag. The
    -- reasoning and the measurement are at the queue site in swapGhostGraphicInPlace.
    do
        local q = genderFrames.deferredTileFrees
        local keep = nil
        for i = 1, #q do
            local e = q[i]
            if frameCounter - e.at >= 6 then
                local stillOurs
                if e.hwArea ~= nil then
                    stillOurs = tiering.hw.area == e.hwArea       -- hardware-tier range
                else
                    stillOurs = ghostAlive(e.g)                   -- spawned-tier range
                end
                -- NEVER FREE A RANGE THAT IS NOT CURRENTLY ALLOCATED. A double free is not a
                -- no-op here: the first clears our bits, the ENGINE then allocates that run for
                -- something of its own, and the second clears the bits out from under it -- so
                -- the next allocation (ours or the game's) lands on tiles already in use. At a
                -- surf start the thing being allocated is the show-mon POKEMON PICTURE, which is
                -- why the user saw both halves of one collision: *"a weird glitched orange
                -- sprite"* on the ghosts, and the banner showing *"an egg instead of sharpedo"*.
                -- Several despawn paths can queue the same range (blob, shadow, body, hardware
                -- release), so idempotence has to be enforced here rather than assumed.
                if stillOurs and inOverworld() and tileIsAllocated(e.start) then
                    for t = e.start, e.start + e.count - 1 do setTileAllocated(t, false) end
                end
                -- Not ours any more (world rebuilt, ghost gone): dropped, never freed.
            else
                keep = keep or {}
                keep[#keep + 1] = e
            end
        end
        genderFrames.deferredTileFrees = keep or {}
    end
    -- CLEAR ONLY WHAT WILL BE REPAINTED. A map transition deliberately returns nil local state
    -- for a frame or two (mapJustChanged), and the whole render block sits inside `if state` --
    -- so an unconditional clear here wiped the overlay on exactly the frames nothing repaints,
    -- which the user saw as both ghosts blinking at every route crossing. Keeping the previous
    -- frame's paint through those frames costs at most two frames of overlay lag against a
    -- scrolling camera; a title-screen exit still clears, so nothing lingers after a session.
    -- ONE state read per frame, up here: getLocalState advances the map-change tracker as a side
    -- effect, so a second call in the same frame would eat the transition edge the sender pauses
    -- on. The connected block below uses this same value.
    local frameState = getLocalState()
    if not (session.live and frameState == nil) then
        gui.clearGraphics()
        tiering.overlayCleared = true   -- for the gap detector at the frame's end
    end
    -- Cross-map upkeep: the gMapGroups self-location (one 128KB chunk a frame until found), the
    -- connection table on map change, and the per-frame re-translation of every peer.
    genderFrames.xmapTick()

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
        -- Only after a full sweep found nothing. A core that is already running -- started by
        -- hand, by a dev script, or left by a previous session -- is used as-is and nothing is
        -- spawned; that ordering is what stops autostart from ever producing a second core.
        if not connected then
            -- On the port the sweep just found empty, never a fixed one -- see firstFreePort.
            startCore(firstFreePort)
        end
        if connected then
            console.log(string.format("MeshGhost: bridge connected on %s:%d.", BRIDGE_HOST, currentPort))
            helloSentAtFrame = frameCounter
            -- Must be the first message on a fresh connection, before any local_state --
            -- see internal/bridge.Hello. Declares the game so the core can connect to the
            -- relay without the user typing "game" into config.json themselves.
            -- render_all_areas: this adapter owns area visibility now. The core's own cross-area
            -- filter turned every seam crossing into a despawn/respawn pop -- the echoed area_id
            -- lags a real crossing by a delivery, and the core's equality test cannot know that
            -- two maps are CONNECTED. This adapter can (the cross-map block above), and it already
            -- hides what it cannot translate, so the core is asked to deliver everything and
            -- decide nothing -- which also keeps the core exactly as game-dumb as the user wants
            -- it: the flag removes an area judgment from the core rather than teaching it one.
            sendLine(string.format('{"type":"hello","payload":{"game_id":%s,"game_version":%s,"render_all_areas":true}}', jsonString(GAME_ID), jsonString(ADAPTER_VERSION)))
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

    -- The orphan sweep WRITES gObjectEvents and gSprites, so it runs only where this adapter is
    -- allowed to write at all -- the same three conditions the spawn path itself is under, which
    -- it was silently missing (found by reading, 2026-08-19):
    --   * avatarAddrConfirmed -- before detection succeeds the object array has not been located,
    --     so every read here is of an address we have not verified holds gObjectEvents;
    --     (The third condition here used to be `avatarAddrOffset == 0`, because gSprites'
    --     Archipelago location was unmeasured and the sweep would have read a relocated
    --     gObjectEvents while writing the vanilla gSprites. It is measured now -- gSprites does
    --     NOT move on the Archipelago build, probes/gsprites_scan_probe.lua, verified.md
    --     2026-08-19 -- so the sweep is correct on both builds and the condition is gone.)
    --   * inOverworld() -- outside it there is no live object array to sweep, and a ghost of ours
    --     cannot have been created, so there is nothing this could legitimately find.
    -- Every second, AND immediately on the way back into the overworld.
    --
    -- Coming out of a battle the user saw *"a 3rd ghost temporarily shown right after ending a
    -- battle, and then went away"* (2026-08-19), which is this sweep doing its job a beat late.
    -- It is the direct consequence of the despawn guard added the same day: outside the overworld
    -- we drop a ghost's bookkeeping without writing to the arrays, because a battle has re-used
    -- the sprite slots -- so an object of ours can outlive its record and the engine will happily
    -- draw it when the map comes back. Waiting up to 60 frames to notice is what made it visible.
    -- Sweeping on the transition itself costs one array scan per battle and closes the window.
    local nowOverworld = inOverworld()
    if avatarAddrConfirmed and nowOverworld and not tiering.wasOverworld
        and #genderFrames.pendingTileFrees > 0 then
        -- Back in the overworld: settle anything a battle stopped us freeing. If the slot still
        -- carries our own localId the range is genuinely still ours and freeing it is right; if it
        -- does not, the engine has already run its own reset over the bitmap and the range is
        -- long since somebody else's, so the only safe thing is to forget it.
        for i = 1, #genderFrames.pendingTileFrees do
            local p = genderFrames.pendingTileFrees[i]
            if p.tileStart and r8(objAddr(p.objId) + 0x08) == GHOST_LOCAL_ID then
                for t = p.tileStart, p.tileStart + p.tileCount - 1 do setTileAllocated(t, false) end
            end
            genderFrames.pendingTileFrees[i] = nil
        end
    end
    if avatarAddrConfirmed and nowOverworld
        and (frameCounter % 60 == 0 or not tiering.wasOverworld) then
        sweepOrphanGhosts()
    end
    tiering.wasOverworld = nowOverworld

    -- Once every 5s, to the log file only: enough to tell which link in the chain is quiet
    -- without reading the game. "connected" and "ready" are different questions, and so are
    -- "a peer is known" and "a ghost exists for it" -- a silent failure looks different in each.
    if frameCounter % 300 == 0 then
        local nRemotes, nGhosts, nDrawn = 0, 0, 0
        for _ in pairs(remotes) do nRemotes = nRemotes + 1 end
        for _ in pairs(ghosts) do nGhosts = nGhosts + 1 end
        -- The drawn tier's own count, so "every peer is visible" is a number in the log rather
        -- than something to squint at: peers here, minus the ones holding an object slot. Counted
        -- only when that tier is on, so the figure never implies pixels nobody drew.
        -- COMPARE_TIERS counts too: it paints the loopback ghost with the tier itself off, and a
        -- status line reading drawn=0 while a painted ghost is on screen is a counter that lies
        -- about the one thing this mode exists to look at.
        if tiering.drawn or COMPARE_TIERS then nDrawn = tiering.painted or 0 end
        local nClipped = genderFrames.clippedRuns or 0
        genderFrames.clippedRuns = 0
        logFile(string.format(
            "status: frame=%d connected=%s ready=%s port=%s remotes=%d ghosts=%d hw=%d drawn=%d "
                .. "clipped=%d overworld=%s inGame=%s slide=%d/%d paused=%d",
            frameCounter, tostring(connected), tostring(ready), tostring(currentPort),
            nRemotes, nGhosts, tiering.hw.placed or 0,
            nDrawn, nClipped, tostring(inOverworld()), tostring(session.live),
            (tiering.slide or {}).legs or 0, (tiering.slide or {}).step or 0,
            (tiering.slide or {}).paused or 0))
        tiering.slide = { step = 0, legs = 0, paused = 0 }
        -- "Peers are known but none of them is being rendered" is its own failure, and the status
        -- counts above cannot tell which of the two reasons it is: the peer is somewhere else, or
        -- it is here and the spawn declined. area_id is opaque and compared by equality, so
        -- printing both sides settles it in one line. Only when the counts actually disagree.
        if nRemotes > 0 and nGhosts == 0 then
            -- Rebuilt from memory rather than reused: the smoothed area id is a local of the
            -- block further down and is not in scope here, and this is a once-per-300-frames
            -- diagnostic, so a fresh read costs nothing.
            local b = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
            local localArea = b ~= 0
                and (memory.read_s8(b + 0x04) .. ":" .. memory.read_s8(b + 0x05)) or "nil"
            for playerId, r in pairs(remotes) do
                logFile(string.format("  unrendered %s: area=%s local=%s at=(%s,%s)",
                    tostring(playerId), tostring(r.areaId), localArea,
                    tostring(r.x), tostring(r.y)))
            end
        end
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
                logFile(string.format("         gfx: ghost drawn as %s, peer reports %s",
                    tostring(g.gfx), tostring(remotes[playerId] and remotes[playerId].gfx)))
                -- Ghost vs PLAYER, field by field. The player's sprite is the control: it is the
                -- one that definitely renders, so any field that differs is a candidate and any
                -- field that matches is ruled out. Beats reasoning about which write was wrong.
                local ps = sprAddr(r8(pa + 0x04))
                local function spr(tag, a)
                    logFile(string.format(
                        "         %s oam=%04X %04X %04X %04X flags=%02X %02X sub=%02X c2c=%d,%d "
                            .. "anim=%d/%d img=%08X anims=%08X",
                        tag, r16(a + 0x00), r16(a + 0x02), r16(a + 0x04), r16(a + 0x06),
                        r8(a + 0x3e), r8(a + 0x3f), r8(a + 0x42), r8(a + 0x28), r8(a + 0x29),
                        r8(a + 0x2a), r8(a + 0x2b), r32(a + 0x0c), r32(a + 0x08)))
                end
                spr("ghost ", gs)
                spr("player", ps)
                if g.blobSprId then spr("blob  ", sprAddr(g.blobSprId)) end
            end
        end
    end

    if connected then
        local state = frameState
        -- The session ended (title screen / soft reset). Announce it by dropping the bridge --
        -- see the session table's declaration for why going quiet is not enough. Cleared
        -- unconditionally so a drop is attempted exactly once per edge even if resetBridge
        -- throws; the next frame reconnects.
        if session.ended then
            session.ended = false
            console.log("MeshGhost: left the game (title screen) -- dropping the bridge so peers "
                .. "stop seeing this ghost.")
            -- Resolved once per session, and the next session may be a different save or a new
            -- game with the other gender chosen -- keeping the old answer would dress every peer's
            -- view of this player in the previous save's character for the rest of the emulator
            -- session, since readLocalGender only ever runs while this is nil.
            localGender = nil
            resetBridge()
        end
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
            if DIAG_STEP_CURVE and inRealGlide and diag.stepCurveLogs < DIAG_STEP_CURVE_MAX_LOGS then
                local realX, realY = playerScreenPos()
                local deltaX = diag.prevRealX and (realX - diag.prevRealX) or 0
                local deltaY = diag.prevRealY and (realY - diag.prevRealY) or 0
                diag.prevRealX, diag.prevRealY = realX, realY
                diag.stepCurveLogs = diag.stepCurveLogs + 1
                console.log(string.format(
                    "MeshGhost DIAG CURVE: frame=%d smoothX=%.4f smoothY=%.4f realScreenX=%d realScreenY=%d realDX=%d realDY=%d",
                    frameCounter, smoothX, smoothY, realX, realY, deltaX, deltaY))
            end
            -- Not until bridge_ready. "The socket connected" is not "this core is ours", and
            -- sending state to a core that is about to reject us is state sent to somebody
            -- else's session (agent_docs/contract.md, PROTOCOL.md's tick loop).
            if ready then
                if MESHGHOST_EMERALD_PROFILE then tiering.profT = os.clock() end
                -- On the table rather than in locals: this chunk is at Lua's 200-local ceiling.
                genderFrames.sendGfx = localGraphicsId()
                genderFrames.sendAnim, genderFrames.sendIdx = genderFrames.coherentAnim(
                    genderFrames.sendGfx,
                    r8(sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04)) + 0x2a),
                    r8(sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04)) + 0x2b))
                sendLine(encodeLocalState(state.areaId, smoothX, smoothY, state.orientation,
                    state.anim, localGender or "male", genderFrames.sendGfx,
                    genderFrames.sendAnim, genderFrames.sendIdx,
                    -- movementActionId (pokeemerald include/global.fieldmap.h:246, +0x1C): what
                    -- the engine is currently making this character DO. A ledge hop is a jump
                    -- action, and no amount of watching positions can recover that -- see the
                    -- remote side for why.
                    r8(GOBJECTEVENTS_ADDR + avatarAddrOffset
                        + r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05) * OBJECTEVENT_SIZE
                        + 0x1c),
                    -- pos2 (+0x24/+0x26): the sprite offset the game's own TASKS move a character
                    -- by. Fishing shifts it to 8,0 to keep the character on its tile inside a
                    -- 32-wide frame -- and a ghost has no task, so without this it sits half a
                    -- tile off exactly when it picks up the rod.
                    --
                    -- Taken from localGraphicsId's paired values, NOT read fresh here: while a new
                    -- graphic is being held back, its offset must be held with it, or the peer
                    -- gets the old graphic wearing the new offset.
                    genderFrames.sendSox or 0, genderFrames.sendSoy or 0,
                    -- animPaused (bit 0x40 of the sprite's +0x2C): whether the animation is
                    -- RUNNING. The overworld pauses an idle character's sprite, so this is what
                    -- tells a ghost to hold a frame rather than play the loop.
                    ((r8(sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04)) + 0x2c) & 0x40)
                        ~= 0) and 1 or 0,
                    -- gPlayerAvatar.bikeSpeed (+0x0B, include/global.fieldmap.h:355): the game's
                    -- OWN statement of how fast this character is moving, as a PLAYER_SPEED_*
                    -- (include/bike.h:16-25 -- STANDING 0, NORMAL 1, FAST 2, FASTER 3, FASTEST 4).
                    --
                    -- A stable field, which is the point. The first attempt read the speed out of
                    -- movementActionId, and that is a TRANSIENT: sampled at 20Hz it caught
                    -- WALK_NORMAL or a turn as often as the fast action, so six steps in ten fell
                    -- back to walking pace behind a peer at bike speed (measured 2026-08-19,
                    -- `spd=` counters: walk/run=6 against 2D=3 and 15=1).
                    r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x0b),
                    -- disableAnim (bit 0x04 of the object event's +0x01, include/global.fieldmap.h
                    -- :203-211): "this character may not animate", which a movement cannot
                    -- override. See encodeLocalState for why spaused alone was not enough.
                    ((r8(GOBJECTEVENTS_ADDR + avatarAddrOffset
                        + r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05) * OBJECTEVENT_SIZE
                        + 0x01) & 0x04) ~= 0) and 1 or 0))
                if tiering.profT then
                    local pr = tiering.prof or {}
                    pr.send = (pr.send or 0) + (os.clock() - tiering.profT)
                    tiering.prof = pr
                end
            end
        elseif ready then
            sendLine(ENCODED_NO_SEND)
        end

        if connected then
            if MESHGHOST_EMERALD_PROFILE then tiering.profT = os.clock() end
            drainBridge()
            if MESHGHOST_EMERALD_PROFILE then
                local pr = tiering.prof or {}
                pr.drain = (pr.drain or 0) + (os.clock() - tiering.profT)
                tiering.prof = pr
            end
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
            -- ONE render path on both builds, since 2026-08-19. This used to branch on
            -- avatarAddrOffset: a patched ROM got the drawn overlay instead of real spawns,
            -- because gObjectEvents' Archipelago relocation was measured while gSprites' was
            -- not, and writing an unmeasured address corrupts whatever now lives there.
            -- gSprites is measured now and it does NOT move -- gObjectEvents shifts by 0x284 on
            -- the Archipelago build, gSprites does not shift at all (probes/gsprites_scan_probe.lua,
            -- verified.md 2026-08-19). So the split is gone, and with it the reason the drawn
            -- renderer had to exist for anything but the overflow tier.
            --
            -- Nothing here relies on that measurement being right on some FUTURE patched build:
            -- spawnGhost() refuses to write a byte unless the player's own object/sprite
            -- cross-link resolves through gSprites first, so a build that did move it gets a
            -- logged refusal rather than a corrupted sprite.
            --
            -- TIER ONE: real object events, as many as the map can spare (nearest peers win).
            if MESHGHOST_EMERALD_PROFILE then tiering.profT = os.clock() end
            local spawnSet = tiering.chooseSpawned(smoothAreaId, smoothX, smoothY)
            syncRemoteGhosts(smoothAreaId, spawnSet)
            if MESHGHOST_EMERALD_PROFILE then
                local pr = tiering.prof or {}
                pr.sync = (pr.sync or 0) + (os.clock() - tiering.profT)
                tiering.profT = os.clock()
            end
            -- Independent of the drawn tier: a spawned ghost needs this whether or not the
            -- overflow tier is on, so it cannot live inside drawRemotes.
            drawGhostShadows()
            if MESHGHOST_EMERALD_PROFILE and tiering.prof then
                tiering.prof.shadows = (tiering.prof.shadows or 0) + (os.clock() - tiering.profT)
                tiering.profT = os.clock()
            end
            -- The PAINTED tier, now the third rung rather than the second. Flag-gated -- see
            -- FLAGS.md and BANDAGES.md. A drawn ghost has no engine occlusion of its own, so it clips
            -- against the panel regions tiering.scanPanel() measures per row, rather than
            -- painting over a text box or menu the way an unclipped overlay would.
            -- TIER TWO: hardware sprites the PPU draws, for peers the engine had no room for.
            -- Preferred over painting because it is both cheaper and BETTER -- real background
            -- priority and a live palette, which is exactly what the painted tier has to fake or
            -- simply lacks. Flag-gated (FLAGS.md); off leaves the ladder as it was.
            local hwSet = tiering.chooseHardware(smoothAreaId, smoothX, smoothY, spawnSet)
            renderHardwareGhosts(smoothAreaId, smoothX, smoothY, hwSet)
            -- WHO THE PAINTED TIER MUST SKIP: the engine's peers AND the hardware ones. Merged into
            -- one set rather than passing two, because drawRemotes already takes exactly this
            -- question ("is somebody else drawing this peer?") and the answer is now yes for two
            -- different reasons. Built fresh each frame -- mutating spawnSet in place would corrupt
            -- the tiering decision for the following frame.
            local drawnSkip = spawnSet
            if next(hwSet) then
                drawnSkip = {}
                for id in pairs(spawnSet) do drawnSkip[id] = true end
                for id in pairs(hwSet) do drawnSkip[id] = true end
            end
            -- TIER THREE: everyone neither of the two above could take, painted over the finished
            -- frame so that no peer is ever simply absent.
            if tiering.drawn then
                drawRemotes(smoothAreaId, smoothX, smoothY, drawnSkip)
            elseif COMPARE_TIERS then
                -- Compare mode with the overflow tier off: the loopback ghost, and only it.
                drawRemotes(smoothAreaId, smoothX, smoothY, drawnSkip, true)
            end
            if MESHGHOST_EMERALD_PROFILE and tiering.prof then
                tiering.prof.draw = (tiering.prof.draw or 0) + (os.clock() - tiering.profT)
            end
        end
    end
end

-- nil, NOT 0. Starting at 0 made the rate limit swallow every error in the first 300 frames --
-- `frameCounter - 0 > 300` is false there -- which is exactly the window connecting, the port
-- walk, address detection and the first spawns all happen in. A startup error was therefore
-- invisible by construction, in the one place a log is most wanted. Found by reading, 2026-08-19:
-- an error the fix in drainBridge() removes fired on every bridge rejection and left no trace in
-- any of the eight session logs that recorded a rejection.
-- Two fields on one table rather than two locals: the main chunk is AT Lua's 200-local ceiling,
-- and the two-tier renderer needed the slot. frameErrors.lastLogged / .consecutive.
local frameErrors = { lastLogged = nil, consecutive = 0 }
-- BANDAGES.md entry 2: a blanket per-frame pcall cannot tell one malformed line from every frame
-- failing. This does not close that entry, but it stops the log lying about the difference --
-- the count says whether this is a blip or a subsystem that has been broken for 5000 frames.

local function guardedFrame()
    -- MESHGHOST_EMERALD_PROFILE (dev): price the LUA side of the frame. os.clock around runFrame,
    -- reported once every 300 frames as an average -- cheap enough to leave on for a whole ride.
    -- What it can and cannot see is the point of having it: a big number here means the cost is
    -- in this script; a SMALL number while the fps is still low means the cost is in the emulator
    -- core or another script, and no amount of adapter tuning will find it.
    local t0
    if MESHGHOST_EMERALD_PROFILE then t0 = os.clock() end
    local ok, err = pcall(runFrame)
    -- THE GAP ITSELF, logged the frame it happens. Cleared + a live compare ghost + zero paints
    -- means the drawn copy was absent from this frame, which is the exact thing the user reports
    -- and the exact thing every stored-state probe missed. Context on the line is what decides
    -- WHERE the paint path bailed; consecutive gap frames all log, because the LENGTH of the gap
    -- is part of the symptom.
    if COMPARE_TIERS and tiering.overlayCleared then
        local ghostRemote = nil
        for id, rr in pairs(remotes) do
            if id:match("%-ghost$") then ghostRemote = rr break end
        end
        -- BODY specifically. The first version counted every drawRunList call, and a frame where
        -- only the ghost's REFLECTION painted read as "no gap" -- while the user watched the body
        -- vanish. The reflection and the body are separate paints, and the symptom is the body's.
        if ghostRemote and not MG_BODY_PAINTED then
            local g2 = nil
            for id in pairs(remotes) do
                if id:match("%-ghost$") then g2 = ghosts[id] break end
            end
            logFile(string.format(
                "DRAWN GAP f=%d gfx=%s sanim=%s/%s act=%s spawnedAlive=%s hwPlaced=%s",
                frameCounter, tostring(ghostRemote.gfx), tostring(ghostRemote.sanim),
                tostring(ghostRemote.sidx), tostring(ghostRemote.act),
                tostring(g2 and ghostAlive(g2) or false), tostring(tiering.hw.placed)))
        end
    end
    MG_DRAWN_CALLS, MG_BODY_PAINTED, tiering.overlayCleared = 0, nil, nil
    if t0 then
        local dt = os.clock() - t0
        frameErrors.profSum = (frameErrors.profSum or 0) + dt
        frameErrors.profN = (frameErrors.profN or 0) + 1
        if dt > (frameErrors.profMax or 0) then frameErrors.profMax = dt end
        if frameErrors.profN >= 300 then
            -- Sections, so a number has a name. Accumulated inside runFrame under the same flag.
            local p = tiering.prof or {}
            console.log(string.format(
                "MeshGhost PROFILE: lua avg %.3f ms, worst %.1f ms | send %.3f drain %.3f sync %.3f shadows %.3f draw %.3f (ms avg)",
                frameErrors.profSum / frameErrors.profN * 1000, (frameErrors.profMax or 0) * 1000,
                (p.send or 0) / frameErrors.profN * 1000, (p.drain or 0) / frameErrors.profN * 1000,
                (p.sync or 0) / frameErrors.profN * 1000, (p.shadows or 0) / frameErrors.profN * 1000,
                (p.draw or 0) / frameErrors.profN * 1000))
            frameErrors.profSum, frameErrors.profN, frameErrors.profMax = 0, 0, 0
            tiering.prof = {}
        end
    end
    if ok then
        frameErrors.consecutive = 0
        return
    end
    frameErrors.consecutive = frameErrors.consecutive + 1
    -- Rate-limited after the first: a per-frame error would otherwise spam the console every
    -- 1/60s. The FIRST one always logs, whenever it happens.
    if not frameErrors.lastLogged or frameCounter - frameErrors.lastLogged > 300 then
        console.log(string.format("MeshGhost: frame error (continuing, %d in a row): %s",
            frameErrors.consecutive, tostring(err)))
        -- To the FILE as well: the console is invisible to log greps, and a per-frame error on
        -- one side of a route seam hid behind exactly that for an hour on 2026-08-20.
        logFile(string.format("FRAME ERROR (%d in a row): %s",
            frameErrors.consecutive, tostring(err)))
        frameErrors.lastLogged = frameCounter
    end
end

-- Four lines of dev affordance, and the only one in this file: when loaded by
-- dev-scripts/bizhawk-dev-loader.lua (a development tool, never shipped), hand it the per-frame
-- function instead of taking the frame loop, so the adapter can be swapped and reloaded live like
-- any probe. A player opening this file in the Lua Console sets neither global and gets the
-- normal loop below, unchanged. Without this, testing an adapter edit costs a full emulator
-- relaunch each time, which is the cost the loader exists to remove.
-- ATOMIC FISHING ALIGNMENT. The game recomputes the fishing sprite's offset from the frame being
-- displayed, INSIDE the frame update, so image and offset can never disagree on screen
-- (AlignFishingAnimationFrames, pokeemerald src/field_player_avatar.c:2045-2078). A Lua script's
-- own writes land between frames, which is measurably too early or too late -- the engine steps
-- the animation before it builds OAM, so a between-frames offset is one frame out of phase with
-- the image, and the ghost flicks 8px sideways at every alignment change while the player and the
-- painted tier stay still.
--
-- So the alignment runs from a code hook at BuildOamBuffer (0x08006a0c, vanilla, from our own
-- pokeemerald.map build -- agent_docs/environment.md): sprite animations for the frame are final,
-- OAM is not yet built. The same point in the pipeline the game's own task has, which is what
-- makes it the same on screen. Vanilla-gated: an Archipelago ROM relocates code, so there the
-- alignment stays at the frame boundary (the mirror block above) until that ROM's address is
-- measured. Registered once per load: under the dev loader the previous load's hook survives in
-- the emulator, so it is unregistered first, and MESHGHOST_DEV_UNLOAD drops it with the sockets.
if MESHGHOST_FISH_ALIGN_HOOK then
    pcall(event.unregisterbyid, MESHGHOST_FISH_ALIGN_HOOK)
    MESHGHOST_FISH_ALIGN_HOOK = nil
end
tiering.fishAlignActive = false
-- MESHGHOST_EMERALD_NO_FISH_HOOK (dev): skip registering the BuildOamBuffer execute hook.
-- Exists for one measurement (2026-08-20): an execute breakpoint can push the emulator CORE onto a
-- slow per-instruction path, a cost invisible to any Lua-side timer -- so the only way to price
-- this hook is to run the same route with and without it.
if avatarAddrOffset == 0 and not MESHGHOST_EMERALD_NO_FISH_HOOK then
    -- On tiering, not locals: the main chunk is at Lua's 200-local ceiling.
    tiering.hookOk, tiering.hookId = pcall(event.onmemoryexecute, function()
        local aok = pcall(function()
            for _, g in pairs(ghosts) do
                if g.gfx and isFishingGfx(g.gfx) then alignFishingGhost(g) end
            end
        end)
        if not aok then tiering.fishAlignActive = false end
    end, 0x08006A0C, "meshghost_fish_align")
    if tiering.hookOk and tiering.hookId then
        MESHGHOST_FISH_ALIGN_HOOK = tiering.hookId
        tiering.fishAlignActive = true
    else
        console.log("MeshGhost: BuildOamBuffer hook unavailable ("
            .. tostring(tiering.hookId) .. "); fishing alignment stays at the frame boundary.")
    end
end

MESHGHOST_DEV_TICK = guardedFrame
MESHGHOST_DEV_UNLOAD = function()
    -- Three things, and every one of them leaked at some point on 2026-08-18:
    --  * the BRIDGE SOCKET. A core serves exactly one adapter, so a leaked connection makes the
    --    core reject the next load with "busy: this core already has a game attached" -- the port
    --    walk then correctly looks elsewhere, finds nothing, and the adapter runs with no peers.
    --    That cost a long detour debugging an "invisible ghost" that was really no connection.
    --  * the GHOSTS. They are objects in the game; nothing else will ever clear them.
    --  * the LOG FILE, a real OS handle -- leaking it locks the file on disk.
    -- resetBridge() covers the first two (it despawns ghosts as part of dropping the connection).
    pcall(resetBridge)
    pcall(hwReleaseAll, true)
    -- FLUSH THE DEFERRED FREES -- the queue's service point dies with this script, so anything
    -- still waiting would leak its bits into the live session's bitmap forever (the dev loader
    -- swaps scripts constantly, so this is the common path, not a corner). The age gate is
    -- dropped; the ownership tests are not.
    pcall(function()
        for _, e in ipairs(genderFrames.deferredTileFrees or {}) do
            local stillOurs
            if e.hwArea ~= nil then stillOurs = tiering.hw.area == e.hwArea
            else stillOurs = ghostAlive(e.g) end
            if stillOurs and inOverworld() and tileIsAllocated(e.start) then
                for t = e.start, e.start + e.count - 1 do setTileAllocated(t, false) end
            end
        end
        genderFrames.deferredTileFrees = {}
    end)
    if MESHGHOST_FISH_ALIGN_HOOK then
        pcall(event.unregisterbyid, MESHGHOST_FISH_ALIGN_HOOK)
        MESHGHOST_FISH_ALIGN_HOOK = nil
    end
    -- A fourth: console.log itself. This script REPLACES the emulator's global console.log with a
    -- wrapper that also writes the log file, and never put it back -- so under the dev loader each
    -- reload wrapped the previous wrapper, one layer deeper every time, with every dead layer
    -- still on the call path for the rest of the emulator session. Restore what was there.
    if rawConsoleLog then console.log = rawConsoleLog end
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
