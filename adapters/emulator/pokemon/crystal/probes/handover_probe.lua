-- Crystal: how many frames a freshly PROMOTED ghost takes to reach hardware OAM.
--
-- READ-ONLY. Writes nothing.
--
-- The adapter keeps the drawn copy for exactly ONE frame after it creates the engine object
-- ("OVERLAP THE TWO TIERS BY ONE FRAME"), on the reasoning that a new object is not in the engine's
-- sprite list until the engine next builds one. If the engine actually takes longer than that, the
-- drawn copy is dropped into a gap and the peer is drawn by NOBODY for a frame or more -- which is
-- the blink the user still reports at the moment a ghost starts moving after being idle.
--
-- Measured, not reasoned: a new struct wearing the player's sprite is the promotion, and the count
-- runs until an OAM entry actually appears at that struct's screen position.
--
-- Constants copied from meshghost_crystal.lua: OBJECT_STRUCTS 0xD4D6 (13 x 0x28), F_SPRITE 0x00,
-- F_SPRITE_X 0x17, F_SPRITE_Y 0x18, F_MAP_X 0x10, F_MAP_Y 0x11.
local OBJ, LEN = 0xD4D6, 0x28
local F_SPRITE, F_SPRITE_X, F_SPRITE_Y = 0x00, 0x17, 0x18
local function u8(a) return memory.read_u8(a, "System Bus") or 0 end

local f
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)/[^/]*$") or "."  -- the loader hands out forward slashes
	end
	f = io.open(dir .. "/handover.log", "w")
end
local function log(s) if f then f:write(s .. "\n"); f:flush() end end
log("=== promotion -> visible in OAM, in frames ===")

-- SELF-VALIDATING, because the obvious calibration is the one this adapter warns about: OAM entries
-- 0-3 are the PLAYER's only while nothing else is on screen, and a spawned ghost can take them. A
-- probe built on that reported 21-24 frames on its first run, which is a third of a second and was
-- an artefact of matching the wrong sprite.
--
-- So the engine offset is treated as a FIXED constant (a sprite at object coords sx,sy lands at
-- sx+8, sy+16 in OAM -- the Game Boy's own sprite origin), and every reading is gated on FINDING THE
-- PLAYER at its own expected position with that same constant. If the player cannot be found, the
-- assumption is wrong this frame and nothing is recorded, rather than a number being produced.
local OAM_DX, OAM_DY = 8, 16

local function oamHasSpriteAt(sx, sy)
	local wx, wy = (sx + OAM_DX) & 0xFF, (sy + OAM_DY) & 0xFF
	for i = 0, 39 do
		local y = memory.read_u8(i * 4, "OAM") or 0
		local x = memory.read_u8(i * 4 + 1, "OAM") or 0
		if y ~= 0 and y < 160 and math.abs(x - wx) <= 4 and math.abs(y - wy) <= 4 then
			return true
		end
	end
	return false
end

-- The gate: is the local player where this arithmetic says it should be?
local function trustworthy()
	return oamHasSpriteAt(u8(OBJ + F_SPRITE_X), u8(OBJ + F_SPRITE_Y))
end

local watching, seen = {}, {}
local hist, n = {}, 0

MESHGHOST_DEV_TICK = function()
	local playerSprite = u8(OBJ + F_SPRITE)
	if playerSprite == 0 then return end
	local ok = trustworthy()
	for i = 1, 12 do
		local b = OBJ + i * LEN
		local sprite = u8(b)
		local present = sprite ~= 0 and sprite == playerSprite
		if present and not seen[i] then
			watching[i] = { at = emu.framecount(), frames = 0 }
			log(string.format("f=%d  struct %d promoted at tile %d,%d", emu.framecount(), i,
				u8(b + 0x10), u8(b + 0x11)))
		elseif not present then
			watching[i] = nil
		end
		seen[i] = present
		local w = watching[i]
		if w and ok then
			w.frames = w.frames + 1
			if oamHasSpriteAt(u8(b + F_SPRITE_X), u8(b + F_SPRITE_Y)) then
				n = n + 1
				local k = w.frames
				hist[k] = (hist[k] or 0) + 1
				log(string.format("f=%d  struct %d VISIBLE after %d frame%s "
					.. "(the adapter drops the drawn copy after 1)",
					emu.framecount(), i, k, (k == 1) and "" or "s"))
				watching[i] = nil
				local keys = {}
				for kk in pairs(hist) do keys[#keys + 1] = kk end
				table.sort(keys)
				local out = {}
				for _, kk in ipairs(keys) do out[#out + 1] = kk .. ":" .. hist[kk] end
				log("    so far, frames-to-visible: " .. table.concat(out, " ")
					.. string.format("   (%d promotions)", n))
			elseif w.frames > 120 then
				log(string.format("f=%d  struct %d never became visible within 120 frames -- "
					.. "not a handover gap, something else", emu.framecount(), i))
				watching[i] = nil
			end
		end
	end
end
