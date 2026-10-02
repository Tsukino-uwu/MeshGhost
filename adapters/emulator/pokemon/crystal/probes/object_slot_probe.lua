-- Read-only: which of the 13 object structs are free during real play, whether a free one stays free, and what a
-- map transition does to them, with each struct dumped the frame the game fills it and as it settles. Writes
-- nothing. Walk around, enter and leave a building, and pass some NPCs. Addresses from our hash-verified build.

local DOMAIN = "WRAM" -- bank 1 whatever bank is selected; the same bytes as System Bus

local function flat(cpu_addr) -- CPU 0xD000-0xDFFF -> flat WRAM offset for bank 1
	return 0x1000 + (cpu_addr - 0xD000)
end

local OBJECT_STRUCTS = flat(0xD4D6)
local MAP_GROUP = flat(0xDCB5)
local OBJECT_LENGTH = 0x28
local NUM_OBJECT_STRUCTS = 13

-- Field offsets within one object struct, from the decompilation's layout.
local F_SPRITE = 0x00
local F_MAP_OBJECT_INDEX = 0x01
local F_PALETTE = 0x06
local F_DIRECTION = 0x08
local F_MAP_X = 0x10
local F_MAP_Y = 0x11

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	local path = string.format("%s/object_slot_probe_%s.log", dir, os.date("%Y%m%d_%H%M%S"))
	local f = io.open(path, "w")
	if f then
		logfile = f
		return path
	end
	return nil
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

local function slot(i)
	local base = OBJECT_STRUCTS + (i * OBJECT_LENGTH)
	return {
		sprite = u8(base + F_SPRITE),
		map_object = u8(base + F_MAP_OBJECT_INDEX),
		palette = u8(base + F_PALETTE),
		direction = u8(base + F_DIRECTION),
		x = u8(base + F_MAP_X),
		y = u8(base + F_MAP_Y),
	}
end

-- Sprite 0 means unused, the probe's one inference, so the full occupancy string is printed every time.
local function occupancy()
	local marks, used = {}, 0
	for i = 0, NUM_OBJECT_STRUCTS - 1 do
		local s = slot(i)
		if s.sprite and s.sprite ~= 0 then
			marks[#marks + 1] = "X"
			used = used + 1
		else
			marks[#marks + 1] = "."
		end
	end
	return table.concat(marks), used
end

local log_path = open_log()
log("=== MeshGhost Crystal object-slot probe (READ-ONLY) ===")
if log_path then
	log("Logging to " .. log_path)
end
log(string.format(
	"%d slots of %d bytes at flat 0x%04X (01:d4d6). Slot 0 is the player.",
	NUM_OBJECT_STRUCTS, OBJECT_LENGTH, OBJECT_STRUCTS
))
log("Walk around, pass NPCs, and enter/leave a building.")

local last_key = nil
local last_map = nil
local frames = 0

-- Occupancy every frame (13 reads), and the whole struct dumped the frame a slot fills: what a game-built object
-- looks like.
local occupied = {}
local pending = {} -- follow-up dumps, so a settling struct is visible rather than guessed at
local spawn_frame = {}

local function dump_struct(i, why)
	local base = OBJECT_STRUCTS + (i * OBJECT_LENGTH)
	local bytes = {}
	for off = 0, OBJECT_LENGTH - 1 do
		bytes[#bytes + 1] = string.format("%02X", u8(base + off) or 0)
	end
	log(string.format("*** %s: slot %d at frame %d ***", why, i, frames))
	-- Raw first, so nothing depends on the field offsets being right.
	log("    raw: " .. table.concat(bytes, " "))
	local s = slot(i)
	log(string.format(
		"    sprite=%d mapobj=%d pal=%d dir=%d x=%d y=%d",
		s.sprite or -1, s.map_object or -1, s.palette or -1,
		s.direction or -1, s.x or -1, s.y or -1
	))
end

local function tick()
	frames = frames + 1

	for i = 0, NUM_OBJECT_STRUCTS - 1 do
		local sprite = u8(OBJECT_STRUCTS + (i * OBJECT_LENGTH) + F_SPRITE)
		local now = (sprite ~= nil and sprite ~= 0)
		if now ~= (occupied[i] or false) then
			if now then
				-- The first non-zero frame is mid-initialisation: follow-ups show when the struct stops changing.
				spawn_frame[i] = frames
				dump_struct(i, "SPAWNED (first frame, still initialising)")
				pending[#pending + 1] = { slot = i, at = frames + 1 }
				pending[#pending + 1] = { slot = i, at = frames + 4 }
				pending[#pending + 1] = { slot = i, at = frames + 16 }
				pending[#pending + 1] = { slot = i, at = frames + 64 }
			else
				log(string.format("*** CLEARED: slot %d at frame %d ***", i, frames))
			end
			occupied[i] = now
		end
	end

	for n = #pending, 1, -1 do
		if frames >= pending[n].at then
			dump_struct(pending[n].slot, string.format("+%d frames", frames - spawn_frame[pending[n].slot]))
			table.remove(pending, n)
		end
	end

	if frames % 10 ~= 0 then -- the summary view below stays at 6Hz; the watch above is per-frame
		return
	end

	local group, number = u8(MAP_GROUP), u8(MAP_GROUP + 1)
	local marks, used = occupancy()
	local map_key = string.format("%d/%d", group or -1, number or -1)
	local key = map_key .. " " .. marks

	-- Heartbeat: a quiet map (the player's bedroom has no NPCs) must not look like a broken probe.
	if frames % 300 == 0 and key == last_key then
		local p = slot(0)
		log(string.format(
			"  [alive] map=%s slots [%s] %d used   player x=%d y=%d",
			map_key, marks, used, p.x or -1, p.y or -1
		))
	end

	if key ~= last_key then
		if map_key ~= last_map then
			log(string.format("--- map changed -> group=%s ---", map_key))
			last_map = map_key
		end
		log(string.format("slots [%s]  %d used, %d free", marks, used, NUM_OBJECT_STRUCTS - used))
		for i = 0, NUM_OBJECT_STRUCTS - 1 do
			local s = slot(i)
			if s.sprite and s.sprite ~= 0 then
				log(string.format(
					"  slot %2d: sprite=%3d mapobj=%3d pal=%3d dir=%d x=%3d y=%3d%s",
					i, s.sprite, s.map_object or -1, s.palette or -1,
					s.direction or -1, s.x or -1, s.y or -1,
					(i == 0) and "   <- player" or ""
				))
			end
		end
		last_key = key
	end
end

while true do
	tick()
	emu.frameadvance()
end
