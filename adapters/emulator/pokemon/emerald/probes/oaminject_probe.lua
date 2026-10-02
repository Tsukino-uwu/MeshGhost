-- MeshGhost — Emerald: park hardware sprites above gOamLimit and let the PPU draw them (dev tool, writes shadow OAM).
-- A copy of the player two tiles up, borrowing its tile and palette; released on unload, and a map load clears any.
local GMAIN_ADDR = 0x030022c0
local OAMBUF_ADDR = GMAIN_ADDR + 0x038
local GOAMLIMIT_ADDR = 0x02021b38
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local GPLAYERAVATAR_ADDR = 0x02037590
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
local ENTRY_SIZE = 8

-- The first slot above the overworld's gOamLimit; 120..127 stay free, as Emerald parks its wireless indicator at 125.
-- From 64 up, a copy also loses overlap ties to the engine's own 0..63.
local SLOT = 64
local SLOT_ADDR = OAMBUF_ADDR + SLOT * ENTRY_SIZE

local OFFSET_Y_PX = -32

-- gDummyOamData, the engine's own hidden entry: releasing with it leaves a slot like one the engine never used.
local DUMMY_A0, DUMMY_A1, DUMMY_A2 = 0x00a0, 0x0130, 0x0c00

local REPORT_FRAMES = 60

-- Subtraction switches. Set them explicitly every run: the dev loader shares one Lua environment, so an unset global
-- keeps the previous run's value.
local NO_WRITE = MESHGHOST_OAMINJECT_NO_WRITE and true or false   -- scan and log, write nothing
local NO_SCAN = MESHGHOST_OAMINJECT_NO_SCAN and true or false     -- write a fixed entry, never scan
local QUIET = MESHGHOST_OAMINJECT_QUIET and true or false         -- no per-second log line

-- How many copies, 1..56 (oamBuffer[64..119]), set explicitly every run too: at one ghost every tier looks free, so
-- this measures a slope.
local COUNT = tonumber(MESHGHOST_OAMINJECT_COUNT) or 1
if COUNT < 1 then COUNT = 1 end
if COUNT > 56 then COUNT = 56 end

local function scriptDir()
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
    end
    return "."
end

local logfile = io.open(scriptDir() .. "/oaminject_probe.log", "w")

-- say() is for the few lines at load; log() is the per-frame path and never reaches the console, a GUI append.
local function log(msg)
    if logfile then logfile:write(msg, string.char(10)) logfile:flush() end
end
local function say(msg)
    console.log(msg)
    log(msg)
end

local function r8(a) return memory.read_u8(a) end
local function r16(a) return memory.read_u16_le(a) end
local function r32(a) return memory.read_u32_le(a) end
local function w16(a, v) memory.write_u16_le(a, v) end

-- The +1 is the Thumb bit. Also the vanilla gate: Archipelago relocates CB2_Overworld, so there nothing is written.
local function inOverworld()
    local cb2 = r32(GMAIN_CALLBACK2_ADDR)
    return cb2 == CB2_OVERWORLD_ADDR or cb2 == CB2_OVERWORLD_ADDR + 1
end

-- The player's screen position exists only in the OAM entry the engine built, so find it by the tile number its sprite
-- names (an OAM index is not stable, its tiles are), in the shadow buffer written into, so both come from one frame.
local function playerEntry()
    local spriteId = r8(GPLAYERAVATAR_ADDR + 0x04)
    if spriteId > 63 then return nil end
    local tile = r16(GSPRITES_ADDR + spriteId * SPRITE_SIZE + 0x04) & 0x3ff
    local limit = r8(GOAMLIMIT_ADDR)
    for i = 0, limit - 1 do
        local e = OAMBUF_ADDR + i * ENTRY_SIZE
        local a0, a1, a2 = r16(e), r16(e + 2), r16(e + 4)
        if (a2 & 0x3ff) == tile and not (a0 == DUMMY_A0 and a1 == DUMMY_A1 and a2 == DUMMY_A2) then
            return a0, a1, a2, i, tile
        end
    end
    return nil, nil, nil, nil, tile
end

