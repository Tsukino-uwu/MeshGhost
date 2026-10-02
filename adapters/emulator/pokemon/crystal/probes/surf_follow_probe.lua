-- Driven from savestate 10, writing no game memory: why a spawned ghost stops following a peer on water. Logs the
-- ghost's SWIMMING bit against the player's, respawns, lag in tiles and its step bytes, so the suspect (the swim bit
-- copied once at spawn) can be refuted. Holds the d-pad: unload it before judging anything on screen. Field offsets
-- and flag bits are the decompilation's, not measured. MESHGHOST_SURF_SLOT (10), _NOLOAD, _NODRIVE (just watch).

local f
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)/[^/]*$") or "."
	end
	f = io.open(dir .. "/surf_follow.log", "w")
	if f then f:setvbuf("full", 1 << 16) end
end

local function u8(a) return memory.read_u8(a, "System Bus") or 0 end

local OBJ, STRIDE, NSTRUCTS = 0xD4D6, 0x28, 13
local F = { sprite = 0x01, tile = 0x02, flags1 = 0x04, flags2 = 0x05, pal = 0x06, walking = 0x07,
	dir = 0x08, steptype = 0x09, act = 0x0B, face = 0x0D, tilecoll = 0x0E, mx = 0x10, my = 0x11,
	sx = 0x17, sy = 0x18 }
local SWIMMING, NOCLIP_TILES, MOVE_ANYWHERE, WONT_DELETE = 0x20, 0x10, 0x20, 0x02

