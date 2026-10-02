-- Read-only, once a second: the player's area id (mapGroup:mapNum) and tile as the Emerald adapter sends them, for
-- meshghost-fakeadapter's -area-id and -center. To a log, never the console: a console line a second costs frames.
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
