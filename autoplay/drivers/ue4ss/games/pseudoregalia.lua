-- autoplay UE4SS driver, Pseudoregalia's module (DEV TOOL, never shipped).
--
-- What observe reads and how input reaches the player, each from a measurement named in
-- adapters/pseudoregalia/MEASURED.md or the adapter's own C++ (the field names it already reads by reflection:
-- moveState, actionState, controlState, BP_HpHitable's CurrentHp and maxHP, the level's full name).
-- Everything runs on the game thread (the driver's frame loop).

local host = ...
local log = host.log

local M = {
	game = "pseudoregalia",
	variant = "vanilla",
	capabilities = { "wait", "press", "sequence", "screenshot", "snapshot", "restore", "cheat:teleport", "reflex:walk_to", "reflex:look" },
	-- The user's save files 1-7 are never written; File 8 is autoplay's (the user, 2026-09-23).
	protected_slots = { 1, 2, 3, 4, 5, 6, 7 },
}

-- A player controller, re-found when the one held stops being valid. FindFirstOf walks the object array, so it
-- runs only when the cached one is gone, never per frame while it is live.
local pcCache = nil
local function controller()
	if pcCache and pcCache:IsValid() then return pcCache end
	pcCache = nil
	local ok, pc = pcall(FindFirstOf, "PlayerController")
	if ok and pc and pc:IsValid() then pcCache = pc end
	return pcCache
end

local function pawnOf(pc)
	if not pc then return nil end
	local p = pc.Pawn
	if p and p:IsValid() then return p end
	return nil
end

local statics = nil
local function gameplayStatics()
	if statics and statics:IsValid() then return statics end
	statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
	return statics
end

local function levelName(pc)
	local ok, name = pcall(function()
		local world = pc:GetWorld()
		return world.PersistentLevel:GetFullName()
	end)
	if ok then return name end
	return nil
end

-- A level's full name reads "Level /Game/Maps/<Map>.<Map>:PersistentLevel"; the map is the short form.
local function mapOf(level)
	if not level then return nil end
	return level:match("/([^/%.]+)%.[^/]*:PersistentLevel") or level
end

local function num(v)
	if type(v) == "number" then return v end
	return nil
end

function M.build()
	return "steam"
end

-- THE SAVE GUARD. The game writes its save to the game instance's `activeSaveSlotName`, and after File 8 was started
-- as a new game through File Select that read "File 5", one of the user's (2026-09-23; File 5 was still identical to
-- the backup). From the moment a core first connects until the game exits, every tenth frame in play puts it back to
-- AUTOPLAY_SLOT and logs each correction. The user's files 1-7 are never autoplay's (the user, 2026-09-23). A game
-- started without a core ever connecting is not guarded, so the user's own play saves where it always does.
local AUTOPLAY_SLOT = "File 8"
local guard = { armed = false, corrections = 0, last_from = nil }

local function gameInstance(pawn)
	local gi = pawn and pawn["As MV Game Instance Ref"]
	if gi and gi:IsValid() then return gi end
	return nil
end

local function guardSlot(pawn)
	local gi = gameInstance(pawn)
	if not gi then return nil end
	local slot = gi.activeSaveSlotName:ToString()
	if slot ~= AUTOPLAY_SLOT then
		gi.activeSaveSlotName = AUTOPLAY_SLOT
		guard.corrections = guard.corrections + 1
		guard.last_from = slot
		log(string.format("save guard: activeSaveSlotName was %q, set to %q (now %q)", slot, AUTOPLAY_SLOT,
			gi.activeSaveSlotName:ToString()))
	end
	return gi.activeSaveSlotName:ToString()
end

function M.onConnect()
	if not guard.armed then
		guard.armed = true
		log("save guard armed: the game's save slot is held on " .. AUTOPLAY_SLOT .. " until the game exits")
	end
end

