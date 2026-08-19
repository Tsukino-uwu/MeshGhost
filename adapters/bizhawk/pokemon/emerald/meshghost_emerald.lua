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
local function localGraphicsId()
    if not avatarAddrConfirmed then return nil end
    local objId = memory.read_u8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05)
    if objId > 15 then return nil end
    return memory.read_u8(GOBJECTEVENTS_ADDR + avatarAddrOffset + objId * OBJECTEVENT_SIZE + 0x05)
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
local function encodeLocalState(areaId, x, y, orientation, anim, gender, gfx, sanim, sidx, act)
    return string.format(
        '{"type":"local_state","payload":{"state":{"area_id":%s,"position":[%s,%s],"orientation":%s,"anim":%s,"extras":{"gender":%s,"gfx":%s,"sanim":%s,"sidx":%s,"act":%s}}}}',
        jsonString(areaId), tostring(x), tostring(y), jsonString(orientation), jsonString(anim),
        jsonString(gender), tostring(gfx or "null"), tostring(sanim or "null"),
        tostring(sidx or "null"), tostring(act or "null"))
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

    -- 0.25 a frame: settles a 2-4px delivery in about five frames, which is under a tenth of a
    -- second and shorter than the gap between deliveries, so it is smoothing rather than lagging.
    local prevX, prevY = r.gX, r.gY
    r.gX = r.gX + (targetX - r.gX) * 0.25
    r.gY = r.gY + (targetY - r.gY) * 0.25
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
                -- The peer's own graphic. Absent from an older peer, in which case the ghost
                -- falls back to borrowing this machine's player graphic, exactly as before.
                r.gfx = (type(st.extras) == "table" and tonumber(st.extras.gfx)) or nil
                -- Peer-controlled, so bounded like every other inbound number: animNum is a u8.
                local sa = (type(st.extras) == "table" and tonumber(st.extras.sanim)) or nil
                r.sanim = (sa and sa >= 0 and sa <= 255 and math.floor(sa) == sa) and sa or nil
                local si = (type(st.extras) == "table" and tonumber(st.extras.sidx)) or nil
                r.sidx = (si and si >= 0 and si <= 255 and math.floor(si) == si) and si or nil
                local ac = (type(st.extras) == "table" and tonumber(st.extras.act)) or nil
                r.act = (ac and ac >= 0 and ac <= 255 and math.floor(ac) == ac) and ac or nil
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

genderFrames.runsFor = function(gender, pose, frameIndex)
    local key = gender .. ":" .. pose .. ":" .. frameIndex
    local cached = genderFrames.runCache[key]
    if cached then return cached end

    local genderSet = genderFrames[gender] or genderFrames.male
    local pixels = (genderSet[pose] or genderSet.walk)[frameIndex]
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
    genderFrames.runCache[key] = runs
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
local function drawSpriteFrame(gender, pose, frameIndex, hFlip, screenX, screenY, panelRows, dim)
    drawRunList(genderFrames.runsFor(gender, pose, frameIndex), FRAME_WIDTH_PX, hFlip,
        screenX, screenY, panelRows, dim)
end

