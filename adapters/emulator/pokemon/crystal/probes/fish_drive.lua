-- MeshGhost — Pokémon Crystal: cast the rod, hold it, clear the text, cast again
--
-- DEVELOPMENT TOOL. **It holds the controller** (SELECT, A, and optionally a direction) and it
-- **can load a savestate**. It writes no game memory.
--
-- WHY THIS EXISTS
-- Fishing is the first of Crystal's remaining action classes (`UNVERIFIED.md`, "NEXT SESSION'S
-- WORK: FISHING FIRST"), and judging it needs the same cast watched many times — once to see the
-- pose arrive, once to see it held, once to see it end. The user's own framing, 2026-08-25:
-- *"press select, wait a bit for the animation, then reload/repeat"*.
--
-- AND THEN: **A BITE IS THE INTERESTING CASE, AND RELOADING NEVER REACHES IT.** The user, the same
-- day: *"if i catch a fish, the 2 ghosts move back 1 tile"*, with the method — *"you can't
-- replicate this if you keep reloading the savestate7, need to press A and try to fish again"*.
-- Reloading a savestate replays one RNG state; only casting again and again reaches a bite. So the
-- default loop CLEARS THE TEXT AND RECASTS, and the savestate is the fallback, not the cycle.
--
-- WHAT IT ASKS
--   1. Does the PLAYER's object hold OBJECT_ACTION 6 and OBJECT_FACING $10+dir for the whole cast?
--      That pair is what the adapter puts on the wire; without it no ghost was ever going to fish.
--   2. What do the POSITION fields do at the bite? A ghost that steps back a tile is a peer whose
--      position was read as mid-step — so `walking`, `step_type`, `step_duration` and the map/last
--      map pair are all in the sample, and the frame they change is the frame to look at.
--   3. Does anything else hold the fishing pair — a spawned ghost has a struct and is scanned.
-- Run-length encoded: a pose that flickers is a different fault from a pose that never arrives.
--
-- WHAT IT CANNOT ANSWER
--   * Whichever way the water is, that is the only fishing direction it exercises. It says so in
--     its own log rather than letting the reader assume all four were covered.
--   * **The screenshots do not contain the drawn tier.** `client.screenshot` captures the
--     emulator's video output, and a painted ghost is a `gui.*` overlay on top of it — so a
--     screenshot showing no ghost is not evidence that no ghost was painted. Found exactly that
--     way 2026-08-25, with the user watching two ghosts the screenshots did not have.
--
-- HOW TO RUN
--   Add it to dev-scripts/bizhawk-dev-loader-crystal.target; remove the line to stop it.
--   Globals, all optional:
--     MESHGHOST_FISH_DIR     where the log and screenshots go (default: beside this file)
--     MESHGHOST_FISH_SLOT    savestate slot loaded ONCE at the start (default 7; nil for none)
--     MESHGHOST_FISH_RELOAD  reload that slot every N casts as well (default: never)
--     MESHGHOST_FISH_FACE    "Down"/"Up"/"Left"/"Right" held before casting, for a spot where the
--                            water is not the way the state faces (default: none)
--     MESHGHOST_FISH_CYCLES  stop after this many casts (default: run forever)
--
-- AND UNLOAD IT BEFORE JUDGING ANYTHING ELSE. An input-driving probe left loaded is a suspect in
-- every later report.

local SLOT = tonumber(MESHGHOST_FISH_SLOT)
if MESHGHOST_FISH_SLOT == nil then SLOT = 7 end
local RELOAD_EVERY = tonumber(MESHGHOST_FISH_RELOAD)
local FACE = MESHGHOST_FISH_FACE
local MAX_CYCLES = tonumber(MESHGHOST_FISH_CYCLES)

-- Fixed phases with a countdown, never a window anybody has to hit. Frames, at 60fps.
local SETTLE = 150 -- after a load: the map, the adapter's ghosts and the peer stream all resume
local TURN = 24 -- optional pre-cast facing press
local PRESS = 8 -- SELECT held
local WATCH = 420 -- 7s of rod-out: the cast, the wait, and a bite if one comes
local CLEAR = 150 -- A pressed in bursts to walk through "Not even a nibble!" and back to standing
local SHOTS = { 30, 120, 300 } -- frames into WATCH at which a screenshot is taken

