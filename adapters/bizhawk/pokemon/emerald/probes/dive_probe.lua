-- MeshGhost — Pokémon Emerald: what DIVING does to a character (PROBE, never shipped)
--
-- WHY
-- Underwater is not a variant of surfing. Surfing spawns a companion sprite under the rider;
-- diving warps to a separate map, swaps the player's graphic, and starts a BOBBING driver — a
-- dummy invisible sprite whose callback nudges the rider's own `y2` up and down
-- (`StartUnderwaterSurfBlobBobbing`, src/field_effect_helpers.c:1150). None of the surf-blob work
-- covers any of that, and nothing about an underwater peer has ever been seen on screen
-- (`agent_docs/unverified.md`, 2026-08-21).
--
-- So this reads the real thing while the user dives: what the player becomes, what the engine
-- creates alongside, and how far and how often the bob actually moves — the three facts each
-- self-drawn tier needs before it can reproduce any of it.
--
-- WHAT IT PRINTS
--   * one CHANGE line whenever the player's graphicsId, avatar flags, map, or fieldEffectSpriteId
--     changes — so the walk -> surf -> dive -> emerge transitions each leave a mark;
--   * one BOB line per frame for a bounded window after the player goes underwater, carrying the
--     rider's `y2` and the driver sprite's data slots, which is the curve itself rather than a
--     claim about it;
--   * one GHOST line per change for each of OUR ghosts (object events with localId 255), so
--     "the peer became a diver" and "our copy did not" are on the same timeline.
--
-- ADDRESSES, from our own make-compare-verified pokeemerald build, same as surfblob_probe.lua:
--   gPlayerAvatar   02037590  { flags 0x00, spriteId 0x04, objectEventId 0x05 }
--                             (struct PlayerAvatar, include/global.fieldmap.h:342)
--   gObjectEvents   02037350  stride 0x24; graphicsId 0x05, localId 0x08, spriteId 0x04,
--                             fieldEffectSpriteId 0x1A
--   gSprites        02020630  stride 0x44; callback 0x1C, pos1 0x20, pos2 0x24, data[0] 0x2E
--   gSaveBlock1Ptr  03005D8C  { mapGroup 0x04, mapNum 0x05 }
--   PLAYER_AVATAR_FLAG_UNDERWATER = 1 << 4   (include/global.fieldmap.h:292)
--   OBJ_EVENT_GFX_BRENDAN_UNDERWATER 111 / _MAY_UNDERWATER 112  (agent_docs/verified.md 2026-08-18)
--
-- COST. One read set per frame; a write only on a change, plus a bounded per-frame window while
-- underwater. Buffered and flushed every 60 lines — never console.log, which lags the emulator.
--
-- HOW TO RUN
--   Add this file to dev-scripts/bizhawk-dev-loader-emerald.target, then surf to a dive spot and
--   dive. It writes probes/dive_probe_<date>.log and says so in the console.

local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
local SAVEBLOCK1PTR = 0x03005d8c
local FLAG_UNDERWATER = 0x10
local GHOST_LOCAL_ID = 255
local BOB_WINDOW_FRAMES = 240
local REFLECTION_CB = 0x081540a8 + 1   -- UpdateObjectReflectionSprite (pokeemerald.sym)
-- Beside this probe, never an absolute path: this repo is public and a home directory must not
-- appear in a tracked file (CLAUDE.md). scriptDir is resolved above.
local SHOT_DIR = nil   -- set after scriptDir exists, below
local SHOT_FRAMES = 24                  -- how many frames to photograph after a tile range changes   -- four seconds of the curve, then it stops writing per-frame

local function r8(a) return memory.read_u8(a) end
local function r16(a) return memory.read_u16_le(a) end
local function r32(a) return memory.read_u32_le(a) end
local function rs16(a) return memory.read_s16_le(a) end

local function sprAddr(id) return GSPRITES_ADDR + id * SPRITE_SIZE end
local function objAddr(id) return GOBJECTEVENTS_ADDR + id * OBJECTEVENT_SIZE end

local BS = string.char(92) -- a literal backslash, BUILT rather than escaped: this
-- emulator build's Lua rejects the escaped form, and it cost ripple_probe.lua a load
-- failure the same way (2026-08-21, dev-loader log).
local scriptDir = (debug.getinfo(1, "S").source:sub(2)
    :match("^(.*)[/" .. BS .. "][^/" .. BS .. "]*$") or ".")
