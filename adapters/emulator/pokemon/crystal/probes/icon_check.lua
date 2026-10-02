-- Read-only, the cartridge only: does the species -> Pokemon icon lookup land on graphics? Two hops in bank 0x23,
-- species -> icon via MonMenuIcons (23:6ac4 in our hash-verified build's .sym), icon -> tiles via IconPointers
-- (23:6bbf). Prints each species' offset and first eight bytes: a row of zeroes or $FF runs is a misread pointer.

local ROM = "ROM"
local MON_ICONS, ICON_PTRS, ICONS_BANK = 0x8EAC4, 0x8EBBF, 0x23

local function rb(off)
	local ok, v = pcall(memory.read_u8, off, ROM)
	return (ok and v) or 0
end

local f
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)/[^/]*$") or "."
	end
	f = io.open(string.format("%s/icon_check_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
end
local function say(s)
	if f then f:write(s .. "\n"); f:flush() end
	pcall(function() console.log(s) end)
end

local function iconOf(species)
	return rb(MON_ICONS + species - 1)
end

local function gfxOf(species)
	local icon = iconOf(species)
	local e = ICON_PTRS + icon * 2
	local addr = rb(e) | (rb(e + 1) << 8)
	if addr < 0x4000 then
		return nil, icon, addr
	end
	return ICONS_BANK * 0x4000 + (addr - 0x4000), icon, addr
end

say("=== MeshGhost -- Crystal: species -> mon icon graphics ===")
say(string.format("MonMenuIcons=%06X  IconPointers=%06X  BANK(Icons)=%02X",
	MON_ICONS, ICON_PTRS, ICONS_BANK))
say("")

for _, sp in ipairs({ 1, 4, 7, 16, 17, 21, 22, 25, 133, 144, 149, 152, 155, 158, 249, 250, 251 }) do
	local at, icon, addr = gfxOf(sp)
	local bytes = {}
	if at then
		for b = 0, 7 do
			bytes[#bytes + 1] = string.format("%02X", rb(at + b))
		end
	end
	say(string.format("species %3d -> icon %3d  ptr %04X  at %06X  [%s]", sp, icon, addr,
		at or 0, table.concat(bytes, " ")))
end

say("")
-- Pidgey (16), Spearow (21) and Fearow (22) all wear the bird icon: three species on one offset proves the first hop.
local a16 = gfxOf(16)
local a21 = gfxOf(21)
local a22 = gfxOf(22)
if a16 and a16 == a21 and a21 == a22 then
	say(string.format("PASS: Pidgey/Spearow/Fearow share one icon at %06X, as they should", a16))
else
	say(string.format("FAIL: the shared-bird check did not hold (%s / %s / %s)"
		.. " -- the species table is not being read where this thinks it is",
		tostring(a16), tostring(a21), tostring(a22)))
end

-- An icon's eight tiles are 128 bytes, so consecutive distinct icons should sit 128 apart.
local p0 = ICON_PTRS
local d = (rb(p0 + 2) | (rb(p0 + 3) << 8)) - (rb(p0) | (rb(p0 + 1) << 8))
say(string.format("%s: consecutive icon pointers differ by %d (128 expected)",
	(d == 128) and "PASS" or "FAIL", d))

MESHGHOST_DEV_TICK = function() end