local OUT = MESHGHOST_FISH_DIR
if not OUT then
  local info = debug.getinfo(1, "S")
  OUT = "."
  if info and info.source and info.source:sub(1, 1) == "@" then
    local src = info.source:sub(2):gsub("\\", "/")
    OUT = src:match("^(.*)/[^/]*$") or "."
  end
end

-- Addresses copied from meshghost_crystal.lua's own vanilla table, not remembered. This probe is
-- VANILLA V1.0 ONLY for that reason: on another build these are somebody else's bytes.
local function flat(cpu)
  if cpu < 0xD000 then return cpu - 0xC000 end
  return 0x1000 + (cpu - 0xD000)
end
local ST, OLEN, NSTRUCTS = flat(0xD4D6), 0x28, 13
local MAPGROUP, MAPNUMBER, BATTLEMODE = flat(0xDCB5), flat(0xDCB6), flat(0xD22D)
-- THE CAMERA TERMS THE DRAWN TIER PAINTS THROUGH. A peer's tile can be perfectly steady and the
-- painted copy still move, because the map-pixel-to-screen conversion has its own inputs — so when
-- the user reports *"the 2 ghosts move back 1 tile"* while the player stands still, these are the
-- numbers that have to be in the same log as the player's.
local BGMAPOFFX, BGMAPOFFY = flat(0xD14C), flat(0xD14D)
local W_XCOORD, W_YCOORD = flat(0xDCB8), flat(0xDCB7)
-- AND THE GATES THE ADAPTER ITSELF PAINTS THROUGH. A ghost that vanishes is not necessarily a
-- ghost that stopped arriving: `inPlay()` reads wMapStatus and wBattleMode, the hardware tier
-- reads wStateFlags' SPRITE_UPDATES_DISABLED bit, and the UI clip reads the window registers. The
-- user, 2026-08-26: *"both ghosts disappeared before they could show the ! above their head"* --
-- so the question is which of these flipped, and when, relative to the emote object appearing.
local MAPSTATUS, STATEFLAGS = flat(0xD432), flat(0xD0ED)
local F_SPRITE, F_WALKING, F_DIRECTION, F_STEP_TYPE = 0x00, 0x07, 0x08, 0x09
local F_STEP_DURATION, F_ACTION, F_FACING = 0x0A, 0x0B, 0x0D
local F_MAP_X, F_MAP_Y, F_LAST_X, F_LAST_Y = 0x10, 0x11, 0x12, 0x13
local F_SPRITE_X, F_SPRITE_Y, F_SPR_X_OFF, F_SPR_Y_OFF = 0x17, 0x18, 0x19, 0x1A
local function u8(a) local v = memory.read_u8(a, "WRAM") return v or -1 end

local logfile = io.open(string.format("%s/fish_drive_%s.log", OUT, os.date("%Y%m%d_%H%M%S")), "w")
if logfile then pcall(function() logfile:setvbuf("full", 8192) end) end
-- The console is the expensive half (pitfalls.md: one line a second cost 7.4 fps), so it gets the
-- headlines and the file gets everything.
local consoleLines, pending = 0, 0
local function log(m, loud)
  consoleLines = consoleLines + 1
  if loud or consoleLines <= 6 then console.log(m) end
  if logfile then
    logfile:write(m, "\n")
    pending = pending + 1
    if pending >= 20 then pending = 0 pcall(function() logfile:flush() end) end
  end
end

log("=== MeshGhost Crystal fishing driver ===", true)
log(string.format("slot %s, %d-frame watch then B to clear and recast, pre-cast facing %s. "
  .. "It holds SELECT and B.", tostring(SLOT), WATCH, tostring(FACE)), true)
log("NOTE: screenshots do NOT contain painted ghosts -- they are a gui overlay. Watch the screen.",
  true)

