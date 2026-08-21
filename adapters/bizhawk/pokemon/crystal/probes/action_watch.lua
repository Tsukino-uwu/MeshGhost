-- MeshGhost — Pokémon Crystal: what the PLAYER's object is doing, in the engine's own terms
--
-- READ-ONLY DIAGNOSTIC. Writes nothing, spawns nothing, changes nothing on screen.
--
-- WHY THIS EXISTS
-- phase9.md's animation enumeration says every animation a player can be seen doing -- fishing,
-- bumping a wall, spinning on a spin tile, the "!" emote, the Fly landing -- is selected by ONE
-- byte, `OBJECT_ACTION` (offset 0x0b), because the engine indexes ObjectActionPairPointers with
-- it (engine/overworld/map_object_action.asm) and derives `OBJECT_FACING` from the result. That
-- is read from the decomp, and reading is not watching.
--
-- What has NOT been established is the thing the whole design rests on: **does the PLAYER's own
-- object actually carry those action values while the player does those things?** Fishing might
-- be driven entirely by a script that never touches the player's object struct; the emote might
-- live on a separate object. If so, sending `extras.act` sends a byte that never changes, and the
-- ghost would animate nothing while every log line looked healthy.
--
-- This probe answers exactly that question, and nothing else.
--
-- HOW TO RUN
--   Load it beside the adapter (dev-scripts/bizhawk-dev-loader.lua takes several targets), or on
--   its own from the Lua Console -> Script -> Open. It prints only the frames where something
--   changed, so a quiet log means a quiet player. Log: action_watch_<timestamp>.log beside this
--   file.
--
--   There is no window to hit and no timing to get right. Play normally and do the things in the
--   checklist it prints; each one that happens shows up as a line naming the action by name.
--
-- READING IT
--   `ACTION 1->6 (STAND->FISHING)` is the whole answer for fishing: the byte moved, and it moved
--   to the value the decomp's table says means fishing. An action that never appears is one the
--   player object does not carry -- write that down rather than assuming the probe missed it.

local DOMAIN = "WRAM"

-- WRAM bank 1 laid flat, the same mapping the adapter uses: bank 0 is 0xC000-0xCFFF, bank 1 is
-- 0xD000-0xDFFF, and this domain addresses bank 1 unconditionally rather than following whatever
-- bank happens to be selected.
local function flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

-- Vanilla V1.0 addresses, from our own hash-verified pokecrystal build's pokecrystal.sym.
-- This probe is deliberately vanilla-only: it exists to settle a question about the GAME, and
-- asking it on a patched build first would answer a different one.
local OBJECT_STRUCTS = flat(0xD4D6) -- wObjectStructs
local W_PLAYERSTATE = flat(0xD95D) -- wPlayerState
local OBJECT_LENGTH = 0x28

-- Player is struct 0 by construction (phase9.md).
local PLAYER = OBJECT_STRUCTS

-- constants/map_object_constants.asm, the ObjectActionPairPointers indexes.
local ACTION_NAMES = {
	[0] = "00", [1] = "STAND", [2] = "STEP", [3] = "BUMP", [4] = "SPIN",
	[5] = "SPIN_FLICKER", [6] = "FISHING", [7] = "SHADOW", [8] = "EMOTE",
	[9] = "BIG_DOLL_SYM", [10] = "BOUNCE", [11] = "WEIRD_TREE", [12] = "BIG_DOLL_ASYM",
	[13] = "BIG_DOLL", [14] = "BOULDER_DUST", [15] = "GRASS_SHAKE", [16] = "SKYFALL",
}

-- constants/map_object_constants.asm, the Facings indexes. Only the ones a player can reach are
-- named; anything else prints as a number, which is itself the finding.
local FACING_NAMES = {
	[0] = "STEP_DOWN_0", [1] = "STEP_DOWN_1", [2] = "STEP_DOWN_2", [3] = "STEP_DOWN_3",
	[4] = "STEP_UP_0", [5] = "STEP_UP_1", [6] = "STEP_UP_2", [7] = "STEP_UP_3",
	[8] = "STEP_LEFT_0", [9] = "STEP_LEFT_1", [10] = "STEP_LEFT_2", [11] = "STEP_LEFT_3",
	[12] = "STEP_RIGHT_0", [13] = "STEP_RIGHT_1", [14] = "STEP_RIGHT_2", [15] = "STEP_RIGHT_3",
	[16] = "FISH_DOWN", [17] = "FISH_UP", [18] = "FISH_LEFT", [19] = "FISH_RIGHT",
	[20] = "EMOTE", [21] = "SHADOW",
	[255] = "STANDING",
}

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
end

local raw_log = console.log
local function log(msg)
	raw_log(msg)
	if logfile then
		logfile:write(msg, "\n")
		logfile:flush()
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
	return ACTION_NAMES[v] or ("?" .. tostring(v))
end

local function facingName(v)
	return FACING_NAMES[v] or ("?" .. tostring(v))
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

	-- The action byte is the point of the probe, so it gets its own line and its own running
	-- tally: "which actions did this session ever see" is the answer being collected, and a
	-- tally survives a log nobody scrolls back through.
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

	-- The rest is context, and only printed when the action byte is NOT the thing that moved --
	-- otherwise one step prints the same information twice.
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
		if now.facing ~= prev.facing and FACING_NAMES[now.facing] == nil then
			-- An unnamed facing is a finding: it means the player reached a frame index this
			-- probe's table does not cover, which is worth a line even mid-step.
			changes[#changes + 1] = string.format("FACING %s->%s",
				facingName(prev.facing), facingName(now.facing))
		end
		if #changes > 0 then
			log(string.format("  f=%-7d %s", frames, table.concat(changes, "  ")))
		end
	end

	prev = now
end

-- Every 30 seconds, say what has been seen so far. A probe that has been running for ten minutes
-- with nothing to say is indistinguishable from one that died, and this one is expected to be
-- quiet for long stretches.
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
		logfile:close()
		logfile = nil
	end
end

-- Standalone: the loader is not driving us, so run our own loop. A registered callback outlives
-- its script under BizHawk, which is why this is a loop and not event.onframeend (pitfalls.md).
if not MESHGHOST_DEV_LOADER then
	while true do
		tick()
		heartbeat()
		emu.frameadvance()
	end
end
