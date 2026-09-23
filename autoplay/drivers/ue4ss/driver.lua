-- autoplay UE4SS driver (DEV TOOL, WRITES INPUT, never shipped; agent_docs/phases/autoplay/pseudoregalia.md)
--
-- The piece inside an Unreal game running UE4SS that carries out the autoplay core's commands, the way
-- drivers/bizhawk/driver.lua does inside BizHawk. Loaded by mod/Scripts/main.lua (the bootstrap copied into the
-- game), which sets AUTOPLAY = {repo, port, game, mod_dir}. It runs one frame at a time on the GAME thread,
-- from UE4SS's engine-tick hook (LoopInGameThreadAfterFrames(1, ...)): the socket is polled there without
-- blocking, and every read of an actor happens there, never on UE4SS's async thread.
--
-- The link is the core's protocol 1, stated at the top of autoplay/driver/driver.go. One request is carried out
-- at a time; a program (a hold, a wait) runs a frame at a time and answers when it ends.
-- WHILE A PRESS IS RUNNING THIS SCRIPT DRIVES THE PLAYER. Take the mod out (or its config) when done.

local PROTOCOL = 1
local MAX_LINE = 64 * 1024
local RETRY_SECONDS = 1
local REJECT_BACKOFF_SECONDS = 10
local PROGRAM_FRAME_LIMIT = 3600

local A = AUTOPLAY
local ROOT, port = A.repo, A.port

local logf = io.open(string.format("%s/autoplay/runs/driver_ue4ss_%s_%d.log", ROOT, A.game, port), "a")
local frame = 0
local function log(msg)
	local line = string.format("[%s f%d] %s", os.date("%H:%M:%S"), frame, msg)
	if logf then
		logf:write(line, "\n")
		logf:flush()
	end
	print("[MeshGhostAutoplay] " .. msg .. "\n")
end

local json = dofile(ROOT .. "/autoplay/drivers/bizhawk/json.lua")

-- LuaSocket: the copy Pseudoregalia's socket probe proved inside UE4SS's Lua (probe_socket, Phase 7.2).
-- lua54.dll first by full path, so the socket DLL binds to the Lua the game already has loaded.
local LIB = (ROOT .. "/adapters/pseudoregalia/probes/probe_socket/Scripts/lib/x64/"):gsub("/", "\\")
pcall(function() package.loadlib(LIB .. "lua54.dll", "autoplay_force_preload") end)
local openSocket, socketErr = package.loadlib(LIB .. "socket-windows-5-4.dll", "luaopen_socket_core")
if not openSocket then
	log("could not load LuaSocket from " .. LIB .. ": " .. tostring(socketErr))
	return
end
local socket = openSocket()

-- The game module, handed the driver's helpers.
local host = { log = log, json = json, frame = function() return frame end, root = ROOT }
local chunk, cerr = loadfile(ROOT .. "/autoplay/drivers/ue4ss/games/" .. A.game .. ".lua")
if not chunk then
	log("no game module for " .. tostring(A.game) .. ": " .. tostring(cerr))
	return
end
local game = chunk(host)

local sock, state = nil, "down"
local pieces, piecesBytes = {}, 0 -- a line being received, in pieces (drain)
local nextTry, nextPing = 0, 0
local queue = {}
local hold = nil
local lastWatch = nil

local close

