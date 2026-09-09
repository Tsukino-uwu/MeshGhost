-- fly_menu_drive.lua -- INPUT-DRIVING, one-shot, any build: FLY from the overworld through the
-- menus, no prepared savestate needed (fly_drive.lua needs one, and the five-build room had
-- none). Presses, on a fixed countdown: START -> A (POKeMON, the first entry) -> A (the first
-- party member) -> Down (FLY sits one below SURF when the lead knows both; see the screenshot
-- of 2026-09-09) -> A (the fly map, cursor on the current town) -> A (go) -> waits for the
-- flight. A screenshot after every press goes beside the adapter's logs, so a menu that differs
-- (a lead without Surf puts FLY first: drop the Down) is seen rather than guessed. Endurance,
-- not timing: each wait is generous. Take it off the target afterwards.
--   MESHGHOST_FLY_MENU_SEQ (a global set by a loader-side probe) overrides the sequence.
local SEQ = _G.MESHGHOST_FLY_MENU_SEQ or { { "Start", 60 }, { "A", 60 }, { "A", 60 }, { "Down", 30 }, { "A", 90 }, { "A", 120 }, { "A", 300 } }
local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then dir = info.source:sub(2):match("^(.*)/[^/]*$") or "." end
	dir = dir:match("^(.*)/probes$") or dir
end
local port = os.getenv("MESHGHOST_BRIDGE_PORT") or "x"
local stamp = os.date("%H%M%S")
local f = io.open(string.format("%s/logs/fly_menu_%s_%s.log", dir, stamp, port), "w")
local function log(s) console.log("fly_menu_drive: " .. s); if f then f:write(s, "\n"); f:flush() end end
local i, n, done = 1, 0, false
MESHGHOST_DEV_TICK = function()
	if done then return end
	n = n + 1
	if n < 30 then return end
	local step = SEQ[i]
	if not step then done = true; log("done"); return end
	local k = n - 30
	if k < 6 then joypad.set({ [step[1]] = true }) end
	if k == step[2] then
		local p = string.format("%s/logs/fly_menu_%s_%s_%02d_%s.png", dir, stamp, port, i, step[1])
		local ok = pcall(function() client.screenshot(p) end)
		log(string.format("step %d %s held 6 frames, waited %d -> %s (%s)", i, step[1], step[2], p, tostring(ok)))
		i, n = i + 1, 29
	end
end
if not MESHGHOST_DEV_LOADER then while true do MESHGHOST_DEV_TICK(); emu.frameadvance() end end
