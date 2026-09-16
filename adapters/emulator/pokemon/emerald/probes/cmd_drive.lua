-- MeshGhost — Pokémon Emerald: a command-queue driver that builds a test state on the spot
-- (DEV TOOL, WRITES, HOLDS THE CONTROLLER, never shipped) -- 2026-09-16
--
-- WHY THIS EXISTS. `agent_docs/playing.md`, "the mindset": anything inside the game may be made to
-- happen to reach a test, and the mechanism under test is then driven the way the game intends. This
-- is that loop for vanilla Emerald without a relaunch or a savestate: it re-reads a small command file
-- and runs it line by line. Crystal's twin is `crystal/probes/cmd_drive.lua`.
--
-- COMMAND FILE: `cmd_drive.cmd` beside this script (`.gitignore` covers `*.cmd`), read every 15
-- frames; a CHANGED file replaces the queue. One command per line, `#` comments allowed:
--   hold BTN[+BTN] N       hold buttons N frames (a tap of ~4 turns toward a blocked tile)
--   wait N                 do nothing for N frames
--   shot NAME              client.screenshot to dev-scripts/shots/emerald/NAME.png, then `status`
--   status                 SaveBlock1 pos and map, avatar flags, the player object and sprite
--   warp G.N X,Y           the game's own map load to map G.N, standing at map tile X,Y
--   grid DX,DY             the map-grid value at the player's tile + (DX,DY)
--   mtscan BEH             metatile ids of the loaded tilesets whose behaviour byte is BEH (decimal)
--   mtset DX,DY ID[:COLL]  rewrite the metatile id (and collision) at the player's tile + (DX,DY)
--   givekey ID             an item id (decimal) into the first free Key Items slot, quantity 1
--   register ID            the item Select uses
--   rec on LABEL | rec off `borrowed_values_probe.lua`'s recorder flag (the loader shares globals)
--   objdump                every non-empty object event slot, raw
--   poke8|poke16|poke32 ADDR VAL   one System Bus write (hex), read back
--
-- WHAT IS MEASURED (vanilla, 2026-09-16, this tool's log and `borrowed_values_probe.lua`):
--   * `warp` -- sWarpDestination and SaveBlock1's location, SaveBlock1 pos, gFieldCallback, then
--     gMain.callback2 = CB2_LoadMap (`goto_map.lua`'s writes) -- landed on the named map and tile
--     every time, onto land and onto water; a warp onto water arrives SURFING (graphic 2, the blob).
--     A warp reloads the map grid from ROM, so it undoes every `mtset`.
--   * `mtset` into gBackupMapLayout's grid: a ledge metatile (135, behaviour 59) written 8 rows below
--     the player was drawn by the game when it scrolled on screen and hopped two tiles by walking
--     into it. A tile written ON screen is not redrawn -- write it off screen and walk to it.
--   * `mtscan` reads gMapHeader -> mapLayout -> primary/secondary tileset -> metatileAttributes;
--     behaviours 16/22/56/57/59 came back as tiles that behaved as such. Past the secondary
--     tileset's real count it reads whatever follows, so trust low secondary ids only.
--   * `givekey`/`register`: SaveBlock1 Key Items at +0x5D8 with the quantity XOR SaveBlock2's key low
--     half (`testkit.lua`'s write), and SaveBlock1+0x496 -- Select then mounted the Acro Bike (272)
--     and cast the Super Rod (264) through the game's own paths.
--   * SaveBlock1's object-event copy starts at +0xA30 (slot 0 matched it byte for byte).
-- UNMEASURED: every address on a patched build -- `warp` refuses unless gMain.callback2 is vanilla's
-- CB2_Overworld, and nothing else checks.
--
-- Nothing here writes the save file, but SaveBlock1 is what an in-game save stores: a `givekey` or
-- `register` survives one. Take it off the target when done -- an input-driving tool left loaded is a
-- suspect in every later report.
--
-- FINDING A REAL PLACE: `find_behaviour.py` (beside this file) scans every map grid in the ROM for a
-- behaviour and lists tiles to warp to, including a walkable tile directly above one.

local GPLAYERAVATAR, GOBJECTEVENTS = 0x02037590, 0x02037350
local GSPRITES = 0x02020630
local SB1PTR, SB2PTR = 0x03005d8c, 0x03005d90
local GMAIN_CB2, CB2_OVERWORLD, CB2_LOADMAP = 0x030022c4, 0x08085e5c, 0x08085fcc
local GFIELDCALLBACK, FIELDCB_DEFAULTWARPEXIT = 0x03005dac, 0x080af398
local SWARPDESTINATION = 0x020322e4
local GMAPHEADER, GBACKUPMAPLAYOUT = 0x02037318, 0x03005dc0
local BUS = "System Bus"

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local root = dir:match("^(.*)/adapters/") or "."
local CMD = dir .. "/cmd_drive.cmd"
local SHOTS = root .. "/dev-scripts/shots/emerald"
local logf = io.open(dir .. "/cmd_drive_" .. os.date("%Y%m%d_%H%M%S") .. ".log", "w")

local function log(s)
	if logf then
		logf:write(string.format("[%d] %s\n", emu.framecount(), s))
		logf:flush() -- once per command, never per frame
	end
end
local function r8(a) return memory.read_u8(a, BUS) end
local function r16(a) return memory.read_u16_le(a, BUS) end
local function r32(a) return memory.read_u32_le(a, BUS) end
local function w8(a, v) memory.write_u8(a, v, BUS) end
local function w16(a, v) memory.write_u16_le(a, v, BUS) end
local function w32(a, v) memory.write_u32_le(a, v, BUS) end

local function playerObj() return GOBJECTEVENTS + r8(GPLAYERAVATAR + 5) * 0x24 end

local function status()
	local sb1, o = r32(SB1PTR), playerObj()
	local d = GSPRITES + r8(GPLAYERAVATAR + 4) * 0x44
	log(string.format("pos %d,%d map %d.%d | avatar flags %02X | object gfx %d x,y %d,%d facing %02X action %02X | sprite anim %d idx %d",
		r16(sb1), r16(sb1 + 2), r8(sb1 + 4), r8(sb1 + 5), r8(GPLAYERAVATAR), r8(o + 5), r16(o + 0x10),
		r16(o + 0x12), r8(o + 0x18), r8(o + 0x1c), r8(d + 0x2a), r8(d + 0x2b)))
end

local function gridAddr(dx, dy)
	local o = playerObj()
	local x, y = r16(o + 0x10) + dx, r16(o + 0x12) + dy
	return r32(GBACKUPMAPLAYOUT + 8) + (x + r32(GBACKUPMAPLAYOUT) * y) * 2, x, y
end

local last, queue, wait, hold, holdN, poll = nil, {}, 0, nil, 0, 0

local function readCmd()
	local fh = io.open(CMD, "r")
	if not fh then return end
	local s = fh:read("*a")
	fh:close()
	if s == last then return end
	last, queue, wait, hold, holdN = s, {}, 0, nil, 0
	for line in s:gmatch("[^\r\n]+") do
		if line:match("%S") and not line:match("^%s*#") then queue[#queue + 1] = line end
	end
	log("new command set: " .. #queue .. " lines")
end

local function run(cmd, a, b)
	if cmd == "hold" then
		hold, holdN = a, tonumber(b) or 1
		log("hold " .. a .. " " .. holdN)
	elseif cmd == "wait" then
		wait = tonumber(a) or 1
	elseif cmd == "shot" then
		local p = SHOTS .. "/" .. a .. ".png"
		local ok = pcall(function() client.screenshot(p) end)
		log("shot " .. p .. (ok and "" or " FAILED"))
		status()
	elseif cmd == "status" then
		status()
	elseif cmd == "warp" then
		local g, n = a:match("^(%d+)%.(%d+)$")
		local x, y = b:match("^(%d+),(%d+)$")
		local cb = r32(GMAIN_CB2)
		if cb ~= CB2_OVERWORLD + 1 and cb ~= CB2_OVERWORLD then
			log("warp refused: gMain.callback2 is not vanilla's CB2_Overworld")
			return
		end
		local sb1 = r32(SB1PTR)
		for _, at in ipairs({ SWARPDESTINATION, sb1 + 0x04 }) do
			w8(at, tonumber(g)); w8(at + 1, tonumber(n)); w8(at + 2, 0)
			w16(at + 4, 0xffff); w16(at + 6, 0xffff)
		end
		w16(sb1, tonumber(x)); w16(sb1 + 2, tonumber(y))
		w32(GFIELDCALLBACK, FIELDCB_DEFAULTWARPEXIT + 1)
		w32(GMAIN_CB2, CB2_LOADMAP + 1)
		log("warp " .. a .. " " .. b)
	elseif cmd == "grid" then
		local dx, dy = a:match("^(%-?%d+),(%-?%d+)$")
		local at, x, y = gridAddr(tonumber(dx), tonumber(dy))
		local v = r16(at)
		log(string.format("grid %d,%d = %04X (metatile %d, collision %d, elevation %d)", x, y, v, v & 0x3ff,
			(v >> 10) & 3, v >> 12))
	elseif cmd == "mtset" then
		local dx, dy = a:match("^(%-?%d+),(%-?%d+)$")
		local id, coll = b:match("^(%d+):?(%d*)$")
		local at, x, y = gridAddr(tonumber(dx), tonumber(dy))
		local old = r16(at)
		local new = (old & 0xfc00) | tonumber(id)
		if coll ~= "" then new = (new & 0xf3ff) | (tonumber(coll) << 10) end
		w16(at, new)
		log(string.format("mtset %d,%d: %04X -> %04X, read back %04X", x, y, old, new, r16(at)))
	elseif cmd == "mtscan" then
		local layout, out = r32(GMAPHEADER), {}
		for k, base in ipairs({ 0, 512 }) do
			local ts = r32(layout + 0x10 + (k - 1) * 4)
			local attrs = ts ~= 0 and r32(ts + 0x10) or 0
			if attrs ~= 0 then
				for i = 0, 511 do
					if (r16(attrs + i * 2) & 0xff) == tonumber(a) then out[#out + 1] = tostring(base + i) end
				end
			end
		end
		log("mtscan " .. a .. ": " .. (#out > 0 and table.concat(out, " ") or "none"))
	elseif cmd == "givekey" then
		local sb1, key = r32(SB1PTR), r32(r32(SB2PTR) + 0xac) & 0xffff
		local id = tonumber(a)
		for s = 0, 29 do
			local at = sb1 + 0x5d8 + s * 4
			if r16(at) == id then
				log("givekey " .. a .. ": already in slot " .. s)
				return
			end
			if r16(at) == 0 then
				w16(at, id)
				w16(at + 2, 1 ~ key)
				log(string.format("givekey %s -> slot %d, read back id %d quantity %d", a, s, r16(at), r16(at + 2) ~ key))
				return
			end
		end
		log("givekey " .. a .. ": the pocket is full")
	elseif cmd == "register" then
		local sb1 = r32(SB1PTR)
		w16(sb1 + 0x496, tonumber(a))
		log("register " .. a .. ", read back " .. r16(sb1 + 0x496))
	elseif cmd == "rec" then
		MESHGHOST_BV_REC = (a == "on") or nil
		MESHGHOST_BV_LABEL = b
		log("rec " .. a .. " " .. b)
	elseif cmd == "objdump" then
		for i = 0, 15 do
			local bytes = memory.read_bytes_as_array(GOBJECTEVENTS + i * 0x24, 0x24, BUS)
			local h, nz = {}, false
			for k = 1, 0x24 do
				h[k] = string.format("%02X", bytes[k])
				if bytes[k] ~= 0 then nz = true end
			end
			if nz then log(string.format("object %2d %s", i, table.concat(h))) end
		end
	elseif cmd == "poke8" or cmd == "poke16" or cmd == "poke32" then
		local at, v = tonumber(a, 16), tonumber(b, 16)
		local write = ({ poke8 = w8, poke16 = w16, poke32 = w32 })[cmd]
		local read = ({ poke8 = r8, poke16 = r16, poke32 = r32 })[cmd]
		write(at, v)
		log(string.format("%s %08X=%X read back %X", cmd, at, v, read(at)))
	else
		log("unknown command: " .. tostring(cmd))
	end
end

local function step()
	if hold then
		local t = {}
		for btn in hold:gmatch("[^+]+") do t[btn] = true end
		joypad.set(t)
		holdN = holdN - 1
		if holdN <= 0 then hold = nil end
		return
	end
	if wait > 0 then
		wait = wait - 1
		return
	end
	local line = table.remove(queue, 1)
	if not line then return end
	run(line:match("^(%S+)%s*(%S*)%s*(%S*)"))
end

log("cmd_drive loaded; command file " .. CMD)
MESHGHOST_DEV_TICK = function()
	poll = poll + 1
	if poll % 15 == 0 then readCmd() end
	step()
end
MESHGHOST_DEV_UNLOAD = function()
	MESHGHOST_BV_REC = nil
	log("unloaded")
	if logf then logf:close() end
	logf = nil
end