local function flagStr(flags1, pal)
	local s = {}
	if (pal & SWIMMING) ~= 0 then s[#s + 1] = "SWIM" end
	if (flags1 & NOCLIP_TILES) ~= 0 then s[#s + 1] = "NOCLIP_T" end
	if (flags1 & MOVE_ANYWHERE) ~= 0 then s[#s + 1] = "MOVE_ANY" end
	if (flags1 & WONT_DELETE) ~= 0 then s[#s + 1] = "WONT_DEL" end
	return #s > 0 and table.concat(s, "+") or "-"
end

-- A ghost is identified by the adapter's own marker, orphan_probe.lua's fingerprint, never by slot number.
local function ghostSlots()
	local playerSprite = u8(OBJ + F.sprite)
	local out = {}
	for i = 1, NSTRUCTS - 1 do
		local b = OBJ + i * STRIDE
		if u8(b + F.tile) ~= 0 or u8(b + F.act) ~= 0 then
			if (u8(b + F.flags1) & WONT_DELETE) ~= 0 and u8(b + F.sprite) == playerSprite then
				out[#out + 1] = i
			end
		end
	end
	return out
end

local run = { key = nil, n = 0, at = 0 }
local function flush()
	if not run.key or not f then return end
	f:write(string.format("  f%-7d %s   x%d frames\n", run.at, run.key, run.n))
	run.key = nil
end
local function record(key, frame)
	if key ~= run.key then
		flush()
		run.key, run.n, run.at = key, 0, frame
	end
	run.n = run.n + 1
end

-- Counted: breaks and respawns side by side are the test of the suspect.
local stats = { frames = 0, swimAgree = 0, swimDisagree = 0, respawns = 0, maxLag = 0,
	lagSum = 0, lagN = 0, noGhost = 0, brokeWithSwim = 0, brokeWithoutSwim = 0 }
local lastGhostCount, lastLagBig = nil, false

local FPS = 60
local SLOT = tonumber(MESHGHOST_SURF_SLOT) or 10
local PHASES = {
	{ name = "settle", secs = 3, say = "slot " .. SLOT .. " loaded -- no input, recording as it arrives" },
	{ name = "surf", secs = 45,
		say = "DRIVEN: moving around on the water (left/right/down/up), watching the ghost follow" },
	{ name = "rest", secs = 4, say = "released -- recording what it settles to" },
}
local phase, phaseLeft, done, n, frame = 0, 0, false, 0, 0
local loaded = false

MESHGHOST_DEV_TICK = function()
	n = n + 1
	if n < 30 then return end

	if not loaded then
		loaded = true
		if not MESHGHOST_SURF_NOLOAD then
			savestate.loadslot(SLOT)
			console.log("surf_follow_probe: loaded savestate slot " .. SLOT)
		end
		if f then f:write(string.format("=== surf_follow_probe, slot %s ===\n",
			MESHGHOST_SURF_NOLOAD and "(not loaded)" or tostring(SLOT))) end
		return
	end

	frame = frame + 1

	if phaseLeft <= 0 then
		flush()
		phase = phase + 1
		if phase > #PHASES then
			if not done then
				done = true
				if f then
					f:write("\n=== done ===\n")
					f:write(string.format("  frames watched            %d\n", stats.frames))
					f:write(string.format("  frames with NO ghost      %d\n", stats.noGhost))
					f:write(string.format("  ghost respawns            %d\n", stats.respawns))
					f:write(string.format("  SWIMMING agrees w/ player %d\n", stats.swimAgree))
					f:write(string.format("  SWIMMING DISAGREES        %d\n", stats.swimDisagree))
					if stats.lagN > 0 then
						f:write(string.format("  follow lag: mean %.1f tiles, worst %d\n",
							stats.lagSum / stats.lagN, stats.maxLag))
					end
					f:write(string.format("  breaks (lag>2) while ghost HAD swim bit    %d\n",
						stats.brokeWithSwim))
					f:write(string.format("  breaks (lag>2) while ghost LACKED swim bit %d\n",
						stats.brokeWithoutSwim))
					f:write("\n  Reading it: the suspect predicts breaks concentrated in the\n")
					f:write("  LACKED row. Breaks in the HAD row refute it and mean the refusal\n")
					f:write("  is somewhere other than CanObjectMoveInDirection's water branch.\n")
					f:flush()
				end
				console.log("surf_follow_probe: done -- see surf_follow.log beside the script.")
			end
			return
		end
		local p = PHASES[phase]
		phaseLeft = p.secs * FPS
		console.log(string.format("surf_follow_probe [%d/%d] %s (%ds): %s",
			phase, #PHASES, p.name, p.secs, p.say))
		if f then f:write(string.format("\n=== phase %s, %ds ===\n", p.name, p.secs)) end
	end
	phaseLeft = phaseLeft - 1
	local p = PHASES[phase]
	if phaseLeft % (10 * FPS) == 0 and phaseLeft > 0 then
		console.log(string.format("surf_follow_probe: %s -- %ds left", p.name, phaseLeft // FPS))
	end

	-- Each leg long enough that a merely late ghost catches up, so one still behind at a leg's end is refused.
	if p.name == "surf" and not MESHGHOST_SURF_NODRIVE then
		local legs = { "Left", "Left", "Down", "Down", "Right", "Right", "Up", "Up" }
		local i = ((frame // (5 * FPS)) % #legs) + 1
		joypad.set({ [legs[i]] = true })
	end

	local pmx, pmy = u8(OBJ + F.mx), u8(OBJ + F.my)
	local ppal, pflags = u8(OBJ + F.pal), u8(OBJ + F.flags1)
	local pswim = (ppal & SWIMMING) ~= 0

	local gs = ghostSlots()
	stats.frames = stats.frames + 1
	if lastGhostCount ~= nil and #gs > lastGhostCount then
		stats.respawns = stats.respawns + 1
		if f then f:write(string.format("  f%-7d *** GHOST APPEARED (now %d) player swim=%s ***\n",
			frame, #gs, tostring(pswim))) end
		run.key = nil
	end
	lastGhostCount = #gs

	if #gs == 0 then
		stats.noGhost = stats.noGhost + 1
		record(string.format("player %2d,%2d %s  -- NO GHOST OBJECT", pmx, pmy,
			flagStr(pflags, ppal)), frame)
		return
	end

	local parts = {}
	for _, i in ipairs(gs) do
		local b = OBJ + i * STRIDE
		local gpal, gflags = u8(b + F.pal), u8(b + F.flags1)
		local gswim = (gpal & SWIMMING) ~= 0
		local gmx, gmy = u8(b + F.mx), u8(b + F.my)
		-- Lag on Y only: the rig offsets the spawned copy sideways, so X carries a constant offset.
		local lag = math.abs(gmy - pmy)
		if lag > stats.maxLag then stats.maxLag = lag end
		stats.lagSum, stats.lagN = stats.lagSum + lag, stats.lagN + 1
		if gswim == pswim then stats.swimAgree = stats.swimAgree + 1
		else stats.swimDisagree = stats.swimDisagree + 1 end
		if lag > 2 then
			if gswim then stats.brokeWithSwim = stats.brokeWithSwim + 1
			else stats.brokeWithoutSwim = stats.brokeWithoutSwim + 1 end
		end
		parts[#parts + 1] = string.format(
			"g%d %2d,%2d %-22s stype=%2d walk=%3d coll=%02X lagY=%d",
			i, gmx, gmy, flagStr(gflags, gpal), u8(b + F.steptype), u8(b + F.walking),
			u8(b + F.tilecoll), lag)
	end

	record(string.format("player %2d,%2d %-22s | %s", pmx, pmy, flagStr(pflags, ppal),
		table.concat(parts, " | ")), frame)
	if frame % 120 == 0 and f then f:flush() end
end
