-- Dev tool: casts the rod, watches, clears the text with B and casts again, logging every object's action, facing and
-- position run-length encoded. Holds the controller and can load a savestate; writes no game memory. Recasting, not
-- reloading, reaches a bite. Only the water's direction is exercised, and screenshots never contain a painted ghost.
-- Optional globals MESHGHOST_FISH_DIR, _SLOT (default 7), _RELOAD, _FACE, _CYCLES. Unload it before judging anything.

local SLOT = tonumber(MESHGHOST_FISH_SLOT)
if MESHGHOST_FISH_SLOT == nil then SLOT = 7 end
local RELOAD_EVERY = tonumber(MESHGHOST_FISH_RELOAD)
local FACE = MESHGHOST_FISH_FACE
local MAX_CYCLES = tonumber(MESHGHOST_FISH_CYCLES)

-- Phase lengths in frames: a countdown, never a window anybody has to hit.
local SETTLE = 150 -- after a load: the map, the adapter's ghosts and the peer stream all resume
local TURN = 24 -- optional pre-cast facing press
local PRESS = 8 -- SELECT held
local WATCH = 420 -- 7s of rod-out: the cast, the wait, and a bite if one comes
local CLEAR = 150 -- B in bursts, through "Not even a nibble!" and back to standing
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

-- From meshghost_crystal.lua's vanilla table, so vanilla V1.0 only: on another build these are other bytes.
local function flat(cpu)
  if cpu < 0xD000 then return cpu - 0xC000 end
  return 0x1000 + (cpu - 0xD000)
end
local ST, OLEN, NSTRUCTS = flat(0xD4D6), 0x28, 13
local MAPGROUP, MAPNUMBER, BATTLEMODE = flat(0xDCB5), flat(0xDCB6), flat(0xD22D)
-- The camera terms the drawn tier paints through: a painted copy can move while the peer's tile is steady.
local BGMAPOFFX, BGMAPOFFY = flat(0xD14C), flat(0xD14D)
local W_XCOORD, W_YCOORD = flat(0xDCB8), flat(0xDCB7)
-- And the gates the adapter paints through (inPlay's wMapStatus and wBattleMode, the hardware tier's
-- SPRITE_UPDATES_DISABLED bit, the UI clip's window registers): a vanished ghost is not one that stopped arriving.
local MAPSTATUS, STATEFLAGS = flat(0xD432), flat(0xD0ED)
local F_SPRITE, F_WALKING, F_DIRECTION, F_STEP_TYPE = 0x00, 0x07, 0x08, 0x09
local F_STEP_DURATION, F_ACTION, F_FACING = 0x0A, 0x0B, 0x0D
local F_MAP_X, F_MAP_Y, F_LAST_X, F_LAST_Y = 0x10, 0x11, 0x12, 0x13
local F_SPRITE_X, F_SPRITE_Y, F_SPR_X_OFF, F_SPR_Y_OFF = 0x17, 0x18, 0x19, 0x1A
local function u8(a) local v = memory.read_u8(a, "WRAM") return v or -1 end

local logfile = io.open(string.format("%s/fish_drive_%s.log", OUT, os.date("%Y%m%d_%H%M%S")), "w")
if logfile then pcall(function() logfile:setvbuf("full", 8192) end) end
-- The console costs frames, so it gets the headlines and the file gets everything.
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

-- Position fields are in the run-length key: a field that moves for one frame then shows.
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
    -- Once per cast, not once per frame of the press.
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
    -- Counts, not a boolean, so the verdict can be checked.
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
    -- Only a battle reloads: it must be left before another cast, and only the savestate leaves it unplayed.
    if SLOT and (u8(BATTLEMODE) ~= 0
        or (RELOAD_EVERY and cycle % RELOAD_EVERY == 0)) then
      phase, frames = "load", 0
    else
      phase, frames = "clear", 0
    end
    return
  end

  if phase == "clear" then
    -- B, not A, in bursts: A on the overworld interacts with what is in front, and B held down re-opens what it closed.
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

-- A loop, not event.onframeend: a registered callback outlives its script under BizHawk.
if not MESHGHOST_DEV_LOADER then
  while true do
    tick()
    emu.frameadvance()
  end
end
