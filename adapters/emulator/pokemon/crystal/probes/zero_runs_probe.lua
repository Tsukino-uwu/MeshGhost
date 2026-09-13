-- MeshGhost — Pokémon Crystal: the long zero runs in CPU-visible WRAM, and whether they stay zero
-- (READ-ONLY)
--
-- `noclip.lua` points the collision table at the longest zero run and never writes into it. A noclip
-- that keeps doors working has to WRITE a filtered copy of the table there instead, which is only
-- acceptable in a region the game is not using. This lists every run of >= 256 zero bytes in
-- $C000-$DFFF (bank 1 selected, as in the overworld), then re-reads them for ten seconds and reports
-- how many bytes of each were ever non-zero. Names come afterwards, from the build's .sym, offline.
-- Log: zero_runs_<build>_<timestamp>.log beside this file.

local WRAM = "WRAM"
local MIN_RUN = 256

local title = ""
for i = 0x134, 0x13E do
	local c = memory.read_u8(i, "ROM")
	if c == 0 then break end
	title = title .. string.char(c)
end

local logfile
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/zero_runs_%s_%s.log", dir, title:gsub("%W", ""),
		os.date("%Y%m%d_%H%M%S")), "w")
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end
local function say(msg)
	console.log(msg)
	if logfile then logfile:write(msg, "\n") end
end

-- Flat WRAM: $C000-$CFFF is 0x0000-0x0FFF, and bank 1's $D000-$DFFF is 0x1000-0x1FFF.
local function cpu(flat) return 0xC000 + flat end

local runs = {}
do
	local b = memory.read_bytes_as_array(0, 0x2000, WRAM)
	local start
	for i = 1, #b + 1 do
		if b[i] == 0 then
			start = start or i
		elseif start then
			if i - start >= MIN_RUN then
				runs[#runs + 1] = { from = start - 1, len = i - start, dirty = 0, dirtyAt = {} }
			end
			start = nil
		end
	end
end
say(string.format("=== zero runs, ROM %q, frame %d: %d run(s) of >= %d bytes ===", title,
	emu.framecount(), #runs, MIN_RUN))
for _, r in ipairs(runs) do
	say(string.format("  $%04X-$%04X  %d bytes", cpu(r.from), cpu(r.from + r.len - 1), r.len))
end

local frames = 0
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	if frames > 600 then return end
	if frames % 10 == 0 then
		local b = memory.read_bytes_as_array(0, 0x2000, WRAM)
		for _, r in ipairs(runs) do
			for i = r.from, r.from + r.len - 1 do
				if b[i + 1] ~= 0 and not r.dirtyAt[i] then
					r.dirtyAt[i] = frames
					r.dirty = r.dirty + 1
				end
			end
		end
	end
	if frames == 600 then
		say("  after 10 seconds of re-reads every 10 frames:")
		for _, r in ipairs(runs) do
			local first
			for i = r.from, r.from + r.len - 1 do
				if r.dirtyAt[i] then first = i break end
			end
			say(string.format("  $%04X-$%04X  %d byte(s) became non-zero%s", cpu(r.from),
				cpu(r.from + r.len - 1), r.dirty,
				first and string.format(" (first at $%04X)", cpu(first)) or ""))
		end
		say("  done. Drop this file from the loader target.")
		if logfile then logfile:flush() end
	end
end

MESHGHOST_DEV_UNLOAD = function()
	if logfile then
		pcall(function() logfile:flush() end)
		logfile:close()
		logfile = nil
	end
end
