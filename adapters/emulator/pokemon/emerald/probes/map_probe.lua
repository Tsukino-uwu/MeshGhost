-- MeshGhost — Pokémon Emerald: the map around the player, raw (DEV TOOL, READ-ONLY, never shipped)
-- -- 2026-09-16
--
-- WHY THIS EXISTS. autoplay's Phase 1 wants a text map of the tiles around the player and the
-- characters on them (`agent_docs/phases/phase13.md`), and a walk that ends on the game's own state.
-- What each byte of the map grid, the object events and the map's event lists MEANS is to be measured:
-- this logs them raw every time the player's map, tile, facing or elevation changes, so walking into a
-- wall, an NPC, a door or water pairs each reading with what the game did.
--
-- ADDRESSES: a pokeemerald build whose ROM hashed identical to the vanilla ROM this runs on (SHA-1
-- compared 2026-09-16) proves where each lives, not what its bytes mean. Vanilla only.
--
-- WHAT IT LOGS (map_probe_<target>_<time>.log beside this file; gitignored), on change only:
--   POS    map from SaveBlock1 +4/+5, SaveBlock1 +0/+2, the player object's +0x10/+0x12, +0x0B, +0x18,
--          the avatar block's first 4 bytes
--   LAYOUT the 12 bytes named gBackupMapLayout, and the 0x18 bytes of the header's first pointer
--   GRID   rows of the grid entries (16-bit hex) from 7 left to 7 right and 5 up to 5 down of the
--          player object's coordinates, addressed as cmd_drive.lua's `grid` does
--   BEH    the low byte of each of those tiles' attribute word (cmd_drive.lua's `mtscan` route); "--"
--          past a tileset's attribute table
--   OBJ    every object slot whose first byte has bit 0 set: its first 0x1C bytes
--   EVT    the header's second pointer: its 4 count bytes, then each list raw (8 / 16 / 12 / 24 bytes
--          per entry for the second, third, fourth and first counts)
-- WHAT IT CANNOT SEE: why a step is refused (it logs the tiles, not the decision), anything drawn
-- rather than stored, and a patched ROM.

local BUS = "System Bus"
local SB1PTR = 0x03005d8c
local GPLAYERAVATAR, GOBJECTEVENTS, OBJ_SIZE = 0x02037590, 0x02037350, 0x24
local GBACKUPMAPLAYOUT, GMAPHEADER = 0x03005dc0, 0x02037318
local HALF_W, HALF_H = 7, 5

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local target = (os.getenv("MESHGHOST_DEV_LOADER_TARGET") or "default"):gsub("[^%w_%-]", "_")
local logf = io.open(string.format("%s/map_probe_%s_%s.log", dir, target, os.date("%Y%m%d_%H%M%S")), "w")
local pending = {}
local function log(s) pending[#pending + 1] = string.format("f%d %s", emu.framecount(), s) end
local function flush()
	if logf and #pending > 0 then
		logf:write(table.concat(pending, "\n"), "\n")
		logf:flush() -- on a change or a timer, never per frame
		pending = {}
	end
end

local function r8(a) return memory.read_u8(a, BUS) end
local function r16(a) return memory.read_u16_le(a, BUS) end
local function r32(a) return memory.read_u32_le(a, BUS) end
local function hex(a, n)
	local b, out = memory.read_bytes_as_array(a, n, BUS), {}
	for i = 1, n do out[i] = string.format("%02X", b[i]) end
	return table.concat(out)
end
local function inRom(p) return p >= 0x08000000 and p < 0x0A000000 end

local function dump()
	local sb1 = r32(SB1PTR)
	local obj = GOBJECTEVENTS + r8(GPLAYERAVATAR + 5) * OBJ_SIZE
	local ox, oy = r16(obj + 0x10), r16(obj + 0x12)
	log(string.format("POS map %d.%d sb1 %d,%d obj %d,%d +0B=%02X +18=%02X avatar=%s", r8(sb1 + 4), r8(sb1 + 5),
		r16(sb1), r16(sb1 + 2), ox, oy, r8(obj + 0x0B), r8(obj + 0x18), hex(GPLAYERAVATAR, 4)))

	local width, height, grid = r32(GBACKUPMAPLAYOUT), r32(GBACKUPMAPLAYOUT + 4), r32(GBACKUPMAPLAYOUT + 8)
	local layout = r32(GMAPHEADER)
	log(string.format("LAYOUT backup=%s header[0]=%08X %s", hex(GBACKUPMAPLAYOUT, 12), layout,
		inRom(layout) and hex(layout, 0x18) or "?"))
	local attrs = {}
	if inRom(layout) then
		for k = 0, 1 do
			local ts = r32(layout + 0x10 + k * 4)
			attrs[k] = inRom(ts) and r32(ts + 0x10) or 0
		end
	end
	for dy = -HALF_H, HALF_H do
		local cells, behs = {}, {}
		for dx = -HALF_W, HALF_W do
			local x, y = ox + dx, oy + dy
			if x < 0 or y < 0 or x >= width or y >= height then
				cells[#cells + 1], behs[#behs + 1] = "....", "--"
			else
				local v = r16(grid + (x + width * y) * 2)
				cells[#cells + 1] = string.format("%04X", v)
				local id = v & 0x3FF
				local base, index = attrs[0], id
				if id >= 512 then base, index = attrs[1], id - 512 end
				if base and inRom(base) and index < 512 then
					behs[#behs + 1] = string.format("%02X", r16(base + index * 2) & 0xFF)
				else
					behs[#behs + 1] = "--"
				end
			end
		end
		log(string.format("GRID dy=%+d %s", dy, table.concat(cells, " ")))
		log(string.format("BEH  dy=%+d %s", dy, table.concat(behs, " ")))
	end

	for s = 0, 15 do
		local at = GOBJECTEVENTS + s * OBJ_SIZE
		if r8(at) & 1 == 1 then log(string.format("OBJ %2d %s", s, hex(at, 0x1C))) end
	end

	local events = r32(GMAPHEADER + 4)
	if inRom(events) then
		local counts = memory.read_bytes_as_array(events, 4, BUS)
		log(string.format("EVT counts %02X %02X %02X %02X", counts[1], counts[2], counts[3], counts[4]))
		local lists = { { name = "list1", n = counts[1], size = 24, ptr = r32(events + 4) },
			{ name = "list2", n = counts[2], size = 8, ptr = r32(events + 8) },
			{ name = "list3", n = counts[3], size = 16, ptr = r32(events + 12) },
			{ name = "list4", n = counts[4], size = 12, ptr = r32(events + 16) } }
		for _, l in ipairs(lists) do
			for i = 0, math.min(l.n, 64) - 1 do
				if inRom(l.ptr) then log(string.format("EVT %s[%d] %s", l.name, i, hex(l.ptr + i * l.size, l.size))) end
			end
		end
	else
		log(string.format("EVT header[4]=%08X not ROM", events))
	end
	flush()
end

local lastKey, frames = nil, 0
log("map_probe loaded")
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	local sb1 = r32(SB1PTR)
	local obj = GOBJECTEVENTS + r8(GPLAYERAVATAR + 5) * OBJ_SIZE
	local key = string.format("%d.%d %d,%d %02X %02X", r8(sb1 + 4), r8(sb1 + 5), r16(obj + 0x10), r16(obj + 0x12),
		r8(obj + 0x18), r8(obj + 0x0B))
	if key ~= lastKey then
		lastKey = key
		dump()
	end
	if frames % 120 == 0 then flush() end
end
MESHGHOST_DEV_UNLOAD = function()
	log("unloaded")
	flush()
	if logf then logf:close() end
	logf = nil
end
