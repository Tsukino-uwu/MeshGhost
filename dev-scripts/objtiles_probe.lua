-- Read-only, once a second: the set bits of Emerald's OBJ tile allocation bitmap against the tile every in-use sprite
-- points at. A large gap is orphaned bits, allocated and never freed.
local dir = (debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or ".")
local f = io.open(dir .. "/../dev-logs/objtiles.log", "a")
local frames = 0
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	if frames % 60 ~= 0 then return end
	local set = 0
	for n = 0, 1023 do
		if (memory.read_u8(0x02021b3c + (n // 8)) >> (n % 8)) & 1 == 1 then set = set + 1 end
	end
	local inUse, owned = 0, {}
	local parts = {}
	for i = 0, 63 do
		local d = 0x02020630 + i * 0x44
		if (memory.read_u8(d + 0x3e) & 1) == 1 then
			inUse = inUse + 1
			local t = memory.read_u16_le(d + 0x04) & 0x3ff
			owned[#owned + 1] = t
			parts[#parts + 1] = string.format("%d@%d", i, t)
		end
	end
	table.sort(owned)
	f:write(string.format("%s reserved=%d bitsSet=%d/1024 spritesInUse=%d tileNums=[%s]\n",
		os.date("%H:%M:%S"), memory.read_u16_le(0x02021b3a), set, inUse, table.concat(parts, " ")))
	f:flush()
end
MESHGHOST_DEV_UNLOAD = function() if f then f:close() end end