function M.tick(frame)
	if not guard.armed or frame % 10 ~= 0 then return end
	local pc = controller()
	local pawn = pawnOf(pc)
	if not pawn then return end
	local level = levelName(pc)
	if level and level:find("TitleScreen", 1, true) then return end
	guardSlot(pawn)
end

-- THINGS: the actors a player meets, by class, from a census of ZONE_Dungeon's 840 actors (2026-09-23). The list is
-- rebuilt from one FindAllOf("Actor") walk when the map changes or 300 frames have passed (a walk costs about a
-- millisecond, CLAUDE.md), never per frame; each entry is re-checked with IsValid before it is read, and its position is
-- its root component's RelativeLocation -- a named read, no UFunction called on an object FindAllOf handed back.
local KIND_BY_CLASS = {
	BP_NPC_C = "npc", BP_NPC_Child_C = "npc", BP_SavePoint_C = "save_point", BP_UpgradeBase_C = "upgrade",
	BP_HealthPiece_C = "health_piece", BP_GenericKey_C = "key", BP_LockDoor_C = "locked_door",
	BP_TransitionZone_C = "exit", BP_BreakableWall_C = "breakable_wall", BP_ClimbPole_C = "pole",
	BP_HitSwitch_C = "switch", BP_ExamineTextPopup_C = "sign", BP_HazardAxe_C = "hazard", BP_HazardZone_C = "hazard",
	BP_Stalactite_C = "hazard", BP_BounceHitter_C = "bouncer", BP_TimeTrial_C = "time_trial", BP_TrialGate_C = "trial_gate",
	BP_CutAndDropPlatform_C = "platform",
}
local function kindOf(class)
	local k = KIND_BY_CLASS[class]
	if k then return k end
	if class:find("^BP_Enemy") or class:find("^BP_hazemy") then return "enemy" end
	return nil
end

