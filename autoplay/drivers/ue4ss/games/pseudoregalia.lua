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
	capabilities = { "wait", "press", "sequence", "screenshot", "snapshot", "restore", "advance_text", "recent", "cheat:teleport", "reflex:walk_to", "reflex:goto", "reflex:reach", "reflex:fight", "reflex:look" },
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

-- THE FLIGHT RECORDER: one row a frame of the player's position, speed, states and the camera's yaw, the last
-- RECORD_FRAMES frames, recorded whether or not a core is connected, for `recent`.
local RECORD_FRAMES = 600
local TRAIL_ROWS = 20000
local trail, trailN = {}, 0
local rec = {}
local function record(frame, pc, pawn)
	local ok, row = pcall(function()
		local l = pawn:K2_GetActorLocation()
		local v = pawn:GetVelocity()
		local r = { f = frame, x = math.floor(l.X + 0.5), y = math.floor(l.Y + 0.5), z = math.floor(l.Z + 0.5),
			vz = math.floor(v.Z + 0.5), hs = math.floor(math.sqrt(v.X * v.X + v.Y * v.Y) + 0.5),
			ms = num(pawn.moveState), as = num(pawn.actionState), cs = num(pawn.controlState) }
		local cm = pc.PlayerCameraManager
		if cm and cm:IsValid() then r.cam = math.floor(cm:GetCameraRotation().Yaw + 0.5) end
		return r
	end)
	if ok then
		rec[frame % RECORD_FRAMES] = row
		if frame % 3 == 0 then
			trailN = trailN + 1
			trail[trailN % TRAIL_ROWS] = row
		end
	end
end

