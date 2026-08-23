-- What a BUMP looks like, in the player's own struct AND in the frames actually drawn.
--
-- The struct half answered the first question (walking stays STANDING, action reads 3, facing
-- alternates). It did NOT answer the one that matters for the drawn tier: which IMAGE the engine
-- puts on screen each frame. The tile index in the player's OAM entry, relative to the player's own
-- OBJECT_SPRITE_TILE, is that image -- the same `(tile - base) & 0x7F` the adapter's frame learner
-- uses. A ghost is 1:1 when it shows this sequence, at this cadence.
--
-- Constants from meshghost_crystal.lua: OBJECT_STRUCTS 0xD4D6, F_SPRITE_TILE 0x02, F_WALKING 0x07,
-- F_DIRECTION 0x08, F_ACTION 0x0B, F_FACING 0x0D, F_MAP_X 0x10, F_MAP_Y 0x11.
-- Log beside this script, resolved from the script's own path -- never an absolute one. A probe
-- committed with a developer's directory baked into it is a personal path in a public repo, which
-- is exactly what happened to the first version of this file (2026-08-23).
local f
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)/[^/]*$") or "."
	end
	f = io.open(dir .. "/bump.log", "w")
end
local function u8(a) return memory.read_u8(a, "System Bus") or 0 end
local OBJ = 0xD4D6
local DIRS = { "Down", "Left", "Up", "Right" }
local di, held, startTile, n = 1, 0, nil, 0
local run = { last = nil, count = 0 }

local function playerFrame()
	-- The player's own art is (tile - base) & 0x7F < 12; the 0x80 bit is the STEPPING block.
	local base = u8(OBJ + 0x02)
	local tile = memory.read_u8(2, "OAM") or 0
	return (tile - base) & 0xFF
end

MESHGHOST_DEV_TICK = function()
	n = n + 1
	if n < 120 then return end
	if di > #DIRS then return end
	local mx, my = u8(OBJ + 0x10), u8(OBJ + 0x11)
	if held == 0 then
		startTile = mx .. "," .. my
		f:write(string.format("\n=== holding %s from tile %s ===\n", DIRS[di], startTile))
		f:flush()
	end
	joypad.set({ [DIRS[di]] = true })
	held = held + 1
	local moved = (mx .. "," .. my) ~= startTile
	if held > 20 and not moved then
		-- RUN-LENGTH, not one line per frame: the question is the CADENCE, and 100 identical lines
		-- hide it while a run length states it directly.
		local key = string.format("frame=0x%02X facing=%2d action=%d", playerFrame(),
			u8(OBJ + 0x0D), u8(OBJ + 0x0B))
		if key == run.last then
			run.count = run.count + 1
		else
			if run.last then
				f:write(string.format("  %s   x%d frames\n", run.last, run.count))
				f:flush()
			end
			run.last, run.count = key, 1
		end
	end
	if held >= 240 then
		if run.last then
			f:write(string.format("  %s   x%d frames\n", run.last, run.count))
			run.last, run.count = nil, 0
		end
		if moved then
			f:write("  (moved -- not a wall, trying the next direction)\n")
			di = di + 1
		else
			f:write("  (this direction is a wall; holding it)\n")
		end
		f:flush()
		held = 0
	end
end
