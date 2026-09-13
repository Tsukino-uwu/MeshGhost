-- MeshGhost — Crystal: turn noclip OFF and prove it (DEV TOOL, one action)
--
-- noclip.lua redirects the tileset collision pointer into WRAM and flags nearby NPCs EMOTE_OBJECT.
-- Its unload handler undoes both, but an unload only runs if the loader dropped the file while it was
-- healthy -- so this checks the pointer itself and, if it still points into WRAM, restores the value
-- from the ROM `Tilesets` entry matching the loaded header (the same lookup noclip.lua uses, so it is
-- right for whichever tileset is loaded, on either build). NPC flags are NOT touched here: a flag this
-- tool cannot attribute might belong to a real emote, and any map change rebuilds every object anyway.
-- Addresses and their provenance: noclip.lua's header.
local BUILDS = {
	PM_CRYSTAL = { tilesetsRom = 0x4D596, header = 0x11D9 },
	AP_CRYSTAL = { tilesetsRom = 0x4D46B, header = 0x11E0 },
}
local title = ""
for i = 0x134, 0x13E do
	local c = memory.read_u8(i, "ROM")
	if c == 0 then break end
	title = title .. string.char(c)
end
local build = BUILDS[title]

local done = false
MESHGHOST_DEV_TICK = function()
	if done then return end
	done = true
	if not build then
		console.log(string.format("noclip_off: ROM title %q has no addresses here -- nothing done.", title))
		return
	end
	local h = memory.read_bytes_as_array(build.header, 9, "WRAM")
	local ptr = h[8] + h[9] * 256
	if ptr < 0xC000 then
		console.log(string.format("noclip_off: already off -- collision pointer is $%04X (ROM side).", ptr))
		return
	end
	local t = memory.read_bytes_as_array(build.tilesetsRom, 37 * 15, "ROM")
	for e = 0, 36 do
		local same = true
		for k = 1, 6 do
			if t[e * 15 + k] ~= h[k] then same = false break end
		end
		if same then
			local real = t[e * 15 + 8] + t[e * 15 + 9] * 256
			memory.write_u8(build.header + 7, real & 0xFF, "WRAM")
			memory.write_u8(build.header + 8, (real >> 8) & 0xFF, "WRAM")
			console.log(string.format("noclip_off: WAS on (pointer $%04X). Restored tileset %d's $%04X; "
				.. "read back $%02X%02X. Leave the map to reset any NPC still walk-through.", ptr, e, real,
				memory.read_u8(build.header + 8, "WRAM"), memory.read_u8(build.header + 7, "WRAM")))
			return
		end
	end
	console.log("noclip_off: pointer is in WRAM but the header matches no ROM entry -- walk through a "
		.. "door; the map load writes the game's own pointer back.")
end
