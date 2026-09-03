-- where_emerald.lua -- READ-ONLY dev helper for the crowd rig: prints the local player's area id
-- and tile in exactly the form the Emerald adapter sends them (`mapGroup:mapNum`, tile x,y), so
-- meshghost-fakeadapter's -area-id and -center can be set without asking the player where they
-- are. Reads the same two things the adapter's getLocalState reads, from the same place:
-- gSaveBlock1Ptr (0x03005d8c, adapters/emulator/pokemon/emerald/meshghost_emerald.lua line 76)
-- -> x @+0x00, y @+0x02, mapGroup @+0x04, mapNum @+0x05. Writes nothing to game memory.
--
-- Loader contract: sets MESHGHOST_DEV_TICK; no frame loop of its own. One line per second to
-- where_emerald.log beside this file (a file, never the console: adapters/emulator/CLAUDE.md prices
-- one console line a second at ~7fps on this game). Drop it from the target file when done.
local dir = (debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or ".")
local f = io.open(dir .. "/../dev-logs/where_emerald.log", "a")
local frames = 0
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	if frames % 60 ~= 0 then return end
	local base = memory.read_u32_le(0x03005d8c)
	if base == 0 then
		f:write(string.format("%s no save block (title screen?)\n", os.date("%H:%M:%S")))
		f:flush()
		return
	end
	local x = memory.read_s16_le(base + 0x00)
	local y = memory.read_s16_le(base + 0x02)
	local g = memory.read_s8(base + 0x04)
	local n = memory.read_s8(base + 0x05)
	f:write(string.format("%s area_id=%d:%d center=%d,%d\n", os.date("%H:%M:%S"), g, n, x, y))
	f:flush()
end
MESHGHOST_DEV_UNLOAD = function() if f then f:close() end end
