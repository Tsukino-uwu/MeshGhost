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
local SHOT_DIR = "C:/Users/nyden/AppData/Local/Temp/claude/c--dev-MeshGhost/8695574c-5fb1-4f61-aa97-ac8f67793533/scratchpad/glitch"
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
    frame = frame + 1
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
            local nTiles = (shape == 0 and sz == 3) and 16 or ((shape == 2 and sz == 2) and 8 or 8)
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
                        for k = 0, 7 do
                            if r32(dst + k * 4) ~= r32(src + k * 4) then
                                verdict = "VRAM MISMATCH" break
                            end
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
