-- Read-only: how many frames a freshly promoted ghost takes to reach hardware OAM, so whether the adapter's tier
-- overlap leaves the peer drawn by nobody for a frame. A new struct wearing the player's sprite is the promotion; the
-- count runs until an OAM entry appears at that struct's screen position. Addresses as in meshghost_crystal.lua.
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

-- Assumes a sprite at object coords sx,sy lands at sx+8, sy+16 in OAM, and gates every reading on finding the player
-- there, since OAM entries 0-3 are the player's only while nothing else is on screen: a wrong offset records nothing.
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
