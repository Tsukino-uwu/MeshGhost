-- Builds a test state on the spot, vanilla V1.0 only: writes the game and holds the controller, running the command
-- file cmd_drive.cmd beside it (re-read every 15 frames; a changed file replaces the queue; `#` starts a comment):
--   hold BTN[+BTN] N   hold buttons N frames (a tap of ~4 turns in place, ~10 walks a tile)
--   wait N             do nothing for N frames
--   shot NAME          capture to dev-scripts/shots/crystal/NAME.png, then `status`
--   status             map, the player's tile, facing and action, the cached neighbour collisions, key items
--   poke FLAT HEX      write one WRAM byte and log the read-back
--   block BX,BY HEX    write one map block into wOverworldMapBlocks, logging the id it replaced
--   redraw             START then B: closing the START menu redraws the map from the blocks
--   tilecheck          the player's tile -> block -> collision, beside the engine's own byte
--   collfind HEX       blocks of the loaded tileset whose four collisions all read HEX
--   collscan           blocks of the loaded tileset carrying a ledge-family ($a0-$a7) collision
-- A block written beside the player is not seen by the next step, since the engine caches the neighbouring
-- collisions: write, then walk onto or next to it. Nothing here writes the save; a map load undoes every `block`, but
-- an in-game save keeps a `poke`d item. Take it off the target when done.

local function flat(cpu) return cpu < 0xD000 and cpu - 0xC000 or 0x1000 + (cpu - 0xD000) end
local PS = flat(0xD4D6) -- wPlayerStruct
local W_MAPGROUP, W_MAPNUMBER = flat(0xDCB5), flat(0xDCB6)
local W_YCOORD, W_XCOORD, W_MAPWIDTH = flat(0xDCB7), flat(0xDCB8), flat(0xD19F)
local W_TILESET = flat(0xD1D9)
local W_TILE_DOWN = flat(0xC2FA) -- then Up, Left, Right
local W_OVERWORLD_BLOCKS = flat(0xC800)
local W_NUM_KEY_ITEMS, W_KEY_ITEMS = flat(0xD8BC), flat(0xD8BD)

local title = ""
for i = 0x134, 0x13E do
	local c = memory.read_u8(i, "ROM")
	if c == 0 then break end
	title = title .. string.char(c)
end

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local root = dir:match("^(.*)/adapters/") or "."
local CMD = dir .. "/cmd_drive.cmd"
local SHOTS = root .. "/dev-scripts/shots/crystal"
local logdir = (dir:match("^(.*)/probes$") or dir) .. "/logs"
local logf = io.open(logdir .. "/cmd_drive_" .. os.date("%Y%m%d_%H%M%S") .. ".log", "w")

local function log(s)
	if logf then
		logf:write(string.format("[%d] %s\n", emu.framecount(), s))
		logf:flush() -- once per command, never per frame
	end
end

if title ~= "PM_CRYSTAL" then
	log(string.format("ROM title %q is not vanilla Crystal -- nothing will run.", title))
	MESHGHOST_DEV_TICK = function() end
	return
end

local function u8(a) return memory.read_u8(a, "WRAM") end

local function collision()
	local bank, ptr = u8(W_TILESET + 6), u8(W_TILESET + 7) + u8(W_TILESET + 8) * 256
	return function(id, q)
		if ptr >= 0x4000 and ptr <= 0x7FFF then
			return memory.read_u8(bank * 0x4000 + (ptr - 0x4000) + id * 4 + q, "ROM")
		end
		return u8(ptr - 0xC000 + id * 4 + q) -- redirected into WRAM (noclip.lua)
	end, bank, ptr
end

local function blockIndex(bx, by)
	return (by + 3) * (u8(W_MAPWIDTH) + 6) + (bx + 3)
end

