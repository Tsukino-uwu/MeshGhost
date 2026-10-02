-- Input-driving, one-shot, any build: walks MESHGHOST_SURF_DIR (env, default Right) until blocked, presses A at the
-- water and confirms, paddles a 2-tile square, screenshots to MESHGHOST_SURF_SHOT (env, default <cwd>/surf_<port>.png).
-- On Archipelago, where wPlayerState is unmeasured, surfing means the tile that blocked the walk is now underfoot.
-- Logs every decision with its values; take it off the target afterwards, as it acts once per attach.

local DOMAIN = "WRAM"
local function flat(cpu) return cpu < 0xD000 and cpu - 0xC000 or 0x1000 + (cpu - 0xD000) end
local function u8(a) return memory.read_u8(a, DOMAIN) end
local F_MAP_X, F_MAP_Y, F_WALKING = 0x10, 0x11, 0x07
local PLAYER_SURF = 4 -- wPlayerState while surfing, measured on vanilla V1.0
local t = {}
for i = 0, 9 do t[#t + 1] = string.char(memory.read_u8(0x134 + i, "ROM") or 0) end
local title, ver = table.concat(t), memory.read_u8(0x14C, "ROM") or 0
local A
if title:sub(1, 3) == "AP_" then A = { name = "Archipelago", structs = 0x14DC, state = nil }
elseif title == "PM_CRYSTAL" and ver == 6 then A = { name = "Speedchoice", structs = flat(0xD4D6), state = flat(0xD95D) }
else A = { name = "vanilla", structs = flat(0xD4D6), state = flat(0xD95D) } end
local DIR = os.getenv("MESHGHOST_SURF_DIR") or "Right"
local port = os.getenv("MESHGHOST_BRIDGE_PORT") or "noport"
local cwd = io.popen("cd"):read("*l") or "."
local SHOT = os.getenv("MESHGHOST_SURF_SHOT") or string.format("%s/surf_%s.png", cwd, port)
local f = io.open(string.format("%s/drive_surf_%s_%s.log", cwd, os.date("%Y%m%d_%H%M%S"), port), "w")
local function log(s) console.log(s); if f then f:write(os.date("%H:%M:%S "), s, "\n"); f:flush() end end
local function tile() return u8(A.structs + F_MAP_X) or -1, u8(A.structs + F_MAP_Y) or -1 end
local function surfing()
	if A.state then return (u8(A.state) or 0) == PLAYER_SURF end
	return nil
end
log(string.format("drive_surf on %s: structs@%04X state@%s, walking %s", A.name, A.structs, A.state and string.format("%04X", A.state) or "n/a", DIR))

-- The square: {kind, button, steps}; a leg ends after its steps or 240 frames without progress.
local SQUARE = { { "walk", "Right", 2 }, { "walk", "Down", 2 }, { "walk", "Left", 2 }, { "walk", "Up", 2 } }
local phase, sub, held, tries = "approach", 0, 0, 0
local lastX, lastY = tile()
local blockedFor, waterX, waterY = 0, nil, nil
local sqIndex, sqSteps = 1, 0
local frames = 0
local function press(btn) joypad.set({ [btn] = true }) end
local function tick()
	frames = frames + 1
	if phase == "done" or frames < 30 then return end
	local x, y = tile()
	if phase == "approach" then
		press(DIR)
		held = held + 1
		if held % 24 == 0 then
			if x == lastX and y == lastY then blockedFor = blockedFor + 1 else blockedFor = 0 end
			lastX, lastY = x, y
			if blockedFor >= 2 then
				log(string.format("blocked at tile %d,%d facing %s after %d frames -- pressing A", x, y, DIR, held))
				phase, sub, held = "prompt", 0, 0
			end
		end
	elseif phase == "prompt" then
		-- The SURF prompt opens with YES selected and prints slowly: tap A until surfing (on AP, until the tile moves).
		-- Never B here, which declines the prompt.
		sub = sub + 1
		if sub % 40 <= 5 then press("A") end
		local s = surfing()
		if s == true or (s == nil and (x ~= lastX or y ~= lastY)) or sub >= 420 then
			log(string.format("after the prompt (%d frames): tile %d,%d, surfing=%s", sub, x, y, tostring(s)))
			if s == true or (s == nil and (x ~= lastX or y ~= lastY)) then
				waterX, waterY = x, y
				phase, sub = "verify", 0
			else
				tries = tries + 1
				log(string.format("not surfing (try %d): pressing B twice, stepping Down, trying again", tries))
				phase, sub = "retry", 0
			end
		end
	elseif phase == "retry" then
		sub = sub + 1
		if sub <= 6 or (sub >= 30 and sub <= 36) then press("B") end
		if sub >= 60 and sub <= 84 then press("Down") end
		if sub >= 100 then
			if tries >= 3 then log("giving up after 3 tries"); phase = "done"; return end
			phase, held, blockedFor = "approach", 0, 0; lastX, lastY = tile()
		end
	elseif phase == "verify" then
		-- Push once more toward the water: on the water the tile must now advance.
		sub = sub + 1
		if sub <= 40 then press(DIR) end
		if sub == 70 then
			local s = surfing()
			log(string.format("verify: tile %d,%d (was %d,%d), surfing=%s", x, y, waterX, waterY, tostring(s)))
			if s == true or (s == nil and (x ~= waterX or y ~= waterY)) then
				phase, sub, sqIndex, sqSteps = "square", 0, 1, 0; lastX, lastY = tile()
			else
				tries = tries + 1
				if tries >= 3 then log("could not get onto the water; giving up"); phase = "done"; return end
				phase, sub = "retry", 0
			end
		end
	elseif phase == "square" then
		local step = SQUARE[sqIndex]
		if not step then
			local ok, err = pcall(function() client.screenshot(SHOT) end)
			log(string.format("square done at tile %d,%d surfing=%s; screenshot -> %s (%s)", x, y, tostring(surfing()), SHOT, ok and "ok" or tostring(err)))
			phase = "done"; log("done"); return
		end
		press(step[2])
		sub = sub + 1
		if x ~= lastX or y ~= lastY then
			sqSteps = sqSteps + 1; lastX, lastY = x, y
			log(string.format("  %s: now at %d,%d (%d/%d)", step[2], x, y, sqSteps, step[3]))
			if sqSteps >= step[3] then sqIndex, sqSteps, sub = sqIndex + 1, 0, 0 end
		elseif sub > 240 then
			log(string.format("  %s: no progress in 240 frames at %d,%d -- skipping this leg", step[2], x, y))
			sqIndex, sqSteps, sub = sqIndex + 1, 0, 0
		end
	end
end
MESHGHOST_DEV_TICK = tick
if not MESHGHOST_DEV_LOADER then while true do tick(); emu.frameadvance() end end
