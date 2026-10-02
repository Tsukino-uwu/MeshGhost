-- Which BizHawk memory domain reaches Game Boy WRAM bank 1, and under which mapping: a candidate counts only if
-- wMapGroup..wXCoord read as four sane consecutive bytes and both coordinates move on a walk. Read-only. Run once per
-- core (Gambatte, SameBoy) in the overworld, walking both axes; logs domain_probe_<timestamp>.log beside this script.

local WMAPGROUP = 0xDCB5 -- 01:dcb5 in the .sym; the other three follow it
local BANK1_BASE = 0xD000 -- GB banked WRAM window
local SETTLE_FRAMES = 30 -- ignore the first half-second, so a mid-load read isn't judged

-- Addressed as the CPU sees it (as System Bus is), or the whole WRAM array with banks end to end (bank 1 at 0x1000).
local MAPPINGS = {
	{ name = "cpu", addr = WMAPGROUP },
	{ name = "flat", addr = 0x1000 + (WMAPGROUP - BANK1_BASE) },
}

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	local stamp = os.date("%Y%m%d_%H%M%S")
	local path = string.format("%s/domain_probe_%s.log", dir, stamp)
	local f = io.open(path, "w")
	if f then
		logfile = f
		return path
	end
	return nil
end

-- The console is a GUI append on the emulator's thread and costs frames: it gets the opening lines and one in
-- twenty, the file gets every line.
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
		-- Every 20 lines, never per line: bounded cost, and the log stays live through a run.
		flushEvery = (flushEvery or 0) + 1
		if flushEvery >= 20 then
			flushEvery = 0
			pcall(function() logfile:flush() end)
		end
	end
end

local function domain_list()
	local ok, list = pcall(memory.getmemorydomainlist)
	if not ok or type(list) ~= "table" then
		return {}
	end
	-- BizHawk returns a 0- or 1-based list depending on version; normalise by walking both.
	local out = {}
	for _, name in pairs(list) do
		if type(name) == "string" then
			out[#out + 1] = name
		end
	end
	table.sort(out)
	return out
end

local function read_quad(domain, addr)
	local vals = {}
	for i = 0, 3 do
		local ok, v = pcall(memory.read_u8, addr + i, domain)
		if not ok or type(v) ~= "number" then
			return nil
		end
		vals[i + 1] = v
	end
	return vals
end

-- Deliberately loose: it rejects nonsense without claiming to know the real map-group range; movement decides.
local function plausible(q)
	if not q then
		return false
	end
	local all_same = q[1] == q[2] and q[2] == q[3] and q[3] == q[4]
	if all_same then
		return false
	end
	if q[1] == 0 and q[2] == 0 then
		return false -- map group and number both zero: not a loaded overworld map
	end
	return true
end

local candidates = {}
local frames = 0
local reported = false

local domains = domain_list()
local log_path = open_log()
log("=== MeshGhost Crystal domain probe ===")
if log_path then
	log("Logging to " .. log_path)
else
	log("NOTE: could not open a log file; console output is the only record.")
end
if #domains == 0 then
	log("Could not read the domain list. Is a ROM loaded?")
	return
end
log("Domains offered by this core: " .. table.concat(domains, ", "))
log("Looking for wMapGroup/wMapNumber/wYCoord/wXCoord as 4 consecutive bytes.")
log("Walk around for a few seconds...")

for _, domain in ipairs(domains) do
	for _, m in ipairs(MAPPINGS) do
		local q = read_quad(domain, m.addr)
		if plausible(q) then
			candidates[#candidates + 1] = {
				domain = domain,
				mapping = m.name,
				addr = m.addr,
				seen_y = {},
				seen_x = {},
				initial = q,
			}
		end
	end
end

if #candidates == 0 then
	log("No candidate domain looked plausible. Are you in the overworld, not a menu?")
	return
end

log(string.format("%d candidate(s) to disambiguate by movement.", #candidates))

local function summarise(c)
	local ycount, xcount = 0, 0
	for _ in pairs(c.seen_y) do
		ycount = ycount + 1
	end
	for _ in pairs(c.seen_x) do
		xcount = xcount + 1
	end
	return ycount, xcount
end

local function tick()
	frames = frames + 1
	if frames < SETTLE_FRAMES then
		return
	end

	for _, c in ipairs(candidates) do
		local q = read_quad(c.domain, c.addr)
		if q then
			c.seen_y[q[3]] = true
			c.seen_x[q[4]] = true
			c.last = q
		end
	end

	-- Every 2 seconds until the candidates moving on both axes agree, so a run that never resolves still reports.
	if not reported and frames % 120 == 0 then
		local movers = {}
		for _, c in ipairs(candidates) do
			local ycount, xcount = summarise(c)
			if ycount > 1 and xcount > 1 then
				movers[#movers + 1] = c
			end
		end

		-- A core exposes the same bytes through several domains, so candidates agreeing is corroboration; only
		-- disagreement is ambiguous.
		local function agree(a, b)
			for i = 1, 4 do
				if a.last[i] ~= b.last[i] then
					return false
				end
			end
			return true
		end

		local unanimous = #movers > 0
		for i = 2, #movers do
			if not agree(movers[1], movers[i]) then
				unanimous = false
				break
			end
		end

		if unanimous then
			local c = movers[1]
			log("=== MATCH ===")
			log(string.format(
				"group=%d number=%d  y=%d x=%d",
				c.last[1], c.last[2], c.last[3], c.last[4]
			))
			if #movers > 1 then
				log(string.format(
					"%d domains expose these same bytes and agree exactly:", #movers
				))
			end
			for _, m in ipairs(movers) do
				log(string.format(
					"  domain=%q mapping=%s  wMapGroup at 0x%04X",
					m.domain, m.mapping, m.addr
				))
			end
			log("Prefer the raw WRAM domain if offered: it addresses bank 1 unconditionally,")
			log("whereas the CPU-addressed view follows whatever bank is currently selected.")
			log("Record this in agent_docs/verified.md, noting which core is loaded.")
			reported = true
		elseif #movers > 1 then
			log(string.format(
				"%d candidates moving and they DISAGREE -- genuinely ambiguous:", #movers
			))
			for _, c in ipairs(movers) do
				log(string.format(
					"  domain=%q mapping=%s -> group=%d number=%d y=%d x=%d",
					c.domain, c.mapping, c.last[1], c.last[2], c.last[3], c.last[4]
				))
			end
		else
			log("No candidate has shown both coordinates changing yet -- walk further.")
		end
	end
end

while true do
	tick()
	emu.frameadvance()
end
