-- Pokémon Crystal: the wrong-trainer-sprite repro, driven: loads savestate MESHGHOST_TC_SLOT (default 5), walks 3
-- tiles left and 5 down, then dumps what decides a trainer's look (wVariableSprites, wUsedSprites, map objects,
-- object structs, OAM) with a screenshot in the same tick. Run it twice, with the adapter loaded and without
-- (MESHGHOST_TC_TAG "B-adapter"/"A-clean"): identical dumps acquit the adapter, a differing field names the fault.
-- Holds the d-pad: unload it before judging anything. MESHGHOST_TC_NOLOAD and MESHGHOST_TC_NOWALK skip the steps.

local TAG = tostring(MESHGHOST_TC_TAG or "run")
local DIR
do
	DIR = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		DIR = info.source:sub(2):match("^(.*)/[^/]*$") or "."
	end
end
local f = io.open(DIR .. "/trainer_check_" .. TAG .. ".log", "w")

local function u8(a) return memory.read_u8(a, "System Bus") or 0 end

local OBJ, OSTRIDE, NSTRUCTS = 0xD4D6, 0x28, 13
local MAPOBJ, MSTRIDE, NMAPOBJ = 0xD71E, 16, 16
local USEDSPR = 0xD154 -- wUsedSprites, 32 entries of 2 bytes (id, then a bank/flag byte)
local VARSPR = 0xD82E -- wVariableSprites, one byte per id from SPRITE_VARS ($f0) up
local W_MAPGROUP, W_MAPNUM = 0xDCB5, 0xDCB6
local M = { st = 0, sprite = 1, y = 2, x = 3, movement = 4, paltype = 8, sight = 9 }
local F = { sprite = 0x00, moidx = 0x01, tile = 0x02, flags1 = 0x04, pal = 0x06,
	act = 0x0B, face = 0x0D, mx = 0x10, my = 0x11 }

local SLOT = tonumber(MESHGHOST_TC_SLOT) or 5
local phase, n, loaded, done = "boot", 0, false, false
local startX, startY, timeout = nil, nil, 0

local function dump()
	if not f then return end
	f:write(string.format("=== trainer_check [%s] slot %s, map %d:%d, frame %d ===\n",
		TAG, MESHGHOST_TC_NOLOAD and "(none)" or tostring(SLOT),
		u8(W_MAPGROUP), u8(W_MAPNUM), emu.framecount()))
	f:write(string.format("player at %d,%d\n", u8(OBJ + F.mx), u8(OBJ + F.my)))

	f:write("\n-- wVariableSprites ($f5..$ff -> resolved sprite id) --\n")
	for i = 0, 10 do
		local v = u8(VARSPR + i)
		if v ~= 0 then
			-- SPRITE_VARS is $F0, whatever the heading above says.
			f:write(string.format("  var[%02X] = %d\n", 0xF0 + i, v))
		end
	end

	f:write("\n-- wUsedSprites (id : second byte) --\n")
	for i = 0, 31 do
		local id = u8(USEDSPR + i * 2)
		if id ~= 0 then
			f:write(string.format("  [%2d] id=%3d b=%3d\n", i, id, u8(USEDSPR + i * 2 + 1)))
		end
	end

	f:write("\n-- MAP OBJECTS --\n")
	for i = 0, NMAPOBJ - 1 do
		local b = MAPOBJ + i * MSTRIDE
		local spr = u8(b + M.sprite)
		if spr ~= 0 or u8(b + M.st) ~= 0xFF then
			local pt = u8(b + M.paltype)
			f:write(string.format(
				"  mo%-2d sprite=%3d struct=%3d at %3d,%3d move=%3d pal=%d type=%d sight=%d\n",
				i, spr, u8(b + M.st), u8(b + M.x), u8(b + M.y), u8(b + M.movement),
				pt >> 4, pt & 0x0F, u8(b + M.sight)))
		end
	end

	f:write("\n-- OBJECT STRUCTS --\n")
	for i = 0, NSTRUCTS - 1 do
		local b = OBJ + i * OSTRIDE
		local spr = u8(b + F.sprite)
		if spr ~= 0 or u8(b + F.act) ~= 0 then
			f:write(string.format(
				"  st%-2d sprite=%3d mapobj=%3d tilebase=%02X flags1=%02X pal=%02X act=%2d face=%02X at %3d,%3d\n",
				i, spr, u8(b + F.moidx), u8(b + F.tile), u8(b + F.flags1), u8(b + F.pal),
				u8(b + F.act), u8(b + F.face), u8(b + F.mx), u8(b + F.my)))
		end
	end

	-- The hardware's own answer: the tile ids say which graphics block a trainer is drawn from (id or tiles).
	f:write("\n-- OAM (y x tile attr), live entries only --\n")
	for e = 0, 39 do
		local y = memory.read_u8(e * 4, "OAM") or 0
		if y ~= 0 and y < 160 then
			f:write(string.format("  oam%-2d y=%3d x=%3d tile=%02X attr=%02X\n", e, y,
				memory.read_u8(e * 4 + 1, "OAM") or 0, memory.read_u8(e * 4 + 2, "OAM") or 0,
				memory.read_u8(e * 4 + 3, "OAM") or 0))
		end
	end
	f:close()
	pcall(function() client.screenshot(DIR .. "/trainer_check_" .. TAG .. ".png") end)
	console.log("trainer_check[" .. TAG .. "]: dumped + screenshot")
