-- TURN THE LIGHTS ON IN A DARK CAVE (DEV TOOL, WRITES ONE BIT).
--
-- WHY. Warping into Ice Path on a save that skipped the story shows a grey screen: the map loads
-- correctly and the player is drawn, but the background is blank, because a CAVE map without the
-- FLASH status flag is drawn dark. Measured by `warp_check.lua` -- map 5:61, mapStatus HANDLE,
-- 4 live OAM entries, "BG row 0 = ALL ONE TILE" -- so the cave is lightless, not broken.
--
-- WHAT IT WRITES. One bit: `STATUSFLAGS_FLASH_F` (bit 2) of `wStatusFlags` (`01:d84c`, from our
-- own hash-verified `pokecrystal` build's symbol file, cross-checked against
-- `constants/ram_constants.asm:235`). That is the same bit `BlindingFlash`
-- (`engine/events/field_moves.asm`) sets when the player actually uses Flash.
--
-- IT DOES NOT RELOAD THE PALETTES. `BlindingFlash` sets the bit and then fades and rebuilds the
-- map palettes; this only sets the bit, so the lighting changes on the next map load. Walk in
-- (or out and back) rather than expecting the current screen to brighten -- an important
-- difference, because "nothing happened" here would otherwise read as the write failing.
--
-- CLAUDE.md permits a PROBE to cheat and never an adapter: this is dev tooling, it is never
-- imported by `meshghost_crystal.lua`, and it is never copied into a release. It writes RAM, not
-- the .sav -- but an in-game save afterwards makes it permanent, so savestate first if that
-- matters.
--
-- Writes once, reads the byte back independently, and goes quiet.

local function u8(a) return memory.read_u8(a, "System Bus") or 0 end
local function w8(a, v) memory.write_u8(a, v, "System Bus") end

local W_STATUSFLAGS = 0xD84C
local FLASH_BIT = 0x04 -- STATUSFLAGS_FLASH_F is bit 2

local done, n = false, 0

MESHGHOST_DEV_TICK = function()
	if done then return end
	n = n + 1
	if n < 60 then return end -- let a map load settle before touching save-block flags
	done = true

	local before = u8(W_STATUSFLAGS)
	if (before & FLASH_BIT) ~= 0 then
		console.log(string.format("grant_flash: already set (wStatusFlags=%02X) -- nothing written",
			before))
		return
	end
	w8(W_STATUSFLAGS, before | FLASH_BIT)
	-- READ BACK from memory, never the value just written -- CLAUDE.md's rule. This is the whole
	-- evidence that the write landed, so it has to be an independent read.
	local after = u8(W_STATUSFLAGS)
	console.log(string.format(
		"grant_flash: wStatusFlags %02X -> %02X (FLASH bit %s). Lighting applies on the NEXT map load.",
		before, after, ((after & FLASH_BIT) ~= 0) and "SET" or "*** NOT SET -- write refused ***"))
end
