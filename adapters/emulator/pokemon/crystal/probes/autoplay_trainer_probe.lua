-- MeshGhost — Pokémon Crystal: a trainer seeing the player, coming over, and its defeat flag, for autoplay
-- (DEV TOOL, READ-ONLY, never shipped) -- 2026-09-17
--
-- READ-ONLY. Load it beside the autoplay driver, step into a trainer's line with `walk`, play the battle with
-- `battle`, and read this log against the driver's answers and captures.
--
-- WHY. On Route 30 Bug Catcher Don came for the player at three tiles and not at four; wScriptRunning read 1 from
-- that step until the map reloaded after the battle, where signs and wild encounters read 255. autoplay's `walk` and
-- `battle` need to know a trainer has seen the player and which one; `nearby` wants each trainer's range and whether
-- it is beaten. Our V1.0 build's .sym names the bytes to watch (wSeenTrainerBank..wTempTrainerEnd, hLastTalked,
-- wMapObjects, wEventFlags); what they read is this log's job.
--
-- WHAT IT LOGS, each on change, every frame, with the frame:
--   script   wScriptRunning, wScriptMode, wScriptFlags, hLastTalked (FFE0), wBattleMode, wOtherTrainerClass (D22F),
--            wOtherTrainerID (D231), wTrainerClass (D233)
--   seen     the 17 bytes D03E-D04E, raw
--   trainer N  for each map-object record (16 x 0x10 from D71E) whose +0x08 low nibble reads 2: the record, the 12
--            bytes its script pointer (+0x0A) points at in wMapScriptsBank, and the byte and bit of wEventFlags (DA72)
--            the first two of those bytes would name as a flag: byte, bit and value
-- What it cannot see: a trainer whose record does not read 2 at +0x08, anything between frames.
--
-- COST. About 40 bytes a frame, plus 16 records compared a frame. Log: crystal/logs/autoplay_trainer_<port>_<ts>.log.

local dir, port = ".", tostring(AUTOPLAY_PORT or os.getenv("AUTOPLAY_PORT") or "na")
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local logdir = (dir:match("^(.*)/probes$") or dir) .. "/logs"
local logf = io.open(string.format("%s/autoplay_trainer_%s_%s.log", logdir, port, os.date("%Y%m%d_%H%M%S")), "w")
if logf then logf:setvbuf("full", 16384) end
local function log(s)
	if logf then logf:write(string.format("[%s f%d] %s\n", os.date("%H:%M:%S"), emu.framecount(), s)) end
end

local function flat(cpu) return cpu < 0xD000 and cpu - 0xC000 or 0x1000 + (cpu - 0xD000) end
local function u8(cpu) return memory.read_u8(flat(cpu), "WRAM") end
local function hex(b)
	local out = {}
	for i = 1, #b do out[i] = string.format("%02X", b[i]) end
	return table.concat(out, " ")
end

local last = {}
local function changed(key, line)
	if last[key] ~= line then
		last[key] = line
		log(key .. " " .. line)
	end
end

log("loaded")
local frames = 0

MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	changed("script", string.format("running %d mode %d flags %02X lastTalked %d battleMode %d otherClass %d otherId %d class %d map %d.%d",
		u8(0xD438), u8(0xD437), u8(0xD434), memory.read_u8(0xFFE0, "System Bus"), u8(0xD22D), u8(0xD22F), u8(0xD231), u8(0xD233),
		u8(0xDCB5), u8(0xDCB6)))
	changed("seen", hex(memory.read_bytes_as_array(flat(0xD03E), 17, "WRAM")))
	local bank = u8(0xD1A3)
	for i = 0, 15 do
		local r = memory.read_bytes_as_array(flat(0xD71E) + i * 0x10, 0x10, "WRAM")
		if (r[9] & 0x0F) == 2 then
			local ptr = r[11] | (r[12] << 8)
			local header, flagInfo = "(pointer outside the bank)", ""
			if ptr >= 0x4000 and ptr <= 0x7FF0 then
				local h = memory.read_bytes_as_array(bank * 0x4000 + (ptr - 0x4000), 12, "ROM")
				header = hex(h)
				local flag = h[1] | (h[2] << 8)
				local byte = u8(0xDA72 + (flag >> 3))
				flagInfo = string.format(" flag %d byte %02X bit %d value %d", flag, byte, flag & 7, (byte >> (flag & 7)) & 1)
			end
			changed("trainer" .. i, string.format("record %s header %02X:%04X %s%s", hex(r), bank, ptr, header, flagInfo))
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
