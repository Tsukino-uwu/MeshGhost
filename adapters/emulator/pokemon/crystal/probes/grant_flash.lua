-- Writes one game bit, once: STATUSFLAGS_FLASH_F (bit 2) of wStatusFlags (01:d84c in our hash-verified build's .sym),
-- the bit real Flash is expected to set, then reads it back. It does not reload the palettes, so expect any change on
-- the next map load. A dev tool, never in a release; it writes RAM, not the .sav, but an in-game save keeps it, so
-- savestate first.

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
	-- Read back from memory, never the value just written: it is the only evidence the write landed.
	local after = u8(W_STATUSFLAGS)
	console.log(string.format(
		"grant_flash: wStatusFlags %02X -> %02X (FLASH bit %s). Lighting applies on the NEXT map load.",
		before, after, ((after & FLASH_BIT) ~= 0) and "SET" or "*** NOT SET -- write refused ***"))
end
