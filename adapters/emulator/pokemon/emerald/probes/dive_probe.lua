-- MeshGhost — Pokémon Emerald: what diving does to a character (dev tool, read-only, never shipped). Dive from a
-- dive spot; it logs on change the player (graphic, avatar flags, map, field-effect sprite, action, its graphic and
-- animation pair), each of our ghosts with its tile range, VRAM against ROM and OAM entries, and the window
-- registers; per frame, a BOB window once underwater and screenshots to shots/ after a ghost's tiles change or go bad.

local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
local SAVEBLOCK1PTR = 0x03005d8c
local FLAG_UNDERWATER = 0x10 -- the decomp's bit, unmeasured; the PLAYER lines while diving test it
local GHOST_LOCAL_ID = 255
local BOB_WINDOW_FRAMES = 240 -- four seconds of the curve, then it stops writing per frame
local REFLECTION_CB = 0x081540a8 + 1   -- UpdateObjectReflectionSprite
local SHOT_DIR = nil   -- set after scriptDir exists, below
local SHOT_FRAMES = 24                  -- how many frames to photograph after a tile range changes

local function r8(a) return memory.read_u8(a) end
local function r16(a) return memory.read_u16_le(a) end
local function r32(a) return memory.read_u32_le(a) end
local function rs16(a) return memory.read_s16_le(a) end

local function sprAddr(id) return GSPRITES_ADDR + id * SPRITE_SIZE end
local function objAddr(id) return GOBJECTEVENTS_ADDR + id * OBJECTEVENT_SIZE end

local BS = string.char(92) -- a backslash built, not escaped, so no tool writing this file can drop one
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

-- A sprite in the fields that matter for a bob; d0..d2 are its driver's first data slots.
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
    -- The emulator's frame number, so screenshots, the adapter's lines and these share one timeline.
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

    -- movementActionId is in the key: a surf start is a held movement, which graphicsId alone cannot see.
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

    if bobUntil and frame <= bobUntil then
        say(string.format("%6d | BOB rider_y2=%d %s", frame, rs16(sprAddr(sprId) + 0x26),
            spriteLine(fldSpr)))
    elseif bobUntil and frame > bobUntil then
        bobUntil = nil
        say(string.format("%6d | BOB WINDOW closed", frame))
        if fh then fh:flush() end
    end

    -- The player's own (graphic, animation) pair on change: a pair the player is never in is not real.
    do
        local ps = sprAddr(sprId)
        local pk = string.format("%d|%d|%d", gfx, r8(ps + 0x2a), r8(ps + 0x2b))
        if last.playerPair ~= pk then
            last.playerPair = pk
            say(string.format("%6d | PAIR player gfx=%d anim=%d/%d act=%02X", frame, gfx,
                r8(ps + 0x2a), r8(ps + 0x2b), act))
        end
    end

    -- Who else draws from a ghost's tiles: any other live sprite whose tile number lands in the ghost's range.
    for i = 0, 15 do
        local a = objAddr(i)
        if i ~= objId and (r8(a) & 0x01) == 1 and r8(a + 0x08) == GHOST_LOCAL_ID then
            local gsp = r8(a + 0x04)
            local gs = sprAddr(gsp)
            local gStart = r16(gs + 0x04) & 0x3ff
            local shape = (r16(gs + 0x00) >> 14) & 3
            local sz = (r16(gs + 0x02) >> 14) & 3
            local nTiles = (shape == 0 and sz == 2) and 16 or 8  -- square 32x32, else 16x32
            -- A reflection draws its character's own tiles, so it is not a clash.
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
                -- A tile range changes when a graphic swap lands; a screenshot sees the spawned tier.
                shootUntil = frame + SHOT_FRAMES
                last["clash" .. i] = ck
                say(string.format("%6d | TILES obj=%d spr=%d range=%d..%d clash=%s%s",
                    frame, i, gsp, gStart, gStart + nTiles - 1, tostring(clash),
                    clash and (" (" .. spriteLine(clash) .. ")") or ""))
            end
        end
    end

    -- Each ghost's OBJ VRAM against the ROM frame its sprite names; a mismatch is pixels nobody loaded.
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
                        -- The whole frame, sized from the sprite's own shape/size bits.
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
                        -- The bytes name the writer: a Pokémon picture, a stale walker frame and a freed
                        -- range all look different.
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

    -- The real OAM entries drawing from the slot-15 ghost's tiles: when every struct agrees and the screen does not.
    do
        local ga = objAddr(15)
        if (r8(ga) & 0x01) == 1 and r8(ga + 0x08) == GHOST_LOCAL_ID then
            local gs2 = sprAddr(r8(ga + 0x04))
            local t0 = r16(gs2 + 0x04) & 0x3ff
            -- Any overlap, so a big sprite starting below the range counts; tile counts per GBATEK's OBJ sizes, 1D.
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
            -- The tile allocator's bitmap beside it: who believed these tiles were free.
            do
                local bm = {}
                -- sSpriteTileAllocBitmap; byte k covers tiles 8k..8k+7, so bytes 10..17 span tiles 80..143.
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

    -- The banner's window: WIN0H/WIN0V are write-only on hardware, so a read may be junk; DISPCNT and WININ read fine.
    do
        local wk = string.format("%04X %04X %04X %04X", r16(0x04000040), r16(0x04000044),
            r16(0x04000048), r16(0x04000000))
        if last.winRegs ~= wk then
            last.winRegs = wk
            say(string.format("%6d | WINREG win0h/win0v/winin/dispcnt = %s", frame, wk))
        end
    end

    -- Every live entry in the adapter's OAM range (64..127), on change.
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

    -- Our ghosts: active, localId 255, not the player's slot.
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
