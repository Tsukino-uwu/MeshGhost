-- Dev tool, holds the d-pad: turns on the spot down, left, up, right, 90 frames apart, never pressing A or B. Each
-- direction is held only until OBJECT_DIRECTION changes, so a press never runs on into a step.
-- The object array per build, as in meshghost_crystal.lua's ADDRESSES.
local BUILDS = { PM_CRYSTAL = 0x14D6, AP_CRYSTAL = 0x14DC }
local title = ""
for i = 0x134, 0x13E do
	local c = memory.read_u8(i, "ROM")
	if c == 0 then break end
	title = title .. string.char(c)
end
local objects = BUILDS[title]
local ORDER = { { "Down", 0 }, { "Left", 2 }, { "Up", 1 }, { "Right", 3 } }
local idx, holding, wait, turns = 1, false, 90, 0

MESHGHOST_DEV_TICK = function()
	if not objects or MESHGHOST_TURN_PAUSE then return end
	local dir = (memory.read_u8(objects + 0x08, "WRAM") // 4) & 3
	local standing = memory.read_u8(objects + 0x07, "WRAM") == 0xFF
	if wait > 0 then
		wait = wait - 1
		return
	end
	local want = ORDER[idx]
	if dir == want[2] and not holding then
		idx = idx % #ORDER + 1 -- already facing it: take the next one
		return
	end
	if holding then
		if dir == want[2] then
			holding, wait, turns = false, 90, turns + 1
			idx = idx % #ORDER + 1
			console.log(string.format("turn_drive: turned %s at frame %d (%d turns)", want[1], emu.framecount(), turns))
			return
		end
		pcall(joypad.set, { [want[1]] = true })
		pcall(joypad.set, { [want[1]] = true }, 1)
		return
	end
	if standing then
		holding = true
		pcall(joypad.set, { [want[1]] = true })
		pcall(joypad.set, { [want[1]] = true }, 1)
	end
end
