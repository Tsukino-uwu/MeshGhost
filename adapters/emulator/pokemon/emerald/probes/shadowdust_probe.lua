-- MeshGhost — Pokémon Emerald: who has a shadow and who has dust (PROBE, never shipped)
--
-- WHY
-- Two questions about a hopping ghost that a screenshot answers badly and a memory read answers
-- exactly:
--
--   1. Does the REAL shadow sprite the adapter builds for a spawned ghost actually exist, sit
--      where the engine would put it, and carry the engine's subpriority? It was disabled after it
--      reset the game (the NULL callback, `pitfalls.md` 2026-08-21), and re-enabling it deserves an
--      observation rather than "it did not crash this time".
--   2. Does the engine spawn its OWN landing dust for a ghost? The adapter paints dust over the
--      spawned ghost on the assumption that the engine's is there but hidden behind our painted
--      shadow. If the engine's is really there, the painted one is a bandage that can come out; if
--      it is not, the painted one is the only dust that tier will ever have. Nobody has looked.
--
-- HOW IT TELLS THEM APART, without knowing which sprite belongs to whom: a shadow and a dust are
-- ordinary sprites drawing from a field effect's own ROM `images` pointer, so every in-use sprite
-- is compared against those five pointers by value. That is the same describe-it-do-not-memorise
-- discipline the rest of this folder uses.
--
-- ADDRESSES, from our own make-compare-verified pokeemerald build:
--   gSprites      02020630  stride 0x44 { oam 0x00, images 0x0C, pos1 0x20, pos2 0x24,
--                                         callback 0x1C, flags 0x3E, subpriority 0x43 }
--   gPlayerAvatar 02037590  { spriteId 0x04, objectEventId 0x05 }
--   gObjectEvents 02037350  stride 0x24 { movementActionId 0x1C }
--   gSpriteCoordOffsetX/Y 03005dec / 03005dee
--   Field effect sprite templates (pokeemerald.map), `images` at +0x0C:
--     ShadowSmall 0850C9FC · ShadowMedium 0850CA14 · ShadowLarge 0850CA2C
--     ShadowExtraLarge 0850CA44 · GroundImpactDust 0850CCA0
--
-- COST. One pass over 64 sprites per frame, all plain reads, and it writes a line only when the
-- set of shadows/dusts on screen CHANGES. A probe can break what it measures (`_template/probes.md`)
-- so it stays quiet by default: nothing is drawn, nothing is written to the game.
--
-- HOW TO RUN
--   Add this file to dev-scripts/bizhawk-dev-loader-emerald.target alongside the adapter, get a
--   ghost hopping (probes/acro_hop.lua does it without anyone holding a button), and read
--   probes/shadowdust_probe_<date>.log.

local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local GSPRITECOORDOFFSETX_ADDR = 0x03005dec
local GSPRITECOORDOFFSETY_ADDR = 0x03005dee

local function r8(a) return memory.read_u8(a) end
local function r16(a) return memory.read_u16_le(a) end
local function r32(a) return memory.read_u32_le(a) end
local function rs16(a) return memory.read_s16_le(a) end
local function sprAddr(i) return GSPRITES_ADDR + i * SPRITE_SIZE end

local TEMPLATES = {
    { name = "shadow.S", addr = 0x0850c9fc },
    { name = "shadow.M", addr = 0x0850ca14 },
    { name = "shadow.L", addr = 0x0850ca2c },
    { name = "shadow.XL", addr = 0x0850ca44 },
    { name = "dust", addr = 0x0850cca0 },
}

-- Resolved once: a template's images pointer is ROM data and does not move while the game runs.
local WANTED = {}
for _, t in ipairs(TEMPLATES) do
    local images = r32(t.addr + 0x0c)
    if images ~= 0 then WANTED[images] = t.name end
end

local logPath = ("%s/shadowdust_probe_%s.log"):format(
    (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."),
    os.date("%Y%m%d_%H%M%S"))
local logFile = io.open(logPath, "a")
local function say(s)
    console.log("shadowdust: " .. s)
    if logFile then logFile:write(s .. string.char(10)) logFile:flush() end
end

local n = 0
for _ in pairs(WANTED) do n = n + 1 end
say(("watching %d field-effect image pointers -- hop and see who gets a shadow and dust"):format(n))

local last = nil

local function tick()
    local pSpr = sprAddr(r8(GPLAYERAVATAR_ADDR + 0x04))
    local px, py = rs16(pSpr + 0x20), rs16(pSpr + 0x22)
    local act = r8(GOBJECTEVENTS_ADDR + r8(GPLAYERAVATAR_ADDR + 0x05) * OBJECTEVENT_SIZE + 0x1c)

    local parts = {}
    for i = 0, 63 do
        local d = sprAddr(i)
        if (r8(d + 0x3e) & 0x01) == 1 then
            local what = WANTED[r32(d + 0x0c)]
            if what then
                -- dx/dy against the PLAYER's own sprite is what says whose effect this is: the
                -- loopback ghost stands a couple of tiles to the side, so anything near 0,0 is the
                -- player's and anything ~32px out is the ghost's.
                parts[#parts + 1] = ("%s spr=%d dx=%d dy=%d sub=%d pri=%d pal=%d tile=%d "
                    .. "vis=%s cb=%08X")
                    :format(what, i, rs16(d + 0x20) - px, rs16(d + 0x22) - py,
                        r8(d + 0x43), (r16(d + 0x04) >> 10) & 3,
                        (r16(d + 0x04) >> 12) & 0x0f, r16(d + 0x04) & 0x3ff,
                        tostring((r8(d + 0x3e) & 0x04) == 0), r32(d + 0x1c))
            end
        end
    end

    local key = table.concat(parts, " | ")
    if key ~= last then
        last = key
        say(("act=%02X coordOff=%d,%d  %s"):format(act,
            rs16(GSPRITECOORDOFFSETX_ADDR), rs16(GSPRITECOORDOFFSETY_ADDR),
            key == "" and "(nothing)" or key))
    end
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function() if logFile then logFile:close() logFile = nil end end
else
    while true do tick() emu.frameadvance() end
end