end

MESHGHOST_DEV_TICK = function()
	if done then return end
	n = n + 1
	if n < 30 then return end

	if not loaded then
		loaded = true
		preX, preY = u8(OBJ + F.mx), u8(OBJ + F.my) -- where we are BEFORE the load
		if not MESHGHOST_TC_NOLOAD then
			savestate.loadslot(SLOT)
			console.log("trainer_check[" .. TAG .. "]: loaded slot " .. SLOT)
		end
		n = 0
		phase = "armload"
		return
	end

	-- Waits for the load to apply: loadslot lands a few frames after the call, so the position leaving the pre-load
	-- one is the load arriving. 120 frames unchanged means the state was already here (or MESHGHOST_TC_NOLOAD).
	if phase == "armload" then
		if u8(OBJ + F.mx) ~= preX or u8(OBJ + F.my) ~= preY or n >= 120 then
			phase, startX, startY, timeout = "settle", nil, nil, 0
		end
		return
	end

	-- Settles on a coordinate unmoved for 60 frames, not a frame count. Timeouts are sized to the walk asked for, so a
	-- wrong stop condition shows as a short overshoot in the log.
	if phase == "settle" then
		local mx, my = u8(OBJ + F.mx), u8(OBJ + F.my)
		if mx == startX and my == startY then
			timeout = timeout + 1
		else
			startX, startY, timeout = mx, my, 0
		end
		if timeout >= 60 then
			phase = MESHGHOST_TC_NOWALK and "dump" or "left"
			timeout = 0
			console.log(string.format("trainer_check: start %d,%d -> walking 3 left, 5 down",
				startX, startY))
			if f then f:write(string.format("start %d,%d\n", startX, startY)) end
		end
		return
	end

	if phase == "left" or phase == "down" then
		timeout = timeout + 1
		local mx, my = u8(OBJ + F.mx), u8(OBJ + F.my)
		if f and (mx ~= lastWX or my ~= lastWY) then
			f:write(string.format("walk: at %d,%d (%s)\n", mx, my, phase))
			lastWX, lastWY = mx, my
		end
		if phase == "left" then
			if mx <= startX - 3 then
				phase, timeout = "down", 0
			elseif timeout > 180 then
				if f then f:write("TIMEOUT walking left -- dump is from the wrong tile\n") end
				phase, timeout = "down", 0
			else
				joypad.set({ Left = true })
			end
		else
			if my >= startY + 5 then
				phase, timeout, n = "wait", 0, 0
			elseif timeout > 240 then
				if f then f:write("TIMEOUT walking down -- dump is from the wrong tile\n") end
				phase, n = "wait", 0
			else
				joypad.set({ Down = true })
			end
		end
		return
	end
	if phase == "wait" then
		if n >= 60 then phase = "dump" end
		return
	end
	if phase == "dump" then
		done = true
		dump()
	end
end
