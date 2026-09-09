-- drive_fish.lua -- INPUT-DRIVING, one-shot: load savestate slot N (default 5, a spot where A
-- casts the rod), cast, dismiss the text, then open the START menu and its first two entries.
-- Written 2026-09-09 to let ui_signals_probe.lua see a fishing text box, the START menu, the
-- party screen and the Pack without the user pressing anything. Fixed phases on a frame
-- countdown, never a window to hit. Unload it before judging anything -- and take it off the
-- target after it acts, or a reload plays it again. Dev-loader contract.
local SLOT = tonumber(os.getenv("MESHGHOST_DRIVE_SLOT") or "") or 5
local port = os.getenv("MESHGHOST_BRIDGE_PORT") or "noport"
local f = io.open(string.format("%s/drive_fish_%s_%s.log", (io.popen("cd"):read("*l") or "."), os.date("%Y%m%d_%H%M%S"), port), "w")
local function log(s) console.log(s); if f then f:write(os.date("%H:%M:%S "), s, "\n"); f:flush() end end
-- phases: {frames, button or nil, label}; a button is held for the first 6 frames of its phase
local PHASES = {
	{ 60, nil, "settle after load" },
	{ 240, "A", "cast (A)" },          -- the rod goes out; ~2-3 s until the text
	{ 120, nil, "text up (nibble / bite)" },
	{ 90, "A", "dismiss text (A)" },
	{ 90, "A", "dismiss again (A) -- a bite starts a battle here" },
	{ 120, "B", "B, in case a battle menu is up" },
	{ 240, "B", "B again / run (leaves a battle only if RUN is picked by hand)" },
	{ 90, "Start", "START menu" },
	{ 120, "A", "first entry (A)" },
	{ 90, "B", "back (B)" },
	{ 30, "Down", "down" },
	{ 120, "A", "second entry (A)" },
	{ 90, "B", "back (B)" },
	{ 60, "B", "close menu (B)" },
}
local frames, phase, inPhase, loaded, done = 0, 1, 0, false, false
local function tick()
	frames = frames + 1
	if done then return end
	if not loaded then
		if frames < 30 then return end
		savestate.loadslot(SLOT)
		loaded = true
		log(string.format("loaded slot %d at frame %d", SLOT, emu.framecount()))
		return
	end
	local p = PHASES[phase]
	if not p then done = true; log("done"); return end
	if inPhase == 0 then log(string.format("phase %d: %s", phase, p[3])) end
	if p[2] and inPhase < 6 then joypad.set({ [p[2]] = true }) end
	inPhase = inPhase + 1
	if inPhase >= p[1] then phase, inPhase = phase + 1, 0 end
end
MESHGHOST_DEV_TICK = tick
if not MESHGHOST_DEV_LOADER then while true do tick(); emu.frameadvance() end end
