-- MeshGhost — Pokémon Emerald: what a FLY actually does, frame by frame (DEV TOOL, never shipped)
--
-- WHY
-- The boat/Fly work shipped 2026-08-26 detects a fly by scanning gTasks for Task_FlyOut /
-- Task_FlyIn and reading the bird sprite the task owns. On the first live run the user reported
-- *"sprites are glitchy, and the ghosts are not following the player at all during fly"* — which
-- is exactly what a detection that never fires looks like, and also exactly what a detection that
-- fires on the wrong thing looks like. Those two need separating before anything is changed.
--
-- SO THIS READS THE GAME, NOT THE ADAPTER. It never touches flyRide.* or any adapter state: it
-- does its own task scan and its own sprite walk, so "the adapter thinks X" and "the game is doing
-- X" stay two different statements. Logging the value we just wrote back to ourselves is the one
-- shape this repo has been burned by most (CLAUDE.md).
--
-- WHAT IT ANSWERS, in order
--   1. Is a fly task running at all, and at WHAT ADDRESS? Every active task's function pointer is
--      dumped, so a wrong constant shows up as "a task is running and it is not the one we look
--      for" rather than as silence.
--   2. What does the PLAYER's own object/sprite do across the sequence — invisible bit, graphicsId,
--      map coords, sprite screen position, coordOffsetEnabled.
--   3. Is there a bird, and what is in its data slots (the arc parameter, the passenger, done).
--   4. What is the GHOST doing at the same instant — the same fields, side by side.
--
-- Both halves on one line is the point: a ghost that does not follow is either not being told to
-- fly, or being told and not moving, and only the pair distinguishes them.
--
-- DRIVING IT
-- The user's savestates make this self-testable (their slots, offered for this):
--   slot 5 — same-town fly       slot 6 — different-town fly      press A once to fly
-- Set MESHGHOST_FLY_SLOT to pick one (default 5). It drives input, so it must be the ONLY
-- input-driving script in the loader's target list.
--
-- Lenient by construction: fixed phases with a countdown, never a window to hit.

local SLOT = tonumber(MESHGHOST_FLY_SLOT or os.getenv("MESHGHOST_FLY_SLOT") or "") or 5
local SETTLE_FRAMES = 60      -- let the adapter settle before yanking the state
local TAP_FRAMES = 120        -- press A, leniently, for two seconds
local LOG_FRAMES = 600        -- ten seconds: the whole departure and then some

local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
local GTASKS_ADDR = 0x03005e00
local TASK_SIZE = 0x28
local GHOST_LOCAL_ID = 255
-- gSaveBlock1Ptr, for the map the LOCAL player is standing in. Two instances only ever exchange
-- ghosts while their area ids match, so "was there even a ghost to watch" is a question about
-- this pair of bytes before it is a question about anything in the fly code -- and the first
-- paired run failed on exactly that: the watcher held one ghost all run and it was its own.
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local function localArea()
    local b = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
    if b == 0 then return "?:?" end
    return string.format("%d:%d", memory.read_s8(b + 0x04), memory.read_s8(b + 0x05))
end

-- Beside this script, never an absolute path: this repo is public (CLAUDE.md).
local BS = string.char(92)
local DIR = debug.getinfo(1, "S").source:sub(2)
    :match("^(.*)[/" .. BS .. "][^/" .. BS .. "]*$") or "."
-- Separate files per role, so a driven run and an observed run never overwrite each other --
-- they are the two halves of one measurement and are read side by side.
local out = io.open(DIR .. (MESHGHOST_FLY_OBSERVE and "/fly_probe_watch.log"
    or "/fly_probe.log"), "w")
-- Buffered, flushed in batches. A per-line flush was measured at 63-83ms on this emulator --
-- four to five frames, on the emulator's own thread (adapters/emulator/CLAUDE.md).
if out then out:setvbuf("full", 1 << 16) end
local nLines = 0
local function log(s)
    if not out then return end
    out:write(s, "\n")
    nLines = nLines + 1
    if nLines % 120 == 0 then out:flush() end
end

local function r8(a) return memory.read_u8(a) end
local function r16(a) return memory.read_u16_le(a) end
local function rs16(a) return memory.read_s16_le(a) end
local function r32(a) return memory.read_u32_le(a) end
local function objAddr(i) return GOBJECTEVENTS_ADDR + i * OBJECTEVENT_SIZE end
local function sprAddr(i) return GSPRITES_ADDR + i * SPRITE_SIZE end

