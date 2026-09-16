-- autoplay BizHawk driver (DEV TOOL, WRITES INPUT, never shipped; agent_docs/phases/phase13.md, ADR 0071)
--
-- The piece inside BizHawk that carries out the autoplay core's commands. Load it through the dev
-- loader (dev-scripts/bizhawk-dev-loader.lua): add this file's absolute path to the instance's
-- control file. It picks its game module from AUTOPLAY_GAME (a global, or the environment) -- the
-- handoff names it -- and connects to the core on 127.0.0.1:AUTOPLAY_PORT (default 7870).
--
-- The link is the core's protocol 1, stated at the top of autoplay/driver/driver.go. One request
-- is carried out at a time; a press holds the controller for its frames and answers after them.
-- WHILE A PRESS IS RUNNING THIS SCRIPT HOLDS THE CONTROLLER. Take it off the target when done: an
-- input-driving tool left loaded is a suspect in every later report.

local PROTOCOL = 1
local MAX_LINE = 64 * 1024
-- Reconnect by the wall clock, not by frames: a connect attempt to a port nobody listens on blocks for
-- its timeout, and one every 30 frames took the emulator from 835 frames/s to 350 with no core running
-- (hookcost_probe.lua, 2026-09-16) -- at fast-forward, 30 frames is a few hundredths of a second.
local RETRY_SECONDS = 1
local REJECT_BACKOFF_SECONDS = 10
local PROGRAM_FRAME_LIMIT = 1800 -- a select across a long menu is far shorter; the core waits 40s

local function scriptDir()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$")
	end
	return nil
end

local DIR = scriptDir()
if not DIR then
	error("autoplay driver: cannot find its own folder; load it by absolute path through the dev loader")
end
local ROOT = DIR:match("^(.*)/autoplay/drivers/bizhawk$")
if not ROOT then
	error("autoplay driver: expected to live at <repo>/autoplay/drivers/bizhawk, found " .. DIR)
end

local gameName = AUTOPLAY_GAME or os.getenv("AUTOPLAY_GAME")
local port = tonumber(AUTOPLAY_PORT or os.getenv("AUTOPLAY_PORT") or "") or 7870

-- One log per instance: two emulators writing one file cannot be told apart. The first instance, a game on
-- the default port, keeps the plain name.
local logName = port == 7870 and "driver_bizhawk.log"
	or string.format("driver_bizhawk_%s_%d.log", tostring(gameName):gsub("[^%w_]", "_"), port)
local logf = io.open(ROOT .. "/autoplay/runs/" .. logName, "a")
local function log(msg)
	local line = string.format("[%s f%d] %s", os.date("%H:%M:%S"), emu.framecount(), msg)
	if logf then
		logf:write(line, "\n")
		logf:flush() -- a handful of lines per command, never per frame
	else
		console.log("autoplay: " .. msg)
	end
end

local json = dofile(DIR .. "/json.lua")

-- LuaSocket, the copy the Emerald adapter vendors. lua54.dll first by full path, backslashes only:
-- the reasons are in meshghost_emerald.lua's "LuaSocket" block.
local LIB = (ROOT .. "/adapters/emulator/pokemon/emerald/lib/x64/"):gsub("/", "\\")
pcall(function() package.loadlib(LIB .. "lua54.dll", "autoplay_force_preload") end)
local openSocket, socketErr = package.loadlib(LIB .. "socket-windows-5-4.dll", "luaopen_socket_core")
if not openSocket then
	error("autoplay driver: could not load LuaSocket from " .. LIB .. ": " .. tostring(socketErr))
end
local socket = openSocket()

local game = nil
if gameName and gameName:match("^[%w_]+$") then
	game = dofile(DIR .. "/games/" .. gameName .. ".lua")
end

local sock, partial, state = nil, "", "down"
local nextTry = 0 -- os.time() at or after which to try connecting again
local queue = {}
local hold = nil
local lastDiff = nil