SHOT_DIR = scriptDir .. "/shots"
local stamp = os.date("%Y%m%d_%H%M%S")
local logPath = scriptDir .. "/dive_probe_" .. stamp .. ".log"
local fh = io.open(logPath, "w")
local pending, frame = 0, 0

local function say(line)
    if not fh then return end
    fh:write(line .. "\n")
    pending = pending + 1
    if pending >= 60 then fh:flush() pending = 0 end
end

console.log("MeshGhost dive probe: writing " .. logPath)
say("# frame | what")

-- A sprite, described in the fields that matter for a bob: where it is, what drives it, what it
-- carries. data[0..2] are the driver's own slots (sSpriteId / sBobY / sTimer).
local function spriteLine(id)
    if not id or id >= 64 then return "spr=none" end
    local s = sprAddr(id)
    return string.format("spr=%d cb=%08X pos1=(%d,%d) pos2=(%d,%d) anim=%d/%d img=%08X "
        .. "oam=%04X/%04X/%04X d0=%d d1=%d d2=%d f3e=%02X f3f=%02X",
        id, r32(s + 0x1c), rs16(s + 0x20), rs16(s + 0x22), rs16(s + 0x24), rs16(s + 0x26),
        r8(s + 0x2a), r8(s + 0x2b), r32(s + 0x0c),
        r16(s + 0x00), r16(s + 0x02), r16(s + 0x04),
        r16(s + 0x2e), r16(s + 0x30), r16(s + 0x32), r8(s + 0x3e), r8(s + 0x3f))
end

local last = {}
local bobUntil = nil
local shootUntil = nil