-- One character's whole state in one field: the object's flags that matter here, its graphic, its
-- map coords, and the SPRITE's screen position -- which is the half that moves during a fly while
-- the map coords stand still.
local function describe(tag, objId)
    if objId == nil or objId >= 16 then return tag .. "=none" end
    local a = objAddr(objId)
    if (r8(a + 0x00) & 0x01) == 0 then return tag .. "=inactive" end
    local sprId = r8(a + 0x04)
    local d = sprAddr(sprId)
    return string.format(
        "%s obj=%d spr=%d gfx=%d inv=%d inanim=%d shadow=%d act=%02X coords=(%d,%d) "
            .. "spr=(%d,%d) pos2=(%d,%d) coordOff=%d sprInv=%d anim=%d/%d",
        tag, objId, sprId, r8(a + 0x05),
        (r8(a + 0x01) >> 5) & 1,        -- invisible
        (r8(a + 0x01) >> 4) & 1,        -- inanimate
        (r8(a + 0x02) >> 6) & 1,        -- hasShadow
        r8(a + 0x1c),                   -- movementActionId
        rs16(a + 0x10), rs16(a + 0x12),
        rs16(d + 0x20), rs16(d + 0x22),
        rs16(d + 0x24), rs16(d + 0x26),
        (r8(d + 0x3e) >> 1) & 1,        -- coordOffsetEnabled
        (r8(d + 0x3e) >> 2) & 1,        -- invisible
        r8(d + 0x2a), r8(d + 0x2b))
        -- WHICH TILES IT IS ACTUALLY DRAWN FROM, and the shape it is drawn with. A "broken
        -- sprite" is by definition a thing no struct field can show: graphicsId, animation number
        -- and position can all agree while the picture is wrong, because the picture lives in the
        -- tile range OAM points at and in the shape/size bits that say how to read it. This is the
        -- half that was missing when every earlier field came back clean and the user still saw a
        -- broken character after a cross-map fly.
        .. string.format(" | oam=%04X %04X %04X tile=%d pal=%d shape=%d size=%d sub=%02X",
            r16(d + 0x00), r16(d + 0x02), r16(d + 0x04),
            r16(d + 0x04) & 0x3ff, (r16(d + 0x04) >> 12) & 0x0f,
            (r16(d + 0x00) >> 14) & 0x03, (r16(d + 0x02) >> 14) & 0x03, r8(d + 0x42))
end

-- Every ACTIVE task, with its function pointer. The point is the pointer: a fly that is running
-- under an address we do not recognise is a different bug from a fly that is not running.
local function tasks()
    local parts = {}
    for t = 0, 15 do
        local ta = GTASKS_ADDR + t * TASK_SIZE
        if r8(ta + 0x04) == 1 then
            parts[#parts + 1] = string.format("t%d:%08X st=%d d1=%d d2=%d",
                t, r32(ta + 0x00), r16(ta + 0x08), r16(ta + 0x0a), r16(ta + 0x0c))
        end
    end
    return table.concat(parts, " ; ")
end

-- Any sprite that is NOT an object-event sprite and is running something -- the bird is one of
-- these. Reported by callback so a wrong constant is visible as an address rather than as an
-- absence, which is the same reason the task dump prints pointers.
local function loose(skip)
    local parts = {}
    for s = 0, 63 do
        local d = sprAddr(s)
        if (r8(d + 0x3e) & 0x01) ~= 0 and not skip[s] then
            local cb = r32(d + 0x1c)
            -- data[2] is the fly arc parameter, data[6] the passenger, data[7] the done flag.
            parts[#parts + 1] = string.format("s%d:cb=%08X xy=(%d,%d) d2=%d d6=%d d7=%d",
                s, cb, rs16(d + 0x20), rs16(d + 0x22),
                r16(d + 0x32), r16(d + 0x3a), r16(d + 0x3c))
        end
    end
    if #parts == 0 then return "none" end
    return table.concat(parts, " ; ")
end

