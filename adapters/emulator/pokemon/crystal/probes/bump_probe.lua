-- Pokémon Crystal: holds Down, Left, Up, Right in turn until one is a wall, then keeps holding it, and logs run-length
-- the image the engine draws for the player ((tile - base) of its OAM entry against OBJECT_SPRITE_TILE), its facing
-- and its action.
-- Player struct at 0xD4D6: +0x02 sprite tile, +0x0B action, +0x0D facing, +0x10/+0x11 map x/y.
-- The log goes beside this script, resolved from its own path: never an absolute one.
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
	-- The player's own art is (tile - base) & 0x7F < 12; the 0x80 bit is the stepping block.
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
		-- Run-length, not a line per frame: the question is the cadence.
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
