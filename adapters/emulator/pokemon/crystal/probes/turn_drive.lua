-- MeshGhost — Pokémon Crystal: turn on the spot, one direction at a time (DEV TOOL, holds the d-pad)
--
-- Asked 2026-09-13: the user saw a peer's ghost *"look at the direction instantly"* where the player
-- plays a turn animation. A reproducible turn is what the move trace needs on the sender's side; what
-- it measured (step type 10, action 2, the face byte's frame sequence) is in `crystal/documentation.md`,
-- "Turning in place".
--
-- MEASURED, NOT TIMED: a direction is held only until the engine's own OBJECT_DIRECTION changes and
-- then released, so the press can never run on into a step; then 90 frames of nothing before the
-- next. Cycles down -> left -> up -> right. It presses the d-pad only, never A or B.
-- Object array per build: meshghost_crystal.lua ADDRESSES (vanilla .sym 01:d4d6; Archipelago measured).
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
