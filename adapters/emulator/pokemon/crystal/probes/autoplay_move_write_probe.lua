-- MeshGhost — Pokémon Crystal: what a move's power and accuracy bytes DO, by changing them in a battle
-- (DEV TOOL, WRITES WRAM, never shipped) -- 2026-09-17
--
-- WRITES one byte of the player's move struct in WRAM, and only while armed. Load it beside the autoplay driver and
-- autoplay_battle_probe.lua; arm it with a line in autoplay_move_write.cmd beside this file (read every 15 frames):
--   write <offset> <value> <move id>   while a battle runs and the struct's first byte reads <move id>, keep byte
--                                      <offset> (0-6) of wPlayerMoveStruct (C60F) at <value>, every frame
--   hold <address> <value>             while a battle runs, keep the WRAM byte at CPU address <address> (hex, C000-DFFF)
--                                      at <value>, every frame (added 2026-09-17 for which stat a type's damage uses)
--   off                                write nothing (also the state with no file)
-- A file may hold several lines, one command each.
-- Then restore a snapshot on the move menu, choose that move, and read what the turn did (damage, HP, a miss message)
-- against the same snapshot's turn with the probe off. Take it off the loader's target when done.
--
-- WHY. Crystal draws a move's type and PP in the battle's move box, never its power or accuracy, so those two bytes
-- cannot be read against the screen the way Emerald's summary allowed. What the game does with them can be seen: a
-- turn replayed from one snapshot with only that byte changed.
--
-- WHAT IT LOGS: every change of the command, each frame a write was needed (the byte before, the value written, and
-- the byte read back on the next frame through a fresh read), and on change the player's move struct, wCurDamage,
-- wAttackMissed and the enemy's HP (wEnemyMon +0x10). What it cannot see: a load and a use of the struct inside one
-- frame (the write would come too late; the log's "before" values show whether the struct was reloaded mid-turn).
--
-- COST. One 7-byte read a frame, one file read every 15 frames. Log: crystal/logs/autoplay_move_write_<port>_<ts>.log.

local dir, port = ".", tostring(AUTOPLAY_PORT or os.getenv("AUTOPLAY_PORT") or "na")
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local logdir = (dir:match("^(.*)/probes$") or dir) .. "/logs"
local cmdPath = dir .. "/autoplay_move_write.cmd"
local logf = io.open(string.format("%s/autoplay_move_write_%s_%s.log", logdir, port, os.date("%Y%m%d_%H%M%S")), "w")
if logf then logf:setvbuf("full", 16384) end
local function log(s)
	if logf then logf:write(string.format("[%s f%d] %s\n", os.date("%H:%M:%S"), emu.framecount(), s)) end
end

local function flat(cpu) return cpu < 0xD000 and cpu - 0xC000 or 0x1000 + (cpu - 0xD000) end
local STRUCT, BATTLE_MODE, DAMAGE, MISSED, ENEMY_HP = flat(0xC60F), flat(0xD22D), flat(0xD256), flat(0xC667), flat(0xD216)

local armed, holds, cmdText, frames, pendingCheck, last = nil, {}, nil, 0, nil, nil

local function readCmd()
	local f = io.open(cmdPath, "r")
	local text = f and f:read("*a") or ""
	if f then f:close() end
	text = text:gsub("%s+$", "")
	if text == cmdText then return end
	cmdText = text
	armed, holds = nil, {}
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		line = line:gsub("%s+$", "")
		local off, val, move = line:match("^write%s+(%d+)%s+(%d+)%s+(%d+)$")
		off, val, move = tonumber(off), tonumber(val), tonumber(move)
		local addr, hval = line:match("^hold%s+(%x+)%s+(%d+)$")
		addr, hval = tonumber(addr or "", 16), tonumber(hval)
		if off and val and move and off <= 6 and val <= 255 and move >= 1 and move <= 255 then
			armed = { off = off, val = val, move = move }
			log(string.format("armed: offset %d value %d move %d", off, val, move))
		elseif addr and hval and addr >= 0xC000 and addr <= 0xDFFF and hval <= 255 then
			holds[#holds + 1] = { at = flat(addr), addr = addr, val = hval }
			log(string.format("armed: hold %04X at %d", addr, hval))
		elseif line ~= "" then
			log("ignored line: " .. line)
		end
	end
	if not armed and #holds == 0 then log("off (command: " .. (text == "" and "none" or text) .. ")") end
end

log("loaded")
readCmd()

MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	if frames % 15 == 0 then readCmd() end
	local s = memory.read_bytes_as_array(STRUCT, 7, "WRAM")
	if pendingCheck then
		log(string.format("read back offset %d: %d (wrote %d)", pendingCheck.off, s[pendingCheck.off + 1], pendingCheck.val))
		pendingCheck = nil
	end
	local d = memory.read_bytes_as_array(DAMAGE, 2, "WRAM")
	local hp = memory.read_bytes_as_array(ENEMY_HP, 2, "WRAM")
	local line = string.format("struct %02X %02X %02X %02X %02X %02X %02X damage %d missed %d enemy_hp %d battle %d",
		s[1], s[2], s[3], s[4], s[5], s[6], s[7], (d[1] << 8) | d[2], memory.read_u8(MISSED, "WRAM"),
		(hp[1] << 8) | hp[2], memory.read_u8(BATTLE_MODE, "WRAM"))
	if line ~= last then
		log(line)
		last = line
	end
	if armed and memory.read_u8(BATTLE_MODE, "WRAM") ~= 0 and s[1] == armed.move and s[armed.off + 1] ~= armed.val then
		log(string.format("write offset %d: was %d, writing %d", armed.off, s[armed.off + 1], armed.val))
		memory.write_u8(STRUCT + armed.off, armed.val, "WRAM")
		pendingCheck = { off = armed.off, val = armed.val }
	end
	if memory.read_u8(BATTLE_MODE, "WRAM") ~= 0 then
		for _, h in ipairs(holds) do
			local now = memory.read_u8(h.at, "WRAM")
			if now ~= h.val then
				log(string.format("hold %04X: was %d, writing %d", h.addr, now, h.val))
				memory.write_u8(h.at, h.val, "WRAM")
			end
		end
	end
	if logf and frames % 120 == 0 then logf:flush() end
end

MESHGHOST_DEV_UNLOAD = function()
	log("unloaded")
	if logf then
		logf:flush()
		logf:close()
	end
	logf = nil
end