local function send(msg)
	if not sock then return false end
	local line = json.encode(msg)
	if #line + 1 > MAX_LINE then
		log("dropping an outgoing line of " .. #line .. " bytes")
		return false
	end
	local ok, err = sock:send(line .. "\n")
	if not ok then
		log("send failed: " .. tostring(err))
		return false
	end
	return true
end

local function close(why, backoff)
	if sock then pcall(function() sock:close() end) end
	sock, partial, state, queue, hold = nil, "", "down", {}, nil
	nextTry = os.time() + (backoff or RETRY_SECONDS)
	log("link down: " .. why)
end

local function reply(id, payload)
	send({ id = id, type = "result", payload = payload })
end

local function fail(id, message)
	send({ id = id, type = "error", payload = { message = message } })
end

local function changed(before, after)
	local a, b, out = game.diffKeys(before), game.diffKeys(after), {}
	for k, v in pairs(b) do
		if a[k] ~= v then out[k] = { from = a[k], to = v } end
	end
	return out
end

local function has(capability)
	for _, c in ipairs(game.capabilities) do
		if c == capability then return true end
	end
	return false
end

-- The answer to a press or a wait: how long, and what moved between before and after.
local function heldFor(frames)
	return function(after, _, _, before)
		return { frames = frames, before = before, after = after, changed = changed(before, after) }
	end
end

-- select: a program run one frame at a time over the module's observe().menu ({cursor, items, and
-- columns for a grid}) and its menuButtons ({prev, next, confirm, and left and right for a grid}). Every leg ends on the game's own state, never on a frame
-- count: press toward the entry until the menu's cursor changes, release for SETTLE frames, look
-- again; then hold confirm until the menu closes or changes. Returns a function, called once a frame,
-- that answers (pad or nil, finished, result or nil, error or nil) -- the shape of every program,
-- a game module's own included (game.programs).
local SETTLE, LEG_LIMIT = 2, 30