local function status()
	local ki = {}
	for i = 0, math.min(u8(W_NUM_KEY_ITEMS), 25) - 1 do
		ki[#ki + 1] = string.format("%02X", u8(W_KEY_ITEMS + i))
	end
	log(string.format("map %d.%d tile %d,%d face %02X act %02X | cached D%02X U%02X L%02X R%02X | key items %s",
		u8(W_MAPGROUP), u8(W_MAPNUMBER), u8(W_XCOORD), u8(W_YCOORD), u8(PS + 0x0D), u8(PS + 0x0B),
		u8(W_TILE_DOWN), u8(W_TILE_DOWN + 1), u8(W_TILE_DOWN + 2), u8(W_TILE_DOWN + 3), table.concat(ki, " ")))
end

local function tilecheck()
	local coll, bank, ptr = collision()
	local tx, ty = u8(W_XCOORD), u8(W_YCOORD)
	local function at(x, y)
		local id = u8(W_OVERWORLD_BLOCKS + blockIndex(x // 2, y // 2))
		return id, coll(id, (y % 2) * 2 + x % 2)
	end
	local id, c = at(tx, ty)
	local nb = {}
	for _, d in ipairs({ { 0, 1, "D" }, { 0, -1, "U" }, { -1, 0, "L" }, { 1, 0, "R" } }) do
		local nid, nc = at(tx + d[1], ty + d[2])
		nb[#nb + 1] = string.format("%s blk%02X c%02X", d[3], nid, nc)
	end
	log(string.format("tilecheck tile %d,%d blk %02X coll %02X | engine standing %02X | table %02X:%04X | %s",
		tx, ty, id, c, u8(PS + 0x0E), bank, ptr, table.concat(nb, " ")))
end

local function scan(match, label)
	local coll = collision()
	local out = {}
	for id = 0, 255 do
		local q = { coll(id, 0), coll(id, 1), coll(id, 2), coll(id, 3) }
		if match(q) then
			out[#out + 1] = string.format("%02X[%02X %02X %02X %02X]", id, q[1], q[2], q[3], q[4])
		end
	end
	-- The table's length is not in the header, so a hit with implausible neighbours is past its end, not a block.
	log(label .. ": " .. (#out > 0 and table.concat(out, ", ") or "none"))
end

local last, queue, wait, hold, holdN = nil, {}, 0, nil, 0
local poll = 0

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

local function step()
	if hold then
		local t = {}
		for b in hold:gmatch("[^+]+") do t[b] = true end
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
	local cmd, a, b = line:match("^(%S+)%s*(%S*)%s*(%S*)")
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
	elseif cmd == "poke" then
		local addr, val = tonumber(a, 16), tonumber(b, 16)
		memory.write_u8(addr, val, "WRAM")
		log(string.format("poke %04X=%02X read back %02X", addr, val, u8(addr)))
	elseif cmd == "block" then
		local bx, by = a:match("^(%d+),(%d+)$")
		local idx = blockIndex(tonumber(bx), tonumber(by))
		local old = u8(W_OVERWORLD_BLOCKS + idx)
		memory.write_u8(W_OVERWORLD_BLOCKS + idx, tonumber(b, 16), "WRAM")
		log(string.format("block %s index %d: %02X -> %s, read back %02X", a, idx, old, b,
			u8(W_OVERWORLD_BLOCKS + idx)))
	elseif cmd == "redraw" then
		-- START now; then, in order: wait 40, B, wait 40, and whatever was queued after `redraw`.
		table.insert(queue, 1, "wait 40")
		table.insert(queue, 1, "hold B 4")
		table.insert(queue, 1, "wait 40")
		hold, holdN = "Start", 4
		log("redraw: START, then B")
	elseif cmd == "tilecheck" then
		tilecheck()
	elseif cmd == "collfind" then
		local v = tonumber(a, 16)
		scan(function(q) return q[1] == v and q[2] == v and q[3] == v and q[4] == v end, "collfind " .. a)
	elseif cmd == "collscan" then
		scan(function(q)
			for k = 1, 4 do
				if q[k] >= 0xA0 and q[k] <= 0xA7 then return true end
			end
			return false
		end, "collscan ledge family")
	else
		log("unknown: " .. line)
	end
end

log("cmd_drive loaded; command file " .. CMD)
MESHGHOST_DEV_TICK = function()
	poll = poll + 1
	if poll % 15 == 0 then readCmd() end
	step()
end
MESHGHOST_DEV_UNLOAD = function()
	log("unloaded")
	if logf then logf:close() end
	logf = nil
end
