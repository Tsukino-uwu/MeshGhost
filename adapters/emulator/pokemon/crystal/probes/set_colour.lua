-- set_colour.lua -- WRITES OBJECT RAM AND PALETTE RAM, dev only, any build: dress the LOCAL player
-- in a trainer colour so the OTHER window can be judged. Written 2026-09-09 for the trainer-colour
-- feature (`extras.pal` + `extras.clo` in meshghost_crystal.lua): a patched build may let the
-- player pick a fixed palette or a custom clothing colour, and no seed on this machine has one,
-- so this probe fakes both, the way that build does it -- an OBJ palette index on the player
-- object, and for the custom case a rewritten clothing colour (word 2 of 4, byte 4) in a slot.
--   MESHGHOST_COLOUR_PAL  (env) OBJ palette index 0-7 to put on the player object; default 2 (green)
--   MESHGHOST_COLOUR_RGB  (env) RRGGBB hex; when set, that colour is written as the clothing colour (word 2) of
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

-- THE ADDRESS CHECK, before writing a byte: the game keeps RGB 31,07,01 as the red slot's
-- colour 2 at every hour (`gfx/overworld/npc_sprites.pal`), which is 0x04FF as a BGR555 word. If
-- slot 0 does not read that, W_OBPALS is wrong on this build and the probe refuses to write.
-- Re-asked EVERY FRAME until it passes, not once at load: the first run of this probe checked at
-- attach, on three windows still at the title screen, where palette RAM holds the intro's colours
-- (7FFF, 7197), refused, and never looked again (2026-09-09). The overworld is what loads the
-- object palettes, so the check waits for it, and a failure is logged once a second, not once.
-- TWO MODES (2026-09-10). Default, WIRE ONLY: hand the colour to the adapter's own dev override
-- (`MESHGHOST_CRYSTAL_DEV_CLOTHING`, a global it re-reads every state) and write NOTHING -- the
-- local player keeps the game's colour and only the ghosts elsewhere wear this one, which is the
-- feature under test. MESHGHOST_COLOUR_FAKE_PATCH=1 is the other mode, everything below: do what
-- the patch does to the game's own memory, which colours the LOCAL player as well -- the user's
-- first reading of that was a defect ("it still affected the speedchoice player color itself").
if RGB and os.getenv("MESHGHOST_COLOUR_FAKE_PATCH") ~= "1" then
	MESHGHOST_CRYSTAL_DEV_CLOTHING = RGB
	log(string.format("set_colour on %s: WIRE ONLY -- the adapter sends %s as this player's clothing colour; no memory written", A.name, RGB))
	MESHGHOST_DEV_UNLOAD = function() MESHGHOST_CRYSTAL_DEV_CLOTHING = nil end
	return
end
local want = RGB and bgr(RGB) or nil
log(string.format("set_colour on %s: structs@%04X; plan: OBJECT_PALETTE <- %d%s -- waiting for the overworld palettes",
	A.name, A.structs, PAL, want and string.format(", slot %d colour2 <- %04X (%s)", PAL, want, RGB) or ""))

local frames, reported, armed, pushLogged = 0, false, false, false
local function tick()
	frames = frames + 1
	if frames < 30 then return end
	if not armed then
		local red2 = slotColour(0, 2)
		if red2 ~= 0x04FF then
			if frames % 60 == 0 then
				log(string.format("slot0 colour2 = %04X (want 04FF): not the overworld palettes yet -- not writing", red2))
			end
			return
		end
		armed = true
		log("palette RAM reads as the game keeps it (slot0 colour2 = 04FF) -- writing from now on")
	end
	w8(A.structs + F_PALETTE, PAL)
	if want then
		local at = W_OBPALS + (PAL & 7) * 8 + 4
		w8(at, want & 0xFF); w8(at + 1, want >> 8)
		-- TWO BLOCKS. wOBPals1 is the working set (what the adapter reads and sends), and
		-- `ForceUpdateCGBPals` (home/palettes.asm) copies the HARDWARE from wBGPals2/wOBPals2, 128
		-- bytes past it. Writing only the first left every local player in the pink slot's own
		-- salmon while the ghosts were already right (the user, 2026-09-10: "it kept being salmon
		-- even after a hard/full reset"). The game's own ApplyPals copies 1 -> 2 on a map load,
		-- so both are held.
		w8(at + 0x80, want & 0xFF); w8(at + 0x81, want >> 8)
		-- hCGBPalUpdate ($FFE5): the game copies wOBPals to the hardware only when this is set,
		-- so without it the LOCAL player keeps the old colour on screen while the wire already
		-- carries the new one. Best effort: an emulator core without an HRAM domain skips it.
		-- BizHawk's HRAM domain starts at $FF80, so $FFE5 is offset $65: the first run wrote $E5,
		-- past the domain's end, and every local player stayed the pink slot's salmon (the user:
		-- Speedchoice "looks orange/yellow ish", 2026-09-09) while the ghosts were already right.
		local okH, errH = pcall(memory.write_u8, 0x65, 1, "HRAM")
		local okB, errB = pcall(memory.write_u8, 0xFFE5, 1, "System Bus")
		if not pushLogged then
			pushLogged = true
			local doms = {}
			for _, d in ipairs(memory.getmemorydomainlist() or {}) do doms[#doms + 1] = tostring(d) end
			local rbH = select(2, pcall(memory.read_u8, 0x65, "HRAM"))
			local rbB = select(2, pcall(memory.read_u8, 0xFFE5, "System Bus"))
			log(string.format("hardware push: HRAM write %s (%s), read back %s; System Bus write %s (%s), read back %s; domains: %s",
				tostring(okH), tostring(errH), tostring(rbH), tostring(okB), tostring(errB), tostring(rbB), table.concat(doms, ",")))
		end
	end
	if not reported and frames % 60 == 0 then
		-- read back through the same reads the adapter uses, not the values just written
		local gotPal, got2 = u8(A.structs + F_PALETTE), slotColour(PAL, 2)
		log(string.format("read back: OBJECT_PALETTE = %d, slot %d colour2 = %04X", gotPal or -1, PAL, got2))
		reported = (gotPal == PAL) and (not want or got2 == want)
		if reported then log("holding; the other window's ghost of this player is the verdict") end
	end
end
-- Dev-loader contract (dev-scripts/bizhawk-dev-loader.lua): ticked by the loader when it runs us,
-- else by a frame-end event so the file also works opened straight in the Lua Console.
if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick else event.onframeend(tick) end