local function selectProgram(p)
	local keys = game.menuButtons
	local target, label, before, dir
	local phase, held, settle, steps, from, maxSteps = "look", 0, 0, 0, nil, 0

	local function sameMenu(m)
		if not m or m.window ~= before.window or #m.items ~= #before.items then return false end
		for i, item in ipairs(m.items) do
			if item ~= before.items[i] then return false end
		end
		return true
	end

	return function()
		-- game.menu() when the module has it: the menu alone, not a whole observation, every frame.
		local m
		if game.menu then m = game.menu() else m = game.observe().menu end
		if phase == "look" then
			before = m
			if type(m) ~= "table" or type(m.items) ~= "table" or #m.items == 0 then
				return nil, true, nil, "no menu is open (observe shows none)"
			end
			if p.index ~= nil then
				target = math.tointeger(p.index)
				if not target or target < 0 or target >= #m.items then
					return nil, true, nil, string.format("index %s is outside the menu's %d entries", tostring(p.index), #m.items)
				end
			else
				local want, hits = tostring(p.item):lower(), {}
				for i, item in ipairs(m.items) do
					if item:lower() == want then hits[#hits + 1] = i - 1 end
				end
				if #hits ~= 1 then
					return nil, true, nil, string.format("%d entries read %q; the menu has: %s", #hits, tostring(p.item), table.concat(m.items, " | "))
				end
				target = hits[1]
			end
			label, maxSteps, phase = m.items[target + 1], #m.items * 2 + 2, "move"
		end

		if settle > 0 then
			settle = settle - 1
			return nil, false
		end

		if phase == "move" then
			if not sameMenu(m) then return nil, true, nil, "the menu closed or changed while the cursor was moving" end
			if held == 0 and m.cursor == target then
				if p.confirm == false then
					return nil, true, { selected = label, index = target, steps = steps, confirmed = false }
				end
				phase = "confirm"
			else
				if held == 0 then
					if steps >= maxSteps then
						return nil, true, nil, string.format("the cursor is on %d after %d steps, not on %d", m.cursor, steps, target)
					end
					from, steps = m.cursor, steps + 1
					-- A menu with `columns` is a grid numbered row by row: reach the column first with
					-- the module's left/right, then the row with prev/next.
					local cols = math.tointeger(m.columns) or 1
					if cols > 1 and keys.left and keys.right and target % cols ~= m.cursor % cols then
						dir = (target % cols > m.cursor % cols) and keys.right or keys.left
					else
						dir = (target > m.cursor) and keys.next or keys.prev
					end
				elseif m.cursor ~= from then
					held, settle = 0, SETTLE
					return nil, false
				end
				held = held + 1
				if held > LEG_LIMIT then
					return nil, true, nil, string.format("the cursor did not move from %d on %s in %d frames", from, dir, LEG_LIMIT)
				end
				return { [dir] = true }, false
			end
		end

		-- confirm: hold until the menu is gone or no longer the same menu with the cursor on the entry.
		if held > 0 and (not sameMenu(m) or m.cursor ~= target) then
			return nil, true, { selected = label, index = target, steps = steps, confirmed = true }
		end
		held = held + 1
		if held > LEG_LIMIT then
			return nil, true, nil, string.format("the menu did not respond to %s in %d frames", keys.confirm, LEG_LIMIT)
		end
		return { [keys.confirm] = true }, false
	end
end

-- Start carrying out one request. Returns true when it answered at once.
local function begin(req)
	local verb, p = req.type, req.payload or {}
	local capability = verb
	if verb == "cheat" then capability = "cheat:" .. tostring(p.kind) end
	if not has(capability) then
		fail(req.id, "this driver does not support " .. tostring(capability))
		return true
	end
	if verb == "observe" then
		-- true: the agent asked, so the module may add what it leaves out of a press's before and after.
		reply(req.id, game.observe(true))
		return true
	elseif verb == "screenshot" then
		-- The game frame only (client.screenshot), never the window, into the game's own shots
		-- folder (the play-game skill's references/screenshots.md). A drawn-tier ghost is not in it.
		local name = type(p.name) == "string" and p.name or ""
		if not name:match("^[%w_%-]+$") or #name > 64 then
			fail(req.id, "screenshot needs a name of letters, digits, _ or -")
			return true
		end
		local path = string.format("%s/dev-scripts/shots/%s/autoplay_%s.png", ROOT, game.shots, name)
		local ok, err = pcall(function() client.screenshot(path) end)
		local fh = ok and io.open(path, "rb")
		if not fh then
			fail(req.id, "client.screenshot did not write " .. path .. ": " .. tostring(err))
			return true
		end
		fh:close()
		reply(req.id, { path = path, frame = emu.framecount() })
		return true
	elseif verb == "press" then
		local frames = math.tointeger(p.frames)
		if type(p.buttons) ~= "table" or #p.buttons == 0 or not frames or frames < 1 or frames > 600 then
			fail(req.id, "press needs buttons and 1 to 600 frames")
			return true
		end
		local known, pad = joypad.get(), {}
		for _, b in ipairs(p.buttons) do
			if type(b) ~= "string" or known[b] == nil then
				local names = {}
				for name in pairs(known) do names[#names + 1] = name end
				table.sort(names)
				fail(req.id, "unknown button " .. tostring(b) .. "; this core has " .. table.concat(names, ", "))
				return true
			end
			pad[b] = true
		end
		hold = { id = req.id, pad = pad, left = frames, before = game.observe(), finish = heldFor(frames) }
		log(string.format("press %s for %d frames", table.concat(p.buttons, "+"), frames))
		return false
	elseif verb == "wait" then
		-- Frames pass with NO input: never hold a button to wait, since every button means
		-- something somewhere (B backs out of a menu).
		local frames = math.tointeger(p.frames)
		if not frames or frames < 1 or frames > 3600 then
			fail(req.id, "wait needs 1 to 3600 frames")
			return true
		end
		hold = { id = req.id, pad = nil, left = frames, before = game.observe(), finish = heldFor(frames) }
		return false
	elseif verb == "select" then
		if type(game.menuButtons) ~= "table" then
			fail(req.id, "this game module names no menu buttons")
			return true
		end
		if (p.item == nil) == (p.index == nil) then
			fail(req.id, "select needs exactly one of item and index")
			return true
		end
		log("select " .. tostring(p.item or p.index))
		hold = { id = req.id, program = selectProgram(p), before = game.observe(), count = 0 }
		return false
	elseif verb == "snapshot" or verb == "restore" then
		-- The core names the file: a named state under its gitignored states folder, never a numbered
		-- slot, so nothing here can touch slot 1 or any rig's slot. BizHawk's savestate.save/load take a
		-- path (tasvideos.org/Bizhawk/LuaFunctions); the core checks the file itself afterwards.
		local path = p.path
		if type(path) ~= "string" or not path:match("%.State$") then
			fail(req.id, verb .. " needs a path ending in .State")
			return true
		end
		if verb == "snapshot" then
			local ok, err = pcall(function() savestate.save(path) end)
			if not ok then
				fail(req.id, "savestate.save failed: " .. tostring(err))
				return true
			end
			log("snapshot " .. path)
			reply(req.id, { path = path, frame = emu.framecount() })
			return true
		end
		local ok, loaded = pcall(function() return savestate.load(path) end)
		if not ok or loaded == false then
			fail(req.id, "savestate.load failed: " .. tostring(loaded))
			return true
		end
		log("restore " .. path)
		-- Whatever the module built up from hooks describes the memory before the load, not after.
		if game.restored then game.restored() end
		-- Answer one frame later, from the loaded state.
		hold = { id = req.id, left = 1, before = nil, finish = function(after) return { path = path, after = after } end }
		return false
	elseif verb == "cheat" then
		local run = game.cheats and game.cheats[p.kind]
		if not run then
			fail(req.id, "no cheat " .. tostring(p.kind) .. " in this game module")
			return true
		end
		local before = game.observe()
		local plan, err = run(type(p.args) == "table" and p.args or {})
		if not plan then
			fail(req.id, tostring(err))
			return true
		end
		log("cheat " .. tostring(p.kind))
		hold = {
			id = req.id, left = 0, before = before, untilFn = plan.untilFn, limit = plan.limit or 1, count = 0,
			finish = function(after, done, count)
				-- plan.report, when the module has one, reads the cheat's effect back from the game.
				return { kind = p.kind, done = done, frames = count, before = before, after = after, changed = changed(before, after),
					report = plan.report and plan.report() or nil }
			end,
		}
		return false
	end
	local make = game.programs and game.programs[verb]
	if make then
		-- A program may name its own frame limit (a long route outlasts a menu).
		local program, err, limit = make(p)
		if not program then
			fail(req.id, tostring(err))
			return true
		end
		log(verb)
		hold = { id = req.id, program = program, before = game.observe(), count = 0, limit = limit }
		return false
	end
	fail(req.id, "unhandled request " .. tostring(verb))
	return true
end

local function handle(line)
	local ok, msg = pcall(json.decode, line)
	if not ok or type(msg) ~= "table" then
		log("ignoring a line that does not parse")
		return
	end
	if msg.type == "welcome" then
		state = "ready"
		log("welcomed by the core on port " .. port)
	elseif msg.type == "reject" then
		local reason = type(msg.payload) == "table" and msg.payload.reason or "?"
		close("rejected: " .. tostring(reason), REJECT_BACKOFF_SECONDS)
	elseif msg.id and state == "ready" then
		queue[#queue + 1] = msg
	end
end

local function connect()
	local s = socket.tcp()
	if not s then return end
	s:settimeout(0.05)
	if not s:connect("127.0.0.1", port) then
		pcall(function() s:close() end)
		nextTry = os.time() + RETRY_SECONDS
		return
	end
	s:settimeout(0)
	pcall(function() s:setoption("tcp-nodelay", true) end)
	sock, partial, state = s, "", "hello_sent"
	send({
		type = "hello",
		payload = {
			protocol = PROTOCOL,
			host = "bizhawk",
			game = game.game,
			variant = game.variant,
			build = game.build(),
			capabilities = game.capabilities,
			protected_slots = game.protected_slots,
		},
	})
	log("connected to 127.0.0.1:" .. port .. ", hello sent")
end

local function drain()
	while sock do
		local line, err, part = sock:receive("*l", partial)
		if line then
			partial = ""
			handle(line)
		elseif err == "timeout" then
			partial = part or ""
			if #partial > MAX_LINE then close("a line over " .. MAX_LINE .. " bytes") end
			return
		else
			close(tostring(err))
			return
		end
	end
end

-- Every frame: each key of the game module's watch() that changed goes out as a "<key>_changed" event
-- (map_changed, mode_changed, and whatever else the module watches). Without a watch(), map and mode.
local function watchEvents()
	local d
	if game.watch then
		d = game.watch()
	else
		local k = game.diffKeys(game.observe())
		d = { map = k.map, mode = k.mode }
	end
	if lastDiff and state == "ready" then
		for key, value in pairs(d) do
			if value ~= lastDiff[key] then
				send({ type = "event", payload = { kind = key .. "_changed", from = lastDiff[key], to = value, frame = emu.framecount() } })
			end
		end
	end
	lastDiff = d
end

if not game then
	log("no game module: set AUTOPLAY_GAME (e.g. emerald) before loading; doing nothing")
else
	log(string.format("loaded for %s (%s), core port %d", game.game, game.variant, port))
	if game.start then log(game.start()) end
end

MESHGHOST_DEV_TICK = function()
	if not game then return end
	if not sock then
		if os.time() >= nextTry then connect() end
		return
	end
	drain()
	if not sock then return end

	if hold then
		if hold.program then
			-- One frame of a program: it looks at what it needs, then either finishes or sets this frame's input.
			hold.count = hold.count + 1
			local pad, finished, result, err = hold.program()
			if not finished and hold.count > (hold.limit or PROGRAM_FRAME_LIMIT) then
				finished, err = true, string.format("still running after %d frames", hold.limit or PROGRAM_FRAME_LIMIT)
			end
			if finished then
				if err then
					fail(hold.id, err)
				else
					local o = game.observe()
					result.frames, result.before, result.after = hold.count, hold.before, o
					result.changed = changed(hold.before, o)
					reply(hold.id, result)
				end
				hold = nil
			elseif pad then
				joypad.set(pad)
			end
		elseif hold.left > 0 then
			if hold.pad then joypad.set(hold.pad) end
			hold.left = hold.left - 1
		elseif hold.untilFn then
			-- A leg that ends on the game's own state, with a frame limit so it cannot run forever.
			local after = game.observe()
			hold.count = hold.count + 1
			local done = hold.untilFn(after)
			if done or hold.count >= hold.limit then
				reply(hold.id, hold.finish(after, done, hold.count, hold.before))
				hold = nil
			end
		else
			-- The last set applies to the frame after it, so the answer is read one frame later.
			local after = game.observe()
			reply(hold.id, hold.finish(after, true, 0, hold.before))
			hold = nil
		end
	elseif #queue > 0 then
		begin(table.remove(queue, 1))
	end
	watchEvents()
end

MESHGHOST_DEV_UNLOAD = function()
	if game and game.stop then game.stop() end
	close("unloaded")
	if logf then logf:close() end
	logf = nil
end
