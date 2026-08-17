-- MeshGhost — Pokémon Crystal: memory-domain probe
--
-- READ-ONLY DIAGNOSTIC. Writes nothing, sends nothing, draws nothing.
-- Not part of any shipped adapter; no Crystal adapter exists yet.
--
-- WHAT THIS ANSWERS
-- Crystal's addresses are already authoritative (see agent_docs/verified.md): they come from a
-- pokecrystal build whose ROM is byte-identical to the ROM being played. What is NOT yet known is
-- how to *reach* them from BizHawk, because Game Boy WRAM is banked and the decomp reports
-- addresses as bank:offset -- e.g. wMapGroup at 01:dcb5.
--
-- Two things need confirming, and only a running game can confirm them:
--   1. Which memory domain exposes WRAM bank 1, and under which of two plausible mappings.
--   2. Whether the Gambatte and SameBoy cores agree. Run this once under each.
--
-- HOW IT DECIDES, AND WHY IT IS NOT A GUESS
-- A wrong domain returns a plausible number rather than an error -- the exact hazard CLAUDE.md
-- warns about. So this does not trust a single read. It uses the fingerprint from the decomp:
-- wMapGroup / wMapNumber / wYCoord / wXCoord are four CONSECUTIVE bytes (01:dcb5..01:dcb8,
-- declared consecutively in pokecrystal's ram/wram.asm). A candidate is only reported as a match
-- if all four look sane AND the two coordinate bytes actually change when you walk.
--
-- HOW TO RUN
--   1. Open BizHawk, load the Crystal ROM, and be in the overworld (not a menu or battle).
--   2. Lua Console -> Script -> Open, pick this file.
--   3. Walk around for a few seconds, changing BOTH x and y (e.g. left/right, then up/down).
--      Read the verdict in the console -- it is also written to domain_probe_<timestamp>.log
--      beside this script, so the run leaves a record without anyone copying text out.
--
-- Stop it with the Lua Console's stop button; it holds no resources.

local WMAPGROUP = 0xDCB5 -- 01:dcb5, per pokecrystal.sym. The other three follow it.
local BANK1_BASE = 0xD000 -- GB banked WRAM window
local SETTLE_FRAMES = 30 -- ignore the first half-second, so a mid-load read isn't judged

-- The two mappings worth testing, and why each is plausible:
--   "cpu"  -- the domain is addressed exactly as the CPU sees it (System Bus behaves this way),
--            so wMapGroup sits at 0xDCB5 directly.
--   "flat" -- the domain is the whole WRAM array with banks laid end to end, so bank 1 starts at
--            0x1000 and wMapGroup sits at 0x1000 + (0xDCB5 - 0xD000) = 0x1CB5.
local MAPPINGS = {
	{ name = "cpu", addr = WMAPGROUP },
	{ name = "flat", addr = 0x1000 + (WMAPGROUP - BANK1_BASE) },
}

-- Mirror every console line to a timestamped log beside this script, matching the convention
-- Emerald's vram_probe.lua established. Without this the only record is the Lua Console window,
-- which means a human has to copy-paste it back -- found live 2026-08-17, on this probe's own
-- first run.
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

local raw_log = console.log
local function log(msg)
	raw_log(msg)
	if logfile then
		logfile:write(msg, "\n")
		logfile:flush()
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

-- Read the four fingerprint bytes. Returns nil if the domain/address isn't readable at all.
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

-- Sanity, deliberately loose. This rejects obvious nonsense (all zeroes, all 0xFF) without
-- pretending to know Crystal's real map-group range -- that would be an address-from-memory claim,
-- which CLAUDE.md forbids. The real discriminator is movement, checked separately below.
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

event.onframeend(function()
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

	-- Report as soon as exactly one candidate has shown movement in BOTH coordinates, or
	-- periodically so a run that never resolves still says something useful.
	if not reported and frames % 120 == 0 then
		local movers = {}
		for _, c in ipairs(candidates) do
			local ycount, xcount = summarise(c)
			if ycount > 1 and xcount > 1 then
				movers[#movers + 1] = c
			end
		end

		if #movers == 1 then
			local c = movers[1]
			log("=== MATCH ===")
			log(string.format(
				"domain=%q mapping=%s  wMapGroup at 0x%04X",
				c.domain, c.mapping, c.addr
			))
			log(string.format(
				"  group=%d number=%d  y=%d x=%d",
				c.last[1], c.last[2], c.last[3], c.last[4]
			))
			log("Record this in agent_docs/verified.md, noting which core is loaded.")
			reported = true
		elseif #movers > 1 then
			log(string.format(
				"%d candidates still moving -- ambiguous, keep walking:", #movers
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
end)