local written = false
local frame, framesDrawn, framesNoPlayer = 0, 0, 0
local lastLine = nil

-- Never write +6: CopyMatricesToOamBuffer owns affineParam on all 128 entries.
-- Release every slot used: nothing per frame clears 64..127, so one left behind stays on screen until a map load.
local function release()
    if not written then return end
    for i = 0, COUNT - 1 do
        local a = SLOT_ADDR + i * ENTRY_SIZE
        w16(a + 0, DUMMY_A0)
        w16(a + 2, DUMMY_A1)
        w16(a + 4, DUMMY_A2)
    end
    written = false
end

local function tick()
    frame = frame + 1
    if not inOverworld() then
        release()
        return
    end

    local a0, a1, a2, idx, tile
    if NO_SCAN then
        -- A fixed entry mid-screen: the writes and nothing else, which prices the scan by its absence.
        a0, a1, a2, idx, tile = 0x8038, 0x8070, 0x0800, -1, 0
    else
        a0, a1, a2, idx, tile = playerEntry()
    end
    if not a0 then
        -- No player entry this frame (a transition, a fade, a door), so nobody to stand above: hide.
        framesNoPlayer = framesNoPlayer + 1
        release()
        return
    end

    -- attr0's low byte is y (wrapping at 256), attr1's low 9 bits x. Only y is patched, so anything wrong on screen is
    -- our placement, not a field rebuilt badly.
    local y = ((a0 & 0xff) + OFFSET_Y_PX) & 0xff
    -- Written at the Lua frame boundary while LoadOam runs at the next VBlank, so a copy trails by one frame: judge
    -- position and occlusion here, not smoothness.
    if not NO_WRITE then
        if COUNT == 1 then
            w16(SLOT_ADDR + 0, (a0 & 0xff00) | y)
            w16(SLOT_ADDR + 2, a1)
            w16(SLOT_ADDR + 4, a2)
        else
            -- Spread like a crowd round the player: stacked on one scanline they would measure the scanline OBJ budget.
            local px, py = a1 & 0x1ff, a0 & 0xff
            for i = 0, COUNT - 1 do
                local a = SLOT_ADDR + i * ENTRY_SIZE
                local cx = (px + ((i % 8) - 4) * 16) & 0x1ff
                local cy = (py + ((i // 8) - 2) * 24) & 0xff
                w16(a + 0, (a0 & 0xff00) | cy)
                w16(a + 2, (a1 & 0xfe00) | cx)
                w16(a + 4, a2)
            end
        end
        written = true
    end
    framesDrawn = framesDrawn + 1

    if not QUIET and framesDrawn % REPORT_FRAMES == 0 then
        local line = string.format("frame=%d playerOAM=%d tile=%d x=%d y=%d -> copy at y=%d "
            .. "(prio=%d pal=%d) drawn=%d noPlayer=%d",
            frame, idx, tile, a1 & 0x1ff, a0 & 0xff, y,
            (a2 >> 10) & 3, (a2 >> 12) & 0xf, framesDrawn, framesNoPlayer)
        if line ~= lastLine then log(line) lastLine = line end
    end
end

say("=== oaminject_probe: ONE hardware sprite at oamBuffer[64], two tiles above the player ===")
say(string.format("slot 64 at 0x%08x; writing +0/+2/+4 only, never +6", SLOT_ADDR))
say(string.format("switches: COUNT=%d NO_WRITE=%s NO_SCAN=%s QUIET=%s", COUNT, tostring(NO_WRITE), tostring(NO_SCAN), tostring(QUIET)))
say("LOOK FOR: a second copy of the player above them -- then walk it behind scenery, and open the")
say("START menu and a text box. It trails by one frame while walking; that is expected at Stage 1.")

MESHGHOST_DEV_TICK = tick
MESHGHOST_DEV_UNLOAD = function()
    release()
    say(string.format("=== done: %d frames, %d with the copy drawn, %d with no player to stand above ===",
        frame, framesDrawn, framesNoPlayer))
    if logfile then logfile:close() logfile = nil end
end

if not MESHGHOST_DEV_LOADER then
    while true do
        tick()
        emu.frameadvance()
    end
end