-- THE LONG TRAIL: every 3rd recorded row kept for TRAIL_ROWS rows (about 7 minutes at 144 frames a second), so a
-- path the user plays to show the way (their offer, 2026-09-23) can be read back through `exec`:
-- `game.trail_since(frame)` returns the rows after that frame.
function M.trail_since(frame, limit)
	local out = {}
	for i = math.max(1, trailN - TRAIL_ROWS + 1), trailN do
		local r = trail[i % TRAIL_ROWS]
		if r and r.f > frame then
			out[#out + 1] = r
			if limit and #out >= limit then break end
		end
	end
	return out
end

function M.recent(p)
	local newest = host.frame()
	local untilF = tonumber(p.until_frame) or newest
	local n, every = tonumber(p.frames) or 120, tonumber(p.every) or 1
	local rows = {}
	for f = untilF - n + 1, untilF, every do
		local r = rec[f % RECORD_FRAMES]
		if r and r.f == f then rows[#rows + 1] = r end
	end
	return { rows = rows, newest = newest,
		columns = "f frame, x y z position, vz vertical speed, hs horizontal speed, ms moveState, as actionState, cs controlState, cam camera yaw" }
end

function M.tick(frame)
	local pc = controller()
	local pawn = pawnOf(pc)
	if pawn then record(frame, pc, pawn) end
	if not guard.armed or frame % 10 ~= 0 then return end
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
				local t = { kind = e.kind, class = e.class, name = e.name, x = math.floor(x + 0.5), y = math.floor(y + 0.5),
					z = math.floor(z + 0.5), distance = math.floor(math.sqrt(dx * dx + dy * dy + dz * dz) + 0.5),
					bearing = math.floor(math.deg(math.atan(dy, dx)) + 0.5) }
				-- A sign's own words, its prompt (EXAMINE, REFLECT) and whether the player stands where Interact reads it
				-- (BP_ExamineTextPopup_C's textWindows, popupPrompt and overlappingPlayer?, by name, 2026-09-23).
				if e.kind == "sign" and t.distance < 3000 then
					pcall(function()
						t.prompt = a.popupPrompt:ToString()
						t.in_range = a["overlappingPlayer?"]
						local lines = {}
						a.textWindows:ForEach(function(_, el) lines[#lines + 1] = el:get():ToString() end)
						t.text = table.concat(lines, " / ")
					end)
				end
				out[#out + 1] = t
			end
		end
	end
	table.sort(out, function(a, b) return a.distance < b.distance end)
	local n = #out
	for i = n, (limit or 25) + 1, -1 do out[i] = nil end
	return out, n
end

-- SURROUNDINGS: what the level's collision says around the player, by the engine's own line traces
-- (KismetSystemLibrary:LineTraceSingle on trace channel 0, which stopped at the room's walls and at a cage beside her,
-- 2026-09-23). `walls`: the distance to the first hit along 16 bearings (0, 22.5, ... degrees, world yaw; 0 is +x),
-- capped at WALL_RANGE. `floor`: along 8 bearings, the floor's height at 150, 400 and 800 units out, relative to the
-- floor under her (0 level, negative a drop, positive a step or ledge up), nil where nothing is found within 3000 below
-- (a pit), "wall" where the wall on that bearing is nearer. `ceiling`: the distance straight up. Each trace ignores the player.
local WALL_RANGE = 2000
local ksl = nil
local function trace(pawn, x1, y1, z1, x2, y2, z2)
	if not ksl or not ksl:IsValid() then ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
	local hit = {}
	local r = ksl:LineTraceSingle(pawn, { X = x1, Y = y1, Z = z1 }, { X = x2, Y = y2, Z = z2 }, 0, false, {}, 0, hit, true,
		{ R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0)
	if r and hit.Location then return hit.Distance, hit.Location.Z end
	return nil
end

local function surroundings(pawn, x, y, z)
	local s = { walls = {}, floor = {} }
	local _, floorZ = trace(pawn, x, y, z, x, y, z - 3000)
	s.floor_z = floorZ and math.floor(floorZ + 0.5)
	local up = trace(pawn, x, y, z, x, y, z + 3000)
	s.ceiling = up and math.floor(up + 0.5)
	for i = 0, 15 do
		local r = math.rad(i * 22.5)
		local d = trace(pawn, x, y, z, x + WALL_RANGE * math.cos(r), y + WALL_RANGE * math.sin(r), z)
		s.walls[i + 1] = d and math.floor(d + 0.5) or WALL_RANGE
	end
	for i = 0, 7 do
		local r = math.rad(i * 45)
		local row = {}
		for j, dist in ipairs({ 150, 400, 800 }) do
			local fx, fy = x + dist * math.cos(r), y + dist * math.sin(r)
			local _, hz = trace(pawn, fx, fy, z + 150, fx, fy, z - 3000)
			if dist >= s.walls[2 * i + 1] then
				row[j] = "wall" -- past the wall on this bearing: what lies there is not reachable in a line
			else
				row[j] = (hz and floorZ) and math.floor(hz - floorZ + 0.5) or host.json.null
			end
		end
		s.floor[i + 1] = row
	end
	s.bearings = "walls: 16 at 22.5-degree steps from 0 (+x); floor: 8 at 45-degree steps, at 150/400/800 out"
	return s
end

-- DIALOGUE: a conversation's words are the game instance's UI_DialoguePrompt_C: `Text Bubbles` (every line, with the
-- game's markup: [3rr] a pause, [#cf2525](word) a colour), `currentLine` (from 1), `writing` while a line prints,
-- `canClose?` (an NPC conversation, 2026-09-23). Finished prompts linger until garbage collection (MEASURED.md,
-- "what marks talking"), so the newest -- the lowest name number, the one created last -- is read, and only while
-- controlState says she is reading or talking. A sign's words come from the sign itself (`things`).
local function plainText(s)
	s = s:gsub("%[%d*rr%]", ""):gsub("%[#%x+%]%(([^)]*)%)", "%1")
	return s
end

local function dialogue()
	local best, bestN = nil, math.huge
	for _, w in ipairs(FindAllOf("UI_DialoguePrompt_C") or {}) do
		local full = w:GetFullName()
		if full:find("Transient", 1, true) then
			local n = tonumber(full:match("UI_DialoguePrompt_C_(%d+)$") or "")
			if n and n < bestN then best, bestN = w, n end
		end
	end
	if not best then return nil end
	local d = {}
	pcall(function()
		local lines = {}
		best["Text Bubbles"]:ForEach(function(_, e) lines[#lines + 1] = plainText(e:get():ToString()) end)
		d.lines = lines
		d.line = best.currentLine
		d.writing = best.writing
		d.can_close = best["canClose?"]
	end)
	return d
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
		if o.player and (o.player.control_state or 0) ~= 0 then
			local ok, d = pcall(dialogue)
			if ok and d then o.dialogue = d end
		end
		if pawn and o.location.x and o.mode ~= "title" then
			local ok, list, n = pcall(things, o.location.map, o.location.x, o.location.y, o.location.z, 25)
			if ok then o.things, o.things_total = list, n else o.things_error = tostring(list) end
			local ok2, sur = pcall(surroundings, pawn, o.location.x, o.location.y, o.location.z)
			if ok2 then o.surroundings = sur else o.surroundings_error = tostring(sur) end
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

-- advance_text {every (default 45), max_taps (default 20)}: while the player reads or talks (`controlState` 1 or 2,
-- the values an NPC conversation and a book gave, MEASURED.md 2026-09-23; a mirror gave 2 the same day), tap
-- MenuAdvance for 4 frames every `every` frames. Ends `closed` once `controlState` is back to 0 for 10 frames,
-- `not_reading` if it was 0 from the start, or `stuck` after max_taps with no close.
function M.programs.advance_text(p)
	local every, maxTaps = tonumber(p.every) or 45, tonumber(p.max_taps) or 20
	local o = M.observe(false)
	if not o.player or (o.player.control_state or 0) == 0 then return nil, "not reading or talking: controlState is 0" end
	local taps, since, zero = 0, 0, 0
	local okD, d0 = pcall(dialogue)
	local seen = (okD and d0 and d0.lines) or nil
	return function()
		local cs = M.observe(false).player.control_state or 0
		if cs == 0 then zero = zero + 1 else zero = 0 end
		if zero >= 10 then return true, { outcome = "closed", taps = taps, log = seen } end
		since = since + 1
		if cs ~= 0 and since >= every then
			if taps >= maxTaps then return true, { outcome = "stuck", taps = taps, control_state = cs } end
			taps, since = taps + 1, 0
		end
		if cs ~= 0 and since < 4 and taps > 0 then
			local e = inject({ "MenuAdvance" })
			if e then return true, nil, e end
		end
		return false
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

-- goto {x, y, z (optional), radius (default 60), max_cells (default 6000), plan_only}: a route over the level's own collision,
-- then walked. The floor is 50-unit cells, each one's height found by a downward trace (LineTraceSingle, channel 0) and
-- kept only where the surface is walkable (ImpactNormal.Z at least the movement component's WalkableFloorZ, 0.643);
-- a move between cells is allowed when the player's own capsule (radius 22, half-height 65, read 2026-09-23), swept
-- by CapsuleTraceSingle along it, hits nothing: level or within MaxStepHeight (45) it is walked, a rise of 45-170 is
-- jumped (a 200 ledge was climbed; the highest jump measured was 206), a drop of up to 600 is stepped off. A* runs a batch of cells a frame,
-- evaluating a cell only when the search reaches it, so nothing is traced that the route never needs. The walk then
-- steers to each cell of the route (the stick from the camera's yaw, as walk_to), holding Jump for 30 frames when the
-- next cell is a rise and she is within 75 units of it. It plans again from where she stands when 90 frames pass with
-- no cell reached (twice, each with at most 2500 cells). Ends `arrived`, `no_route` (with how far the nearest reachable cell is), `stuck`, `hit`,
-- `map_changed`, or the frame limit.
local CELL = 50
local CAP_R, CAP_H = 20, 62 -- a little inside the capsule's 22/65, so brushing a wall does not close a route
local FEET = 67 -- the capsule's centre above the floor: z -332.85 over a floor traced at -400
-- JUMP_UP: a ledge 200 over the hall's floor in ZONE_Dungeon was climbed by a running jump with Jump held 80 frames
-- (2026-09-23); the highest free jump measured was 206.
local STEP_UP, JUMP_UP, DROP = 45, 200, 600
-- FLIP_UP: the backflip (forward, reverse, Jump during the skid -- actionState 18 --, forward again; the user's
-- description, confirmed on screen 2026-09-23) peaked 265 over its takeoff, about 40 units past it, rising nearly
-- straight; Jump pressed 1 to 16 frames into the skid gave the same peak.
local FLIP_UP = 250
-- GRAB_UP: a rise a running jump reaches by catching the ledge (moveState 3) and climbing; the user's run climbed 286
-- that way (2026-09-23). The flip stays for rises a grab cannot use (a fence has no ledge: the user, same day).
local GRAB_UP = 320
-- A leap across a gap of k cells may land at most this much higher. The user's run (2026-09-23) jumped from the cage
-- platform onto a block 200 higher ~240 units away; a full jump rises 206.
local LEAP_UP = { [2] = 200, [3] = 200, [4] = 200, [5] = 200 }
-- Further, a leap lands only by catching the ledge: the user's grab hops rose 178 across 661 and 286 across 283.
for k = 6, 12 do LEAP_UP[k] = 280 end
local LEAP_CELLS = 12
local EXPAND_PER_FRAME = 12

local function sweep(pawn, x1, y1, z1, x2, y2, z2)
	if not ksl or not ksl:IsValid() then ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
	local hit = {}
	local r = ksl:CapsuleTraceSingle(pawn, { X = x1, Y = y1, Z = z1 }, { X = x2, Y = y2, Z = z2 }, CAP_R, CAP_H, 0, false,
		{}, 0, hit, true, { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0)
	return r == true
end

local function floorProbe(pawn, x, y, fromZ, walkableZ)
	if not ksl or not ksl:IsValid() then ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
	local hit = {}
	local r = ksl:LineTraceSingle(pawn, { X = x, Y = y, Z = fromZ }, { X = x, Y = y, Z = fromZ - 1400 }, 0, false, {}, 0, hit,
		true, { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0)
	if not r or not hit.Location then return nil end
	if hit.ImpactNormal and hit.ImpactNormal.Z < walkableZ then return nil end
	return hit.Location.Z
end

local function newPlan(pawn, sx, sy, sz, tx, ty, maxCells)
	local walkableZ = 0.64
	pcall(function() walkableZ = pawn.CharacterMovement.WalkableFloorZ end)
	local P = { pawn = pawn, cells = {}, open = {}, closed = {}, came = {}, g = {}, edge = {}, count = 0,
		maxCells = maxCells, walkableZ = walkableZ, tx = tx, ty = ty, hopOf = {} }
	pcall(function() P.hops = M.hops_for(M.observe(false).location.map) or nil end) -- defined further down
	local function cellOf(x, y) return math.floor(x / CELL + 0.5), math.floor(y / CELL + 0.5) end
	P.cellOf = cellOf
	local six, siy = cellOf(sx, sy)
	P.gix, P.giy = cellOf(tx, ty)
	local startKey = six .. "," .. siy
	-- The start cell's sweeps begin where she stands, not at the grid point: pressed to a wall, the grid point was
	-- inside it and every move from it was refused (no_route after 1 cell, 2026-09-23).
	P.cells[startKey] = { ix = six, iy = siy, z = sz - FEET, px = sx, py = sy }
	P.g[startKey] = 0
	P.open = { { k = startKey, f = 0 } }
	P.best, P.bestH = startKey, math.huge
	return P
end

local function heapPush(h, item)
	h[#h + 1] = item
	local i = #h
	while i > 1 do
		local p = i // 2
		if h[p].f <= h[i].f then break end
		h[p], h[i] = h[i], h[p]
		i = p
	end
end

local function heapPop(h)
	local top = h[1]
	local last = table.remove(h)
	if #h > 0 then
		h[1] = last
		local i = 1
		while true do
			local l, r, s = 2 * i, 2 * i + 1, i
			if l <= #h and h[l].f < h[s].f then s = l end
			if r <= #h and h[r].f < h[s].f then s = r end
			if s == i then break end
			h[s], h[i] = h[i], h[s]
			i = s
		end
	end
	return top
end

-- HOPS: jumps a person played, from games/pseudoregalia/routes/<map>_hops.json (the user's run to the sword, 2026-09-23),
-- offered to the search as moves: from a cell within 80 of a hop's takeoff and at its height, to its landing.
local hopCache = {}
local function hopsFor(map)
	if hopCache[map] ~= nil then return hopCache[map] end
	local name = map and map:gsub("^ZONE_", ""):lower() or ""
	local f = io.open(host.root .. "/autoplay/games/pseudoregalia/routes/" .. name .. "_hops.json", "r")
	local list = false
	if f then
		local ok, doc = pcall(host.json.decode, f:read("a"))
		f:close()
		if ok and type(doc) == "table" and doc.hops then list = doc.hops end
	end
	hopCache[map] = list
	return list
end

M.hops_for = function(map) return hopsFor(map) end -- for exec, to check what the search is offered

local NEIGHBOURS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }

-- How close a landing is to its platform's edge: of the cells around it up to two out, how many are lower by more than a
-- step or have no floor. The user (2026-09-23): land on the middle of a platform, not its lip, so there is room to stand
-- and take the next jump. Each such cell adds LAND_EDGE_COST to a jump, grab, flip or leap landing there.
local LAND_EDGE_COST = 25
local function edgeCells(P, ix, iy, z)
	local n = 0
	for ox = -2, 2 do
		for oy = -2, 2 do
			if ox ~= 0 or oy ~= 0 then
				local k = (ix + ox) .. "," .. (iy + oy)
				local m = P.cells[k]
				if m == nil then
					local mz = floorProbe(P.pawn, (ix + ox) * CELL, (iy + oy) * CELL, z + JUMP_UP + FEET, P.walkableZ)
					m = { ix = ix + ox, iy = iy + oy, z = mz or false }
					P.cells[k] = m
				end
				if not m.z or m.z < z - STEP_UP then n = n + 1 end
			end
		end
	end
	return n
end

-- Runs up to EXPAND_PER_FRAME expansions. Returns "found", "exhausted" or nil (still searching).
local function planStep(P)
	for _ = 1, EXPAND_PER_FRAME do
		if #P.open == 0 then return "exhausted" end
		local cur = heapPop(P.open)
		if not P.closed[cur.k] then
			P.closed[cur.k] = true
			P.count = P.count + 1
			local c = P.cells[cur.k]
			local hx, hy = (P.gix - c.ix) * CELL, (P.giy - c.iy) * CELL
			local h = math.sqrt(hx * hx + hy * hy)
			if h < P.bestH then P.best, P.bestH = cur.k, h end
			if c.ix == P.gix and c.iy == P.giy then P.goal = cur.k return "found" end
			if P.count >= P.maxCells then return "exhausted" end
			local ax, ay = c.px or c.ix * CELL, c.py or c.iy * CELL
			for _, d in ipairs(NEIGHBOURS) do
				local nix, niy = c.ix + d[1], c.iy + d[2]
				local nk = nix .. "," .. niy
				if not P.closed[nk] then
					local bx, by = nix * CELL, niy * CELL
					local nz = P.cells[nk] and P.cells[nk].z
					if nz == nil and P.cells[nk] == nil then
						nz = floorProbe(P.pawn, bx, by, c.z + JUMP_UP + FEET, P.walkableZ)
						-- A ledge taller than a jump starts above that probe: look again from a grab's height, and keep
						-- what it finds only when it is such a ledge (from that high, most probes meet overhangs).
						local hz = floorProbe(P.pawn, bx, by, c.z + GRAB_UP + 40, P.walkableZ)
						if hz and hz > c.z + JUMP_UP and hz <= c.z + GRAB_UP and (not nz or nz < hz - 100) then nz = hz end
						P.cells[nk] = { ix = nix, iy = niy, z = nz or false }
					end
					if nz then
						local dz = nz - c.z
						local kind, ok = nil, false
						local ca, cb = c.z + FEET, nz + FEET
						if dz > GRAB_UP or dz < -DROP then
							ok = false
						elseif dz > STEP_UP then
							kind = dz > FLIP_UP and "grab" or (dz > JUMP_UP and "flip" or "jump")
							ok = not sweep(P.pawn, ax, ay, ca + 2, ax, ay, cb + 8) and not sweep(P.pawn, ax, ay, cb + 8, bx, by, cb + 8)
						elseif dz < -STEP_UP then
							kind = "drop"
							ok = not sweep(P.pawn, ax, ay, ca + 2, bx, by, ca + 2)
						else
							kind = "walk"
							-- Just over the higher floor: lifted by a whole step height, the capsule met the ceiling of a
							-- low passage and a false wall closed the route (2026-09-23).
							local top = math.max(ca, cb) + 3
							ok = not sweep(P.pawn, ax, ay, top, bx, by, top)
						end
						if ok then
							local step = (d[1] ~= 0 and d[2] ~= 0) and CELL * 1.4142 or CELL
							local cost = P.g[cur.k] + step + (kind == "jump" and 80 or 0) + (kind == "flip" and 200 or 0) + (kind == "grab" and 150 or 0) + (kind == "drop" and 20 or 0)
							if kind == "jump" or kind == "flip" or kind == "grab" then cost = cost + LAND_EDGE_COST * edgeCells(P, nix, niy, nz) end
							if P.g[nk] == nil or cost < P.g[nk] then
								P.g[nk], P.came[nk], P.edge[nk] = cost, cur.k, kind
								local gx, gy = (P.gix - nix) * CELL, (P.giy - niy) * CELL
								heapPush(P.open, { k = nk, f = cost + math.sqrt(gx * gx + gy * gy) })
							end
						end
					end
				end
			end
			if P.hops then
				local cx, cy = c.px or c.ix * CELL, c.py or c.iy * CELL
				for hi, h in ipairs(P.hops) do
					local t = h.takeoff
					local ddx, ddy = t[1] - cx, t[2] - cy
					if ddx * ddx + ddy * ddy <= 80 * 80 and math.abs(t[3] - c.z) <= 40 then
						local l = h.landing
						local nix, niy = P.cellOf(l[1], l[2])
						local nk = nix .. "," .. niy
						if not P.closed[nk] then
							if P.cells[nk] == nil or not P.cells[nk].z then P.cells[nk] = { ix = nix, iy = niy, z = l[3] } end
							local dist = math.sqrt((l[1] - t[1]) ^ 2 + (l[2] - t[2]) ^ 2)
							local cost = P.g[cur.k] + dist + 150
							if P.g[nk] == nil or cost < P.g[nk] then
								P.g[nk], P.came[nk], P.edge[nk], P.hopOf[nk] = cost, cur.k, "hop", hi
								local gx, gy = (P.gix - nix) * CELL, (P.giy - niy) * CELL
								heapPush(P.open, { k = nk, f = cost + math.sqrt(gx * gx + gy * gy) })
							end
						end
					end
				end
			end
			-- LEAPS: across a gap (every cell under the line lower than both ends by a step, or no floor) onto a floor up
			-- to 5 cells away in any direction and at most LEAP_UP[k] higher -- the user's run to the sword (2026-09-23)
			-- jumped from the cage platform onto a block 200 higher, 100 across and 200 along. Only from an edge cell (one
			-- with a neighbour a step lower or missing), so a floor's inner cells cost nothing. The capsule is swept up from
			-- the takeoff and across the air above both ends.
			local edge = false
			for _, d in ipairs(NEIGHBOURS) do
				local m = P.cells[(c.ix + d[1]) .. "," .. (c.iy + d[2])]
				if m and (not m.z or m.z < c.z - STEP_UP) then edge = true break end
			end
			if edge then
				for dx = -LEAP_CELLS, LEAP_CELLS do
					for dy = -LEAP_CELLS, LEAP_CELLS do
						local k = math.max(math.abs(dx), math.abs(dy))
						if k >= 2 then
							local nix, niy = c.ix + dx, c.iy + dy
							local nk = nix .. "," .. niy
							if not P.closed[nk] then
								local bx, by = nix * CELL, niy * CELL
								local nz = P.cells[nk] and P.cells[nk].z
								if nz == nil and P.cells[nk] == nil then
									nz = floorProbe(P.pawn, bx, by, c.z + JUMP_UP + FEET, P.walkableZ)
									P.cells[nk] = { ix = nix, iy = niy, z = nz or false }
								end
								if nz and nz - c.z <= LEAP_UP[k] and nz - c.z >= -300 then
									local low = math.min(c.z, nz) - STEP_UP
									local gap, steps = true, k * 2
									for t = 1, steps - 1 do
										local mx = math.floor(c.ix + dx * t / steps + 0.5)
										local my = math.floor(c.iy + dy * t / steps + 0.5)
										if not (mx == c.ix and my == c.iy) and not (mx == nix and my == niy) then
											local mk = mx .. "," .. my
											local m = P.cells[mk]
											if m == nil then
												local mz = floorProbe(P.pawn, mx * CELL, my * CELL, c.z + JUMP_UP + FEET, P.walkableZ)
												m = { ix = mx, iy = my, z = mz or false }
												P.cells[mk] = m
											end
											-- Part of the takeoff or the landing platform, not the gap: its own edge cells lay
											-- under the line, and every leap onto a block was refused (2026-09-23).
											local own = m.z and ((t * 2 <= steps and math.abs(m.z - c.z) < 20) or (t * 2 >= steps and math.abs(m.z - nz) < 20))
											if m.z and m.z > low and not own then gap = false break end
										end
									end
									if gap then
										local ca, cb = c.z + FEET, nz + FEET
										local top = math.max(ca, cb) + 40
										if not sweep(P.pawn, ax, ay, ca + 2, ax, ay, top) and not sweep(P.pawn, ax, ay, top, bx, by, top) then
											local dist = math.sqrt(dx * dx + dy * dy) * CELL
											-- Long leaps are risky (a 500-wide diagonal one fell short, 2026-09-23): past 250
											-- each unit costs double, so a shorter straight one wins when there is one.
											local cost = P.g[cur.k] + dist + 100 + math.max(0, dist - 250) * 2 + LAND_EDGE_COST * edgeCells(P, nix, niy, nz)
											if P.g[nk] == nil or cost < P.g[nk] then
												P.g[nk], P.came[nk], P.edge[nk] = cost, cur.k, "leap"
												local gx, gy = (P.gix - nix) * CELL, (P.giy - niy) * CELL
												heapPush(P.open, { k = nk, f = cost + math.sqrt(gx * gx + gy * gy) })
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end
	return nil
end

local function pathOf(P, key)
	local path = {}
	while key do
		local c = P.cells[key]
		local hop = P.hopOf and P.hopOf[key] and P.hops[P.hopOf[key]] or nil
		table.insert(path, 1, { x = hop and hop.landing[1] or c.ix * CELL, y = hop and hop.landing[2] or c.iy * CELL, z = c.z, edge = P.edge[key], hop = hop })
		key = P.came[key]
	end
	return path
end

M.reflexes["goto"] = function(a) -- `goto` is a Lua keyword, so it is set by its string key
	local tx, ty = tonumber(a.x), tonumber(a.y)
	if not tx or not ty then return nil, "goto needs x and y" end
	local radius = tonumber(a.radius) or 60
	local maxCells = tonumber(a.max_cells) or 6000
	local s = playerAndCamera()
	if not s then return nil, "no player" end
	local o0 = M.observe(false)
	local map0, hp0 = o0.location.map, o0.player.hp
	local P = newPlan(s.pawn, s.x, s.y, s.z, tx, ty, maxCells)
	local path, wp, lastProgress, replans, jumpLeft, flip, hopState, hang, jumpT, leap = nil, 2, 0, 0, 0, nil, nil, 0, 0, nil
	local planned, planFrames, stats = 0, 0, {}
	return function(count)
		local st = playerAndCamera()
		if not st then return true, { outcome = "no_player" } end
		local o = M.observe(false)
		if o.location.map ~= map0 then return true, { outcome = "map_changed" } end
		if hp0 and o.player.hp and o.player.hp < hp0 then return true, { outcome = "hit", hp = o.player.hp } end
		local dxT, dyT = tx - st.x, ty - st.y
		-- Arrived only once landed: the check is horizontal, and it had ended mid-jump at z -155 over a floor at -300.
		if math.sqrt(dxT * dxT + dyT * dyT) <= radius and (o.player.move_state or 0) == 0 then
			return true, { outcome = "arrived", distance = math.sqrt(dxT * dxT + dyT * dyT), cells_searched = planned, replans = replans }
		end
		if not path then
			planFrames = planFrames + 1
			local r = planStep(P)
			if r == "found" then
				path = pathOf(P, P.goal)
			elseif r == "exhausted" and P.bestH <= radius + CELL then
				-- The target itself is not standable (inside a wall), but a cell within reach of it is: go there.
				path = pathOf(P, P.best)
			elseif r == "exhausted" then
				local best = P.cells[P.best]
				return true, { outcome = "no_route", cells_searched = P.count,
					nearest = { x = best.ix * CELL, y = best.iy * CELL, z = best.z, distance_to_target = math.floor(P.bestH + 0.5) } }
			end
			if not path then return false end
			if a.plan_only then
				local jumps, hopsN = 0, 0
				for _, c in ipairs(path) do
					if c.edge == "jump" or c.edge == "leap" or c.edge == "grab" or c.edge == "flip" then jumps = jumps + 1 end
					if c.edge == "hop" then hopsN = hopsN + 1 end
				end
				local last = path[#path]
				return true, { outcome = "planned", cells_searched = P.count, path_cells = #path, jumps = jumps, hops = hopsN,
					ends = { x = last.x, y = last.y, z = last.z } }
			end
			planned = planned + P.count
			wp, lastProgress = 2, count
			stats.path_cells = #path
			local jumps = 0
			local flips = 0
			for _, c in ipairs(path) do
				if c.edge == "jump" then jumps = jumps + 1 end
				if c.edge == "flip" then flips = flips + 1 end
			end
			stats.jumps, stats.flips = jumps, flips
		end
		local target = path[wp]
		if not target then
			-- The route is walked: the goal cell, or the nearest cell to an unstandable target. Answer once landed.
			if (o.player.move_state or 0) == 0 then
				return true, { outcome = "arrived", distance = math.sqrt(dxT * dxT + dyT * dyT), cells_searched = planned,
					replans = replans, note = "the end of the route; the target point itself was not reached" }
			end
			return false
		end
		-- A hop next: run straight at its takeoff instead of threading the last cells, which slowed her to a walk at
		-- the edge the user took at full speed, and she slid off it (2026-09-23).
		local nxt = path[wp + 1]
		if target.edge ~= "hop" and nxt and nxt.edge == "hop" and nxt.hop then
			local kx, ky = nxt.hop.takeoff[1] - st.x, nxt.hop.takeoff[2] - st.y
			if kx * kx + ky * ky < 200 * 200 and math.abs((st.z - FEET) - nxt.hop.takeoff[3]) < 60 then
				wp, target = wp + 1, nxt
			end
		end
		local dx, dy = target.x - st.x, target.y - st.y
		local d = math.sqrt(dx * dx + dy * dy)
		local feetZ = st.z - FEET
		-- Reached only when standing: counted mid-climb, she steered at the next leap's landing in the air and sailed
		-- over the ledge she had just caught (2026-09-23).
		if d < 30 and math.abs(feetZ - target.z) < 60 and (o.player.move_state or 0) == 0 then
			wp, lastProgress = wp + 1, count
			return false
		end
		-- Moved off the route (the user moved her, to see what it does, 2026-09-23): plan again from here, once standing.
		local pv = path[wp - 1]
		if not leap and not hopState and not flip and (o.player.move_state or 0) == 0 and pv then
			local px, py = pv.x - st.x, pv.y - st.y
			if d > 300 and math.sqrt(px * px + py * py) > 300 then
				P = newPlan(st.pawn, st.x, st.y, st.z, tx, ty, maxCells)
				path, lastProgress = nil, count
				return false
			end
		end
		if count - lastProgress > 90 and (o.player.move_state or 0) ~= 0 and (o.player.move_state or 0) ~= 2 then
			return false -- never plan again mid-air: the start would be taken at the height of the jump (2026-09-23)
		end
		if count - lastProgress > 90 then
			if replans >= 2 then return true, { outcome = "stuck", at = { x = st.x, y = st.y, z = st.z }, route = stats, on = { x = target.x, y = target.y, z = target.z, edge = target.edge, wp = wp, of = #path } } end
			replans = replans + 1
			-- A re-plan stands still while it searches, so it gets a smaller budget: three full ones stood in place until
			-- the frame limit (2026-09-23).
			P = newPlan(st.pawn, st.x, st.y, st.z, tx, ty, math.min(maxCells, 2500))
			path, lastProgress = nil, count
			return false
		end
		-- A hop: run to its takeoff, jump there (Jump held 80 frames) steering at its landing; hanging on a ledge
		-- (moveState 3), keep pushing at the landing and tap Jump to climb. Done when landed near the landing; landed
		-- anywhere else, the route is planned again.
		if target.edge == "hop" and target.hop then
			local h = target.hop
			hopState = hopState or { phase = "run", t = 0, air = 0 }
			local hs = hopState
			hs.t = hs.t + 1
			local ms = o.player.move_state or 0
			local gx, gy
			if hs.phase == "run" then
				gx, gy = h.takeoff[1] - st.x, h.takeoff[2] - st.y
				local td = math.sqrt(gx * gx + gy * gy)
				-- At the takeoff, or off its edge near it: the jump in coyote time the user used (2026-09-23).
				if td < 25 or (ms == 1 and td < 150) then hs.phase, hs.t = "air", 0 end
			end
			if hs.phase ~= "run" then
				gx, gy = h.landing[1] - st.x, h.landing[2] - st.y
				-- Jump held until she stops rising (a full jump), then let go: held on into the landing, the game took it
				-- as a new jump the moment she landed (2026-09-23).
				local vz = 0
				pcall(function() vz = st.pawn:GetVelocity().Z end)
				if not hs.released and (hs.t <= 8 or vz > 20) and hs.t <= 80 and inputReady() then
					subsystem:InjectInputVectorForAction(actions.IA_Jump, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {})
				elseif hs.t > 8 then
					hs.released = true
				end
				if ms == 3 then
					hs.hang = (hs.hang or 0) + 1
					if hs.hang > 5 and hs.hang % 20 < 5 and inputReady() then
						subsystem:InjectInputVectorForAction(actions.IA_Jump, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {})
					end
				end
				if ms ~= 0 then hs.air = hs.air + 1 end
				if ms == 0 and hs.air > 10 then
					local lx, ly = h.landing[1] - st.x, h.landing[2] - st.y
					hopState = nil
					if math.sqrt(lx * lx + ly * ly) < 150 and math.abs((st.z - FEET) - h.landing[3]) < 60 then
						wp, lastProgress = wp + 1, count
					else
						lastProgress = count - 1000 -- missed: plan again from here
					end
					return false
				end
				if hs.t > 400 then hopState, lastProgress = nil, count - 1000 return false end
			end
			local gd = math.sqrt(gx * gx + gy * gy)
			if gd > 1 then
				local rel = math.rad(math.deg(math.atan(gy, gx)) - st.yaw)
				injectMove(math.sin(rel), math.cos(rel))
			end
			lastProgress = count
			return false
		end
		-- A flip: 4 frames of stick away from the ledge (the skid), Jump from the 3rd held 80, then the stick back at it.
		if target.edge == "flip" and d < 70 and (o.player.move_state or 0) == 0 and not flip then
			flip = { t = 0, ux = dx / d, uy = dy / d }
		end
		if flip then
			flip.t = flip.t + 1
			local sx, sy = flip.ux, flip.uy
			if flip.t <= 4 then sx, sy = -sx, -sy end
			local rel = math.rad(math.deg(math.atan(sy, sx)) - st.yaw)
			injectMove(math.sin(rel), math.cos(rel))
			if flip.t >= 3 and flip.t < 83 and inputReady() then
				subsystem:InjectInputVectorForAction(actions.IA_Jump, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {})
			end
			if flip.t > 20 and (o.player.move_state or 0) == 0 then flip = nil end
			if flip and flip.t > 240 then flip = nil end
			return false
		end
		-- Hanging on a ledge (moveState 3), from any move: push at the target and tap Jump to climb, as the user's hangs
		-- ended in a climb 6-21 frames in (2026-09-23).
		if (o.player.move_state or 0) == 3 then
			hang = hang + 1
			local rel = math.rad(math.deg(math.atan(dy, dx)) - st.yaw)
			injectMove(math.sin(rel), math.cos(rel))
			if hang > 5 and hang % 20 < 5 and inputReady() then
				subsystem:InjectInputVectorForAction(actions.IA_Jump, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {})
			end
			lastProgress = count
			return false
		end
		hang = 0
		if target.edge == "grab" and d < 90 and (o.player.move_state or 0) == 0 and jumpLeft == 0 then jumpLeft = 80 end
		-- A leap: jumped from a standstill at the takeoff cell, a 350-wide one fell short into the gap (2026-09-23). So,
		-- as the user took theirs: back away from the landing for 30 frames, run at it, and jump when she runs off the
		-- edge (coyote time) -- or after 90 frames of running if no edge comes.
		if target.edge == "leap" and not leap and (o.player.move_state or 0) == 0 and jumpLeft == 0 then
			local from = path[wp - 1]
			if from and math.abs(feetZ - from.z) > 40 then
				-- Not at the takeoff's height (she fell into the gap): a leap from here is not the planned one.
				P = newPlan(st.pawn, st.x, st.y, st.z, tx, ty, maxCells)
				path, lastProgress = nil, count
				return false
			end
			leap = { t = 0, ux = dx / math.max(d, 1), uy = dy / math.max(d, 1) }
		end
		if leap then
			leap.t = leap.t + 1
			local ms = o.player.move_state or 0
			local sx, sy = dx, dy
			if leap.t <= 30 then sx, sy = -leap.ux, -leap.uy end
			if not leap.jumped and leap.t > 30 and (ms == 1 or leap.t > 120) then leap.jumped, jumpLeft, jumpT = true, 80, 0 end
			local r2 = math.rad(math.deg(math.atan(sy, sx)) - st.yaw)
			injectMove(math.sin(r2), math.cos(r2))
			if jumpLeft > 0 then
				jumpLeft, jumpT = jumpLeft - 1, jumpT + 1
				local vz = 0
				pcall(function() vz = st.pawn:GetVelocity().Z end)
				if jumpT > 8 and vz <= 20 then jumpLeft = 0 end
				if jumpLeft > 0 and inputReady() then subsystem:InjectInputVectorForAction(actions.IA_Jump, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {}) end
			end
			if leap.jumped and ms == 0 and leap.t > 40 and jumpLeft == 0 then leap = nil end
			if leap and leap.t > 400 then leap = nil end
			lastProgress = count
			return false
		end
		if target.edge == "jump" and d < 75 and (o.player.move_state or 0) == 0 and jumpLeft == 0 then
			-- A tall rise needs the full jump: height follows the hold (3 frames 85, 30 frames 180, 80 frames 206).
			local prev = path[wp - 1]
			jumpLeft = (prev and target.z - prev.z > 140) and 80 or 30
		end
		local rel = math.rad(math.deg(math.atan(dy, dx)) - st.yaw)
		injectMove(math.sin(rel), math.cos(rel))
		if jumpLeft > 0 then
			jumpLeft = jumpLeft - 1
			jumpT = jumpT + 1
			-- Let go once she stops rising, never into the landing (a held Jump became a second jump on landing) -- but
			-- not in the first 8 frames: before she leaves the ground she is not rising either, and a 30-frame jump was let
			-- go on its first frame and never happened (2026-09-23).
			local vz = 0
			pcall(function() vz = st.pawn:GetVelocity().Z end)
			if jumpT > 8 and vz <= 20 then jumpLeft = 0 end
			if jumpLeft == 0 then jumpT = 0 end
			if jumpLeft > 0 and inputReady() then subsystem:InjectInputVectorForAction(actions.IA_Jump, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {}) end
		end
		return false
	end
end

-- reach {max_cells (default 8000)}: goto's search with no target, flooding every cell she can get to from here by
-- goto's rules. Answers the count, the box they span, the highest cells, and `too_high`: every refused rise from a
-- reached cell (taller than a jump, up to 1000), strongest first -- where a better move than a jump is needed.
function M.programs.reach(p)
	local s = playerAndCamera()
	if not s then return nil, "no player" end
	local maxCells = tonumber(p.max_cells) or 8000
	-- A target no cell can be nearer to than the start, so the search only ever floods.
	local P = newPlan(s.pawn, s.x, s.y, s.z, s.x + 1e7, s.y + 1e7, maxCells)
	P.tooHigh = {}
	local origJump = GRAB_UP
	return function()
		local r = planStep(P)
		if not r then return false end
		local minx, maxx, miny, maxy, n = math.huge, -math.huge, math.huge, -math.huge, 0
		local tops = {}
		for k in pairs(P.closed) do
			local c = P.cells[k]
			n = n + 1
			local x, y = c.ix * CELL, c.iy * CELL
			minx, maxx, miny, maxy = math.min(minx, x), math.max(maxx, x), math.min(miny, y), math.max(maxy, y)
			-- A floor, not a prop's top: at least 5 of its 8 neighbours reached at about its height (a cage lid 248 up
			-- ranked highest before this, 2026-09-23).
			local level = 0
			for _, d in ipairs(NEIGHBOURS) do
				local nk = (c.ix + d[1]) .. "," .. (c.iy + d[2])
				local nc = P.cells[nk]
				if P.closed[nk] and nc and nc.z and math.abs(nc.z - c.z) < 20 then level = level + 1 end
			end
			if level >= 5 then tops[#tops + 1] = { x = x, y = y, z = math.floor(c.z + 0.5) } end
			-- refused rises: a neighbour whose floor is known and more than a jump above
			for _, d in ipairs(NEIGHBOURS) do
				local nc = P.cells[(c.ix + d[1]) .. "," .. (c.iy + d[2])]
				if nc and nc.z and nc.z - c.z > origJump and nc.z - c.z <= 1000 then
					P.tooHigh[#P.tooHigh + 1] = { x = x, y = y, z = math.floor(c.z + 0.5), rise = math.floor(nc.z - c.z + 0.5) }
				end
			end
		end
		table.sort(tops, function(a, b) return a.z > b.z end)
		for i = #tops, 11, -1 do tops[i] = nil end
		table.sort(P.tooHigh, function(a, b) return a.rise < b.rise end)
		local th = {}
		for i = 1, math.min(15, #P.tooHigh) do th[i] = P.tooHigh[i] end
		return true, { outcome = r == "exhausted" and "flooded" or r, cells = n, capped = n >= maxCells,
			box = { x = { minx, maxx }, y = { miny, maxy } }, highest = tops, too_high = th, too_high_total = #P.tooHigh }
	end
end

M.reflexes.reach = function(a) return M.programs.reach(a) end

-- fight {range (default 160), swing_every (default 24), stop_hp}: the nearest enemy in `things` (within 2500), followed
-- on the ground by the stick from the camera's yaw; inside `range` it is faced and Attack tapped (4 frames) every
-- `swing_every` frames. Ends `defeated` when the enemy actor is gone or being destroyed, `low_hp` below stop_hp, `lost`
-- when none is within 2500, or the frame limit. Reports swings, hits taken and both HPs.
function M.reflexes.fight(a)
	local range = tonumber(a.range) or 160
	local every = tonumber(a.swing_every) or 24
	local stopHp = tonumber(a.stop_hp)
	local o0 = M.observe(false)
	if not o0.location or not o0.location.x then return nil, "no player" end
	local targetName
	for _, t in ipairs((things(o0.location.map, o0.location.x, o0.location.y, o0.location.z, 60))) do
		if t.kind == "enemy" and t.distance < 2500 then targetName = t.name break end
	end
	if not targetName then return nil, "no enemy within 2500" end
	local actor
	for _, e in ipairs(registry.list) do if e.name == targetName then actor = e.actor end end
	local swings, since, hits, lastHp = 0, every, 0, o0.player.hp
	return function()
		local st = playerAndCamera()
		if not st then return true, { outcome = "no_player" } end
		local o = M.observe(false)
		if o.player.hp and lastHp and o.player.hp < lastHp then hits = hits + 1 end
		lastHp = o.player.hp
		if stopHp and o.player.hp and o.player.hp < stopHp then return true, { outcome = "low_hp", hp = o.player.hp, hits_taken = hits, swings = swings } end
		if not actor or not actor:IsValid() or actor.bActorIsBeingDestroyed then
			return true, { outcome = "defeated", enemy = targetName, swings = swings, hits_taken = hits, hp = o.player.hp }
		end
		local ex, ey, ez
		local ok = pcall(function() local l = actor:K2_GetActorLocation(); ex, ey, ez = l.X, l.Y, l.Z end)
		if not ok then return true, { outcome = "defeated", enemy = targetName, swings = swings, hits_taken = hits, hp = o.player.hp } end
		local dx, dy = ex - st.x, ey - st.y
		local d = math.sqrt(dx * dx + dy * dy)
		if d > 2500 then return true, { outcome = "lost", distance = d } end
		local rel = math.rad(math.deg(math.atan(dy, dx)) - st.yaw)
		local push = d > range * 0.6 and 1 or 0.25 -- close in, then hold a little pressure to keep facing it
		injectMove(math.sin(rel) * push, math.cos(rel) * push)
		since = since + 1
		if d <= range and since >= every then since, swings = 0, swings + 1 end
		if since < 4 and swings > 0 and inputReady() then
			subsystem:InjectInputVectorForAction(actions.IA_Attack, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {})
		end
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