local function tick()
    -- The EMULATOR's frame number, not a private counter: the screenshot filenames, the adapter's
    -- swap lines and these lines must all be laid on ONE timeline, or a garbled shot cannot be
    -- matched to what the sprite held that frame -- which is exactly the correlation that failed
    -- before this change.
    frame = emu.framecount()
    local sb1 = r32(SAVEBLOCK1PTR)
    if sb1 < 0x02000000 then return end
    local mapG, mapN = r8(sb1 + 0x04), r8(sb1 + 0x05)
    local flags = r8(GPLAYERAVATAR_ADDR)
    local objId = r8(GPLAYERAVATAR_ADDR + 0x05)
    if objId >= 16 then return end
    local o = objAddr(objId)
    local gfx = r8(o + 0x05)
    local fldSpr = r8(o + 0x1a)
    local sprId = r8(o + 0x04)

    -- movementActionId (ObjectEvent +0x1C) is in the key too: the surf START is a HELD MOVEMENT
    -- (GetJumpSpecialMovementAction, src/field_effect.c:3050), and a transition read only through
    -- graphicsId cannot see it happen at all.
    local act = r8(o + 0x1c)
    local key = string.format("%d|%02X|%d.%d|%d|%02X", gfx, flags, mapG, mapN, fldSpr, act)
    if key ~= last.player then
        last.player = key
        say(string.format("%6d | PLAYER gfx=%d act=%02X flags=%02X%s map=g%d.n%d obj=%d "
            .. "tile=(%d,%d) %s || fldeff %s",
            frame, gfx, act, flags, (flags & FLAG_UNDERWATER) ~= 0 and " UNDERWATER" or "",
            mapG, mapN, objId, r16(o + 0x10), r16(o + 0x12),
            spriteLine(sprId), spriteLine(fldSpr)))
        if (flags & FLAG_UNDERWATER) ~= 0 then
            bobUntil = frame + BOB_WINDOW_FRAMES
            say(string.format("%6d | BOB WINDOW opens for %d frames", frame, BOB_WINDOW_FRAMES))
        end
    end

    -- The curve itself. The rider's y2 is what moves; the driver's slots say why.
    if bobUntil and frame <= bobUntil then
        say(string.format("%6d | BOB rider_y2=%d %s", frame, rs16(sprAddr(sprId) + 0x26),
            spriteLine(fldSpr)))
    elseif bobUntil and frame > bobUntil then
        bobUntil = nil
        say(string.format("%6d | BOB WINDOW closed", frame))
        if fh then fh:flush() end
    end

    -- THE PLAYER'S OWN (graphic, animation) PAIR, EVERY FRAME IT CHANGES.
    --
    -- Three fixes in a row assumed the incoherent pair on the wire was manufactured by the sender.
    -- That is an inference; this is the measurement. If the PLAYER is genuinely in `gfx=3
    -- anim=20/4` for a frame, then the pair is real, the wire is honest, and the fix belongs on the
    -- consumers instead. Logged per change, not per frame.
    do
        local ps = sprAddr(sprId)
        local pk = string.format("%d|%d|%d", gfx, r8(ps + 0x2a), r8(ps + 0x2b))
        if last.playerPair ~= pk then
            last.playerPair = pk
            say(string.format("%6d | PAIR player gfx=%d anim=%d/%d act=%02X", frame, gfx,
                r8(ps + 0x2a), r8(ps + 0x2b), act))
        end
    end

    -- WHO ELSE IS DRAWING FROM OUR TILES.
    --
    -- A ghost that goes grey is drawing from OBJ VRAM somebody else owns, and there are only two
    -- ways that happens: nobody wrote our range, or somebody else is writing it. This answers the
    -- second directly -- for every ghost sprite, scan the other live sprites for one whose tile
    -- number lands inside the ghost's own range. One line per change, so a clash that lasts a
    -- single frame is still recorded and a stable frame costs nothing.
    --
    -- 64 sprite reads a frame: a probe's budget, not an adapter's (_template/probes.md).
    for i = 0, 15 do
        local a = objAddr(i)
        if i ~= objId and (r8(a) & 0x01) == 1 and r8(a + 0x08) == GHOST_LOCAL_ID then
            local gsp = r8(a + 0x04)
            local gs = sprAddr(gsp)
            local gStart = r16(gs + 0x04) & 0x3ff
            -- Frame size from the graphic: 32x32 is 16 tiles, 16x32 is 8. Read from the sprite's
            -- own shape/size bits rather than assumed, so a swap mid-flight is measured honestly.
            local shape = (r16(gs + 0x00) >> 14) & 3
            local sz = (r16(gs + 0x02) >> 14) & 3
            local nTiles = (shape == 0 and sz == 2) and 16 or 8  -- square 32x32, else 16x32
            -- A REFLECTION IS NOT A CLASH. UpdateObjectReflectionSprite (08154 0A8) copies the
            -- character's own tileNum every frame -- sharing the tiles IS how a reflection works --
            -- so every ghost reported one and the signal was pure noise until this excluded it.
            local clash = nil
            for j = 0, 63 do
                if j ~= gsp then
                    local o = sprAddr(j)
                    if (r8(o + 0x3e) & 0x01) == 1 and r32(o + 0x1c) ~= REFLECTION_CB then
                        local t = r16(o + 0x04) & 0x3ff
                        if t >= gStart and t < gStart + nTiles then clash = j break end
                    end
                end
            end
            local ck = string.format("%d|%d|%d|%s", gsp, gStart, nTiles, tostring(clash))
            if last["clash" .. i] ~= ck then
                -- PHOTOGRAPH THE SWAP. The reported glitch is a flash of a few frames on a real
                -- sprite, which no struct field describes -- but a screenshot sees the spawned
                -- tier, because it is genuine hardware. A tile range changing is exactly the
                -- moment a graphic swap lands, so that is the trigger.
                shootUntil = frame + SHOT_FRAMES
                last["clash" .. i] = ck
                say(string.format("%6d | TILES obj=%d spr=%d range=%d..%d clash=%s%s",
                    frame, i, gsp, gStart, gStart + nTiles - 1, tostring(clash),
                    clash and (" (" .. spriteLine(clash) .. ")") or ""))
            end
        end
    end

    -- IS THE GHOST DRAWING THE PIXELS IT IS SUPPOSED TO BE DRAWING?
    --
    -- "It looks grey" is a claim about VRAM, and VRAM can be checked against the ROM directly --
    -- which beats every pixel heuristic tried before it (a grey-pixel count over the whole screen
    -- turned out to be measuring the dialogue box). For each ghost: resolve the frame its own
    -- sprite says it is showing, and compare the first tiles of its OBJ VRAM range against the
    -- ROM image that frame names. A mismatch means it is drawing something nobody loaded.
    --
    -- Reads are the budget here: 8 words of ROM against 8 of VRAM per ghost per frame, and a line
    -- only when the verdict CHANGES.
    for i = 0, 15 do
        local a = objAddr(i)
        if i ~= objId and (r8(a) & 0x01) == 1 and r8(a + 0x08) == GHOST_LOCAL_ID then
            local gs = sprAddr(r8(a + 0x04))
            local animsP, imagesP = r32(gs + 0x08), r32(gs + 0x0c)
            local verdict
            if animsP < 0x08000000 or imagesP < 0x08000000 then
                verdict = "no-pointers"
            else
                local ap = r32(animsP + r8(gs + 0x2a) * 4)
                if ap < 0x08000000 then
                    verdict = "anim-out-of-range"
                else
                    local fr = r32(ap + r8(gs + 0x2b) * 4) & 0xffff
                    local src = r32(imagesP + fr * 8)
                    if src < 0x08000000 then
                        verdict = "frame-out-of-range"
                    else
                        local dst = 0x06010000 + (r16(gs + 0x04) & 0x3ff) * 32
                        verdict = "ok"
                        -- The whole frame, not its first tile: a 32x32 graphic owns 16 tiles and
                        -- the first version checked 8 words -- one tile -- so garbage in the other
                        -- fifteen read as "ok".  Size from the sprite's own shape/size bits.
                        local shp = (r16(gs + 0x00) >> 14) & 3
                        local szb = (r16(gs + 0x02) >> 14) & 3
                        local words = (shp == 0 and szb == 2) and 128 or 64  -- 32x32 : 16x32
                        local badAt = nil
                        for k = 0, words - 1 do
                            if r32(dst + k * 4) ~= r32(src + k * 4) then
                                verdict = "VRAM MISMATCH"
                                badAt = k
                                break
                            end
                        end
                        -- THE BYTES NAME THE WRITER. On a mismatch, log where it starts and what
                        -- is actually there against what should be -- garbage from a Pokemon pic,
                        -- a stale walker frame and an engine-freed range all look different.
                        if badAt then
                            local got, want = {}, {}
                            for k = badAt, math.min(badAt + 3, words - 1) do
                                got[#got + 1] = string.format("%08X", r32(dst + k * 4))
                                want[#want + 1] = string.format("%08X", r32(src + k * 4))
                            end
                            say(string.format(
                                "%6d | BYTES obj=%d word %d/%d: got %s want %s (dstTile=%d)",
                                frame, i, badAt, words, table.concat(got, " "),
                                table.concat(want, " "), r16(gs + 0x04) & 0x3ff))
                        end
                    end
                end
            end
            if last["vram" .. i] ~= verdict then
                last["vram" .. i] = verdict
                say(string.format("%6d | PIXELS obj=%d %s (anim=%d/%d gfx=%d)", frame, i, verdict,
                    r8(gs + 0x2a), r8(gs + 0x2b), r8(a + 0x05)))
                if verdict ~= "ok" then shootUntil = frame + SHOT_FRAMES end
            end
        end
    end

    -- THE HARDWARE'S OWN STORY. FLAGS.md's anim-trace note, learned on fishing: when every
    -- struct field agrees and the screen does not, the answer is in the REAL OAM at 0x07000000 --
    -- the entries the PPU actually drew from. For the ghost's tile range, list every entry that
    -- points into it: a clean 32-wide character is its subsprite pieces; a scrambled one is
    -- whatever this prints instead. One line per CHANGE of the whole signature.
    do
        local ga = objAddr(15)
        if (r8(ga) & 0x01) == 1 and r8(ga + 0x08) == GHOST_LOCAL_ID then
            local gs2 = sprAddr(r8(ga + 0x04))
            local t0 = r16(gs2 + 0x04) & 0x3ff
            -- TRUE OVERLAP, both directions. The first version required the entry's STARTING tile
            -- to fall in the ghost's range, which is blind to a big sprite that starts below it
            -- and spans across -- exactly the shape of a 64x64 Pokemon picture. Sizes from the
            -- shape/size bits (GBATEK's OBJ size table), 1D mapping.
            local SIZES = {
                [0] = { [0] = 1, [1] = 4, [2] = 16, [3] = 64 },   -- square: 8,16,32,64
                [1] = { [0] = 2, [1] = 8, [2] = 16, [3] = 32 },   -- wide
                [2] = { [0] = 2, [1] = 8, [2] = 16, [3] = 32 },   -- tall
            }
            local sig = {}
            for e = 0, 127 do
                local a0 = r16(0x07000000 + e * 8)
                local a1 = r16(0x07000002 + e * 8)
                local a2 = r16(0x07000004 + e * 8)
                local tl = a2 & 0x3ff
                local shp = (a0 >> 14) & 3
                local n = (SIZES[shp] or SIZES[0])[(a1 >> 14) & 3] or 1
                if (a0 & 0x0300) ~= 0x0200 and tl < t0 + 16 and tl + n > t0 then
                    sig[#sig + 1] = string.format("e%d:%04X/%04X/%04X(n%d)", e, a0, a1, a2, n)
                end
            end
            -- The allocator bitmap over our neighbourhood, one hex digit per 4 tiles, so "who
            -- believed these tiles were free" is on the same timeline as who drew from them.
            do
                local bm = {}
                -- sSpriteTileAllocBitmap 02021B3C (the adapter's own cited constant); byte k
                -- covers tiles 8k..8k+7, so bytes 10..17 span tiles 80..143.
                for k = 10, 17 do bm[#bm + 1] = string.format("%02X", r8(0x02021b3c + k)) end
                sig[#sig + 1] = "bm80-144:" .. table.concat(bm)
            end
            local key = table.concat(sig, " ")
            if last.oamSig ~= key then
                last.oamSig = key
                say(string.format("%6d | OAM ghost tiles %d..: %s", frame, t0,
                    #sig > 0 and key or "(no entry)"))
            end
        end
    end

    -- THE BANNER'S WINDOW. The show-mon banner is revealed by hardware window 0 (WIN0H/WIN0V,
    -- animated per frame -- field_effect.c:2617-2668), so the 1:1 clip for the painted tier is
    -- that rectangle, not the tilemap. WIN0H/V are WRITE-ONLY on hardware; whether this
    -- emulator serves reads anyway is exactly what this measures. DISPCNT and WININ are
    -- readable regardless.
    do
        local wk = string.format("%04X %04X %04X %04X", r16(0x04000040), r16(0x04000044),
            r16(0x04000048), r16(0x04000000))
        if last.winRegs ~= wk then
            last.winRegs = wk
            say(string.format("%6d | WINREG win0h/win0v/winin/dispcnt = %s", frame, wk))
        end
    end

    -- EVERY LIVE ENTRY IN THE ADAPTER'S OAM RANGE (64..127), per change. The dismount leaves
    -- static garbage entries and a missing body; which SLOTS hold what is the whole question.
    do
        local hsig = {}
        for e = 64, 127 do
            local a0 = r16(0x07000000 + e * 8)
            local a1 = r16(0x07000002 + e * 8)
            local a2 = r16(0x07000004 + e * 8)
            -- skip the engine's dummy encoding (off-screen 8x8 at y=0xA0)
            if not (a0 == 0x00a0 and a1 == 0x0130) then
                hsig[#hsig + 1] = string.format("e%d:%04X/%04X/%04X", e, a0, a1, a2)
            end
        end
        local hk = table.concat(hsig, " ")
        if last.hwSig ~= hk then
            last.hwSig = hk
            say(string.format("%6d | HWOAM %s", frame, #hsig > 0 and hk or "(none)"))
        end
    end

    if shootUntil and frame <= shootUntil then
        pcall(function() client.screenshot(string.format("%s/g_%06d.png", SHOT_DIR, frame)) end)
    end

    -- Our ghosts, on the same timeline: active, localId 255, not the player's slot.
    for i = 0, 15 do
        if i ~= objId then
            local a = objAddr(i)
            if (r8(a) & 0x01) == 1 and r8(a + 0x08) == GHOST_LOCAL_ID then
                local gs = sprAddr(r8(a + 0x04))
                local gk = string.format("%d|%d|%d|%d/%d|%02X", r8(a + 0x05), r8(a + 0x04),
                    r8(a + 0x1a), r8(gs + 0x2a), r8(gs + 0x2b), r8(a + 0x1c))
                if last[i] ~= gk then
                    last[i] = gk
                    say(string.format("%6d | GHOST obj=%d gfx=%d act=%02X tile=(%d,%d) %s "
                        .. "|| fldeff %s",
                        frame, i, r8(a + 0x05), r8(a + 0x1c), r16(a + 0x10), r16(a + 0x12),
                        spriteLine(r8(a + 0x04)), spriteLine(r8(a + 0x1a))))
                end
            elseif last[i] then
                last[i] = nil
                say(string.format("%6d | GHOST obj=%d gone", frame, i))
            end
        end
    end
end

MESHGHOST_DEV_TICK = tick
MESHGHOST_DEV_UNLOAD = function()
    if fh then fh:flush() fh:close() fh = nil end
end

if not MESHGHOST_DEV_LOADER then
    while true do tick() emu.frameadvance() end
end