local function send(msg)
	if not sock then return false end
	local okEnc, line = pcall(json.encode, msg)
	if not okEnc then
		log("an outgoing message does not encode: " .. tostring(line))
		return false
	end
	if #line + 1 > MAX_LINE then
		log("dropping an outgoing line of " .. #line .. " bytes")
		return false
	end
	local ok, err = sock:send(line .. "\n")
	if not ok then
		if err ~= "timeout" then close("send failed: " .. tostring(err)) else log("send failed: timeout") end
		return false
	end
	return true
end

function close(why, backoff)
	if sock then pcall(function() sock:close() end) end
	sock, state, queue, pieces, piecesBytes = nil, "down", {}, {}, 0
	if hold then
		if game.release then game.release() end
		hold = nil
	end
	nextTry = os.time() + (backoff or RETRY_SECONDS)
	log("link down: " .. why)
end

local function reply(id, payload) send({ id = id, type = "result", payload = payload }) end
local function fail(id, message) send({ id = id, type = "error", payload = { message = message } }) end

local function changed(before, after)
	local a, b, out = game.diffKeys(before), game.diffKeys(after), {}
	for k, v in pairs(b) do
		if a[k] ~= v then out[k] = { from = a[k], to = v } end
	end
	return out
end

-- EXEC {code, token}: Lua run inside the game, on the game thread, for a question no tool answers yet. Only with
-- the token the core wrote for this port (autoplay/runs/exec_token_<port>.txt). The chunk reads UE4SS's globals
-- through its own environment, gets `game` (the module), `host` and `print` (into the answer), and is stopped after
-- EXEC_INSTRUCTIONS VM instructions. A native fault is not a Lua error: no pcall catches an access violation, so
-- a UFunction call on an object you do not own can still take the game down (adapters/pseudoregalia/CLAUDE.md).
local EXEC_INSTRUCTIONS, EXEC_OUTPUT_LINES = 20000000, 400

local function toPlain(v, depth)
	depth = depth or 0
	local t = type(v)
	if t == "nil" or t == "boolean" or t == "number" or t == "string" then return v end
	if t == "table" and depth < 6 then
		local out = {}
		for k, x in pairs(v) do
			local key = (math.type(k) == "integer") and k or tostring(k)
			out[key] = toPlain(x, depth + 1)
		end
		return out
	end
	return tostring(v)
end

local function execCode(p)
	if type(p.code) ~= "string" or p.code == "" then return nil, "exec needs code" end
	local path = string.format("%s/autoplay/runs/exec_token_%d.txt", ROOT, port)
	local fh = io.open(path, "r")
	local want = fh and fh:read("*l")
	if fh then fh:close() end
	if not want or want == "" or p.token ~= want then
		return nil, "exec refused: the request's token is not the one in " .. path
	end
	local output = {}
	local env = setmetatable({
		game = game,
		host = host,
		print = function(...)
			if #output >= EXEC_OUTPUT_LINES then return end
			local parts = {}
			for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
			output[#output + 1] = table.concat(parts, "\t")
		end,
	}, { __index = _G })
	local fn, err = load(p.code, "=exec", "t", env)
	if not fn then return nil, "exec: " .. tostring(err) end
	debug.sethook(function() error(string.format("stopped after %d instructions", EXEC_INSTRUCTIONS), 2) end, "", EXEC_INSTRUCTIONS)
	local res = table.pack(pcall(fn))
	debug.sethook()
	if not res[1] then return nil, "exec: " .. tostring(res[2]) end
	local results = {}
	for i = 2, res.n do results[#results + 1] = toPlain(res[i]) end
	local answer = { results = results, output = output, frame = frame }
	local ok, line = pcall(json.encode, answer)
	if not ok then return nil, "exec: the answer does not encode: " .. tostring(line) end
	if #line > MAX_LINE - 256 then
		return nil, string.format("exec: the answer is %d bytes, over the link's %d; return less", #line, MAX_LINE)
	end
	return answer
end

local function capabilities()
	local caps = { "observe", "exec" }
	for _, c in ipairs(game.capabilities) do caps[#caps + 1] = c end
	return caps
end

local function persisting()
	return game.persisting and game.persisting() or {}
end

-- A request becomes either an immediate answer or a `hold`: a program run once per frame, returning
-- (finished, result, err). The game module's `programs` table makes them; `wait` is the driver's own.
local function begin(req)
	local verb, p = req.type, req.payload or {}
	if verb == "observe" then
		local ok, o = pcall(game.observe, true)
		if ok then reply(req.id, o) else fail(req.id, "observe: " .. tostring(o)) end
		return
	end
	if verb == "exec" then
		local answer, err = execCode(p)
		log(answer and "exec" or ("exec failed: " .. tostring(err)))
		if answer then reply(req.id, answer) else fail(req.id, err) end
		return
	end
	if verb == "cheat" then
		local fn = game.cheats and game.cheats[p.kind]
		if not fn then return fail(req.id, "no cheat " .. tostring(p.kind)) end
		local ok, report, err = pcall(fn, p.args or {})
		if not ok then return fail(req.id, "cheat " .. p.kind .. ": " .. tostring(report)) end
		if not report then return fail(req.id, err or ("cheat " .. p.kind .. " refused")) end
		if report.program then
			hold = { id = req.id, program = report.program, count = 0, before = game.observe(false), limit = report.limit }
			return
		end
		report.persisting = persisting()
		return reply(req.id, report)
	end
	local make = game.programs and game.programs[verb]
	if verb == "wait" then
		local n = tonumber(p.frames) or 0
		make = function()
			return function(count)
				if count >= n then return true, { frames = count } end
				return false
			end
		end
	end
	local limit = p.limit
	if verb == "reflex" then
		local kind = p.kind
		local r = game.reflexes and game.reflexes[kind]
		if not r then return fail(req.id, "no reflex " .. tostring(kind)) end
		make = function() return r(p.args or {}) end
		limit = tonumber(p.frames) or 600
	end
	if not make then return fail(req.id, "unhandled request " .. tostring(verb)) end
	local ok, program, err = pcall(make, p)
	if not ok then return fail(req.id, verb .. ": " .. tostring(program)) end
	if not program then return fail(req.id, err or (verb .. " refused")) end
	hold = { id = req.id, program = program, count = 0, before = game.observe(false), limit = limit, reflex = verb == "reflex" }
end

local function handle(line)
	local ok, msg = pcall(json.decode, line)
	if not ok or type(msg) ~= "table" then
		log(string.format("ignoring a line that does not parse (%d bytes, type %s, first %s): %s", #line, type(line), table.concat({ line:byte(1, 12) }, ","), tostring(msg)))
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
	s:settimeout(0.02)
	if not s:connect("127.0.0.1", port) then
		pcall(function() s:close() end)
		nextTry = os.time() + RETRY_SECONDS
		return
	end
	s:settimeout(0)
	pcall(function() s:setoption("tcp-nodelay", true) end)
	sock, state, pieces, piecesBytes = s, "hello_sent", {}, 0
	send({
		type = "hello",
		payload = {
			protocol = PROTOCOL,
			host = "ue4ss",
			game = game.game,
			variant = game.variant,
			build = game.build(),
			capabilities = capabilities(),
			protected_slots = game.protected_slots,
			persisting = persisting(),
		},
	})
	log("connected to 127.0.0.1:" .. port .. ", hello sent")
end

-- Received bytes come in pieces of at most CHUNK: a string LuaSocket makes is built by ITS OWN lua54.dll, a second
-- Lua runtime, and one longer than Lua's short-string limit (40) reads as empty in UE4SS's Lua while a shorter one
-- reads right (the loopback self-test, 2026-09-23; the 98% "corrupt lines" of Phase 7.5 were the same wall). So
-- nothing is ever received as a line or with a prefix: pieces are joined here, in UE4SS's own runtime.
local CHUNK, NL = 40, string.char(10)

local function takeLines(piece)
	local start = 1
	while true do
		local nl = piece:find(NL, start, true)
		if not nl then break end
		pieces[#pieces + 1] = piece:sub(start, nl - 1)
		local line = table.concat(pieces)
		pieces, piecesBytes = {}, 0
		handle(line)
		if not sock then return end
		start = nl + 1
	end
	if start <= #piece then
		pieces[#pieces + 1] = piece:sub(start)
		piecesBytes = piecesBytes + #piece - start + 1
		if piecesBytes > MAX_LINE then close("a line over " .. MAX_LINE .. " bytes") end
	end
end

local function drain()
	while sock do
		local piece, err, part = sock:receive(CHUNK)
		if piece then
			takeLines(piece)
		elseif err == "timeout" then
			if part and #part > 0 then takeLines(part) end
			return
		else
			close(tostring(err))
			return
		end
	end
end

-- Each key of the module's watch() that changed goes out as "<key>_changed".
local function watchEvents()
	local ok, d = pcall(game.watch)
	if not ok or type(d) ~= "table" then return end
	if lastWatch and state == "ready" then
		for key, value in pairs(d) do
			if value ~= lastWatch[key] then
				send({ type = "event", payload = { kind = key .. "_changed", from = lastWatch[key], to = value, frame = frame } })
			end
		end
	end
	lastWatch = d
end

local function tick()
	frame = frame + 1
	if game.tick then
		local ok, err = pcall(game.tick, frame)
		if not ok then log("game.tick: " .. tostring(err)) end
	end
	if not sock then
		if os.time() >= nextTry then connect() end
		return
	end
	drain()
	if not sock then return end
	if state == "ready" and os.time() >= nextPing then
		nextPing = os.time() + RETRY_SECONDS
		send({ type = "ping" })
		if not sock then return end
	end
	if hold then
		hold.count = hold.count + 1
		local ok, finished, result, err = pcall(hold.program, hold.count)
		if not ok then finished, err = true, tostring(finished) end
		if not finished and hold.count > (hold.limit or PROGRAM_FRAME_LIMIT) then
			if hold.reflex then
				finished, result = true, { outcome = "timeout" } -- a reflex's frame budget is an ordinary ending
			else
				finished, err = true, string.format("still running after %d frames", hold.limit or PROGRAM_FRAME_LIMIT)
			end
		end
		if finished then
			if game.release then game.release() end
			if err then
				fail(hold.id, err)
			else
				local o = game.observe(false)
				result = result or {}
				result.before, result.after = hold.before, o
				result.changed = changed(hold.before, o)
				reply(hold.id, result)
			end
			hold = nil
		end
	elseif #queue > 0 then
		begin(table.remove(queue, 1))
	end
	if frame % 6 == 0 then watchEvents() end
end

if not EngineTickAvailable then
	log("UE4SS reports no engine-tick hook: a frame loop is impossible, not starting")
	return
end
log(string.format("loaded for %s (%s), core port %d", game.game, game.variant, port))
if game.start then log(tostring(game.start())) end
LoopInGameThreadAfterFrames(1, function()
	local ok, err = pcall(tick)
	if not ok then log("tick: " .. tostring(err)) end
end)
