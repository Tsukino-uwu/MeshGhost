-- ghostobjs_probe.lua -- READ-ONLY: which of the game's object events and hardware OAM entries
-- are MeshGhost's right now, and what each is drawing from.
--
-- Question (2026-09-02): after several hot reloads of the Emerald adapter with a crowd up, one
-- ghost stands still while its facing keeps changing, with the top of its hat cut off and the
-- wrong colours. That is either an orphan object from an earlier script instance that the fresh
-- one is still writing facing into, or a hardware entry pointing at tiles somebody else now
-- owns. This lists both tables once a second so the count of objects carrying the adapter's own
-- marker can be compared with the adapter's `status: ... ghosts=N` line, and each entry's tile
-- and palette read against the others.
--
-- Addresses and offsets are the adapter's own (adapters/emulator/pokemon/emerald/meshghost_emerald.lua):
--   gObjectEvents 0x02037350 (line 84), OBJECTEVENT_SIZE 0x24 (85), 16 entries; active = bit 0 of
--   +0x00, spriteId +0x04, graphicsId +0x05, localId +0x08 (GHOST_LOCAL_ID 255, line 3986),
--   currentCoords +0x10/+0x12 (spawnGhost writes them); gSprites 0x02020630 x 0x44 (86-87),
--   inUse bit 0 of +0x3e, attr2 at +0x04 (tile = & 0x3ff, palette = >> 12);
--   gMain.oamBuffer[64] at 0x030022f8 + 64*8 (line 8292), entries 64..119, dummy encoding
--   d0=0x00a0 d1=0x0130 d2=0x0c00 (line 8331) means "free". Reads only.
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