local registry = { map = nil, at = -1e9, list = {} }
local function refreshRegistry(map)
	local list = {}
	for _, a in ipairs(FindAllOf("Actor") or {}) do
		local ok, class = pcall(function() return a:GetClass():GetFName():ToString() end)
		local kind = ok and kindOf(class)
		if kind and a:GetFullName():find(map, 1, true) then
			list[#list + 1] = { actor = a, class = class, kind = kind, name = a:GetFName():ToString() }
		end
	end
	registry = { map = map, at = host.frame(), list = list }
end

local function things(map, px, py, pz, limit)
	if registry.map ~= map or host.frame() - registry.at > 300 then refreshRegistry(map) end
	local out = {}
	for _, e in ipairs(registry.list) do
		local a = e.actor
		if a:IsValid() and not a.bActorIsBeingDestroyed then
			local ok, x, y, z = pcall(function()
				local l = a.RootComponent.RelativeLocation
				return l.X, l.Y, l.Z
			end)
			if ok and x then
				local dx, dy, dz = x - px, y - py, z - pz
				out[#out + 1] = { kind = e.kind, class = e.class, name = e.name, x = math.floor(x + 0.5), y = math.floor(y + 0.5),
					z = math.floor(z + 0.5), distance = math.floor(math.sqrt(dx * dx + dy * dy + dz * dz) + 0.5),
					bearing = math.floor(math.deg(math.atan(dy, dx)) + 0.5) }
			end
		end
	end
	table.sort(out, function(a, b) return a.distance < b.distance end)
	local n = #out
	for i = n, (limit or 25) + 1, -1 do out[i] = nil end
	return out, n
end

function M.observe(full)
	local o = { frame = host.frame() }
	local pc = controller()
	if not pc then
		o.mode = "no_world"
		return o
	end
	local level = levelName(pc)
	o.location = { map = mapOf(level) }
	local pawn = pawnOf(pc)
	local paused = false
	pcall(function() paused = gameplayStatics():IsGamePaused(pc) end)
	if level and level:find("TitleScreen", 1, true) then
		o.mode = "title"
	elseif not pawn then
		o.mode = "no_pawn"
	elseif paused then
		o.mode = "paused"
	else
		o.mode = "play"
	end
	if pawn then
		local loc = pawn:K2_GetActorLocation()
		local rot = pawn:K2_GetActorRotation()
		o.location.x, o.location.y, o.location.z = loc.X, loc.Y, loc.Z
		o.location.yaw = rot.Yaw
		local p = {}
		-- A property the class lacks reads as an invalid object, not nil (the title's DefaultPawn, 2026-09-23):
		-- only a number is kept.
		pcall(function() p.move_state = num(pawn.moveState) end)
		pcall(function() p.action_state = num(pawn.actionState) end)
		pcall(function() p.control_state = num(pawn.controlState) end)
		pcall(function()
			local hp = pawn.BP_HpHitable
			if hp and hp:IsValid() then p.hp, p.max_hp = num(hp.CurrentHp), num(hp.maxHP) end
		end)
		if full then
			pcall(function()
				local v = pawn:GetVelocity()
				p.velocity = { x = v.X, y = v.Y, z = v.Z }
			end)
			pcall(function() p.class = pawn:GetClass():GetFName():ToString() end)
		end
		o.player = p
		-- The camera, from the camera manager: IA_Look orbits the game's own camera rig around the player and leaves the
		-- controller's ControlRotation where it was (a 60-frame LookRight, 2026-09-23), so the view is read here.
		-- `yaw` is the direction the view looks along; MoveUp walks that way.
		pcall(function()
			local cm = pc.PlayerCameraManager
			if cm and cm:IsValid() then
				local cr, cl = cm:GetCameraRotation(), cm:GetCameraLocation()
				o.camera = { yaw = cr.Yaw, pitch = cr.Pitch, x = cl.X, y = cl.Y, z = cl.Z }
			end
		end)
	end
	if full then
		o.level = level
		local s = { guard_armed = guard.armed, corrections = guard.corrections, corrected_from = guard.last_from }
		pcall(function()
			local gi = gameInstance(pawn)
			if gi then
				s.slot = gi.activeSaveSlotName:ToString()
				s.zone = gi["Last Saved Zone Spawn In"]:ToString()
				s.save_point = gi["Last Save Point Name"]:ToString()
			end
		end)
		o.save = s
		if pawn and o.location.x and o.mode ~= "title" then
			local ok, list, n = pcall(things, o.location.map, o.location.x, o.location.y, o.location.z, 25)
			if ok then o.things, o.things_total = list, n else o.things_error = tostring(list) end
		end
	end
	return o
end

-- What a press's before and after are compared on.
function M.diffKeys(o)
	local k = { mode = o.mode, map = o.location and o.location.map }
	if o.location and o.location.x then
		k.x = math.floor(o.location.x + 0.5)
		k.y = math.floor(o.location.y + 0.5)
		k.z = math.floor(o.location.z + 0.5)
	end
	if o.player then
		k.move_state, k.action_state, k.control_state, k.hp = o.player.move_state, o.player.action_state, o.player.control_state, o.player.hp
	end
	if o.camera then
		k.camera_yaw = math.floor(o.camera.yaw + 0.5)
		k.camera_pitch = math.floor(o.camera.pitch + 0.5)
	end
	return k
end

-- Every sixth frame: the map and the mode, sent as events when they change.
function M.watch()
	local o = M.observe(false)
	return { map = o.location and o.location.map or "", mode = o.mode }
end

-- INPUT: the game's own Enhanced Input actions, injected into the local player's subsystem every frame a button is
-- held (InjectInputVectorForAction, found on EnhancedInputSubsystemInterface in this build by reflection,
-- 2026-09-23). An injected value goes through the action's own triggers and modifiers, so the pawn's input events fire
-- as they do for a pad. It only reaches actions in an applied mapping context: none is applied on the title screen,
-- whose menus read raw keys (OnKeyDown), so injection is for play. A button is its action's name without IA_; the
-- stick is MoveUp/MoveDown/MoveLeft/MoveRight (IA_Move, 2D) and the camera LookUp/LookDown/LookLeft/LookRight (IA_Look).
local AXES = {
	MoveUp = { "IA_Move", 0, 1 }, MoveDown = { "IA_Move", 0, -1 }, MoveLeft = { "IA_Move", -1, 0 }, MoveRight = { "IA_Move", 1, 0 },
	LookUp = { "IA_Look", 0, 1 }, LookDown = { "IA_Look", 0, -1 }, LookLeft = { "IA_Look", -1, 0 }, LookRight = { "IA_Look", 1, 0 },
}
local BUTTONS = {
	Jump = true, Attack = true, Crouch = true, WallRide = true, Throw = true, Guard = true, Interact = true, LockOn = true,
	Power = true, MenuAdvance = true, Pause = true, QuickMap = true, PerspectiveToggle = true,
}

local actions = nil -- name -> InputAction, found once (they are assets, loaded for the game's life)
local subsystem = nil
local function inputReady()
	if not subsystem or not subsystem:IsValid() then subsystem = FindFirstOf("EnhancedInputLocalPlayerSubsystem") end
	if not actions then
		local found = {}
		for _, a in ipairs(FindAllOf("InputAction") or {}) do found[a:GetFName():ToString()] = a end
		if found.IA_Move then actions = found end
	end
	return subsystem and subsystem:IsValid() and actions ~= nil
end

-- One frame of input: the buttons held now, as a list of names. Returns an error for a name it does not know.
local function inject(buttons)
	if not inputReady() then return "the game's input is not ready (no subsystem or actions yet)" end
	local vec = {}
	for _, b in ipairs(buttons) do
		local ax = AXES[b]
		if ax then
			local v = vec[ax[1]] or { 0, 0 }
			v[1], v[2] = v[1] + ax[2], v[2] + ax[3]
			vec[ax[1]] = v
		elseif BUTTONS[b] then
			subsystem:InjectInputVectorForAction(actions["IA_" .. b], { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {})
		else
			return "unknown button " .. tostring(b)
		end
	end
	for name, v in pairs(vec) do
		local x, y = v[1], v[2]
		local len = math.sqrt(x * x + y * y)
		if len > 1 then x, y = x / len, y / len end
		subsystem:InjectInputVectorForAction(actions[name], { X = x, Y = y, Z = 0.0 }, {}, {})
	end
	return nil
end

local function checkButtons(list)
	for _, b in ipairs(list or {}) do
		if not AXES[b] and not BUTTONS[b] then return "unknown button " .. tostring(b) end
	end
	return nil
end

M.programs = {}

-- press {buttons, frames}: held from the first frame for `frames` frames, answered on the frame after the last.
function M.programs.press(p)
	local err = checkButtons(p.buttons)
	if err then return nil, err end
	local n = tonumber(p.frames) or 1
	return function(count)
		if count > n then return true, { frames = n } end
		local e = inject(p.buttons)
		if e then return true, nil, e end
		return false
	end
end

-- sequence {steps: [{buttons, from, frames}], stop_on}: each step held from its own frame; overlaps allowed.
function M.programs.sequence(p)
	local steps, last = p.steps or {}, 0
	for _, st in ipairs(steps) do
		local err = checkButtons(st.buttons)
		if err then return nil, err end
		last = math.max(last, (st.from or 0) + (st.frames or 1))
	end
	return function(count)
		local f = count - 1 -- the sequence's own frame number, from 0
		if f >= last then return true, { frames_run = last } end
		local held = {}
		for _, st in ipairs(steps) do
			if f >= (st.from or 0) and f < (st.from or 0) + (st.frames or 1) then
				for _, b in ipairs(st.buttons) do held[#held + 1] = b end
			end
		end
		local e = inject(held)
		if e then return true, nil, e end
		return false
	end
end

-- REFLEXES: programs that read the game every frame and pick that frame's input. Measured 2026-09-23 on the Steam
-- build: MoveUp walks along the camera's yaw and MoveRight along yaw + 90; LookRight raises the camera's yaw (about
-- 1.4 degrees a frame at full tilt, 10 frames).
local function wrap(deg)
	deg = (deg + 180) % 360
	return deg - 180
end

local function playerAndCamera()
	local pc = controller()
	local pawn = pawnOf(pc)
	if not pawn then return nil end
	local cm = pc.PlayerCameraManager
	if not cm or not cm:IsValid() then return nil end
	local loc = pawn:K2_GetActorLocation()
	local cr = cm:GetCameraRotation()
	return { x = loc.X, y = loc.Y, z = loc.Z, yaw = cr.Yaw, pitch = cr.Pitch, pawn = pawn }
end

local function injectMove(x, y)
	if not inputReady() then return "the game's input is not ready" end
	subsystem:InjectInputVectorForAction(actions.IA_Move, { X = x, Y = y, Z = 0.0 }, {}, {})
end

local function injectLook(x, y)
	if not inputReady() then return "the game's input is not ready" end
	subsystem:InjectInputVectorForAction(actions.IA_Look, { X = x, Y = y, Z = 0.0 }, {}, {})
end

-- screenshot {name}: the game's own frame WITH its UI, from the engine's `shot showui` console command (HighResShot
-- leaves the UI out: the title's menu was missing from it, 2026-09-23). The engine writes ScreenShot<NNNNN>.png, the
-- first free number, into Saved\Screenshots\Windows; the driver waits until that file stops growing, copies it to
-- dev-scripts/shots/pseudoregalia/autoplay_<name>.png and removes the original, so the next is 00000 again.
local SHOT_DIR = (os.getenv("LOCALAPPDATA") or "") .. "\\pseudoregalia\\Saved\\Screenshots\\Windows\\"

local function fileSize(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local n = f:seek("end")
	f:close()
	return n
end

function M.programs.screenshot(p)
	local name = tostring(p.name or "")
	if not name:match("^[%w_%-]+$") or #name > 64 then return nil, "a screenshot name is letters, digits, _ or -" end
	local pc = controller()
	if not pc then return nil, "no player controller" end
	local expected
	for i = 0, 99999 do
		local path = string.format("%sScreenShot%05d.png", SHOT_DIR, i)
		if not fileSize(path) then expected = path break end
	end
	local out = string.format("%s/dev-scripts/shots/pseudoregalia/autoplay_%s.png", host.root, name)
	StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):ExecuteConsoleCommand(pc, "shot showui", pc)
	local lastSize, same = -1, 0
	return function(count)
		local n = fileSize(expected)
		if n and n > 0 and n == lastSize then same = same + 1 else same = 0 end
		lastSize = n or -1
		if same >= 3 then
			local src = io.open(expected, "rb")
			local data = src:read("a")
			src:close()
			local dst, err = io.open(out, "wb")
			if not dst then return true, nil, "cannot write " .. out .. ": " .. tostring(err) end
			dst:write(data)
			dst:close()
			os.remove(expected)
			return true, { path = out, bytes = #data }
		end
		if count > 300 then return true, nil, "the engine wrote no screenshot within 300 frames (" .. expected .. ")" end
		return false
	end
end

-- SNAPSHOTS. The game keeps no position in its save (a load spawns at the save point or the zone's spawn tag), so a
-- snapshot is two files: the game's own save of File 8 (`instSaveGameToSlot`, with the guard's slot checked first),
-- copied to the core's .State path, and `<path>.json` beside it with the map, position and camera. A restore copies the
-- save back over File 8, calls the game's own `reloadAndRespawn` (it put the player back on the new game's spawn,
-- 2026-09-23), waits for play, and teleports to the recorded spot on the same map.
local SAVE_DIR = (os.getenv("LOCALAPPDATA") or "") .. "\\pseudoregalia\\Saved\\SaveGames\\"
local AUTOPLAY_FILE = SAVE_DIR .. AUTOPLAY_SLOT .. ".sav"

local function readAll(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local d = f:read("a")
	f:close()
	return d
end

local function writeAll(path, data)
	local f, err = io.open(path, "wb")
	if not f then return false, err end
	f:write(data)
	f:close()
	return true
end

local function teleport(pawn, x, y, z, yaw)
	pawn:K2_SetActorLocation({ X = x, Y = y, Z = z }, false, {}, true)
	if yaw then pawn:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, true) end
	local l = pawn:K2_GetActorLocation()
	return { x = l.X, y = l.Y, z = l.Z }
end

function M.programs.snapshot(p)
	local pc = controller()
	local pawn = pawnOf(pc)
	if not pawn then return nil, "no player to snapshot" end
	if guardSlot(pawn) ~= AUTOPLAY_SLOT then return nil, "the save slot is not " .. AUTOPLAY_SLOT .. "; not saving" end
	local o = M.observe(false)
	if o.mode ~= "play" then return nil, "snapshot only in play, not " .. tostring(o.mode) end
	local before = readAll(AUTOPLAY_FILE)
	gameInstance(pawn):instSaveGameToSlot()
	local path = p.path
	return function(count)
		local now = readAll(AUTOPLAY_FILE)
		-- The save is synchronous here (File 8 changed inside the call, 2026-09-23); wait a few frames for the OS
		-- anyway, and accept an unchanged file after 30 (nothing in the save changed since the last one).
		if not now or (now == before and count < 30) then return false end
		local ok, err = writeAll(path, now)
		if not ok then return true, nil, "cannot write " .. path .. ": " .. tostring(err) end
		local side = { map = o.location.map, x = o.location.x, y = o.location.y, z = o.location.z,
			yaw = o.location.yaw, camera = o.camera, save_bytes = #now }
		writeAll(path .. ".json", host.json.encode(side))
		return true, { saved = AUTOPLAY_SLOT, bytes = #now, position = side }
	end
end

function M.programs.restore(p)
	local path = p.path
	local data = readAll(path)
	if not data then return nil, "no snapshot at " .. tostring(path) end
	local sideRaw = readAll(path .. ".json")
	local side = sideRaw and host.json.decode(sideRaw) or nil
	local pc = controller()
	local pawn = pawnOf(pc)
	if not pawn then return nil, "no player: restore from play" end
	if guardSlot(pawn) ~= AUTOPLAY_SLOT then return nil, "the save slot is not " .. AUTOPLAY_SLOT .. "; not loading" end
	local ok, err = writeAll(AUTOPLAY_FILE, data)
	if not ok then return nil, "cannot write " .. AUTOPLAY_FILE .. ": " .. tostring(err) end
	gameInstance(pawn):reloadAndRespawn()
	local old, settled, phase = pawn, 0, "reloading"
	return function(count)
		local np = pawnOf(controller())
		local o = M.observe(false)
		if phase == "reloading" then
			if np and o.mode == "play" and o.player and o.player.control_state == 0 then settled = settled + 1 else settled = 0 end
			if settled < 30 then
				if count > 1800 then return true, nil, "no play within 1800 frames of the reload" end
				return false
			end
			guardSlot(np)
			if side and side.map == o.location.map and side.x then
				local at = teleport(np, side.x, side.y, side.z, side.yaw)
				return true, { restored = AUTOPLAY_SLOT, new_pawn = np ~= old, teleported = at, map = o.location.map }
			end
			return true, { restored = AUTOPLAY_SLOT, new_pawn = np ~= old, map = o.location.map,
				note = side and ("the snapshot was on " .. tostring(side.map) .. "; left at the save's spawn") or "no position file" }
		end
		return true
	end
end

M.cheats = M.cheats or {}
M.cheats.teleport = function(a)
	local x, y, z = tonumber(a.x), tonumber(a.y), tonumber(a.z)
	if not (x and y and z) then return nil, "teleport needs x, y and z" end
	local pawn = pawnOf(controller())
	if not pawn then return nil, "no player" end
	return { held = teleport(pawn, x, y, z) }
end

M.reflexes = {}

-- walk_to {x, y, radius (default 50), stuck_frames (default 60), jump (list of frames to tap Jump on, optional)}:
-- the stick pushed toward (x, y) in world units, relative to the camera's yaw every frame. Ends `arrived` inside
-- radius (horizontal distance), `stuck` when `stuck_frames` pass without getting 5 units closer, `map_changed`,
-- `hit` when HP drops, or the frame limit. Height is not steered: a ledge in the way is `stuck`.
function M.reflexes.walk_to(a)
	local tx, ty = tonumber(a.x), tonumber(a.y)
	if not tx or not ty then return nil, "walk_to needs x and y" end
	local radius = tonumber(a.radius) or 50
	local stuckFrames = tonumber(a.stuck_frames) or 60
	local start = playerAndCamera()
	if not start then return nil, "no player" end
	local map0 = M.observe(false).location.map
	local hp0 = M.observe(false).player.hp
	local best, bestAt = math.huge, 0
	return function(count)
		local s = playerAndCamera()
		if not s then return true, { outcome = "no_player" } end
		local o = M.observe(false)
		if o.location.map ~= map0 then return true, { outcome = "map_changed" } end
		if hp0 and o.player.hp and o.player.hp < hp0 then return true, { outcome = "hit", hp = o.player.hp } end
		local dx, dy = tx - s.x, ty - s.y
		local d = math.sqrt(dx * dx + dy * dy)
		if d <= radius then return true, { outcome = "arrived", distance = d } end
		if d < best - 5 then best, bestAt = d, count end
		if count - bestAt > stuckFrames then return true, { outcome = "stuck", distance = d } end
		local rel = math.rad(math.deg(math.atan(dy, dx)) - s.yaw)
		local e = injectMove(math.sin(rel), math.cos(rel))
		if e then return true, nil, e end
		return false
	end
end

-- look {yaw, pitch (optional), tolerance (default 2)}: the camera turned with IA_Look, slowing as it nears, until
-- its yaw (and pitch, if asked) is within tolerance degrees. Ends `done`, or `stuck` after 30 frames with no turn.
function M.reflexes.look(a)
	local want = tonumber(a.yaw)
	if not want then return nil, "look needs yaw" end
	local wantPitch = tonumber(a.pitch)
	local tol = tonumber(a.tolerance) or 2
	local last, still = nil, 0
	return function()
		local s = playerAndCamera()
		if not s then return true, { outcome = "no_player" } end
		local dyaw = wrap(want - s.yaw)
		local dpitch = wantPitch and (wantPitch - s.pitch) or 0
		if math.abs(dyaw) <= tol and math.abs(dpitch) <= tol then
			return true, { outcome = "done", yaw = s.yaw, pitch = s.pitch }
		end
		if last and math.abs(wrap(s.yaw - last.yaw)) < 0.01 and math.abs(s.pitch - last.pitch) < 0.01 then
			still = still + 1
			if still > 30 then return true, { outcome = "stuck", yaw = s.yaw, pitch = s.pitch } end
		else
			still = 0
		end
		last = s
		local x = math.max(-1, math.min(1, dyaw / 20))
		-- A positive IA_Look Y raises the camera's pitch (it drove it from 0 to its limit of 50, 2026-09-23), so the
		-- push is the opposite of the pitch still to go.
		local y = math.max(-1, math.min(1, -dpitch / 20))
		local e = injectLook(x, y)
		if e then return true, nil, e end
		return false
	end
end

function M.start()
	return "pseudoregalia module ready"
end

return M
