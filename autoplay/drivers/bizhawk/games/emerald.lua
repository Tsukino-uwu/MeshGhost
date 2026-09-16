-- autoplay BizHawk driver: vanilla Pokémon Emerald (DEV TOOL, never shipped).
--
-- Every address here is one `adapters/emulator/pokemon/emerald/probes/cmd_drive.lua` already uses,
-- and that file's header says what was measured and when (vanilla, 2026-09-16); this module adds no
-- address of its own. Where a byte's MEANING is not measured -- a facing or an action code -- the
-- value goes out raw and unnamed. Refuses nothing yet: `mode` says whether gMain.callback2 is
-- vanilla's overworld callback, and a later cheat will refuse when it is not, as `warp` does there.

local BUS = "System Bus"
local GPLAYERAVATAR, GOBJECTEVENTS = 0x02037590, 0x02037350
local SB1PTR = 0x03005d8c
local GMAIN_CB2, CB2_OVERWORLD = 0x030022c4, 0x08085e5c

local function r8(a) return memory.read_u8(a, BUS) end
local function r16(a) return memory.read_u16_le(a, BUS) end
local function r32(a) return memory.read_u32_le(a, BUS) end

local game = {
	game = "emerald",
	-- Nothing here tells vanilla from a patched build yet; the ROM's own game code goes out raw.
	variant = "unverified",
	capabilities = { "observe", "press", "wait", "screenshot" },
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
