-- MeshGhost — DEV: what does the game think the tile in front of the player IS? (READ-ONLY)
-- The rod was refused with "not usable here", so either the edited tile is not where the player
-- faces, or its behaviour is not water. This reads the tile the same way the game does and says
-- which.
local GBACKUPMAPLAYOUT, GMAPHEADER = 0x03005dc0, 0x02037318
local GPLAYERAVATAR_ADDR, GOBJECTEVENTS_ADDR, OBJECTEVENT_SIZE = 0x02037590, 0x02037350, 0x24
local NUM_PRIMARY, ID_MASK, BEH_MASK, COL_MASK = 512, 0x03ff, 0x00ff, 0x0c00
local BEH = { [0]="NORMAL", [16]="POND_WATER", [17]="INTERIOR_DEEP_WATER", [18]="DEEP_WATER",
              [19]="WATERFALL", [20]="SOOTOPOLIS_DEEP_WATER", [21]="OCEAN_WATER", [22]="PUDDLE",
              [23]="SHALLOW_WATER", [2]="TALL_GRASS" }
local function u8(a) return memory.read_u8(a) end
local function u16(a) return memory.read_u16_le(a) end
local function s16(a) return memory.read_s16_le(a) end
local function u32(a) return memory.read_u32_le(a) end
local function s32(a) return memory.read_s32_le(a) end

local f = io.open("C:/dev/MeshGhost/dev-scripts/tile-inspect.log", "w")
local function log(m) console.log(m) if f then f:write(m, "\n") f:flush() end end

local function behaviourOf(id)
    local layout = u32(GMAPHEADER + 0x00)
    local ts, idx
    if id < NUM_PRIMARY then ts, idx = u32(layout + 0x10), id
    else ts, idx = u32(layout + 0x14), id - NUM_PRIMARY end
    if ts == 0 then return nil end
    local attrs = u32(ts + 0x10)
    if attrs == 0 then return nil end
    return u16(attrs + idx * 2) & BEH_MASK
end

local DIRD = { [1]={0,1}, [2]={0,-1}, [3]={-1,0}, [4]={1,0} }
local frames, done = 0, false
MESHGHOST_DEV_TICK = function()
    if done then return end
    frames = frames + 1
    if frames < 420 then return end -- after watertile has placed its tile
    done = true
    local objId = u8(GPLAYERAVATAR_ADDR + 0x05)
    local a = GOBJECTEVENTS_ADDR + objId * OBJECTEVENT_SIZE
    local dir = u8(a + 0x18) & 0x0f
    local px, py = s16(a + 0x10), s16(a + 0x12)
    local width = s32(GBACKUPMAPLAYOUT + 0x00)
    local map = u32(GBACKUPMAPLAYOUT + 0x08)
    log(string.format("player at (%d,%d) facing %d; backup map %dw at %08X", px, py, dir, width, map))
    -- The tile under the player and all four neighbours, so a facing/coordinate mistake is visible
    -- rather than inferred.
    for _, probe in ipairs({ {0,0,"under"}, {0,1,"south"}, {0,-1,"north"}, {-1,0,"west"}, {1,0,"east"} }) do
        local x, y = px + probe[1], py + probe[2]
        local raw = u16(map + (x + width * y) * 2)
        local id = raw & ID_MASK
        local b = behaviourOf(id)
        log(string.format("  %-5s (%3d,%3d) raw=%04X id=%4d collision=%d behaviour=%s%s",
            probe[3], x, y, raw, id, (raw & COL_MASK) >> 10,
            tostring(b), b and BEH[b] and (" (" .. BEH[b] .. ")") or ""))
    end
    if f then f:close() f = nil end
end
