-- Finds wObjectStructs on the Archipelago build by differential scan: a base survives a step only if its slot 0's
-- MAP_X/MAP_Y moved with the player, and only the real one survives four. Read-only. Run on the AP ROM in the
-- overworld and walk, changing direction; logs ap_address_<timestamp>.log beside this script.

local DOMAIN = "WRAM"

-- Measured on this build by reversal (ap_reverse_probe.lua), not taken from AP's published table. In vanilla these
-- are the window origin, not the player; enough here, since a camera clamped at a map edge only costs a step.
local AP_YCOORD = 7358
local AP_XCOORD = 7359

local F_MAP_X, F_MAP_Y = 0x10, 0x11
local OBJECT_LENGTH = 0x28
local VANILLA_OBJECT_STRUCTS = 0x1000 + (0xD4D6 - 0xD000) -- 0x14D6, for reference in the report
local WRAM_SIZE = 0x8000

local function scriptDir()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		local d = info.source:sub(2):match("^(.*)[/\\]")
		if d and #d > 0 then
			return d
		end
	end
	local p = io.popen and io.popen("cd")
	if p then
		local out = p:read("*l")
		p:close()
		if out and #out > 0 then
			return out
		end
	end
	return "."
end

local logfile = io.open(string.format("%s/ap_address_%s.log", scriptDir(),
	os.date("%Y%m%d_%H%M%S")), "w")

local function log(msg)
	console.log(msg)
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

local function u8(addr)
	local ok, v = pcall(memory.read_u8, addr, DOMAIN)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

log("=== MeshGhost Crystal/AP address probe (READ-ONLY) ===")
log(string.format("Anchored on MEASURED X=%d Y=%d. Vanilla wObjectStructs is 0x%04X (predicting 0x14DC).",
	AP_XCOORD, AP_YCOORD, VANILLA_OBJECT_STRUCTS))
log("WALK, changing direction a few times. Candidates are cut on every step.")

-- The player's struct is slot 0, so a surviving base is the address itself: no stride search.
local candidates = {}
for a = 0, WRAM_SIZE - OBJECT_LENGTH - 1 do
	candidates[#candidates + 1] = a
end

local prevX, prevY = u8(AP_XCOORD), u8(AP_YCOORD)
local prevVals = {}
local steps, frames = 0, 0
local done = false
local snapshot

snapshot = function()
	prevVals = {}
	for _, a in ipairs(candidates) do
		prevVals[a] = { u8(a + F_MAP_X), u8(a + F_MAP_Y) }
	end
end

snapshot()

local function tick()
	frames = frames + 1
	if done or frames % 4 ~= 0 then
		return
	end

	local x, y = u8(AP_XCOORD), u8(AP_YCOORD)
	if not x or not y then
		return
	end
	local dx, dy = x - (prevX or x), y - (prevY or y)
	if dx == 0 and dy == 0 then
		return
	end

	-- Only one tile on one axis is a step; anything else (a warp, a load) re-baselines, or one bad sample
	-- discards every candidate.
	if math.abs(dx) + math.abs(dy) ~= 1 then
		prevX, prevY = x, y
		snapshot()
		log(string.format("  (ignored a jump of %+d,%+d — warp or load, re-baselining)", dx, dy))
		return
	end

	prevX, prevY = x, y

	local kept = {}
	for _, a in ipairs(candidates) do
		local before = prevVals[a]
		local nx, ny = u8(a + F_MAP_X), u8(a + F_MAP_Y)
		if before and before[1] and nx and ny
			and (nx - before[1]) == dx and (ny - before[2]) == dy then
			kept[#kept + 1] = a
		end
	end
	candidates = kept
	steps = steps + 1
	snapshot()

	log(string.format("  step %d (moved %+d,%+d): %d candidate(s) left", steps, dx, dy, #candidates))

	if #candidates == 0 then
		log("!! No candidate survived. wXCoord/wYCoord may be wrong for this ROM, or the object")
		log("!! struct layout differs. Nothing further can be concluded from this run.")
		done = true
	elseif #candidates <= 8 and steps >= 3 then
		log("=== SURVIVORS ===")
		for _, a in ipairs(candidates) do
			log(string.format("  0x%04X (%d)   vanilla+%d   sprite=%s mapx=%s mapy=%s",
				a, a, a - VANILLA_OBJECT_STRUCTS, tostring(u8(a)), tostring(u8(a + F_MAP_X)),
				tostring(u8(a + F_MAP_Y))))
		end
		log("The one whose byte 0 is a plausible sprite id and whose delta looks structural is")
		log("wObjectStructs. wMapObjects sits 0x248 after it in the vanilla build.")
		done = true
	end
end

while true do
	tick()
	emu.frameadvance()
end
