-- MeshGhost — Emerald: park ONE hardware sprite above gOamLimit and see whether the PPU draws it.
-- WRITES. Live RAM only -- one 8-byte OAM shadow entry per frame, and nothing else, ever. It never
-- touches a save, the map, an object event, a sprite struct, VRAM or a palette. Listed in this
-- folder's README writes table for that reason.
--
-- WHY THIS IS STAGE 1, and what it is allowed to prove
-- oamshadow_probe.lua established, over 2250 live overworld frames, that gOamLimit is 64 and that
-- gMain.oamBuffer[64..127] is empty and never written by the engine (verified.md 2026-08-21). What
-- it could NOT establish is the claim the whole hardware-sprite tier rests on: that LoadOam pushes
-- all 128 entries to hardware, so an entry parked up there is actually DRAWN. A frame-boundary
-- compare of shadow against hardware is one frame out of phase by construction and cannot answer it.
--
-- The only thing that answers it is a body on screen. So this probe is deliberately the smallest
-- possible version of the tier: ONE entry, at index 64, borrowing the PLAYER's own tile number and
-- palette slot out of the player's live OAM entry. No tile allocation, no VRAM copy, no palette
-- load -- every one of those is a separate way to fail, and none of them is the question being asked
-- here. If a second copy of the player appears two tiles above the player, the tier is real.
--
-- WHAT TO LOOK FOR, in order of what it tells us
--   1. A SECOND COPY OF THE PLAYER, two tiles above the player, moving with them. That alone is the
--      whole feasibility answer.
--   2. Walk it up behind a house or a ledge so the copy passes BEHIND scenery. The painted tier
--      cannot do that at all -- it is the drawn tier's registered blocking defect (BANDAGES.md) --
--      and it is the reason to prefer hardware sprites over painting, not just the speed.
--   3. Open the START menu, and a text box. The copy should be hidden by both, again for free.
--   4. Walk into a cave or through a door fade. The copy should dim with everything else, because
--      the PPU reads the live palette; the painted tier has to measure and re-apply that by hand.
--
-- IT WILL TRAIL BY ONE FRAME while walking, and that is expected, not a defect. This probe writes at
-- the Lua frame boundary, while the engine's LoadOam runs at the next VBlank -- so what is displayed
-- is one frame behind the player. Stage 3 moves the write onto the BuildOamBuffer execute hook,
-- which is the same point in the pipeline the engine's own sprites are finalised at, and that skew
-- goes away. Judge position and occlusion here; do not judge smoothness.
--
-- IT WILL ALSO LOSE OVERLAP TIES to the player and to NPCs, because hardware draws the lower OAM
-- index on top and ours is index 64 while the engine's are 0..63. Also expected, also recorded in
-- plans.md Phase 8.1 as something the tier does not get.
--
-- HOW TO RUN
--   Point dev-scripts/bizhawk-dev-loader.target at this file and walk around. It releases its entry
--   on unload, so swapping the loader back to the adapter removes the copy; if the emulator is ever
--   killed mid-run instead, a map load clears it (ResetOamRange), and nothing survives a reset.

-- Addresses: all from the adapter, which takes them from our own make-compare-verified pokeemerald
-- build (agent_docs/environment.md). The oamBuffer offset of 0x038 and the dummy encoding are
-- verified.md 2026-08-21. OAM geometry and the 8-byte stride are GBA hardware, not facts about
-- Emerald.
local GMAIN_ADDR = 0x030022c0
local OAMBUF_ADDR = GMAIN_ADDR + 0x038
local GOAMLIMIT_ADDR = 0x02021b38
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local GPLAYERAVATAR_ADDR = 0x02037590
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
local ENTRY_SIZE = 8

-- Index 64 is the first slot above the overworld's gOamLimit. The tier's real window is 64..119,
-- leaving 120..127 as margin because Emerald parks its own wireless status indicator at 125.
local SLOT = 64
local SLOT_ADDR = OAMBUF_ADDR + SLOT * ENTRY_SIZE

-- Two tiles above the player, in pixels. User's call, 2026-08-21: high enough to be unmistakably a
-- separate body rather than a smear on the player, close enough to share the same scenery.
local OFFSET_Y_PX = -32

-- gDummyOamData, the engine's own "hidden" encoding: y=160, x=304, 8x8, priority 3. Releasing with
-- the engine's own value rather than a zeroed entry means the slot is left indistinguishable from
-- one the engine never used.
local DUMMY_A0, DUMMY_A1, DUMMY_A2 = 0x00a0, 0x0130, 0x0c00

local REPORT_FRAMES = 60

