-- set_colour.lua -- WRITES OBJECT RAM AND PALETTE RAM, dev only, any build: dress the LOCAL player
-- in a trainer colour so the OTHER window can be judged. Written 2026-09-09 for the trainer-colour
-- feature (`extras.pal` + `extras.clo` in meshghost_crystal.lua): a patched build may let the
-- player pick a fixed palette or a custom clothing colour, and no seed on this machine has one,
-- so this probe fakes both, the way that build does it -- an OBJ palette index on the player
-- object, and for the custom case a rewritten third colour in a palette slot.
--   MESHGHOST_COLOUR_PAL  (env) OBJ palette index 0-7 to put on the player object; default 2 (green)
--   MESHGHOST_COLOUR_RGB  (env) RRGGBB hex; when set, that colour is written as the THIRD colour of
--                          slot MESHGHOST_COLOUR_PAL (use 4, the pink slot, as the patch does)
-- Held every frame while attached, because a map load rewrites the object and a time-of-day
-- refresh rewrites the palettes; take it off the dev-loader target and the next map load restores
-- both. Nothing here reaches a save. What it proves: on the OTHER window, the ghost of this
-- player wears the index (fixed case) or the hex colour (custom case) -- and, first, that the
-- palette-RAM address is right on THIS build, by reading a colour the game is known to keep there.
local DOMAIN = "WRAM"
local function flat(cpu) return cpu < 0xD000 and cpu - 0xC000 or 0x1000 + (cpu - 0xD000) end
local function u8(a) return memory.read_u8(a, DOMAIN) end
local function w8(a, v) memory.write_u8(a, v, DOMAIN) end
local F_PALETTE = 0x06
local W_OBPALS = 0x5040 -- wOBPals1, 05:d040; the adapter's own value
local t = {}
for i = 0, 9 do t[#t + 1] = string.char(memory.read_u8(0x134 + i, "ROM") or 0) end
local title, ver = table.concat(t), memory.read_u8(0x14C, "ROM") or 0
local A
if title:sub(1, 3) == "AP_" then A = { name = "Archipelago", structs = 0x14DC }
elseif title == "PM_CRYSTAL" and ver == 6 then A = { name = "Speedchoice", structs = flat(0xD4D6) }
else A = { name = "vanilla", structs = flat(0xD4D6) } end
local PAL = tonumber(os.getenv("MESHGHOST_COLOUR_PAL") or "2") or 2
local RGB = os.getenv("MESHGHOST_COLOUR_RGB")
local port = os.getenv("MESHGHOST_BRIDGE_PORT") or "noport"
local cwd = io.popen("cd"):read("*l") or "."
local f = io.open(string.format("%s/set_colour_%s_%s.log", cwd, os.date("%Y%m%d_%H%M%S"), port), "w")
local function log(s) console.log(s); if f then f:write(os.date("%H:%M:%S "), s, "\n"); f:flush() end end

local function slotColour(slot, i) -- BGR555 word, colour i (1-3) of OBJ slot `slot`
	local at = W_OBPALS + (slot & 7) * 8 + i * 2
	return (u8(at) or 0) | ((u8(at + 1) or 0) << 8)
end
local function bgr(hex)
	local n = tonumber(hex:gsub("^#", ""), 16)
	local r, g, b = (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF
	return (r >> 3) | ((g >> 3) << 5) | ((b >> 3) << 10)
end

-- THE ADDRESS CHECK, before writing a byte: the game keeps RGB 31,07,01 as the red slot's third
-- colour at every hour (`gfx/overworld/npc_sprites.pal`), which is 0x04FF as a BGR555 word. If
-- slot 0 does not read that, W_OBPALS is wrong on this build and the probe refuses to write.
local red3 = slotColour(0, 3)
log(string.format("set_colour on %s: structs@%04X, slot0 colour3 = %04X (want 04FF)", A.name, A.structs, red3))
if red3 ~= 0x04FF then
	log("palette RAM did not read as expected on this build -- NOT writing. Fix W_OBPALS first.")
	return
end
local want = RGB and bgr(RGB) or nil
log(string.format("plan: OBJECT_PALETTE <- %d%s", PAL, want and string.format(", slot %d colour3 <- %04X (%s)", PAL, want, RGB) or ""))

local frames, reported = 0, false
event.onframeend(function()
	frames = frames + 1
	if frames < 30 then return end
	w8(A.structs + F_PALETTE, PAL)
	if want then
		local at = W_OBPALS + (PAL & 7) * 8 + 6
		w8(at, want & 0xFF); w8(at + 1, want >> 8)
		-- hCGBPalUpdate ($FFE5): the game copies wOBPals to the hardware only when this is set,
		-- so without it the LOCAL player keeps the old colour on screen while the wire already
		-- carries the new one. Best effort: an emulator core without an HRAM domain skips it.
		pcall(memory.write_u8, 0xE5, 1, "HRAM")
	end
	if not reported and frames % 60 == 0 then
		-- read back through the same reads the adapter uses, not the values just written
		local gotPal, got3 = u8(A.structs + F_PALETTE), slotColour(PAL, 3)
		log(string.format("read back: OBJECT_PALETTE = %d, slot %d colour3 = %04X", gotPal or -1, PAL, got3))
		reported = (gotPal == PAL) and (not want or got3 == want)
		if reported then log("holding; the other window's ghost of this player is the verdict") end
	end
end)