-- A GHOST WEARS LOCALID_PLAYER, AND SO DOES THE PLAYER. That is deliberate in the adapter (it is
-- what makes a ghost non-interactable, using the engine's own check), and it means "localId 255"
-- alone finds the player first and reports it as the ghost -- which is exactly what the first run
-- of this probe did, printing two identical halves and hiding the thing it was written to see.
-- The player's own object id is the discriminator, and it comes from gPlayerAvatar.
local function ghostObjIds(playerObjId)
    local ids = {}
    for i = 0, 15 do
        local a = objAddr(i)
        if i ~= playerObjId and (r8(a + 0x00) & 0x01) ~= 0
            and r8(a + 0x08) == GHOST_LOCAL_ID then
            ids[#ids + 1] = i
        end
    end
    return ids
end

-- OBSERVER MODE: log, drive nothing. The instance that WATCHES a flying peer is the one the
-- remaining bugs live on, and it must not load a state or touch the controller while the other
-- instance is being driven -- two scripts pressing A at each other proves nothing. Set
-- MESHGHOST_FLY_OBSERVE on the watching instance and drive the other one.
local OBSERVE = MESHGHOST_FLY_OBSERVE or os.getenv("MESHGHOST_FLY_OBSERVE")

local phase, n, logged = OBSERVE and "log" or "settle", 0, 0

-- SCREENSHOTS, KEYED ON THE BIRD. Every struct field agreed through five fly bugs while the
-- screen was wrong, so the screen itself is now part of the record: whenever any sprite is
-- running the fly-swoop callback, and for six seconds after the last one, a frame is captured
-- every fourth frame. A screenshot sees the spawned and hardware tiers (real sprites); it cannot
-- see the painted overlay -- known, and fine, because the shipped watcher draws peers spawned.
-- client.screenshot reads the emulated frame, so a backgrounded window captures the same.
local shotUntil, shots = nil, 0
local SHOT_CAP = 150
local function birdOnScreen()
    for si = 0, 63 do
        local d = sprAddr(si)
        if (r8(d + 0x3e) & 0x01) ~= 0 and r32(d + 0x1c) == 0x080B963D then return true end
    end
    return false
end
local function maybeShoot()
    if birdOnScreen() then shotUntil = n + 360 end
    if shotUntil and n <= shotUntil and shots < SHOT_CAP and n % 4 == 0 then
        shots = shots + 1
        pcall(function()
            client.screenshot(string.format("%s/flyshot_%s_%06d.png",
                DIR, OBSERVE and "w" or "d", emu.framecount()))
        end)
    end
end

local function tick()
    n = n + 1
    if OBSERVE then
        -- Never stops, and never touches the controller. The window that matters is whenever the
        -- OTHER instance flies, which this one cannot predict.
        --
        -- It may still be PLACED once, though, which is a different thing from being driven: a
        -- watcher has to be standing somewhere sensible to watch from, and after a relaunch it is
        -- sitting on a title screen. MESHGHOST_FLY_OBSERVE_LOAD_SLOT loads one state, once, and
        -- then never again -- deliberately not re-applied on a script reload, because a slot that
        -- reloads on every re-attach is the trap `status.md` records for the square-drive probe.
        local slot = tonumber(MESHGHOST_FLY_OBSERVE_LOAD_SLOT
            or os.getenv("MESHGHOST_FLY_OBSERVE_LOAD_SLOT") or "")
        if slot and n == SETTLE_FRAMES then
            pcall(function() savestate.loadslot(slot) end)
            console.log("fly_probe: OBSERVE -- placed from slot " .. slot .. ", now watching.")
        end
        if n == 1 then
            console.log("fly_probe: OBSERVE mode -- logging only, no input.")
            log("=== fly_probe OBSERVE emuframe=" .. emu.framecount() .. " ===")
        end
        if slot and n < SETTLE_FRAMES then return end
        phase = "log"
    end
    if phase == "settle" then
        if n < SETTLE_FRAMES then return end
        pcall(function() savestate.loadslot(SLOT) end)
        console.log("fly_probe: loaded slot " .. SLOT .. " -- tapping A, then logging.")
        log(string.format("=== fly_probe slot=%d emuframe=%d ===", SLOT, emu.framecount()))
        phase, n = "tap", 0
        return
    end
    if phase == "tap" then
        -- Tapped, not held: the game reads a NEW press.
        joypad.set({ A = (n % 20) < 10 })
        if n >= TAP_FRAMES then
            console.log("fly_probe: logging " .. LOG_FRAMES .. " frames.")
            phase, n = "log", 0
        end
        -- Log through the tap too -- the field-move pose starts here, before the bird exists.
    end
    if phase == "done" then return end

    local pObj = r8(GPLAYERAVATAR_ADDR + 0x05)
    local pSpr = (pObj < 16) and r8(objAddr(pObj) + 0x04) or 255
    local gs = ghostObjIds(pObj)
    local parts = { describe("PLAYER", pObj) }
    local skip = { [pSpr] = true }
    for _, gObj in ipairs(gs) do
        parts[#parts + 1] = describe("GHOST" .. gObj, gObj)
        skip[r8(objAddr(gObj) + 0x04)] = true
    end
    -- `loose` takes two ids to skip; with several ghosts, pass the set instead.
    log(string.format("f=%d area=%s | %s | TASKS %s | LOOSE %s",
        emu.framecount(), localArea(),
        table.concat(parts, " | "),
        tasks(),
        loose(skip)))
    logged = logged + 1
    maybeShoot()

    if not OBSERVE and phase == "log" and n >= LOG_FRAMES then
        phase = "done"
        if out then out:flush() end
        console.log("fly_probe: done -- " .. logged .. " frames in probes/fly_probe.log")
    end
end

MESHGHOST_DEV_TICK = tick
if not MESHGHOST_DEV_LOADER then
    while true do tick() emu.frameadvance() end
end