-- SUBTRACTION SWITCHES, added 2026-08-21 after the user reported constant lag and the ride harness
-- confirmed it: 50.8 avg against a 58.1 control, reproduced twice, from a probe that does about ten
-- reads and three writes a frame. That is not a cost anyone would have predicted, so it gets
-- isolated by removing one part at a time rather than guessed at a third time.
--
-- Set them EXPLICITLY on every run. The dev loader shares one Lua environment, so an unset global
-- keeps the previous run's value and the measurement silently compares the wrong pair
-- (agent_docs/environment.md).
local NO_WRITE = MESHGHOST_OAMINJECT_NO_WRITE and true or false   -- scan and log, write nothing
local NO_SCAN = MESHGHOST_OAMINJECT_NO_SCAN and true or false     -- write a fixed entry, never scan
local QUIET = MESHGHOST_OAMINJECT_QUIET and true or false         -- no per-second log line

local function scriptDir()
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
    end
    return "."
end

local logfile = io.open(scriptDir() .. "/oaminject_probe.log", "w")

-- TO THE FILE, NOT THE CONSOLE -- and this probe is the evidence for the rule rather than an
-- application of it. Measured 2026-08-21 on the ride harness: with a line going to console.log
-- once a second, the same route ran 50.7 avg / 25 worst; with that line going only to the file,
-- 58.1 / 37 -- the bare-emulator control exactly. Writes on, scan on, hardware sprite on screen, in
-- both runs. So ~33 console lines over 33 seconds cost 7.4 fps while the whole feature cost nothing
-- measurable. BizHawk's Lua Console is a GUI text append into a window that already holds a
-- session's backlog, so its cost grows with the backlog and is nothing like a print.
--
-- say() is for the handful of orientation lines at load. log() is the per-frame path and must never
-- reach the console.
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

-- The +1 is the Thumb bit; gMain.callback2 holds the Thumb form of the pointer, measured live as
-- 0x08085e5d (verified.md 2026-08-21). This doubles as the VANILLA GATE: an Archipelago build
-- relocates CB2_Overworld, so there this never matches and the probe writes nothing at all.
local function inOverworld()
    local cb2 = r32(GMAIN_CALLBACK2_ADDR)
    return cb2 == CB2_OVERWORLD_ADDR or cb2 == CB2_OVERWORLD_ADDR + 1
end

-- WHERE THE PLAYER IS ON SCREEN, asked of the hardware rather than reconstructed.
--
-- gPlayerAvatar's spriteId indexes gSprites, and a Sprite begins with its OamData -- so the player's
-- own tile number is one read away. But the sprite struct's coordinates are the engine's, not the
-- screen's: the final top-left in screen pixels only exists in the OAM entry the engine BUILT from
-- that struct. So find that entry by its tile number and copy it whole. That is the same identify-by-
-- tile-range move oamEntryFor() makes in the adapter (meshghost_emerald.lua:4247), for the same
-- reason: a sprite's index in OAM is not stable, but the tiles it points at are.
--
-- Reading it from the SHADOW buffer rather than hardware is deliberate -- it is the buffer we are
-- writing into, so the copy and the player it is offset from come from the same frame and cannot
-- disagree with each other.
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

-- Never write +6. CopyMatricesToOamBuffer owns affineParam on all 128 entries; +0/+2/+4 are the
-- three halfwords the engine's per-frame path leaves alone above the limit.
local function release()
    if not written then return end
    w16(SLOT_ADDR + 0, DUMMY_A0)
    w16(SLOT_ADDR + 2, DUMMY_A1)
    w16(SLOT_ADDR + 4, DUMMY_A2)
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
        -- A fixed entry in the middle of the screen. Costs the writes and nothing else, so it
        -- prices the scan by its absence.
        a0, a1, a2, idx, tile = 0x8038, 0x8070, 0x0800, -1, 0
    else
        a0, a1, a2, idx, tile = playerEntry()
    end
    if not a0 then
        -- The player's sprite is not in the built list this frame -- a transition, a fade, or the
        -- engine hiding its own player at a door. Nobody for a copy to stand above, so hide.
        framesNoPlayer = framesNoPlayer + 1
        release()
        return
    end

    -- attr0's low byte is y and wraps at 256; attr1's low 9 bits are x. Copying the player's entry
    -- whole and patching only y keeps shape, size, flip, priority, palette and tile exactly as the
    -- engine set them -- which is the point: anything wrong on screen is then OUR placement, not a
    -- field we reconstructed badly.
    local y = ((a0 & 0xff) + OFFSET_Y_PX) & 0xff
    if not NO_WRITE then
        w16(SLOT_ADDR + 0, (a0 & 0xff00) | y)
        w16(SLOT_ADDR + 2, a1)
        w16(SLOT_ADDR + 4, a2)
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
say(string.format("switches: NO_WRITE=%s NO_SCAN=%s QUIET=%s", tostring(NO_WRITE), tostring(NO_SCAN), tostring(QUIET)))
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
