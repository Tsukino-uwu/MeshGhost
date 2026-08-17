-- MeshGhost — Pokémon Crystal: "is the player actually in the game?" probe
--
-- READ-ONLY DIAGNOSTIC. Writes nothing, spawns nothing.
--
-- WHY THIS EXISTS
-- A ghost must never appear during the main menu, the intro, a loading step, or a cutscene. This
-- is not a Crystal quirk -- it is one of the most common adapter bugs there is, so the general
-- rule lives in adapters/_template/README.md and this probe is Crystal's instance of answering it.
--
-- The failure it prevents is not cosmetic. Spawning into a state the game does not consider "the
-- overworld" means writing object RAM the game is *currently rebuilding*, which is how you corrupt
-- something rather than merely look silly. And "the data looked plausible" is exactly the trap
-- CLAUDE.md warns about: during the menu the object slots are simply stale, so a naive check
-- passes and a ghost appears over the title screen.
--
-- WHAT IT MEASURES, and why these four
-- The right gate asks the GAME what state it is in, rather than inferring it from data shape --
-- the same reasoning as Emerald's inOverworld(), which reads the current callback pointer and
-- compares it to CB2_Overworld. Crystal's equivalents, all from our hash-verified build:
--
--   wMapStatus       01:d432  MAPSTATUS_START(0) / ENTER(1) / HANDLE(2) / DONE(3)
--                             The map state machine. HANDLE is the steady overworld state.
--   wMapEventStatus  01:d433  MAPEVENTS_ON(0) / MAPEVENTS_OFF(1)
--                             Off while the player is not free to act.
--   wScriptRunning   01:d438  non-zero while a script/cutscene is driving things
--   wGameLogicPaused 00:c2cd  bank-0 WRAM, so a different address mapping (see to_flat)
--
-- plus wMapGroup/wMapNumber, which were observed reading 0/0 at the main menu on 2026-08-17.
--
-- HOW TO RUN
--   1. Load the ROM but STAY ON THE TITLE/MAIN MENU. Start this script there -- that is the
--      state we most need characterised, and it is the one you cannot get back to without a reset.
--   2. Load a save (or start a new game and sit through the intro).
--   3. Walk around, open the START menu, enter a building, and if convenient start a battle.
--   4. Log: ingame_gate_<timestamp>.log beside this script. It prints only when something
--      CHANGES, so the log reads as a timeline of states rather than a wall of samples.

local DOMAIN = "WRAM"

-- Game Boy WRAM is banked: C000-CFFF is bank 0, D000-DFFF is the switchable bank (1 here).
-- The flat WRAM domain lays banks end to end, so the two halves map differently.
local function to_flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

local WATCH = {
	{ name = "wMapStatus", addr = to_flat(0xD432) },
	{ name = "wMapEventStatus", addr = to_flat(0xD433) },
	{ name = "wScriptRunning", addr = to_flat(0xD438) },
	{ name = "wGameLogicPaused", addr = to_flat(0xC2CD) },
	{ name = "wMapGroup", addr = to_flat(0xDCB5) },
	{ name = "wMapNumber", addr = to_flat(0xDCB6) },
	{ name = "wPlayerStepFlags", addr = to_flat(0xD150) },
}

local MAPSTATUS = { [0] = "START", [1] = "ENTER", [2] = "HANDLE", [3] = "DONE" }

-- Object slot 0 holds the player. Watching whether it exists is a useful cross-check: at the
-- main menu it was empty, and it is populated once the game spawns the player.
local OBJECT_STRUCTS = to_flat(0xD4D6)
local OBJECT_LENGTH = 0x28
local NUM_OBJECT_STRUCTS = 13

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/ingame_gate_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
end

local raw_log = console.log
local function log(msg)
	raw_log(msg)
	if logfile then
		logfile:write(msg, "\n")
		logfile:flush()
	end
end

local function u8(addr)
	local ok, v = pcall(memory.read_u8, addr, DOMAIN)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

local function slots_used()
	local n = 0
	for i = 0, NUM_OBJECT_STRUCTS - 1 do
		local s = u8(OBJECT_STRUCTS + (i * OBJECT_LENGTH))
		if s and s ~= 0 then
			n = n + 1
		end
	end
	return n
end

-- The gate this probe exists to validate. Stated here so the log shows what it WOULD have
-- decided at every moment, which is the only way to tell whether it is right before trusting it.
local function would_spawn(v)
	return v.wMapStatus == 2 -- MAPSTATUS_HANDLE: the steady overworld state
		and v.wMapEventStatus == 0 -- MAPEVENTS_ON: player is free to act
		and v.wScriptRunning == 0 -- no script or cutscene driving things
		and v.wGameLogicPaused == 0
		and not (v.wMapGroup == 0 and v.wMapNumber == 0)
		and v.slots > 0 -- the player object exists
end

open_log()
log("=== MeshGhost Crystal in-game gate probe (READ-ONLY) ===")
log("Prints only on change. Start on the MAIN MENU, then load a save and play.")
log("The 'gate' column is what a spawn guard would decide at that moment.")

local last = nil
local frames = 0

local function tick()
	frames = frames + 1
	if frames % 5 ~= 0 then
		return
	end

	local v = { slots = slots_used() }
	for _, w in ipairs(WATCH) do
		v[w.name] = u8(w.addr)
	end

	local key = string.format(
		"%s|%s|%s|%s|%s/%s|%d",
		tostring(v.wMapStatus), tostring(v.wMapEventStatus), tostring(v.wScriptRunning),
		tostring(v.wGameLogicPaused), tostring(v.wMapGroup), tostring(v.wMapNumber), v.slots
	)
	if key == last then
		return
	end
	last = key

	local gate = would_spawn(v) and "SPAWN-OK" or "blocked "
	log(string.format(
		"[%s] f=%-7d mapStatus=%-6s events=%s script=%s paused=%s map=%s/%s slots=%d",
		gate, frames,
		MAPSTATUS[v.wMapStatus] or tostring(v.wMapStatus),
		tostring(v.wMapEventStatus), tostring(v.wScriptRunning),
		tostring(v.wGameLogicPaused), tostring(v.wMapGroup), tostring(v.wMapNumber),
		v.slots
	))
end

while true do
	tick()
	emu.frameadvance()
end
