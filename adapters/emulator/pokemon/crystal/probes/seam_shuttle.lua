-- Walk back and forth across an EAST/WEST seam, forever. DEV TOOL, presses the d-pad only.
--
-- The user's own repro, 2026-08-27: *"load savestate8 on 1 instance, and then just walk
-- left/right back/forth between the routes"* -- the cheapest way to make the crossing flicker
-- happen over and over instead of once.
--
-- Slot 8 sits one tile west of the Olivine City <-> Route 40 seam, so Right crosses out and Left
-- crosses back. Legs are long enough to clear the seam and settle, short enough that a lap is a
-- few seconds.
local DOMAIN = "WRAM"
local function flat(c) if c < 0xD000 then return c - 0xC000 end return 0x1000 + (c - 0xD000) end
local W_G, W_N, W_Y, W_X = flat(0xDCB5), flat(0xDCB6), flat(0xDCB7), flat(0xDCB8)
local function u8(a) local ok, v = pcall(memory.read_u8, a, DOMAIN) return (ok and v) or 0 end

local LEG = 26
local n, lastArea = 0, nil
MESHGHOST_DEV_TICK = function()
	n = n + 1
	local want = ((n // LEG) % 2 == 0) and "Right" or "Left"
	pcall(joypad.set, { [want] = true })
	pcall(joypad.set, { [want] = true }, 1)
	local area = u8(W_G) .. "/" .. u8(W_N)
	if area ~= lastArea then
		pcall(function()
			console.log(string.format("seam_shuttle: now on %s at %d,%d (pressing %s)",
				area, u8(W_X), u8(W_Y), want))
		end)
		lastArea = area
	end
end
