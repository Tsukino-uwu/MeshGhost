-- MeshGhost — Pokémon Emerald: who has a shadow and who has dust (dev tool, read-only, vanilla only, never shipped).
-- Finds them by what they are: each in-use sprite whose images pointer is a shadow or landing-dust field effect
-- template's, logged on any change with its offset from the player's sprite, subpriority, priority, palette, tile,
-- visibility and callback. Run it beside the adapter with a ghost hopping (acro_hop.lua makes one).

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
                -- Whose effect: near 0,0 is the player's, ~32px out the loopback ghost's, which stands to the side.
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
