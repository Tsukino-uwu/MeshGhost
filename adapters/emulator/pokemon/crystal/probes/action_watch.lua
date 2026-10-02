-- Read-only: does the player's own object carry the action byte while the player fishes, bumps, spins, emotes or
-- lands from a Fly? Logs only the frames where something changed, so a quiet log means a quiet player; load it
-- beside the adapter or on its own, and play through the checklist it prints. An action that never appears is one
-- the player object does not carry.

local DOMAIN = "WRAM"

-- WRAM laid flat as the adapter does: this domain addresses bank 1 whatever bank is selected.
local function flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

-- Vanilla V1.0 only, from our hash-verified build's .sym: the question is about the game, not a patched build.
local OBJECT_STRUCTS = flat(0xD4D6) -- wObjectStructs
local W_PLAYERSTATE = flat(0xD95D) -- wPlayerState
local OBJECT_LENGTH = 0x28

-- The player is struct 0.
local PLAYER = OBJECT_STRUCTS

local F_SPRITE, F_WALKING, F_DIRECTION = 0x00, 0x07, 0x08
local F_STEP_TYPE, F_ACTION, F_STEP_FRAME, F_FACING = 0x09, 0x0B, 0x0C, 0x0D

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/action_watch_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	-- Buffered, never flushed per line: a flush is a synchronous disk write on the emulator's own thread.
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end

-- The console is a GUI append on the emulator's thread, so it gets the first lines and one in twenty; the file all.
local rawConsole, consoleLines = console.log, 0
local function raw_log(msg)
	consoleLines = consoleLines + 1
	if consoleLines <= 4 or consoleLines % 20 == 0 then
		rawConsole(msg)
	end
end
local function log(msg)
	raw_log(msg)
	if logfile then
		logfile:write(msg, "\n")
		-- Flush every 20 lines: a bounded cost, and a log that is never empty for a whole run.
		flushEvery = (flushEvery or 0) + 1
		if flushEvery >= 20 then
			flushEvery = 0
			pcall(function() logfile:flush() end)
		end
	end
end

local function u8(addr)
	local ok, v = pcall(memory.read_u8, addr, DOMAIN)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

local function actionName(v)
	return tostring(v)
end

local function facingName(v)
	return string.format("0x%02X", v)
end

open_log()
log("=== MeshGhost Crystal action watch (READ-ONLY) ===")
log("The question: does the PLAYER's own object struct carry the action byte for each animation?")
log("Play normally and do any of these; each one that reaches the player object prints a line:")
log("  * fish (any rod, at any water tile)      -> expecting ACTION -> FISHING")
log("  * walk into a wall and keep pressing     -> expecting ACTION -> BUMP")
log("  * stand on a spin tile / use Dig or Teleport -> expecting ACTION -> SPIN or SPIN_FLICKER")
log("  * anything that puts a '!' over your head -> expecting ACTION -> EMOTE")
log("  * Fly somewhere and watch the landing    -> expecting ACTION -> SKYFALL")
log("  * ride the bike, and surf                -> expecting SPRITE and wPlayerState to change,")
log("                                              NOT the action byte")
log("No timing to hit. A quiet log means a quiet player, not a broken probe.")

local prev = {}
local frames = 0
local seenActions = {}

local function tick()
	frames = frames + 1

	local now = {
		sprite = u8(PLAYER + F_SPRITE),
		walking = u8(PLAYER + F_WALKING),
		direction = u8(PLAYER + F_DIRECTION),
		steptype = u8(PLAYER + F_STEP_TYPE),
		action = u8(PLAYER + F_ACTION),
		stepframe = u8(PLAYER + F_STEP_FRAME),
		facing = u8(PLAYER + F_FACING),
		state = u8(W_PLAYERSTATE),
	}

	-- The action byte gets its own line and a running tally of every value the session saw.
	if now.action ~= prev.action then
		log(string.format("  f=%-7d ACTION %s->%s   (facing %s, dir %s, sprite %s, playerState %s)",
			frames, actionName(prev.action), actionName(now.action),
			facingName(now.facing), tostring(now.direction), tostring(now.sprite),
			tostring(now.state)))
		if now.action ~= nil and not seenActions[now.action] then
			seenActions[now.action] = true
			log(string.format("  ^^^ FIRST TIME this session the player object has held %s ^^^",
				actionName(now.action)))
		end
	end

	-- Context only when the action byte did not move, or one step prints the same thing twice.
	if now.action == prev.action then
		local changes = {}
		if now.sprite ~= prev.sprite then
			changes[#changes + 1] = string.format("SPRITE %s->%s",
				tostring(prev.sprite), tostring(now.sprite))
		end
		if now.state ~= prev.state then
			changes[#changes + 1] = string.format("wPlayerState %s->%s",
				tostring(prev.state), tostring(now.state))
		end
		-- The facing changes every stride, so it is logged only on an action change, above.
		if #changes > 0 then
			log(string.format("  f=%-7d %s", frames, table.concat(changes, "  ")))
		end
	end

	prev = now
end

-- Every 30 seconds, what has been seen so far: a quiet probe must not look like a dead one.
local function heartbeat()
	if frames % 1800 ~= 0 then
		return
	end
	local seen = {}
	for v in pairs(seenActions) do
		seen[#seen + 1] = actionName(v)
	end
	table.sort(seen)
	log(string.format("  [%ds] actions seen on the player object so far: %s",
		frames // 60, (#seen > 0) and table.concat(seen, ", ") or "(none yet)"))
end

MESHGHOST_DEV_TICK = function()
	tick()
	heartbeat()
end

MESHGHOST_DEV_UNLOAD = function()
	if logfile then
		pcall(function() logfile:flush() end)
		logfile:close()
		logfile = nil
	end
end

-- Standalone, its own loop: a registered callback outlives its script under BizHawk.
if not MESHGHOST_DEV_LOADER then
	while true do
		tick()
		heartbeat()
		emu.frameadvance()
	end
end
