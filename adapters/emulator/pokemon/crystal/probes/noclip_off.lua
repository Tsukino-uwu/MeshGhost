-- MeshGhost — Crystal: turn noclip OFF and prove it (DEV TOOL, one action)
--
-- noclip.lua redirects wTilesetCollisionAddress into a WRAM zero region. Its unload handler
-- restores the pointer, but an unload only runs if the loader dropped the file while it was
-- healthy -- so this checks the pointer itself and restores the recorded original if it still
-- points into WRAM. Original for this session's tileset, from noclip's own log: bank 6, $640E.
local logfile
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(dir .. "/noclip_off.log", "w")
end
local function say(m)
	console.log(m)
	if logfile then logfile:write(m, "\n") logfile:flush() end
end
local function u8(a) return memory.read_u8(a, "WRAM") end
local function w8(a, v) memory.write_u8(a, v, "WRAM") end
local COLL_BANK, COLL_ADDR = 0x11DF, 0x11E0 -- d1df/d1e0 flattened
local done = false
MESHGHOST_DEV_TICK = function()
	if done then return end
	done = true
	local lo, hi = u8(COLL_ADDR), u8(COLL_ADDR + 1)
	local ptr = lo + hi * 256
	if ptr >= 0xC000 and ptr <= 0xDFFF then
		w8(COLL_BANK, 6)
		w8(COLL_ADDR, 0x0E)
		w8(COLL_ADDR + 1, 0x64)
		say(string.format("noclip WAS still on (pointer $%04X in WRAM). Restored bank 6 "
			.. "$640E; read back $%02X%02X. Walk into a wall to confirm -- and any door/map "
			.. "change also rewrites this pointer with the game's own value.",
			ptr, u8(COLL_ADDR + 1), u8(COLL_ADDR)))
	else
		say(string.format("noclip already off: collision pointer is $%04X (ROM side), "
			.. "the game's own.", ptr))
	end
end