-- One run list, at a screen position: the clip against the game's own panels and the scene-
-- brightness scaling, shared by both draw paths. Split out when the peer-graphic path arrived --
-- a second copy of the clipping is exactly how two paths drift apart.
--
-- A GLOBAL, deliberately: this chunk is at 198 of Lua's 200 locals, and a shared helper is a
-- better use of the remaining budget than a name. Assigned before anything calls it.
function drawRunList(runs, frameWidth, hFlip, screenX, screenY, panelRows, dim)
    for i = 1, #runs do
        local r = runs[i]
        local color = r.color
        if dim and dim < 0.99 then
            -- Per RUN, not per pixel, and only while something is actually dimming the screen:
            -- at full brightness this whole branch is one comparison.
            color = (0xFF << 24)
                | (math.floor(((color >> 16) & 0xFF) * dim) << 16)
                | (math.floor(((color >> 8) & 0xFF) * dim) << 8)
                | math.floor((color & 0xFF) * dim)
        end
        local y = screenY + r.y
        local x1, x2 = r.x1, r.x2
        if hFlip then x1, x2 = frameWidth - 1 - r.x2, frameWidth - 1 - r.x1 end
        local ax1, ax2 = screenX + x1, screenX + x2

        -- math.floor, NOT a shift: y comes from the sub-tile smoothing and is a FLOAT, and Lua
        -- 5.4's >> demands an integer -- "number has no integer representation" thrown once per
        -- run, i.e. every frame, which the frame-error counter caught immediately (2026-08-19).
        local span = panelRows and y >= 0 and panelRows[math.floor(y / 8)]
        if span and ax2 >= span[1] and ax1 <= span[2] then
            -- Counted, because "the clip ran" and "the clip did anything" are different claims and
            -- only the second is evidence. Published in the status line as clipped=.
            genderFrames.clippedRuns = (genderFrames.clippedRuns or 0) + 1
            -- Keep whatever falls outside the panel: a run straddling the menu's left edge is
            -- still drawn up to that edge.
            if ax1 < span[1] then drawRun(ax1, math.min(ax2, span[1] - 1), y, color) end
            if ax2 > span[2] then drawRun(math.max(ax1, span[2] + 1), ax2, y, color) end
        else
            drawRun(ax1, ax2, y, color)
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
local LOOPBACK_GHOST_OFFSET_TILES_X = (os.getenv("MESHGHOST_LOOPBACK_TRAIL") and 0) or 2
local LOOPBACK_GHOST_OFFSET_TILES_Y = 0

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
        oam = r32(ptr + 0x10),
        subspriteTables = r32(ptr + 0x14),
        anims = r32(ptr + 0x18),
        images = r32(ptr + 0x1c),
        affineAnims = r32(ptr + 0x20),
    }
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
    if frameCount == 0 or imageIndex * (info.width * info.height // 2) >= 0x10000000 then
        return nil
    end

    local key = string.format("%d:%d", gfx, imageIndex)
    local cached = genderFrames.peerRunCache[key]
    if cached then return cached, info, hFlip end

    local pixels = r32(info.images + imageIndex * 8)
    if not isRomPtr(pixels) then return nil end

    -- 4bpp tiles, 8x8, laid out row of tiles by row of tiles -- the same decode the gender path
    -- uses, with the dimensions taken from the graphic instead of assumed.
    local wTiles, hTiles = info.width // 8, info.height // 8
    local pal = {}
    for i = 0, 15 do
        local c = r16(0x05000200 + (info.paletteSlot & 0x0f) * 32 + i * 2)
        pal[i] = (0xFF << 24) | (expand5to8(c & 0x1F) << 16)
            | (expand5to8((c >> 5) & 0x1F) << 8) | expand5to8((c >> 10) & 0x1F)
    end

    local runs = {}
    for py = 0, info.height - 1 do
        local tileRow, localY = py // 8, py % 8
        local x = 0
        while x < info.width do
            local tileIndex = tileRow * wTiles + (x // 8)
            local b = r8(pixels + tileIndex * 32 + localY * 4 + ((x % 8) // 2))
            local idx = (x % 2 == 0) and (b & 0x0F) or ((b >> 4) & 0x0F)
            if idx ~= 0 then
                local color = pal[idx]
                local x2 = x
                -- Extend the run while the colour holds, exactly like the gender path.
                while x2 + 1 < info.width do
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
    genderFrames.peerRunCache[key] = runs
    return runs, info, hFlip
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
local tiering = {
    blockedFrame = nil,
    lastLogFrame = nil,
    drawn = MESHGHOST_EMERALD_DRAWN_OVERFLOW or os.getenv("MESHGHOST_EMERALD_DRAWN_OVERFLOW"),
    hysteresis = 3,
    reserve = 1,
    castMax = {},
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
tiering.scanPanel = function()
    local SCAN_EVERY_FRAMES = 4
    if tiering.panelScannedAt and frameCounter - tiering.panelScannedAt < SCAN_EVERY_FRAMES then
        return tiering.panelRows
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
    tiering.panelRows = rows
    return rows
end

-- Say which renderer this session is running, once, at load. "Is the drawn tier on?" was
-- guessed at twice during its own bring-up because nothing on screen or in the log answered it.
console.log("MeshGhost: drawn overflow tier = " .. (tiering.drawn and "ON" or "off"))
if COMPARE_TIERS then
    console.log("MeshGhost: PROBE FLAG IN USE -- MESHGHOST_COMPARE_TIERS: the loopback ghost is "
        .. "rendered twice, spawned 2 tiles right and painted 2 tiles left. Dev only.")
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
    local budget = tiering.budget(localAreaId)
    local ranked = {}
    for playerId, remote in pairs(remotes) do
        if remote.areaId == localAreaId then
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
    w8(dst + 0x42, 0)
    if info.subspriteTables ~= 0 then
        w8(dst + 0x42, (r8(dst + 0x42) & 0x3f) | (1 << 6)) -- subspriteTableNum 0, mode ON
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
    }
    -- A state is its animation AND its extras: a surfing rider without the Pokemon underneath is
    -- half the state, and the missing half is the one a player notices first.
    if SURFING_GFX[graphicsId] then
        local blob = spawnSurfBlob(ghosts[playerId], mapX, mapY)
        console.log(string.format("MeshGhost: surf blob for gfx %d -> sprite %s",
            graphicsId, tostring(blob)))
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
local GFIELDEFFECTTEMPLATE_SURFBLOB = 0x0850cbc4
local UPDATESURFBLOBFIELDEFFECT_CB = 0x08155658 + 1
local BOB_PLAYER_AND_MON = 1
local SURFBLOB_SUBPRIORITY = 150

-- Which graphics ids ride a blob. Surfing only: underwater uses a different mechanism
-- (StartUnderwaterSurfBlobBobbing on the player's own sprite), and is not handled here.
SURFING_GFX = { [2] = true, [92] = true } -- Brendan, May

spawnSurfBlob = function(g, mapX, mapY)
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
    w16(d + 0x04, (r16(d + 0x04) & 0x0c00) | (tileStart & 0x03ff)) -- tileNum, paletteNum 0
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
    return sprId
end

despawnSurfBlob = function(g)
    if not g.blobSprId then return end
    local d = sprAddr(g.blobSprId)
    w8(d + 0x3e, (r8(d + 0x3e) & ~0x01) | 0x04) -- inUse = 0, invisible = 1
    w32(d + 0x1c, 0)
    if g.blobTileStart then
        for t = g.blobTileStart, g.blobTileStart + 15 do setTileAllocated(t, false) end
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
            console.log(string.format(
                "MeshGhost: the engine reclaimed %s's ghost slot (%s) -- respawning.",
                tostring(playerId), inOverworld() and "cull or map load" or "not the overworld"))
        end
        ghosts[playerId] = nil
        g = nil
    end
    if not g then
        -- Nothing to spawn into: a peer this frame already found the object array full, and it
        -- cannot empty mid-frame. Skipping the rest is what keeps a room bigger than the map from
        -- costing a full array re-scan per unplaceable peer per frame.
        if tiering.blockedFrame == frameCounter then return end
        -- Placement is only exact on a settled camera; a frame's wait is free.
        if cameraIsSettled() then
            spawnGhost(playerId, targetX, targetY, remote.orientation, wantedGfx(remote))
        end
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
        -- SWEEP IN THE SAME FRAME. despawnGhost only clears a slot it can still prove is ours
        -- (ghostAlive), and when that proof fails it deliberately touches nothing -- correct, but
        -- it leaves the old object active while the new one already exists. Captured in the
        -- fishing log: slot14 and slot15 both live across the swap, until the once-a-second sweep
        -- caught it. Sweeping here closes that window to the frame it happens in, which is what
        -- the user was seeing as the ghost "moving" when it casts a rod.
        sweepOrphanGhosts()
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
    local engineDrivesAnim = (remote.gfx == nil or remote.gfx == 0 or remote.gfx == 89)
    if PEER_GFX_ENABLED and remote.sanim and not engineDrivesAnim
        and remote.anim ~= "walking" and remote.anim ~= "running" then
        local d = sprAddr(g.sprId)
        if r8(d + 0x2a) ~= remote.sanim then
            w8(d + 0x2a, remote.sanim)
            w8(d + 0x3f, (r8(d + 0x3f) | 0x04) & ~0x10)
        end
    end

    if not ghostIsIdle(g) then return end -- never interrupt a half-played step

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
    local jumping = remote.act and remote.act >= 0x0c and remote.act <= 0x0f
    if not jumping then g.jumped = nil end
    if jumping and not g.jumped then
        g.jumped = true
        g.wasRunning = nil
        requestAction(g, remote.act)
        return
    end

    local dir = DIR_ID[remote.orientation] or DIR_ID.south

    -- Trust the engine's own coordinates rather than our record of them: it owns the object once
    -- a step is under way, and a step that got cancelled would otherwise leave us out of sync.
    local a = objAddr(g.objId)
    local curX = rs16(a + 0x10) - MAP_OFFSET
    local curY = rs16(a + 0x12) - MAP_OFFSET
    local dx, dy = targetX - curX, targetY - curY

    if dx == 0 and dy == 0 then
        if (r8(a + 0x18) & 0x0f) ~= dir then
            requestAction(g, FACE_ACTION[dir])
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
            if g.wasRunning then
                g.wasRunning = nil
                requestAction(g, FACE_ACTION[dir])
            end
            return
        end
        g.stillSince = g.stillSince or frameCounter
        if frameCounter - g.stillSince >= BUMP_AFTER_FRAMES then
            requestAction(g, BUMP_ACTION[dir])
        end
        return
    end
    g.stillSince = nil

    if math.abs(dx) + math.abs(dy) == 1 then
        local stepDir
        if dx == 1 then stepDir = DIR_ID.east
        elseif dx == -1 then stepDir = DIR_ID.west
        elseif dy == 1 then stepDir = DIR_ID.south
        else stepDir = DIR_ID.north end
        local running = (remote.anim == "running")
        local actions = running and RUN_ACTION or WALK_ACTION
        requestAction(g, actions[stepDir])
        -- Remembered so the stop above can settle it: a run leaves the object on a running frame
        -- and only an explicit action brings it back to standing. A walk does not need this --
        -- the user's own test was exact about that, "it does idle->walk fine".
        g.wasRunning = running or nil
    else
        -- More than a tile out: a warp, a dropped packet, or a peer moving faster than we sample.
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
local function drawGhostShadows()
    for playerId, g in pairs(ghosts) do
        local remote = remotes[playerId]
        if remote and remote.act and remote.act >= 0x0c and remote.act <= 0x0f and ghostAlive(g) then
            local d = sprAddr(g.sprId)
            local groundX = rs16(d + 0x20) + rs16(d + 0x24) + memory.read_s8(d + 0x28)
                + rs16(GSPRITECOORDOFFSETX_ADDR)
            local groundY = rs16(d + 0x22) + memory.read_s8(d + 0x29)
                + rs16(GSPRITECOORDOFFSETY_ADDR)
            -- Centred on the character and sat at its feet: the frame is FRAME_WIDTH_PX wide and
            -- the sprite's origin is its top-left once centerToCorner is applied above.
            local cx = groundX + (FRAME_WIDTH_PX // 2)
            local cy = groundY + FRAME_HEIGHT_PX - 4
            if cx > -16 and cx < 256 and cy > -16 and cy < 176 then
                -- Drawn, not decoded: the shadow is a field-effect graphic in a different table
                -- from the character graphics this adapter reads, and an ellipse is honest about
                -- being ours rather than a near-miss copy of the game's.
                -- Alpha walked up twice against the game's own shadow, which is the only
                -- reference that matters here: 0x60 read as faint, 0xA0 still lighter than the
                -- player's (user, 2026-08-19). 0xD0 is nearly opaque while still letting the tile
                -- show, which is what the game's does.
                gui.drawEllipse(cx - 8, cy - 3, 16, 6, 0x00000000, 0xD0000000)
            end
        end
    end
end

-- spawnSet names the peers entitled to an object slot this frame (tiering.chooseSpawned). A peer
-- that loses its place does NOT vanish -- the drawn tier picks it up in the same frame, which is
-- the whole point of the split.
-- DEV ONLY -- MESHGHOST_EMERALD_NO_COLLISION: take a ghost's HITBOX off its picture.
--
-- Requested for testing (user, 2026-08-19): a ghost standing two tiles away is a wall in the
-- middle of whatever is being compared. There is no flag in this engine to switch collision off --
-- it is purely positional, so the fix is positional too, and the adapter already knows the two
-- halves are separable: "collision follows the object's map coordinates; drawing follows the
-- sprite's screen position".
--
-- Elevation was tried first and does NOT do it: at 1 the ghost still blocked, and at 15 the user
-- found it blocked from behind but not head-on, which is a positional check with a moving object,
-- not an elevation rule. Recorded so nobody spends the elevation afternoon twice.
--
-- Parking happens ONLY while the ghost is standing still, and the unconditional version is a
-- REVERTED experiment, not an untried idea. The reasoning for it was that this file already
-- records the engine maintaining a ghost's sprite by camera deltas after spawn rather than
-- re-deriving it from the coordinates -- so moving them mid-step ought to be invisible. It is not:
-- the engine's step logic reads those coordinates to drive the movement, and the user's verdict
-- was immediate -- *"now the spawned ghost is acting really weird"*. Reasoning, where a
-- measurement was available.
--
-- So the honest limits of this switch: a STANDING ghost does not block, a stepping one does, for
-- the 8 or 16 frames its step lasts. Removing collision from a moving engine-driven ghost is not
-- possible this way, because the thing that makes it move is the thing that makes it collide.
local function parkGhostHitboxes(park)
    if tiering.noCollision == nil then
        tiering.noCollision = (MESHGHOST_EMERALD_NO_COLLISION
            or os.getenv("MESHGHOST_EMERALD_NO_COLLISION")) and true or false
        if tiering.noCollision then
            console.log("MeshGhost: PROBE FLAG IN USE -- MESHGHOST_EMERALD_NO_COLLISION: ghost "
                .. "hitboxes are parked off their pictures while standing still. Dev only.")
        end
    end
    if not tiering.noCollision then return end
    -- ALL THREE coordinate pairs, and ONLY while the ghost is STANDING STILL. Both halves of that
    -- are settled by testing rather than reasoning, and each cost the user a broken-looking ghost:
    --   * all three parked MID-STEP: *"really choppy/teleporting/invisible popping in and out"*;
    --   * only currentCoords parked mid-step, on the theory that collision and movement might read
    --     different pairs: *"the spawned ghost is teleporting/doing weird things now"*.
    -- The engine drives a step from the same coordinates the collision scan reads, so there is no
    -- pair to separate them by, and no version of this that frees a MOVING ghost. Freeing a
    -- standing one is the whole of what this switch can offer, and saying so is more useful than
    -- another attempt.
    local FIELDS = { 0x0c, 0x0e, 0x10, 0x12, 0x14, 0x16 }
    for _, g in pairs(ghosts) do
        local a = objAddr(g.objId)
        if park then
            if not g.parked and ghostIsIdle(g) then
                g.parked = {}
                for i, off in ipairs(FIELDS) do g.parked[i] = r16(a + off) end
                -- Seven tiles up: off the visible screen, but well inside the window the engine
                -- keeps objects loaded in, so nothing gets culled out from under us.
                w16(a + 0x0e, g.parked[2] - 7)
                w16(a + 0x12, g.parked[4] - 7)
                w16(a + 0x16, g.parked[6] - 7)
            end
        elseif g.parked then
            for i, off in ipairs(FIELDS) do w16(a + off, g.parked[i]) end
            g.parked = nil
        end
    end
end

local function syncRemoteGhosts(localAreaId, spawnSet)
    parkGhostHitboxes(false)
    for playerId in pairs(ghosts) do
        local remote = remotes[playerId]
        -- Gone, somewhere else, or demoted to the drawn tier. area_id is opaque and compared by
        -- equality only.
        if not remote or remote.areaId ~= localAreaId or not spawnSet[playerId] then
            despawnGhost(playerId)
        end
    end
    for playerId, remote in pairs(remotes) do
        if remote.areaId == localAreaId and spawnSet[playerId] then syncGhost(playerId, remote) end
    end
    parkGhostHitboxes(true)
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
    local COMPARE_DRAWN_OFFSET_TILES_X = -2
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
    -- tilemaps) against the ROM palette that same character was decoded from. Their ratio is what
    -- the hardware is doing to every character on screen, so applying it to ours is what "the same
    -- lighting" means. It costs 32 reads a frame and nothing at all per peer.
    local dim = 1
    do
        local ps = sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04))
        local slot = (r16(ps + 0x04) >> 12) & 0xF
        local romPal = GOBJECTEVENTPAL_BRENDAN_ADDR + (genderFrames.romOffset or 0)
        local sb2 = r32(GSAVEBLOCK2PTR_ADDR)
        if sb2 ~= 0 and r8(sb2 + 0x08) == 1 then
            romPal = GOBJECTEVENTPAL_MAY_ADDR + (genderFrames.romOffset or 0)
        end
        local live, ref = 0, 0
        for i = 0, 15 do
            local c = r16(0x05000200 + slot * 32 + i * 2)
            live = live + (c & 0x1F) + ((c >> 5) & 0x1F) + ((c >> 10) & 0x1F)
            local o = r16(romPal + i * 2)
            ref = ref + (o & 0x1F) + ((o >> 5) & 0x1F) + ((o >> 10) & 0x1F)
        end
        -- A ratio above 1 means the slot is not holding the palette we think it is; trust the
        -- cartridge in that case rather than brightening a ghost past what the game can show.
        if ref > 0 then dim = live / ref end
        if dim > 1 then dim = 1 elseif dim < 0 then dim = 0 end
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
        if fresh or (settled and camX % 16 == 0) then
            tiering.anchorX, tiering.originX = tx + camX / 16, playerScreenX
        end
        if fresh or (settled and camY % 16 == 0) then
            tiering.anchorY, tiering.originY = ty + camY / 16, playerScreenY
        end
        tiering.anchorArea = localAreaId
        playerMapX = tiering.anchorX - camX / 16
        playerMapY = tiering.anchorY - camY / 16
    end

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
            local pinnedArc = 0
            if pinned then
                local gs = sprAddr(pinned.sprId)
                -- pos2.y is the jump arc; kept separately so the shadow below can be put on the
                -- ground the ghost left rather than under its feet in mid-air.
                pinnedArc = rs16(gs + 0x26)
                screenX = rs16(gs + 0x20) + rs16(gs + 0x24) + memory.read_s8(gs + 0x28)
                    + rs16(GSPRITECOORDOFFSETX_ADDR)
                    + (COMPARE_DRAWN_OFFSET_TILES_X - LOOPBACK_GHOST_OFFSET_TILES_X) * TILE
                screenY = rs16(gs + 0x22) + pinnedArc + memory.read_s8(gs + 0x29)
                    + rs16(GSPRITECOORDOFFSETY_ADDR)
            end

            local unpinnedX = (tiering.originX or playerScreenX)
                + (glideX - (tiering.anchorX or playerMapX)) * TILE + camPixX
            local unpinnedY = (tiering.originY or playerScreenY)
                + (glideY - (tiering.anchorY or playerMapY)) * TILE + camPixY
            if not pinned then screenX, screenY = unpinnedX, unpinnedY end
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
                if remote.anim == "walking" or remote.anim == "running" or gliding then
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
                end
                -- A peer wearing its OWN graphic -- bike, surf, fishing -- is drawn from that
                -- graphic's own frames. Only when it differs from the plain walker (0), so the
                -- ordinary case keeps the cached gender path and costs nothing extra.
                local drew = false
                if PEER_GFX_ENABLED and remote.gfx and remote.gfx ~= 0 and remote.sanim then
                    local runs, info, gfxFlip =
                        genderFrames.runsForPeerGfx(remote.gfx, remote.sanim, remote.sidx)
                    if runs and info then
                        -- CENTRE IT LIKE THE ENGINE DOES. A fishing or biking frame is 32 wide
                        -- where a walker is 16, and the engine does not shift its position for
                        -- that -- it sets centerToCornerVec = -(width >> 1) and lets the hardware
                        -- draw from the centre. Painting a wider frame from the walker's top-left
                        -- puts it half the difference off, which is what the user saw: the drawn
                        -- ghost *"moves back a bit"* on casting while the player does not move.
                        -- Same arithmetic, applied where we draw.
                        drawRunList(runs, info.width, gfxFlip,
                            screenX + (FRAME_WIDTH_PX >> 1) - (info.width >> 1),
                            screenY + (FRAME_HEIGHT_PX >> 1) - (info.height >> 1),
                            panelRows, dim)
                        drew = true
                    end
                end
                if not drew then
                    drawSpriteFrame(remote.gender, pose, frameIndex, dirInfo.hFlip, screenX,
                        screenY, panelRows, dim)
                end
                -- The painted copy gets a shadow too, on the same terms as the spawned one: only
                -- while the peer reports a jump, and on the ground it left rather than under its
                -- feet -- which is what subtracting the arc does. Compare mode only, because that
                -- is where the painted ghost HAS an arc (it copies the spawned sprite's); a real
                -- overflow peer slides across a ledge and has no ground to separate from.
                if pinned and remote.act and remote.act >= 0x0c and remote.act <= 0x0f then
                    gui.drawEllipse(screenX + (FRAME_WIDTH_PX // 2) - 8,
                        screenY - pinnedArc + FRAME_HEIGHT_PX - 7, 16, 6,
                        0x00000000, 0xD0000000)
                end
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
            "status: frame=%d connected=%s ready=%s port=%s remotes=%d ghosts=%d drawn=%d "
                .. "clipped=%d overworld=%s inGame=%s",
            frameCounter, tostring(connected), tostring(ready), tostring(currentPort),
            nRemotes, nGhosts, nDrawn, nClipped, tostring(inOverworld()), tostring(session.live)))
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
        local state = getLocalState()
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
                sendLine(encodeLocalState(state.areaId, smoothX, smoothY, state.orientation,
                    state.anim, localGender or "male", localGraphicsId(),
                    r8(sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04)) + 0x2a),
                    r8(sprAddr(r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x04)) + 0x2b),
                    -- movementActionId (pokeemerald include/global.fieldmap.h:246, +0x1C): what
                    -- the engine is currently making this character DO. A ledge hop is a jump
                    -- action, and no amount of watching positions can recover that -- see the
                    -- remote side for why.
                    r8(GOBJECTEVENTS_ADDR + avatarAddrOffset
                        + r8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x05) * OBJECTEVENT_SIZE
                        + 0x1c)))
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
            local spawnSet = tiering.chooseSpawned(smoothAreaId, smoothX, smoothY)
            syncRemoteGhosts(smoothAreaId, spawnSet)
            -- Independent of the drawn tier: a spawned ghost needs this whether or not the
            -- overflow tier is on, so it cannot live inside drawRemotes.
            drawGhostShadows()
            -- TIER TWO: everyone the engine had no room for, painted over the finished frame
            -- so that no peer is ever simply absent. Flag-gated -- see FLAGS.md and
            -- BANDAGES.md. A drawn ghost has no engine occlusion of its own, so it clips
            -- against the panel regions tiering.scanPanel() measures per row, rather than
            -- painting over a text box or menu the way an unclipped overlay would.
            if tiering.drawn then
                drawRemotes(smoothAreaId, smoothX, smoothY, spawnSet)
            elseif COMPARE_TIERS then
                -- Compare mode with the overflow tier off: the loopback ghost, and only it.
                drawRemotes(smoothAreaId, smoothX, smoothY, spawnSet, true)
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
    local ok, err = pcall(runFrame)
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
        frameErrors.lastLogged = frameCounter
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
    -- Three things, and every one of them leaked at some point on 2026-08-18:
    --  * the BRIDGE SOCKET. A core serves exactly one adapter, so a leaked connection makes the
    --    core reject the next load with "busy: this core already has a game attached" -- the port
    --    walk then correctly looks elsewhere, finds nothing, and the adapter runs with no peers.
    --    That cost a long detour debugging an "invisible ghost" that was really no connection.
    --  * the GHOSTS. They are objects in the game; nothing else will ever clear them.
    --  * the LOG FILE, a real OS handle -- leaking it locks the file on disk.
    -- resetBridge() covers the first two (it despawns ghosts as part of dropping the connection).
    pcall(resetBridge)
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
