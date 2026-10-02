-- Logs the drawn tier's gate terms and the OBJ palette's brightness on every frame one changes, to find what says
-- "not the overworld" through a door. Read-only. Walk in and out of a house a few times; logs transition_<time>.log.

local DOMAIN = "WRAM"

local function flat(cpu)
	if cpu < 0xD000 then
		return cpu - 0xC000
	end
	return 0x1000 + (cpu - 0xD000)
end

-- Vanilla V1.0, the adapter's own vanilla table.
local W_MAPSTATUS = flat(0xD432)
local W_BATTLEMODE = flat(0xD22D)
local W_STATEFLAGS = flat(0xD0ED)
local W_MAPGROUP, W_MAPNUMBER = flat(0xDCB5), flat(0xDCB6)
local W_OBPALS = 0x5040 -- wOBPals1, WRAM bank 5 in this domain's flat layout

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/transition_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end

local rawConsole, consoleLines = console.log, 0
local function log(msg)
	consoleLines = consoleLines + 1
	if consoleLines <= 4 or consoleLines % 20 == 0 then
		rawConsole(msg)
	end
	if logfile then
		logfile:write(msg, "\n")
	end
end

local function u8(a)
	local ok, v = pcall(memory.read_u8, a, DOMAIN)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

open_log()
log("=== MeshGhost Crystal transition watch (READ-ONLY) ===")
log("Walk into a house and out again a few times. Prints only frames where something changed.")
log("The missing gate term is whichever column already says 'not the overworld' while the")
log("painted ghost is still visible.")

local frames, prev = 0, {}

local function tick()
	frames = frames + 1

	local live, playerEntries = 0, 0
	for i = 0, 39 do
		local y = memory.read_u8(i * 4, "OAM") or 0
		if y > 0 and y < 160 then
			live = live + 1
			if i < 4 then
				playerEntries = playerEntries + 1
			end
		end
	end

	-- Channel sum of the OBJ palette the drawn tier draws with: a fade through it would move this a long way.
	local sum = 0
	for i = 1, 3 do
		local lo = u8(W_OBPALS + i * 2) or 0
		local hi = u8(W_OBPALS + i * 2 + 1) or 0
		local c = lo | (hi << 8)
		sum = sum + (c & 0x1F) + ((c >> 5) & 0x1F) + ((c >> 10) & 0x1F)
	end

	local now = {
		status = u8(W_MAPSTATUS), battle = u8(W_BATTLEMODE), flags = u8(W_STATEFLAGS),
		map = string.format("%s/%s", tostring(u8(W_MAPGROUP)), tostring(u8(W_MAPNUMBER))),
		live = live, player = playerEntries, bright = sum,
	}

	local changed = false
	for k, v in pairs(now) do
		if prev[k] ~= v then
			changed = true
			break
		end
	end
	if changed then
		log(string.format("  f=%-7d map=%-7s status=%-4s battle=%-4s stateFlags=%-4s "
			.. "liveOAM=%-3d player0-3=%d objBrightness=%d",
			frames, now.map, tostring(now.status), tostring(now.battle), tostring(now.flags),
			now.live, now.player, now.bright))
		prev = now
	end

	if logfile and frames % 300 == 0 then
		pcall(function() logfile:flush() end)
	end
end

MESHGHOST_DEV_TICK = tick

MESHGHOST_DEV_UNLOAD = function()
	if logfile then
		pcall(function() logfile:flush() end)
		logfile:close()
		logfile = nil
	end
end

-- A registered callback outlives its script under BizHawk, so this is a loop, not event.onframeend.
if not MESHGHOST_DEV_LOADER then
	while true do
		tick()
		emu.frameadvance()
	end
end
