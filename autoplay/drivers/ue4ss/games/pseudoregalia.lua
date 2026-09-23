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
	capabilities = { "wait", "press", "sequence", "screenshot", "reflex:walk_to", "reflex:look" },
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
	if full then o.level = level end
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

M.cheats = {}

function M.start()
	return "pseudoregalia module ready"
end

return M
