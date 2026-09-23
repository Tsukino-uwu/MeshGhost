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

-- A player controller, kept by its PATH and found again each frame by StaticFindObject (a hash lookup): an object held
-- across frames can outlive what it names, and IsValid on it then reads freed memory (the registry's crashes, below).
-- FindFirstOf walks the object array, so it runs only when the path finds nothing.
local pcPath = nil
local function controller()
	if pcPath then
		local pc = StaticFindObject(pcPath)
		if pc and pc:IsValid() then return pc end
		pcPath = nil
	end
	local ok, pc = pcall(FindFirstOf, "PlayerController")
	if ok and pc and pc:IsValid() then
		local full = pc:GetFullName()
		pcPath = full:sub((full:find(" ", 1, true) or 0) + 1)
		return pc
	end
	return nil
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

local ABILITY_FLAGS = { "obtainedAttack?", "obtainedAirKick?", "obtainedSlide?", "obtainedPlunge?", "obtainedWallRide?",
	"obtainedLight?", "obtainedProjectile?", "obtainedSprint?", "obtainedPowerBoost?", "obtainedGuard?", "obtainedSlideJump",
	"obtainedJump?", "obtainedChargeAttack?", "obtainedMap?", "hasSuperLight", "hasGroundPound", "hasDoubleJump", "hasWallJump",
	"hasBubbleChargedJump" }

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
			-- A watched enemy beside her on the long trail (M.watch_class, set through exec): its path is found once a
			-- second until it exists, then read by StaticFindObject -- never a kept object (the registry's crashes).
			-- For reading a fight the user plays (the Keeper, 2026-09-23).
			if M.watch_class then
				if not M.watch_path and frame % 144 == 0 then
					local a = FindFirstOf(M.watch_class)
					if a and a:IsValid() then
						local full = a:GetFullName()
						M.watch_path = full:sub((full:find(" ", 1, true) or 0) + 1)
					end
				end
				if M.watch_path then
					local a = StaticFindObject(M.watch_path)
					if a and a:IsValid() then
						pcall(function()
							local l = a:K2_GetActorLocation()
							row.ex, row.ey, row.ez = math.floor(l.X + 0.5), math.floor(l.Y + 0.5), math.floor(l.Z + 0.5)
							row.eyaw = math.floor(a:K2_GetActorRotation().Yaw + 0.5)
							row.ehp = num(a.BP_HpHitable.CurrentHp)
						end)
					else
						M.watch_path = nil
					end
				end
				pcall(function() row.hp = num(pawn.BP_HpHitable.CurrentHp) end)
			end
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
-- millisecond, CLAUDE.md), never per frame. An entry keeps the actor's PATH, never the object: each read finds it again
-- by StaticFindObject. A kept object outlived its actor -- a broken wall, the whole level after a restore -- and IsValid
-- on it read freed memory: the game crashed in UE4SS three times (2026-09-23, 16:43 after a restore, 16:57 after walls
-- broke). Its position is its root component's RelativeLocation -- a named read, no UFunction called on it.
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
			local full = a:GetFullName()
			list[#list + 1] = { path = full:sub((full:find(" ", 1, true) or 0) + 1), class = class, kind = kind,
				name = a:GetFName():ToString() }
		end
	end
	registry = { map = map, at = host.frame(), list = list }
end

-- The live actor behind a registry entry, or nil once it is gone.
local function actorOf(e)
	local a = StaticFindObject(e.path)
	if a and a:IsValid() and not a.bActorIsBeingDestroyed then return a end
	return nil
end
M.actor_of = actorOf

-- AXES: the swinging axes (BP_HazardAxe_C), from the registry. Each swings +-45 degrees in the x-z plane about its pivot
-- (the actor's position, 3250 over the axes' corridor floor at 2550); the long one's blade (Box) came down to ~2660 at the
-- bottom of its arc, into a standing player (top 2682) and over a sliding one (~2596) (sampled 2026-09-23). A cell
-- under one is where goto slides.
local axeCache = { map = nil, at = -1e9, list = {} }
local function axesOn(map)
	if axeCache.map == map and host.frame() - axeCache.at < 600 then return axeCache.list end
	if registry.map ~= map or host.frame() - registry.at > 300 then refreshRegistry(map) end
	local list = {}
	for _, e in ipairs(registry.list) do
		if e.class == "BP_HazardAxe_C" then
			local a = actorOf(e)
			if a then
				pcall(function()
					local l = a.RootComponent.RelativeLocation
					list[#list + 1] = { x = l.X, y = l.Y, z = l.Z }
				end)
			end
		end
	end
	axeCache = { map = map, at = host.frame(), list = list }
	return list
end
local function underAxe(axes, x, y, z)
	for _, a in ipairs(axes) do
		-- the swing's reach across x (sin 45 of a ~600 arm, and her capsule) and along its plane's thickness in y
		if math.abs(y - a.y) < 70 and math.abs(x - a.x) < 480 and a.z - z < 900 and a.z > z then return true end
	end
	return false
end
M.axes_on = axesOn

-- ENEMIES where they stand now, from the registry (paths found again, never kept objects). goto routes around them
-- and jumps past one ahead, never fighting (the user, 2026-09-23: "ignore the enemies, no need to attack them, just
-- navigate around them while jumping"; walking into one knocked her into a castle pit).
local function enemiesOn(map)
	if registry.map ~= map or host.frame() - registry.at > 300 then refreshRegistry(map) end
	local list = {}
	for _, e in ipairs(registry.list) do
		if e.kind == "enemy" then
			local a = actorOf(e)
			if a then pcall(function() local l = a.RootComponent.RelativeLocation list[#list + 1] = { x = l.X, y = l.Y, z = l.Z } end) end
		end
	end
	return list
end
M.enemies_on = enemiesOn

local function things(map, px, py, pz, limit)
	if registry.map ~= map or host.frame() - registry.at > 300 then refreshRegistry(map) end
	local out = {}
	for _, e in ipairs(registry.list) do
		local a = actorOf(e)
		if a then
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
			-- What she has: the pawn's own obtained/has flags (BP_PlayerGoatMain_C, read by name 2026-09-23: obtainedSlide?
			-- turned true with the slide's screen).
			pcall(function()
				local have = {}
				for _, n in ipairs(ABILITY_FLAGS) do
					if pawn[n] == true then have[#have + 1] = (n:gsub("^obtained", ""):gsub("^has", ""):gsub("%?$", "")) end
				end
				p.abilities = have
			end)
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
	M.clear_geo()
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
-- An upgrade's screen (UI_NewUpgradePrompt_C) pauses the game and its CONTINUE answered neither a posted key nor an
-- injected action; the widget's own bound click handler is what a click on it runs (the Dream Breaker and the slide,
-- 2026-09-23). Returns the upgrade prompt when one is on screen.
local UPGRADE_CLICK = "BndEvt__UI_NewUpgradePrompt_UI_GenericButton_K2Node_ComponentBoundEvent_0_CommonButtonBaseClicked__DelegateSignature"
local function upgradePrompt()
	for _, w in ipairs(FindAllOf("UI_NewUpgradePrompt_C") or {}) do
		if w:IsValid() and w:GetFullName():find("Transient", 1, true) then return w end
	end
	return nil
end

function M.programs.advance_text(p)
	local every, maxTaps = tonumber(p.every) or 45, tonumber(p.max_taps) or 20
	local o = M.observe(false)
	if o.mode == "paused" then
		local w = upgradePrompt()
		if w then
			local waited = 0
			return function()
				waited = waited + 1
				if waited == 90 then w[UPGRADE_CLICK](w, w.UI_GenericButton) end -- let its screen finish fading in first
				if waited > 90 and M.observe(false).mode == "play" then
					return true, { outcome = "closed", upgrade_screen = true, frames = waited }
				end
				if waited > 600 then return true, { outcome = "stuck", upgrade_screen = true } end
				return false
			end
		end
	end
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
-- no cell reached (twice). Ends `arrived`, `no_route` (with how far the nearest reachable cell is), `stuck`, `hit`,
-- `map_changed`, or the frame limit.
local CELL = 50
local CAP_R, CAP_H = 20, 62 -- a little inside the capsule's 22/65, so brushing a wall does not close a route
local FEET = 67 -- the capsule's centre above the floor: z -332.85 over a floor traced at -400
-- The slide (actionState 1, speed about 1100 for ~85 frames after a Crouch tap at a run, 2026-09-23): the capsule's
-- centre drops from 2267 to 2224 over a floor at 2200, and CrouchedHalfHeight reads 20. Swept a little inside, as CAP_H.
local SLIDE_Z, SLIDE_H = 26, 21
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
-- FLIPGRAB_UP: a backflip (peak 265 against a jump's 206) into a ledge grab: a jump grabbed ledges 80-94 over its apex, so
-- a flip should catch ~350. The rises just past GRAB_UP (320-324) were the smallest the dungeon's full flood refused
-- (2026-09-23). Executed as a flip; the hang handler climbs.
local FLIPGRAB_UP = 350
-- A leap across a gap of k cells may land at most this much higher. The user's run (2026-09-23) jumped from the cage
-- platform onto a block 200 higher ~240 units away; a full jump rises 206.
local LEAP_UP = { [2] = 200, [3] = 200, [4] = 200, [5] = 200 }
-- Further, a leap lands only by catching the ledge: the user's grab hops rose 178 across 661 and 286 across 283.
for k = 6, 12 do LEAP_UP[k] = 280 end
local LEAP_CELLS = 12
local EXPAND_PER_FRAME = 60 -- a ceiling; the trace budget below is what bounds a frame

-- Traces cast by the planner this frame: the search stops for the frame at TRACE_BUDGET. Thirty cells a frame
-- (~500 traces) took the game from 144 to ~89 frames a second while a plan was made (2026-09-23; the user asked
-- whether the drop could be fixed).
local TRACE_BUDGET = 200
local tracesThisFrame, traceFrame = 0, -1
local function countTrace()
	local f = host.frame()
	if f ~= traceFrame then traceFrame, tracesThisFrame = f, 0 end
	tracesThisFrame = tracesThisFrame + 1
end
-- And by time: the Lua around the traces (a leap's candidate cells) cost as much as the traces, and a trace budget alone
-- still left ~90 frames a second while planning, against 142 idle (2026-09-23). os.clock is wall time under MSVC.
-- Raised to 4 when routes grew past the slide: at 1.5 a plan to the dungeon's east exit (30000 cells) outran a reflex's
-- 3600 frames, and every plan is made standing still, where a lower frame rate costs the least (2026-09-23).
local PLAN_MS = 4
local planStart, planFrame = 0, -1
local function overBudget()
	local f = host.frame()
	if f ~= planFrame then planFrame, planStart = f, os.clock() end
	if (os.clock() - planStart) * 1000 >= PLAN_MS then return true end
	return traceFrame == f and tracesThisFrame >= TRACE_BUDGET
end

-- The level's answers, kept for the map: the same probe or sweep asked again (a re-plan, a later route through known
-- ground) is not traced again. Cleared on a restore and when the map changes (a broken wall changes the level).
local geoCache = { map = nil, probes = {}, sweeps = {} }
local function geo(map)
	if geoCache.map ~= map then geoCache = { map = map, probes = {}, sweeps = {} } end
	return geoCache
end
M.clear_geo = function() geoCache = { map = nil, probes = {}, sweeps = {} } end

local function sweepRaw(pawn, x1, y1, z1, x2, y2, z2, h)
	countTrace()
	if not ksl or not ksl:IsValid() then ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
	local hit = {}
	local r = ksl:CapsuleTraceSingle(pawn, { X = x1, Y = y1, Z = z1 }, { X = x2, Y = y2, Z = z2 }, CAP_R, h or CAP_H, 0, false,
		{}, 0, hit, true, { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0)
	return r == true
end

local function sweep(pawn, x1, y1, z1, x2, y2, z2, h)
	local k = string.format("%.0f,%.0f,%.0f>%.0f,%.0f,%.0f/%d", x1, y1, z1, x2, y2, z2, h or CAP_H)
	local c = geoCache.sweeps
	local v = c[k]
	if v == nil then
		v = sweepRaw(pawn, x1, y1, z1, x2, y2, z2, h)
		c[k] = v
	end
	return v
end

local function floorProbe(pawn, x, y, fromZ, walkableZ)
	countTrace()
	if not ksl or not ksl:IsValid() then ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
	local hit = {}
	local r = ksl:LineTraceSingle(pawn, { X = x, Y = y, Z = fromZ }, { X = x, Y = y, Z = fromZ - 1400 }, 0, false, {}, 0, hit,
		true, { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0)
	if not r or not hit.Location then return nil end
	if hit.ImpactNormal and hit.ImpactNormal.Z < walkableZ then return nil end
	return hit.Location.Z
end

local function nodeKey(ix, iy, z)
	return ix .. "," .. iy .. "#" .. math.floor(z / 40 + 0.5)
end

-- The floor under a cell, traced down from fromZ (cached per 100 of height): nil where there is none.
local function probe(P, ix, iy, fromZ)
	local k = ix .. "," .. iy .. "@" .. math.floor(fromZ / 100)
	local v = P.probes[k]
	if v == nil then
		v = floorProbe(P.pawn, ix * CELL, iy * CELL, math.floor(fromZ / 100) * 100 + 50, P.walkableZ) or false
		P.probes[k] = v
	end
	return v or nil
end

-- The floor just under her own floor's height at a cell, traced from 50 above it: under a beam lower than a standing
-- capsule, where probe's higher start meets the beam's top. Cached per 20 of height.
local function lowProbe(P, ix, iy, z)
	local k = ix .. "," .. iy .. "L" .. math.floor(z / 20)
	local v = P.probes[k]
	if v == nil then
		v = floorProbe(P.pawn, ix * CELL, iy * CELL, z + 50, P.walkableZ) or false
		P.probes[k] = v
	end
	return v or nil
end

local function newPlan(pawn, sx, sy, sz, tx, ty, maxCells)
	local walkableZ = 0.64
	pcall(function() walkableZ = pawn.CharacterMovement.WalkableFloorZ end)
	-- `cells` are the search's nodes, keyed by cell AND level (nodeKey): keyed by cell alone, a hop landing on a floor at
	-- 1700 merged with the floor at 800 beneath it and the route lost its thread (2026-09-23). `probes` caches floor traces
	-- per cell and the height they were cast from.
	local g = geo(M.observe(false).location.map)
	local P = { pawn = pawn, cells = {}, probes = g.probes, open = {}, closed = {}, came = {}, g = {}, edge = {}, count = 0,
		maxCells = maxCells, walkableZ = walkableZ, tx = tx, ty = ty, hopOf = {} }
	pcall(function() P.hops = M.hops_for(M.observe(false).location.map) or nil end) -- defined further down
	pcall(function() P.trail = M.trail_for(M.observe(false).location.map) or nil end)
	pcall(function() P.slide = pawn["obtainedSlide?"] == true end) -- slide edges only once she has it
	pcall(function() P.enemies = enemiesOn(M.observe(false).location.map) end)
	local function cellOf(x, y) return math.floor(x / CELL + 0.5), math.floor(y / CELL + 0.5) end
	P.cellOf = cellOf
	local six, siy = cellOf(sx, sy)
	P.gix, P.giy = cellOf(tx, ty)
	local startKey = nodeKey(six, siy, sz - FEET)
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

-- The user's ground path from the same file, bucketed by 100 units: a cell within reach of it costs less, so goto walks
-- their line between hops unless it has reason not to (between two hops it had found its own line down a slope into a
-- hollow where they had stayed on the level floor, 2026-09-23).
local trailCache = {}
local function trailFor(map)
	if trailCache[map] ~= nil then return trailCache[map] end
	local name = map and map:gsub("^ZONE_", ""):lower() or ""
	local f = io.open(host.root .. "/autoplay/games/pseudoregalia/routes/" .. name .. "_hops.json", "r")
	local grid = false
	if f then
		local ok, doc = pcall(host.json.decode, f:read("a"))
		f:close()
		if ok and type(doc) == "table" and doc.trail then
			grid = {}
			for _, p in ipairs(doc.trail) do
				local k = math.floor(p[1] / 100) .. "," .. math.floor(p[2] / 100)
				grid[k] = grid[k] or {}
				table.insert(grid[k], p)
			end
		end
	end
	trailCache[map] = grid
	return grid
end

local function nearTrail(grid, x, y, z)
	if not grid then return false end
	local bx, by = math.floor(x / 100), math.floor(y / 100)
	for ox = -1, 1 do
		for oy = -1, 1 do
			local b = grid[(bx + ox) .. "," .. (by + oy)]
			if b then
				for _, p in ipairs(b) do
					if math.abs(p[1] - x) < 80 and math.abs(p[2] - y) < 80 and math.abs(p[3] - z) < 60 then return true end
				end
			end
		end
	end
	return false
end

M.hops_for = function(map) return hopsFor(map) end -- for exec, to check what the search is offered
M.trail_for = function(map) return trailFor(map) end
M.near_trail = nearTrail

-- The search is weighted A*: the distance still to go counts H_WEIGHT times. At 1 (plain A*) the route's penalties (jumps,
-- edges, cells off the user's trail) made it flood the level: 22691 cells and 2515 frames to find no route to the slide,
-- and each re-plan ate most of a reflex's 3600 frames (2026-09-23). Routes come out at most H_WEIGHT times the best.
local H_WEIGHT = 1.5

-- Near an enemy, hard: the castle's pit platforms each hold one, and a landing 86 from it put her into it and off the
-- platform (2026-09-23); the platforms are large enough to land clear of it.
local function enemyCost(P, x, y, z)
	local c = 0
	for _, e in ipairs(P.enemies or {}) do
		local ex, ey = x - e.x, y - e.y
		local e2 = ex * ex + ey * ey
		if math.abs(e.z - z) < 400 then
			if e2 < 200 * 200 then c = c + 1500 elseif e2 < 300 * 300 then c = c + 300 end
		end
	end
	return c
end

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
				local mz = probe(P, ix + ox, iy + oy, z + JUMP_UP + FEET)
				if not mz or mz < z - STEP_UP then n = n + 1 end
			end
		end
	end
	return n
end

-- Runs up to EXPAND_PER_FRAME expansions. Returns "found", "exhausted" or nil (still searching).
local function planStep(P)
	for _ = 1, EXPAND_PER_FRAME do
		if overBudget() then return nil end
		if #P.open == 0 then return "exhausted" end
		local cur = heapPop(P.open)
		if not P.closed[cur.k] then
			P.closed[cur.k] = true
			P.count = P.count + 1
			local c = P.cells[cur.k]
			local hx, hy = (P.gix - c.ix) * CELL, (P.giy - c.iy) * CELL
			local h = math.sqrt(hx * hx + hy * hy) + (P.tz and math.abs(c.z - P.tz) or 0)
			if h < P.bestH then P.best, P.bestH = cur.k, h end
			if c.ix == P.gix and c.iy == P.giy and (not P.tz or math.abs(c.z - P.tz) < 60) then P.goal = cur.k return "found" end
			if P.count >= P.maxCells then return "exhausted" end
			local ax, ay = c.px or c.ix * CELL, c.py or c.iy * CELL
			for _, d in ipairs(NEIGHBOURS) do
				local nix, niy = c.ix + d[1], c.iy + d[2]
				local bx, by = nix * CELL, niy * CELL
				local nz = probe(P, nix, niy, c.z + JUMP_UP + FEET)
				-- A ledge taller than a jump starts above that probe: look again from a grab's height, and keep what it
				-- finds only when it is such a ledge (from that high, most probes meet overhangs).
				local hz = probe(P, nix, niy, c.z + FLIPGRAB_UP + 40)
				if hz and hz > c.z + JUMP_UP and hz <= c.z + FLIPGRAB_UP and (not nz or nz < hz - 100) then nz = hz end
				-- And, with the slide, the floor under a low beam: probed from above, the passage under the slide room's
				-- corridor read as the beam's top 150 up, its underside 100 over the real floor (2026-09-23).
				local cands = { nz }
				if P.slide then
					local lz = lowProbe(P, nix, niy, c.z)
					if lz and math.abs(lz - c.z) <= STEP_UP and (not nz or math.abs(nz - lz) > 40) then cands[#cands + 1] = lz end
				end
				for ci = 1, #cands do
				local nz = cands[ci]
				local nk = nodeKey(nix, niy, nz)
				if not P.closed[nk] then
					P.cells[nk] = P.cells[nk] or { ix = nix, iy = niy, z = nz }
					do
						local dz = nz - c.z
						local kind, ok = nil, false
						local ca, cb = c.z + FEET, nz + FEET
						if dz > FLIPGRAB_UP or dz < -DROP then
							ok = false
						elseif dz > STEP_UP then
							kind = dz > GRAB_UP and "flipgrab" or (dz > FLIP_UP and "grab" or (dz > JUMP_UP and "flip" or "jump"))
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
							-- A sill between two cells of one height: the game steps her over anything up to MaxStepHeight, so
							-- the capsule lifted by STEP_UP; taller, a jump over it (150 up). A doorway's sill fenced the castle's
							-- map room from its save crystal, both floors at -825 (2026-09-23).
							if not ok and not sweep(P.pawn, ax, ay, top + STEP_UP, bx, by, top + STEP_UP) then
								ok = true
							elseif not ok and not sweep(P.pawn, ax, ay, ca + 2, ax, ay, top + 150)
								and not sweep(P.pawn, ax, ay, top + 150, bx, by, top + 150) then
								kind, ok = "jump", true
							end
							-- Too low to walk, low enough to slide: the slide's capsule (centre 24 over the floor, measured
							-- 2226-2224 from 2267 standing) swept at SLIDE_H. The passage under the slide room's corridor
							-- (2026-09-23) is one.
							if not ok and P.slide then
								local low = math.max(ca, cb) - FEET + SLIDE_Z
								if not sweep(P.pawn, ax, ay, low, bx, by, low, SLIDE_H) then kind, ok = "slide", true end
							end
						end
						-- debug_at {x, y}: every move considered from cells within 80 of it, for reading a refusal.
						if P.debugAt and math.abs(ax - P.debugAt[1]) < 80 and math.abs(ay - P.debugAt[2]) < 80 and #P.dbg < 60 then
							P.dbg[#P.dbg + 1] = string.format("from %.0f,%.0f,%.0f to %d,%d nz %.0f dz %.0f %s %s", ax, ay, c.z, bx, by,
								nz, dz, tostring(kind), tostring(ok))
						end
						if ok then
							local step = (d[1] ~= 0 and d[2] ~= 0) and CELL * 1.4142 or CELL
							local cost = P.g[cur.k] + step + (kind == "jump" and 80 or 0) + (kind == "flip" and 200 or 0) + (kind == "grab" and 150 or 0) + (kind == "flipgrab" and 300 or 0) + (kind == "drop" and 20 or 0) + (kind == "slide" and 40 or 0)
							if kind == "jump" or kind == "flip" or kind == "grab" or kind == "flipgrab" then cost = cost + LAND_EDGE_COST * edgeCells(P, nix, niy, nz) end
							if P.trail and not nearTrail(P.trail, bx, by, nz) then cost = cost + step * 0.8 end
							cost = cost + enemyCost(P, bx, by, nz)
							if P.g[nk] == nil or cost < P.g[nk] then
								P.g[nk], P.came[nk], P.edge[nk] = cost, cur.k, kind
								local gx, gy = (P.gix - nix) * CELL, (P.giy - niy) * CELL
								heapPush(P.open, { k = nk, f = cost + (P.flood and 0 or H_WEIGHT) * math.sqrt(gx * gx + gy * gy) })
							end
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
						local nk = nodeKey(nix, niy, l[3])
						if not P.closed[nk] then
							P.cells[nk] = P.cells[nk] or { ix = nix, iy = niy, z = l[3] }
							local dist = math.sqrt((l[1] - t[1]) ^ 2 + (l[2] - t[2]) ^ 2)
							local cost = P.g[cur.k] + dist + 150
							if P.g[nk] == nil or cost < P.g[nk] then
								P.g[nk], P.came[nk], P.edge[nk], P.hopOf[nk] = cost, cur.k, "hop", hi
								local gx, gy = (P.gix - nix) * CELL, (P.giy - niy) * CELL
								heapPush(P.open, { k = nk, f = cost + (P.flood and 0 or H_WEIGHT) * math.sqrt(gx * gx + gy * gy) })
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
				local mz = probe(P, c.ix + d[1], c.iy + d[2], c.z + JUMP_UP + FEET)
				if not mz or mz < c.z - STEP_UP then edge = true break end
			end
			if edge then
				for dx = -LEAP_CELLS, LEAP_CELLS do
					for dy = -LEAP_CELLS, LEAP_CELLS do
						local k = math.max(math.abs(dx), math.abs(dy))
						-- Counted by distance, not cells: a diagonal of 11 cells is 778 long, and she was sent at one from the
						-- castle pit's edge and fell in (2026-09-23). k is the reach in cells either way.
						local reach = math.sqrt(dx * dx + dy * dy) * CELL
						if reach > LEAP_CELLS * CELL then k = 0 else k = math.max(k, math.ceil(reach / CELL - 0.01)) end
						if k >= 2 and k <= LEAP_CELLS then
							local nix, niy = c.ix + dx, c.iy + dy
							local bx, by = nix * CELL, niy * CELL
							local nz = probe(P, nix, niy, c.z + JUMP_UP + FEET)
							local nk = nz and nodeKey(nix, niy, nz)
							if nz and not P.closed[nk] then
								if nz - c.z <= LEAP_UP[k] and nz - c.z >= -300 then
									local low = math.min(c.z, nz) - STEP_UP
									local gap, steps = true, k * 2
									for t = 1, steps - 1 do
										local mx = math.floor(c.ix + dx * t / steps + 0.5)
										local my = math.floor(c.iy + dy * t / steps + 0.5)
										if not (mx == c.ix and my == c.iy) and not (mx == nix and my == niy) then
											local m = { z = probe(P, mx, my, c.z + JUMP_UP + FEET) or false }
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
											cost = cost + enemyCost(P, nix * CELL, niy * CELL, nz) -- a leap's landing too: the castle's pit
											if P.g[nk] == nil or cost < P.g[nk] then
												P.cells[nk] = P.cells[nk] or { ix = nix, iy = niy, z = nz }
												P.g[nk], P.came[nk], P.edge[nk] = cost, cur.k, "leap"
												local gx, gy = (P.gix - nix) * CELL, (P.giy - niy) * CELL
												heapPush(P.open, { k = nk, f = cost + (P.flood and 0 or H_WEIGHT) * math.sqrt(gx * gx + gy * gy) })
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
	local tz = tonumber(a.z) -- a floor height: the goal is the cell on that floor (x, y alone met the floor 1200 below)
	local P = newPlan(s.pawn, s.x, s.y, s.z, tx, ty, maxCells)
	P.tz = tz
	if a.debug_x then P.debugAt, P.dbg = { tonumber(a.debug_x), tonumber(a.debug_y) }, {} end
	local path, wp, lastProgress, replans, jumpLeft, flip, hopState, hang, jumpT, leap = nil, 2, 0, 0, 0, nil, nil, 0, 0, nil
	local finishJump, fin = false, nil
	local slideTap = 0
	local lastPos = nil
	local planned, planFrames, stats = 0, 0, {}
	return function(count)
		local st = playerAndCamera()
		if not st then return true, { outcome = "no_player" } end
		local o = M.observe(false)
		if o.location.map ~= map0 then return true, { outcome = "map_changed" } end
		if hp0 and o.player.hp and o.player.hp < hp0 then return true, { outcome = "hit", hp = o.player.hp } end
		-- Put back by the game after a fall into a pit (a jump of 2000 in a frame, three times over one call at the castle's
		-- pit, 2026-09-23, and the user saw her "fell multiple times"): stop and say so rather than try the same jump again.
		if lastPos and (st.x - lastPos[1]) ^ 2 + (st.y - lastPos[2]) ^ 2 > 800 * 800 then
			return true, { outcome = "fell", from = { x = lastPos[1], y = lastPos[2], z = lastPos[3] }, to = { x = st.x, y = st.y, z = st.z },
				on = path and path[wp] and { x = path[wp].x, y = path[wp].y, z = path[wp].z, edge = path[wp].edge } or nil }
		end
		lastPos = { st.x, st.y, st.z }
		local dxT, dyT = tx - st.x, ty - st.y
		-- Arrived only once landed: the check is horizontal, and it had ended mid-jump at z -155 over a floor at -300.
		if math.sqrt(dxT * dxT + dyT * dyT) <= radius and (o.player.move_state or 0) == 0 and (not tz or math.abs(st.z - FEET - tz) < 60) then
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
			elseif r == "exhausted" and P.bestH <= 500 and not a.plan_only then
				-- Near enough to finish by eye: the route's end, then a run straight at the target with a jump near it -- the
				-- step onto the Dream Breaker's stage from the water, which the search refused (2026-09-23).
				path, finishJump = pathOf(P, P.best), true
			elseif r == "exhausted" then
				local best = P.cells[P.best]
				return true, { outcome = "no_route", cells_searched = P.count, debug = P.dbg,
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
				local steps
				if a.dump then
					-- The route itself, one line per move that is not a walk (and the walk before it), for reading a plan.
					steps = {}
					for i, c in ipairs(path) do
						local nx = path[i + 1]
						if c.edge ~= "walk" or (nx and nx.edge ~= "walk") then
							steps[#steps + 1] = string.format("%d %s %.0f,%.0f,%.0f", i, tostring(c.edge), c.x, c.y, c.z)
						end
					end
				end
				return true, { outcome = "planned", cells_searched = P.count, path_cells = #path, jumps = jumps, hops = hopsN,
					ends = { x = last.x, y = last.y, z = last.z }, steps = steps }
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
		if not target and finishJump then
			fin = fin or { t = 0 }
			fin.t = fin.t + 1
			local ms = o.player.move_state or 0
			local dd = math.sqrt(dxT * dxT + dyT * dyT)
			local rel = math.rad(math.deg(math.atan(dyT, dxT)) - st.yaw)
			injectMove(math.sin(rel), math.cos(rel))
			if not fin.jumped and dd < 220 and ms == 0 and (o.player.action_state or 0) ~= 18 then fin.jumped, fin.jt = true, 0 end
			if fin.jumped then
				fin.jt = fin.jt + 1
				local vz = 0
				pcall(function() vz = st.pawn:GetVelocity().Z end)
				if fin.jt > 8 and ms == 0 then fin.held = true end -- landed: let go (a held Jump jumps again)
				if not fin.held and (fin.jt <= 8 or vz > -250) and fin.jt < 100 and inputReady() then
					subsystem:InjectInputVectorForAction(actions.IA_Jump, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {})
				end
				if ms == 0 and fin.jt > 20 then
					return true, { outcome = dd <= radius and "arrived" or "finished_short", distance = dd, finish = "a jump at the target" }
				end
			end
			if fin.t > 600 then return true, { outcome = "finished_short", distance = dd } end
			lastProgress = count
			return false
		end
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
				P.tz = tz
				path, lastProgress = nil, count
				return false
			end
		end
		if count - lastProgress > 90 and (o.player.move_state or 0) ~= 0 and (o.player.move_state or 0) ~= 2 then
			return false -- never plan again mid-air: the start would be taken at the height of the jump (2026-09-23)
		end
		if count - lastProgress > 90 then
			-- An upgrade's screen pauses her and controlState stays 0: she stood on the Dream Breaker's stage under its screen
			-- and re-planned until "stuck" (2026-09-23). Checked only here: FindAllOf walks every object.
			if upgradePrompt() then return true, { outcome = "upgrade_screen", at = { x = st.x, y = st.y, z = st.z } } end
			if replans >= 2 then return true, { outcome = "stuck", at = { x = st.x, y = st.y, z = st.z }, route = stats, on = { x = target.x, y = target.y, z = target.z, edge = target.edge, wp = wp, of = #path } } end
			replans = replans + 1
			-- A full search: the level's answers are cached per map, so a re-plan over ground already traced costs little. Capped
			-- at 2500 cells, it answered no_route from the dungeon's hall with the stage 4357 away (2026-09-23).
			P = newPlan(st.pawn, st.x, st.y, st.z, tx, ty, maxCells)
			P.tz = tz
			path, lastProgress = nil, count
			return false
		end
		-- A hop: run to its takeoff, jump there (Jump held 80 frames) steering at its landing; hanging on a ledge
		-- (moveState 3), keep pushing at the landing and tap Jump to climb. Done when landed near the landing; landed
		-- anywhere else, the route is planned again.
		if target.edge == "hop" and target.hop then
			local h = target.hop
			-- The run-up: 250 behind the takeoff along the user's own approach. A flip hop always starts there (a backflip
			-- needs the run the skid carries on, and arriving from the landing's side there was no skid at all,
			-- 2026-09-23); any hop does when she would otherwise reach the takeoff from more than 60 degrees off.
			if not hopState then
				local ux, uy = h.takeoff[1] - h.approach_from[1], h.takeoff[2] - h.approach_from[2]
				local ul = math.sqrt(ux * ux + uy * uy)
				if ul < 1 then ux, uy, ul = h.landing[1] - h.takeoff[1], h.landing[2] - h.takeoff[2], 1 end
				ul = math.sqrt(ux * ux + uy * uy)
				ux, uy = ux / ul, uy / ul
				local rx, ry = h.takeoff[1] - ux * 250, h.takeoff[2] - uy * 250
				-- The user's own run-up where recorded: 250 straight back fell inside a wall where they had come around a
				-- corner, and she stood pushing into it (2026-09-23).
				if h.runup then rx, ry = h.runup[1], h.runup[2] end
				-- Only as far back as the floor at the takeoff's height goes: a recorded run-up can lie in the air (the user's
				-- momentum from the previous landing), and she ran off the back of the platform (2026-09-23).
				do
					local bx, by = rx - h.takeoff[1], ry - h.takeoff[2]
					local bl = math.sqrt(bx * bx + by * by)
					if bl > 1 then
						local okx, oky = h.takeoff[1], h.takeoff[2]
						for dd = 25, bl, 25 do
							local px, py = h.takeoff[1] + bx / bl * dd, h.takeoff[2] + by / bl * dd
							local fz = floorProbe(st.pawn, px, py, h.takeoff[3] + 150, 0.6)
							if not fz or math.abs(fz - h.takeoff[3]) > 40 then break end
							okx, oky = px, py
						end
						-- and 30 short of that edge
						local kx, ky = okx - h.takeoff[1], oky - h.takeoff[2]
						local kl = math.sqrt(kx * kx + ky * ky)
						if kl > 60 then okx, oky = h.takeoff[1] + kx / kl * (kl - 30), h.takeoff[2] + ky / kl * (kl - 30) end
						rx, ry = okx, oky
					end
				end
				local vx, vy = h.takeoff[1] - st.x, h.takeoff[2] - st.y
				local vl = math.sqrt(vx * vx + vy * vy)
				local off = vl > 1 and (vx * ux + vy * uy) / vl < 0.5
				-- Slow and nearer the takeoff than the user's run: take the run-up too. Landed 70 before a 450-wide hop's
				-- takeoff, she jumped at speed 59 against their 550 and fell short (2026-09-23).
				local speed = 0
				pcall(function() local v = st.pawn:GetVelocity(); speed = math.sqrt(v.X * v.X + v.Y * v.Y) end)
				local short = h.runup_path and vl < 0.6 * h.runup_path and speed < 400 and (h.run_speed or 0) > 400
				hopState = { phase = (h.flip or off or short) and "runup" or "run", t = 0, air = 0, rx = rx, ry = ry }
			end
			local hs = hopState
			hs.t = hs.t + 1
			local ms = o.player.move_state or 0
			-- Hanging in any phase (a run-up ran her off an edge onto a ledge, where she hung until the time ran out):
			-- climb, then plan again from wherever she stands.
			if ms == 3 then
				hs.hangAny = (hs.hangAny or 0) + 1
				-- Push toward the wall she faces while hanging: every climb that worked pushed at it; taps alone did not.
				local fy = o.location.yaw or st.yaw
				local r3 = math.rad(fy - st.yaw)
				injectMove(math.sin(r3), math.cos(r3))
				if hs.hangAny > 5 and hs.hangAny % 20 < 5 and inputReady() then
					subsystem:InjectInputVectorForAction(actions.IA_Jump, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {})
				end
				if hs.phase ~= "air" then hs.phase, hs.replan = "climb", true end
				lastProgress = count
				return false
			end
			if hs.phase == "climb" and ms == 0 then
				hopState, lastProgress = nil, count - 1000 -- climbed out: plan again from here
				return false
			end
			if hs.phase == "climb" then lastProgress = count return false end
			local gx, gy
			if hs.phase == "runup" then
				gx, gy = hs.rx - st.x, hs.ry - st.y
				if math.sqrt(gx * gx + gy * gy) < 40 or hs.t > 400 then hs.phase, hs.t = "run", 0 end
			end
			if hs.phase == "run" then
				gx, gy = h.takeoff[1] - st.x, h.takeoff[2] - st.y
				local td = math.sqrt(gx * gx + gy * gy)
				-- Along the user's own approach from the run-up, not a straight line: a straight one clipped a corner they
				-- had run around and she stopped against it (2026-09-23).
				if h.approach then
					hs.ai = hs.ai or 1
					while hs.ai <= #h.approach do
						local q = h.approach[hs.ai]
						local qx, qy = q[1] - st.x, q[2] - st.y
						local qd = math.sqrt(qx * qx + qy * qy)
						-- passed when within 40, or when the next point (or the takeoff) is nearer
						local nq = h.approach[hs.ai + 1] or { h.takeoff[1], h.takeoff[2] }
						local nd = math.sqrt((nq[1] - st.x) ^ 2 + (nq[2] - st.y) ^ 2)
						if qd < 40 or nd < qd then hs.ai = hs.ai + 1 else gx, gy = qx, qy break end
					end
				end
				-- At the takeoff, or off its edge near it: the jump in coyote time the user used (2026-09-23).
				-- Jump where the user did: when she reaches or passes the takeoff along the hop's direction. Within 25 of it
				-- was 25 early at a run, her arc met the ledge lower than theirs and missed the grab they made (2026-09-23).
				local hx, hy = h.landing[1] - h.takeoff[1], h.landing[2] - h.takeoff[2]
				local hl = math.max(1, math.sqrt(hx * hx + hy * hy))
				local along = ((st.x - h.takeoff[1]) * hx + (st.y - h.takeoff[2]) * hy) / hl
				-- Off the edge before the takeoff (the user's coyote-time jumps came 6-9 frames after leaving the ground, each a
				-- full jump, 2026-09-23): keep running and jump over their takeoff point, or at the 8th frame in the air.
				if ms == 1 then hs.off = (hs.off or 0) + 1 else hs.off = 0 end
				-- Near the takeoff only: a seam in the floor 115 before one left her in the air for 12 frames and was taken for
				-- the edge (2026-09-23).
				local coyote = ms == 1 and td < 250 and along >= -60 and (along >= -4 or hs.off >= 8)
				local ground = ms == 0 and ((td < 60 and along >= -4) or td < 8)
				-- A coyote hop leaves a small top: never jump on it, run off its edge at the landing and jump in coyote time,
				-- 6 frames off (the user: "use coyotee time, jumping to early when jumping off from the cage", 2026-09-23).
				if h.coyote then
					ground = false
					coyote = ms == 1 and (hs.off or 0) >= 6 and td < 300
					if along >= -30 then gx, gy = h.landing[1] - st.x, h.landing[2] - st.y end
				end
				-- (Tried and reverted, 2026-09-23: jumping as late as coyote time allows on grab hops met the 2349 ledge
				-- falling, 9 lower than the user's grab; their takeoff, at the edge, meets it at the top of the arc.)
				-- A jump pressed in a skid (actionState 18: turning around at a run) comes out as a backflip; the user saw her
				-- backflip "even for small things" after run-ups that turned her around (2026-09-23). Wait the skid out.
				local skidding = (o.player.action_state or 0) == 18
				if ground and skidding and not h.flip then ground = false end
				if ground or coyote then hs.phase, hs.t = (h.flip and ms == 0) and "skid" or "air", 0 end
				-- Past the takeoff, or off the edge: run at the landing. Steering back at a takeoff already passed slowed her
				-- from 550 to 212 in coyote time and the jump fell short (2026-09-23).
				if along >= 0 or ms == 1 then gx, gy = h.landing[1] - st.x, h.landing[2] - st.y end
			end
			-- A flip hop (the user's backflip, actionState 18 before the takeoff): 5 frames of stick away from the landing,
			-- Jump from the 3rd, then on at the landing as any hop.
			if hs.phase == "skid" then
				local ax, ay = h.landing[1] - st.x, h.landing[2] - st.y
				local r2 = math.rad(math.deg(math.atan(-ay, -ax)) - st.yaw)
				injectMove(math.sin(r2), math.cos(r2))
				if hs.t >= 3 and inputReady() then
					subsystem:InjectInputVectorForAction(actions.IA_Jump, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {})
				end
				if hs.t >= 5 then hs.phase, hs.t = "air", 3 end
				lastProgress = count
				return false
			end
			if hs.phase == "air" then
				gx, gy = h.landing[1] - st.x, h.landing[2] - st.y
				-- Jump held until she stops rising (a full jump), then let go: held on into the landing, the game took it
				-- as a new jump the moment she landed (2026-09-23).
				local vz = 0
				pcall(function() vz = st.pawn:GetVelocity().Z end)
				-- Held through the apex: holding floats her at the top (the user's arc: vertical speed 36, 10, -27 over ~10
				-- frames), and letting go at the apex dropped her at once (24 to -100), 9-30 lower at a ledge they grabbed.
				-- Let go only once clearly falling, which still keeps it off the landing.
				-- Never on the ground after the takeoff: there vz is 0, and landing on the 400 block after hop 1 with Jump still
				-- held, she jumped again, off its far side (2026-09-23).
				if hs.t > 8 and ms == 0 then hs.released = true end
				if not hs.released and (hs.t <= 8 or vz > -250) and hs.t <= 120 and inputReady() then
					subsystem:InjectInputVectorForAction(actions.IA_Jump, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {})
				elseif hs.t > 8 then
					hs.released = true
				end
				-- On a climb pole (moveState 5, the user's run 2026-09-23): push up until at the height they left it, then
				-- jump off at the landing (moveState 6 while leaving).
				if ms == 5 and h.pole then
					hs.pole = (hs.pole or 0) + 1
					if (st.z - FEET) < (h.pole.to_z or h.pole.from_z) - 10 and hs.pole < 600 then
						injectMove(0, 1)
					else
						hs.poleJump = 30
					end
				end
				if hs.poleJump and hs.poleJump > 0 then
					hs.poleJump = hs.poleJump - 1
					if inputReady() then subsystem:InjectInputVectorForAction(actions.IA_Jump, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {}) end
				end
				if ms == 5 and h.pole and not (hs.poleJump and hs.poleJump > 0) then lastProgress = count return false end
				-- At the pole's top (moveState 6), where she stayed: the user jumped from there toward the landing, a second
				-- jump at speed 600 (2026-09-23). Steer at the landing and tap Jump after 10 frames in the state.
				if ms == 6 then
					hs.top = (hs.top or 0) + 1
					if hs.top > 10 and hs.top % 30 < 12 and inputReady() then
						subsystem:InjectInputVectorForAction(actions.IA_Jump, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {})
					end
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
		if (target.edge == "flip" or target.edge == "flipgrab") and d < 70 and (o.player.move_state or 0) == 0 and not flip then
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
			-- Pushed the way she faces (the wall she hangs on), as the hops do: pushed at a grab's target cell 25 away, the
			-- stick ran along the ledge and she hung there until the frame limit (2026-09-23, the 2550 ledge).
			local rel = math.rad((o.location.yaw or st.yaw) - st.yaw)
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
				P.tz = tz
				path, lastProgress = nil, count
				return false
			end
			-- Back up in proportion to the leap (30 frames and a jump at 120 regardless took a 450-wide one at speed 59,
			-- 2026-09-23), and remember the takeoff cell: on the ground the jump comes once she has run past it.
			leap = { t = 0, ux = dx / math.max(d, 1), uy = dy / math.max(d, 1), back = math.max(30, math.min(80, d / 6)),
				fx = from and from.x or st.x, fy = from and from.y or st.y }
			-- The run-up by distance, not frames: two reversals (each a skid) in an 80-frame back-off left her at 340 at
			-- the edge of the gap before exit 1, and she fell to the start (2026-09-23). Arriving at a run toward the
			-- landing already, no back-off; else back up to 300, only as far as the floor goes.
			local vx, vy = 0, 0
			pcall(function() local v = st.pawn:GetVelocity(); vx, vy = v.X, v.Y end)
			if vx * leap.ux + vy * leap.uy >= 450 then
				leap.back, leap.backDist = 0, 0
			else
				local fz, okd = feetZ, 0
				for dd = 25, 300, 25 do
					local z = floorProbe(st.pawn, leap.fx - leap.ux * dd, leap.fy - leap.uy * dd, fz + 150, 0.6)
					if not z or math.abs(z - fz) > 40 then break end
					okd = dd
				end
				leap.backDist, leap.back = math.max(0, okd - 25), 400
			end
		end
		if leap then
			leap.t = leap.t + 1
			local ms = o.player.move_state or 0
			local sx, sy = dx, dy
			local past = (st.x - leap.fx) * leap.ux + (st.y - leap.fy) * leap.uy
			if leap.backDist and leap.t <= leap.back and past <= -leap.backDist then leap.back = leap.t - 1 end
			if leap.t <= leap.back then sx, sy = -leap.ux, -leap.uy end
			local skidding = (o.player.action_state or 0) == 18 -- a jump in the skid is a backflip: wait it out
			if not leap.jumped and leap.t > leap.back and (ms == 1 or ((past >= 20 or leap.t > leap.back + 240) and not skidding)) then
				leap.jumped, jumpLeft, jumpT = true, 80, 0
			end
			local r2 = math.rad(math.deg(math.atan(sy, sx)) - st.yaw)
			injectMove(math.sin(r2), math.cos(r2))
			if jumpLeft > 0 then
				jumpLeft, jumpT = jumpLeft - 1, jumpT + 1
				local vz = 0
				pcall(function() vz = st.pawn:GetVelocity().Z end)
				if jumpT > 8 and (vz <= -250 or ms == 0) then jumpLeft = 0 end -- landed: on the ground vz is 0, and a held Jump jumps again
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
		-- An enemy within 200 ahead on her way, and she on the ground: jump past it (checked every 10 frames).
		if count % 10 == 0 and jumpLeft == 0 and (o.player.move_state or 0) == 0 then
			local ux, uy = dx / math.max(d, 1), dy / math.max(d, 1)
			for _, e in ipairs(enemiesOn(o.location.map)) do
				local ex, ey = e.x - st.x, e.y - st.y
				local along = ex * ux + ey * uy
				if along > 0 and along < 200 and math.abs(ex * uy - ey * ux) < 120 and math.abs(e.z - st.z) < 250 then
					-- Only where a jump is safe: the next cells plain walks and floor at her height 300 on. Unchecked, it
					-- jumped her off a pit platform's far side toward an enemy 700 from the next floor (2026-09-23).
					local safe = true
					for i = wp, math.min(#path, wp + 5) do
						if path[i].edge ~= "walk" then safe = false end
					end
					local fz = safe and floorProbe(st.pawn, st.x + ux * 300, st.y + uy * 300, feetZ + 150, 0.6)
					if safe and fz and math.abs(fz - feetZ) < 45 then jumpLeft = 80 end
					break
				end
			end
		end
		-- A slide edge: a Crouch tap on the ground at a run starts the slide (actionState 1); tapped again only once it has
		-- ended, 4 frames each. Crouch held while standing still crouches her in place (moveState 2) and she does not move.
		-- Crouched (moveState 2) counts as on the ground: a slide that ends under the low ceiling leaves her crouched there.
		-- Under the swinging axes: slide through, as the corridor teaches -- walking, she was hit 5 at a time and knocked off
		-- the shelf (2026-09-23). Tapped when a cell up to 4 ahead is under one and she is within 200 of it.
		local axeAhead = false
		do
			local axes = axesOn(o.location.map)
			if #axes > 0 then
				for i = wp, math.min(#path, wp + 4) do
					local c = path[i]
					if underAxe(axes, c.x, c.y, c.z) then
						local ex, ey = c.x - st.x, c.y - st.y
						if ex * ex + ey * ey < 200 * 200 then axeAhead = true end
						break
					end
				end
			end
		end
		if (target.edge == "slide" or axeAhead) and (o.player.action_state or 0) ~= 1 and ((o.player.move_state or 0) == 0 or o.player.move_state == 2) then
			slideTap = (slideTap or 0) + 1
			if slideTap <= 4 and inputReady() then
				subsystem:InjectInputVectorForAction(actions.IA_Crouch, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {})
			end
			if slideTap > 30 then slideTap = 0 end
		else
			slideTap = 0
		end
		if jumpLeft > 0 and jumpT == 0 and (o.player.action_state or 0) == 18 and (o.player.move_state or 0) == 0 then
			-- not yet: a jump pressed in the skid would be a backflip
		elseif jumpLeft > 0 then
			jumpLeft = jumpLeft - 1
			jumpT = jumpT + 1
			-- Let go once she stops rising, never into the landing (a held Jump became a second jump on landing) -- but
			-- not in the first 8 frames: before she leaves the ground she is not rising either, and a 30-frame jump was let
			-- go on its first frame and never happened (2026-09-23).
			local vz = 0
			pcall(function() vz = st.pawn:GetVelocity().Z end)
			-- Through the apex (it floats her), off before landing; and off once landed, where vz is 0: onto a ledge higher than
			-- the fall's start, a held Jump jumped her again and off the block's far side (2026-09-23).
			if jumpT > 8 and (vz <= -250 or (o.player.move_state or 0) == 0) then jumpLeft = 0 end
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
	-- A target no cell can be nearer to than the start, so the search only ever floods; P.flood orders it by cost alone,
	-- evenly outward (ordered toward that far target, a capped flood ran off one way). `continue` carries on the last
	-- flood with max_cells more, across reflex calls: the whole dungeon did not fit in one call's 3600 frames.
	local P
	if p.continue and M.lastReach then
		P = M.lastReach
		P.maxCells = P.count + maxCells
	else
		P = newPlan(s.pawn, s.x, s.y, s.z, s.x + 1e7, s.y + 1e7, maxCells)
		P.flood = true
		P.tooHigh = {}
		M.lastReach = P
	end
	local origJump = FLIPGRAB_UP
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
				local mz = probe(P, c.ix + d[1], c.iy + d[2], c.z + JUMP_UP + FEET)
				if mz and math.abs(mz - c.z) < 20 and P.closed[nodeKey(c.ix + d[1], c.iy + d[2], mz)] then level = level + 1 end
			end
			if level >= 5 then tops[#tops + 1] = { x = x, y = y, z = math.floor(c.z + 0.5) } end
			-- refused rises: a neighbour whose floor is known and more than a jump above
			for _, d in ipairs(NEIGHBOURS) do
				local nz = probe(P, c.ix + d[1], c.iy + d[2], c.z + 1000 + FEET)
				if nz and nz - c.z > origJump and nz - c.z <= 1000 then
					P.tooHigh[#P.tooHigh + 1] = { x = x, y = y, z = math.floor(c.z + 0.5), rise = math.floor(nz - c.z + 0.5) }
				end
			end
		end
		table.sort(tops, function(a, b) return a.z > b.z end)
		for i = #tops, 11, -1 do tops[i] = nil end
		-- The things worth going to, and whether a reached cell stands within 250 of one (at most 600 under it: a thing's
		-- position is its pivot, above the floor it stands on).
		local byBucket = {}
		for k in pairs(P.closed) do
			local c = P.cells[k]
			local bk = math.floor(c.ix * CELL / 250) .. "," .. math.floor(c.iy * CELL / 250)
			byBucket[bk] = byBucket[bk] or {}
			table.insert(byBucket[bk], c)
		end
		local want = { exit = true, upgrade = true, key = true, npc = true, save_point = true, switch = true,
			breakable_wall = true, health_piece = true, locked_door = true, pole = true }
		local reached, unreached = {}, {}
		local map = M.observe(false).location.map
		if registry.map ~= map or host.frame() - registry.at > 300 then refreshRegistry(map) end
		for _, e in ipairs(registry.list) do
			if want[e.kind] then
				local a = actorOf(e)
				local ok, tx, ty, tz = pcall(function() local l = a.RootComponent.RelativeLocation return l.X, l.Y, l.Z end)
				if a and ok and tx then
					local best = math.huge
					local bx0, by0 = math.floor(tx / 250), math.floor(ty / 250)
					for ox = -1, 1 do for oy = -1, 1 do
						for _, c in ipairs(byBucket[(bx0 + ox) .. "," .. (by0 + oy)] or {}) do
							local dx, dy = c.ix * CELL - tx, c.iy * CELL - ty
							local d = math.sqrt(dx * dx + dy * dy)
							if tz - c.z > -100 and tz - c.z < 600 and d < best then best = d end
						end
					end end
					local row = string.format("%s %s (%.0f,%.0f,%.0f)", e.kind, e.name, tx, ty, tz)
					if best <= 250 then reached[#reached + 1] = row else unreached[#unreached + 1] = row end
				end
			end
		end
		table.sort(P.tooHigh, function(a, b) return a.rise < b.rise end)
		local th = {}
		for i = 1, math.min(15, #P.tooHigh) do th[i] = P.tooHigh[i] end
		return true, { outcome = r == "exhausted" and "flooded" or r, cells = n, capped = n >= maxCells,
			box = { x = { minx, maxx }, y = { miny, maxy } }, highest = tops, too_high = th, too_high_total = #P.tooHigh,
			reached = reached, unreached = unreached, open = #P.open }
	end
end

M.reflexes.reach = function(a) return M.programs.reach(a) end

-- fight {range (default 160), swing_every (default 24), stop_hp, kind (default enemy; breakable_wall, save_point...), name,
-- swings (stop after this many, answered `swung`)}: the nearest thing of that kind in `things` (within 2500), followed
-- on the ground by the stick from the camera's yaw; inside `range` it is faced and Attack tapped (4 frames) every
-- `swing_every` frames. Ends `defeated` when the enemy actor is gone or being destroyed, `low_hp` below stop_hp, `lost`
-- when none is within 2500, or the frame limit. Reports swings, hits taken and both HPs. style "circle" fights as the user
-- fought the Keeper: round it at ~230 swinging, sliding across its line when it moves fast; heal_at (HP) runs off and
-- holds Power to heal to heal_to.
function M.reflexes.fight(a)
	local range = tonumber(a.range) or 160
	local every = tonumber(a.swing_every) or 24
	local stopHp = tonumber(a.stop_hp)
	local o0 = M.observe(false)
	if not o0.location or not o0.location.x then return nil, "no player" end
	local wantKind, wantName = a.kind or "enemy", a.name
	local maxSwings = tonumber(a.swings)
	local targetName
	for _, t in ipairs((things(o0.location.map, o0.location.x, o0.location.y, o0.location.z, 60))) do
		if (wantName and t.name == wantName) or (not wantName and t.kind == wantKind and t.distance < 2500) then targetName = t.name break end
	end
	if not targetName then return nil, "no " .. tostring(wantName or wantKind) .. " within 2500" end
	local entry
	for _, e in ipairs(registry.list) do if e.name == targetName then entry = e end end
	local swings, since, hits, lastHp = 0, every, 0, o0.player.hp
	local circle = a.style == "circle"
	local healAt, healTo = tonumber(a.heal_at), tonumber(a.heal_to) or 25
	local lastE, spin, heal, slideTap, slideCd, flipT = nil, 1, nil, 0, 0, 0
	return function()
		local st = playerAndCamera()
		if not st then return true, { outcome = "no_player" } end
		local o = M.observe(false)
		if o.player.hp and lastHp and o.player.hp < lastHp then hits = hits + 1 end
		lastHp = o.player.hp
		if stopHp and o.player.hp and o.player.hp < stopHp then return true, { outcome = "low_hp", hp = o.player.hp, hits_taken = hits, swings = swings } end
		local actor = entry and actorOf(entry) -- found again each frame: a kept object outlives the wall it broke
		if not actor then
			return true, { outcome = "defeated", enemy = targetName, swings = swings, hits_taken = hits, hp = o.player.hp }
		end
		local ex, ey, ez
		local ok = pcall(function() local l = actor:K2_GetActorLocation(); ex, ey, ez = l.X, l.Y, l.Z end)
		if not ok then return true, { outcome = "defeated", enemy = targetName, swings = swings, hits_taken = hits, hp = o.player.hp } end
		local dx, dy = ex - st.x, ey - st.y
		local d = math.sqrt(dx * dx + dy * dy)
		if d > 2500 then return true, { outcome = "lost", distance = d } end
		if circle then
			-- CIRCLE, as the user fought the Keeper (2026-09-23, recorded with the Keeper beside her): ~230 away, always
			-- running round it and swinging (42 hits of 15 landed from 108-314, median 233); its attacks are short fast
			-- moves (0.1 s at 1000-1700) and both 10-damage hits came as one ended ~410 away with her not sliding. So:
			-- a slide across its line the moment it moves fast (the slide's i-frames), and, low, away to heal (the user:
			-- "go away to a safe spot and heal up during fights. but its better to avoid getting hurt").
			local ksp = lastE and math.sqrt((ex - lastE[1]) ^ 2 + (ey - lastE[2]) ^ 2) * 144 or 0
			lastE = { ex, ey }
			local ux, uy = dx / math.max(d, 1), dy / math.max(d, 1)
			local tx, ty = -uy * spin, ux * spin
			local ms, as = o.player.move_state or 0, o.player.action_state or 0
			local hp = o.player.hp or 0
			if heal == nil and healAt and hp <= healAt then heal = { t = 0, hp = hp } end
			local mx, my
			if heal then
				heal.t = heal.t + 1
				-- Away and round: straight away pinned her to the arena's wall, where it walked up and hit her (2026-09-23).
				if d < 700 and heal.t < 600 then
					mx, my = -ux * 0.6 + tx, -uy * 0.6 + ty
				else
					heal.hold = (heal.hold or 0) + 1
					mx, my = 0, 0
					if inputReady() then subsystem:InjectInputVectorForAction(actions.IA_Power, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {}) end
					-- done when healed past healTo, when it has not risen in 240 frames of holding, or it closes in
					if hp >= healTo or (heal.hold > 240 and hp <= heal.hp) or d < 500 then heal = false end
				end
			else
				-- In range most of the time: with a gentle pull (radial /120 against a 0.9 circle) she spent the round
				-- beyond 330 and swung 4 times (2026-09-23).
				local radial = math.max(-1, math.min(1, (d - 220) / 50))
				local round = d > 400 and 0.2 or 0.7
				mx, my = ux * radial + tx * round, uy * radial + ty * round
				slideCd = (slideCd or 0) - 1
				if ksp > 450 and ms == 0 and as ~= 1 and slideCd <= 0 then slideTap, slideCd = 4, 70 end
				if slideTap and slideTap > 0 then
					slideTap = slideTap - 1
					mx, my = tx, ty -- across its line
					if inputReady() then subsystem:InjectInputVectorForAction(actions.IA_Crouch, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {}) end
				end
				-- round the other way now and then, as the user changed direction
				flipT = (flipT or 0) + 1
				if flipT > 500 then flipT, spin = 0, -spin end
			end
			if heal == false then heal = nil end
			local ml = math.sqrt(mx * mx + my * my)
			if ml > 0.01 then
				local relm = math.rad(math.deg(math.atan(my, mx)) - st.yaw)
				injectMove(math.sin(relm), math.cos(relm))
			end
			since = since + 1
			if not (heal) and d <= 330 and since >= 12 then since, swings = 0, swings + 1 end
			if since < 4 and swings > 0 and not heal and inputReady() then
				subsystem:InjectInputVectorForAction(actions.IA_Attack, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {})
			end
			return false
		end
		local rel = math.rad(math.deg(math.atan(dy, dx)) - st.yaw)
		local push = d > range * 0.6 and 1 or 0.25 -- close in, then hold a little pressure to keep facing it
		injectMove(math.sin(rel) * push, math.cos(rel) * push)
		since = since + 1
		if maxSwings and swings >= maxSwings and since >= every then
			return true, { outcome = "swung", target = targetName, swings = swings, hits_taken = hits, hp = o.player.hp }
		end
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