-- One sample of everything worth knowing, for the player and for every other live object struct.
-- POSITION FIELDS ARE IN THE KEY on purpose: the reported fault is positional, and a field that
-- moves for one frame is exactly what a run-length encoding makes visible.
local function objLine(tag, b)
  return string.format("%s a=%02X f=%02X d=%02X w=%d st=%02X sd=%02X @%d,%d last %d,%d "
    .. "spr %d,%d off %d,%d", tag,
    u8(b + F_ACTION), u8(b + F_FACING), u8(b + F_DIRECTION), u8(b + F_WALKING),
    u8(b + F_STEP_TYPE), u8(b + F_STEP_DURATION),
    u8(b + F_MAP_X), u8(b + F_MAP_Y), u8(b + F_LAST_X), u8(b + F_LAST_Y),
    u8(b + F_SPRITE_X), u8(b + F_SPRITE_Y), u8(b + F_SPR_X_OFF), u8(b + F_SPR_Y_OFF))
end

local function sample()
  local parts = { objLine("P", ST),
    string.format("batt=%d ms=%d sf=%02X wy=%d wx=%d cam %d,%d win %d,%d oam0 %d,%d",
      u8(BATTLEMODE), u8(MAPSTATUS), u8(STATEFLAGS),
      memory.read_u8(0xFF4A, "System Bus") or -1, memory.read_u8(0xFF4B, "System Bus") or -1,
      u8(BGMAPOFFX), u8(BGMAPOFFY), u8(W_XCOORD), u8(W_YCOORD),
      memory.read_u8(1, "OAM") or -1, memory.read_u8(0, "OAM") or -1) }
  for i = 1, NSTRUCTS - 1 do
    local b = ST + i * OLEN
    if u8(b + F_SPRITE) ~= 0 then
      parts[#parts + 1] = objLine("G" .. i, b)
    end
  end
  return table.concat(parts, " | ")
end

local runKey, runLen, runStart = nil, 0, 0
local function emit()
  log(string.format("  f%+4d..%+4d (%3d) %s", runStart, runStart + runLen - 1, runLen, runKey))
end
local function record(frameInPhase)
  local key = sample()
  if key == runKey then runLen = runLen + 1 return end
  if runKey then emit() end
  runKey, runLen, runStart = key, 1, frameInPhase
end
local function flushRun()
  if runKey then emit() end
  runKey, runLen, runStart = nil, 0, 0
end

local phase, frames, cycle, shotIdx = SLOT and "load" or "press", 0, 0, 1
local sawAction6, sawFishFacing, ghostSaw6, ghostSawFish, sawBattle = 0, 0, 0, 0, 0

local function press(button)
  pcall(joypad.set, { [button] = true })
  pcall(joypad.set, { [button] = true }, 1)
end

local function tick()
  frames = frames + 1

  if phase == "load" then
    log(string.format("LOADING SAVESTATE SLOT %d (an action, announced)", SLOT), true)
    local ok, err = pcall(function() savestate.loadslot(SLOT) end)
    if not ok then log("fish_drive: the savestate load FAILED: " .. tostring(err), true) end
    phase, frames = "settle", 0
    return
  end

  if phase == "settle" then
    if frames < SETTLE then return end
    log(string.format("  settled: map %d/%d, %s", u8(MAPGROUP), u8(MAPNUMBER), objLine("P", ST)))
    phase, frames = FACE and "turn" or "press", 0
    return
  end

  if phase == "turn" then
    press(FACE)
    if frames < TURN then return end
    phase, frames = "press", 0
    return
  end

  if phase == "press" then
    -- ONCE PER CAST, not once per frame of the press. The counter used to sit here unguarded and
    -- advanced eight times a cast, so every number in the log named a cast that never happened.
    if frames == 1 then cycle = cycle + 1 end
    if MAX_CYCLES and cycle > MAX_CYCLES then
      log(string.format("fish_drive: %d casts done -- standing by, nothing pressed.", MAX_CYCLES),
        true)
      phase = "done"
      return
    end
    press("Select")
    if frames == 1 then
      log(string.format("--- cast %d", cycle), true)
      -- Read back what the emulator says is held rather than trusting the call above.
      local ok, held = pcall(joypad.get)
      local names = {}
      if ok and type(held) == "table" then
        for k, v in pairs(held) do if v == true then names[#names + 1] = tostring(k) end end
      end
      table.sort(names)
      log("  SELECT pressed -- emulator reports held: "
        .. ((#names > 0) and table.concat(names, "+") or "(nothing)"))
    end
    if frames < PRESS then return end
    phase, frames, shotIdx = "watch", 0, 1
    return
  end

  if phase == "watch" then
    record(frames)
    local act, face = u8(ST + F_ACTION), u8(ST + F_FACING)
    if act == 6 then sawAction6 = sawAction6 + 1 end
    if face >= 0x10 and face <= 0x13 then sawFishFacing = sawFishFacing + 1 end
    if u8(BATTLEMODE) ~= 0 then sawBattle = sawBattle + 1 end
    for i = 1, NSTRUCTS - 1 do
      local b = ST + i * OLEN
      if u8(b + F_SPRITE) ~= 0 then
        if u8(b + F_ACTION) == 6 then ghostSaw6 = ghostSaw6 + 1 end
        local gf = u8(b + F_FACING)
        if gf >= 0x10 and gf <= 0x13 then ghostSawFish = ghostSawFish + 1 end
      end
    end
    if shotIdx <= #SHOTS and frames == SHOTS[shotIdx] then
      pcall(function() client.screenshot(string.format("%s/fish_c%d_f%d.png", OUT, cycle, frames)) end)
      shotIdx = shotIdx + 1
    end
    if frames < WATCH then return end
    flushRun()
    -- THE COUNTS ARE THE VERDICT'S EVIDENCE, not a boolean. A probe that says "fishing worked"
    -- cannot be sanity-checked; these can.
    log(string.format("  cast %d: player held action 6 on %d/%d frames, a FISH facing on %d, "
      .. "battle on %d; other objects held action 6 on %d frame-objects, a FISH facing on %d",
      cycle, sawAction6, WATCH, sawFishFacing, sawBattle, ghostSaw6, ghostSawFish), true)
    if sawAction6 == 0 then
      log("  NOTHING FISHED. Either SELECT is not the rod on this state, or the tile the player "
        .. "faces is not water, or the game is still in text from the last cast.", true)
    end
    if sawBattle > 0 then
      log("  A BATTLE STARTED -- that is the CATCH case. The frames above it are the ones to "
        .. "read; the savestate reload below puts the world back.", true)
    end
    sawAction6, sawFishFacing, ghostSaw6, ghostSawFish, sawBattle = 0, 0, 0, 0, 0, 0
    if logfile then pcall(function() logfile:flush() end) end
    -- ONLY A BATTLE RELOADS. The user's method again: recasting is what reaches a bite, and a
    -- reload replays one RNG state. A battle is the exception -- it has to be left before another
    -- cast is possible, and only the savestate does that without playing it out.
    if SLOT and (u8(BATTLEMODE) ~= 0
        or (RELOAD_EVERY and cycle % RELOAD_EVERY == 0)) then
      phase, frames = "load", 0
    else
      phase, frames = "clear", 0
    end
    return
  end

  if phase == "clear" then
    -- B, NOT A, and in bursts. The user's method, 2026-08-25: *"if you don't catch a fish, press B
    -- to close the text box, then use the fishing rod again"*. A on the overworld is the interact
    -- button and would re-cast or talk to whatever is in front; B only ever closes. Held
    -- continuously it re-opens what it just closed, so it needs the release between presses.
    if (frames % 20) < 4 then press("B") end
    if frames < CLEAR then return end
    phase, frames = "press", 0
    return
  end
end

MESHGHOST_DEV_TICK = tick

MESHGHOST_DEV_UNLOAD = function()
  if logfile then
    pcall(function() flushRun() logfile:flush() logfile:close() end)
    logfile = nil
  end
end

-- A registered callback outlives its script under BizHawk, which is why this is a loop and not
-- event.onframeend (pitfalls.md).
if not MESHGHOST_DEV_LOADER then
  while true do
    tick()
    emu.frameadvance()
  end
end
