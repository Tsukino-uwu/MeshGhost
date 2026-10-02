-- Read-only, once a second: every Emerald object event wearing the adapter's marker (localId 255) and every hardware
-- OAM entry 64..119 not in the engine's dummy encoding, with tile and palette. Compare ours= with the adapter's
-- status ghosts=; a tile inside another owner's range is corruption.
local dir = (debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or ".")
local f = io.open(dir .. "/../dev-logs/ghostobjs.log", "a")
local frames = 0
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	if frames % 60 ~= 0 then return end
	local objs, ours = {}, 0
	for i = 0, 15 do
		local a = 0x02037350 + i * 0x24
		local flags = memory.read_u8(a)
		if (flags & 1) == 1 then
			local localId = memory.read_u8(a + 0x08)
			local spr = memory.read_u8(a + 0x04)
			local gfx = memory.read_u8(a + 0x05)
			local x = memory.read_s16_le(a + 0x10)
			local y = memory.read_s16_le(a + 0x12)
			local s = 0x02020630 + spr * 0x44
			local inUse = (memory.read_u8(s + 0x3e) & 1) == 1
			local attr2 = memory.read_u16_le(s + 0x04)
			local mark = ""
			if localId == 255 then ours = ours + 1; mark = "*" end
			objs[#objs + 1] = string.format("%sobj%d(lid=%d gfx=%d spr=%d%s tile=%d pal=%d at=%d,%d)",
				mark, i, localId, gfx, spr, inUse and "" or "!DEAD", attr2 & 0x3ff, attr2 >> 12, x, y)
		end
	end
	local hw = {}
	for e = 64, 119 do
		local a = 0x030022f8 + e * 8
		local a0, a1, a2 = memory.read_u16_le(a), memory.read_u16_le(a + 2), memory.read_u16_le(a + 4)
		if not (a0 == 0x00a0 and a1 == 0x0130 and a2 == 0x0c00) then
			hw[#hw + 1] = string.format("e%d(tile=%d pal=%d x=%d y=%d)", e, a2 & 0x3ff, a2 >> 12,
				a1 & 0x1ff, a0 & 0xff)
		end
	end
	f:write(string.format("%s ours=%d objs=[%s] hw=[%s]\n", os.date("%H:%M:%S"), ours,
		table.concat(objs, " "), table.concat(hw, " ")))
	f:flush()
end
MESHGHOST_DEV_UNLOAD = function() if f then f:close() end end
