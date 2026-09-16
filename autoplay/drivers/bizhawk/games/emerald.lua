-- autoplay BizHawk driver: vanilla Pokémon Emerald (DEV TOOL, never shipped).
--
-- Every address here is one `adapters/emulator/pokemon/emerald/probes/cmd_drive.lua` already uses,
-- and that file's header says what was measured and when (vanilla, 2026-09-16); this module adds no
-- address of its own. Where a byte's MEANING is not measured -- a facing or an action code -- the
-- value goes out raw and unnamed. `mode` says whether gMain.callback2 is vanilla's overworld callback,
-- and the warp cheat refuses when it is not, as `cmd_drive.lua`'s `warp` does.

local BUS = "System Bus"
local GPLAYERAVATAR, GOBJECTEVENTS = 0x02037590, 0x02037350
local SB1PTR = 0x03005d8c
local GMAIN_CB2, CB2_OVERWORLD, CB2_LOADMAP = 0x030022c4, 0x08085e5c, 0x08085fcc
local GFIELDCALLBACK, FIELDCB_DEFAULTWARPEXIT = 0x03005dac, 0x080af398
local SWARPDESTINATION = 0x020322e4

local function r8(a) return memory.read_u8(a, BUS) end
local function r16(a) return memory.read_u16_le(a, BUS) end
local function r32(a) return memory.read_u32_le(a, BUS) end
local function w8(a, v) memory.write_u8(a, v, BUS) end
local function w16(a, v) memory.write_u16_le(a, v, BUS) end
local function w32(a, v) memory.write_u32_le(a, v, BUS) end

local game = {
	game = "emerald",
	-- Nothing here tells vanilla from a patched build yet; the ROM's own game code goes out raw.
	variant = "unverified",
	capabilities = { "observe", "press", "wait", "screenshot", "snapshot", "restore", "cheat:warp" },
	protected_slots = { 1 },
	-- The folder under dev-scripts/shots/ this game's pictures go to.
	shots = "emerald",
}

function game.build()
	return string.format("gamecode %08X", r32(0x080000AC))
end

function game.observe()
	local cb2 = r32(GMAIN_CB2)
	local sb1 = r32(SB1PTR)
	local obj = GOBJECTEVENTS + r8(GPLAYERAVATAR + 5) * 0x24
	return {
		frame = emu.framecount(),
		mode = (cb2 == CB2_OVERWORLD or cb2 == CB2_OVERWORLD + 1) and "overworld" or "not_overworld",
		location = {
			map = string.format("%d.%d", r8(sb1 + 4), r8(sb1 + 5)),
			x = r16(sb1),
			y = r16(sb1 + 2),
		},
		extras = {
			callback2 = string.format("%08X", cb2),
			avatar_flags = r8(GPLAYERAVATAR),
			player_object = {
				x = r16(obj + 0x10),
				y = r16(obj + 0x12),
				facing_raw = r8(obj + 0x18),
				action_raw = r8(obj + 0x1c),
			},
		},
	}
end

local function inOverworld()
	local cb = r32(GMAIN_CB2)
	return cb == CB2_OVERWORLD or cb == CB2_OVERWORLD + 1
end

-- Cheats: each takes its args and returns a plan -- { untilFn = function(observation) -> done,
-- limit = frames } -- or nil and a reason. A cheat changes the world by other means than play; the
-- core marks the segment reached.
game.cheats = {}

-- warp {map = "G.N", x, y}: the game's own map load, the writes `cmd_drive.lua`'s `warp` measured
-- (2026-09-16: lands on the named map and tile, onto water arriving surfing). Refused unless
-- gMain.callback2 is vanilla's overworld callback. Done once the game has left the overworld and come
-- back on the target map; 600 frames at most.
function game.cheats.warp(args)
	local map = type(args.map) == "string" and args.map or ""
	local g, n = map:match("^(%d+)%.(%d+)$")
	local x, y = math.tointeger(args.x), math.tointeger(args.y)
	g, n = tonumber(g), tonumber(n)
	if not g or g > 255 or n > 255 or not x or not y or x < 0 or y < 0 or x > 0xffff or y > 0xffff then
		return nil, 'warp needs map "G.N" (each 0-255), x and y'
	end
	if not inOverworld() then
		return nil, string.format("warp refused: gMain.callback2 is %08X, not vanilla's overworld", r32(GMAIN_CB2))
	end
	local sb1 = r32(SB1PTR)
	for _, at in ipairs({ SWARPDESTINATION, sb1 + 0x04 }) do
		w8(at, g); w8(at + 1, n); w8(at + 2, 0)
		w16(at + 4, 0xffff); w16(at + 6, 0xffff)
	end
	w16(sb1, x); w16(sb1 + 2, y)
	w32(GFIELDCALLBACK, FIELDCB_DEFAULTWARPEXIT + 1)
	w32(GMAIN_CB2, CB2_LOADMAP + 1)
	local left = false
	return {
		limit = 600,
		untilFn = function(o)
			if o.mode ~= "overworld" then
				left = true
				return false
			end
			return left and o.location.map == map
		end,
	}
end

-- What `changed` compares between two observations: the fields a press is expected to move.
function game.diffKeys(o)
	return {
		mode = o.mode,
		map = o.location.map,
		x = o.location.x,
		y = o.location.y,
		facing_raw = o.extras.player_object.facing_raw,
	}
end

return game
