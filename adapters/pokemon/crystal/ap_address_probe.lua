-- MeshGhost — Crystal/Archipelago: find wObjectStructs by differential scan
--
-- READ-ONLY. Writes nothing, spawns nothing.
--
-- WHY
-- Archipelago's Crystal patch moves WRAM non-uniformly, and its published table exports what its
-- own client uses, not what we do. Five addresses are derivable from it (verified.md, 2026-08-18):
--
--   wMapGroup 7359, wMapNumber 7360, wYCoord 7361, wXCoord 7362   (four consecutive bytes)
--   wMapStatus 5177                                               (one before wMapEventStatus)
--
-- wObjectStructs is not. The obvious guess is vanilla+7, because wMapEventStatus sits at +7 and
-- the object array is ~160 bytes away — but observed deltas elsewhere were +7, -45, +22 and +10,
-- so "nearby means same delta" is exactly the plausible assumption this project keeps getting
-- caught by. So it is MEASURED, not guessed.
--
-- HOW
-- A differential scan, which is the one technique that cannot be fooled by a plausible-looking
-- address. The player's own object struct is slot 0, and its MAP_X/MAP_Y (offsets 0x10/0x11) move
-- exactly with the player. So:
--
--   1. Watch AP's wXCoord/wYCoord for a change (the player took a step).
--   2. Keep only candidate bases whose (base+0x10, base+0x11) changed by the SAME delta.
--   3. Repeat. Each step in a new direction cuts the survivors down hard.
--
-- A lookalike survives one step. Nothing survives four in different directions except the real
-- thing.
--
-- HOW TO RUN
--   1. Load the ARCHIPELAGO Crystal ROM, be in the overworld.
--   2. Lua Console -> Script -> Open, pick this file.
--   3. WALK — several steps, changing direction: right, left, up, down.
--      Log: ap_address_<timestamp>.log beside this script.

local DOMAIN = "WRAM"

-- From Archipelago's own data.json plus the decomp's contiguity facts.
local AP_MAPGROUP = 7359
local AP_MAPNUMBER = 7360
local AP_YCOORD = 7361
local AP_XCOORD = 7362
local AP_MAPSTATUS = 5177

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

log("=== MeshGhost Crystal/AP address probe (READ-ONLY) ===")
log(string.format("Using AP's wXCoord=%d wYCoord=%d. Vanilla wObjectStructs is 0x%04X.",
	AP_XCOORD, AP_YCOORD, VANILLA_OBJECT_STRUCTS))
log("WALK, changing direction a few times. Candidates are cut on every step.")

-- Every plausible base. The player's struct is slot 0 of the array, so the base IS the address we
-- want -- no stride search needed for this half.
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

	-- ONLY a real step counts: exactly one tile, on exactly one axis. The first run treated any
	-- change as a step and the very first sample was "+88,+4" — a map load or a mid-transition
	-- read — which discarded every candidate at once and reported a confident dead end.
	--
	-- Anything else (a warp, a map change, garbage during a load) re-baselines instead of
	-- filtering, so it costs nothing rather than destroying the run.
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
