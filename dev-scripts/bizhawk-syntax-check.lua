-- MeshGhost — BizHawk syntax check (DEVELOPMENT TOOL, never shipped)
--
-- Loads each named Lua file with loadfile() and reports whether it COMPILES. It never runs any of
-- them, so an adapter's own socket/frame loop is not started and nothing touches the game.
--
-- WHY THIS EXISTS
-- BizHawk embeds Lua 5.4; the machine has no standalone Lua binary, so before this there was no
-- way to answer "does this file even parse?" short of loading it into a real emulator session and
-- watching it either work or fail. Editing an adapter's connect path and finding out from a live
-- session is a slow and destructive way to catch a missing `end`.
--
-- HOW TO RUN
--   Point dev-scripts/bizhawk-dev-loader.target at this file. Results go to the Lua Console and
--   to bizhawk-syntax-check.log beside this script, then it goes quiet.

local FILES = {
	"../adapters/bizhawk/pokemon/emerald/meshghost_emerald.lua",
	"../adapters/bizhawk/pokemon/crystal/meshghost_crystal.lua",
	"../adapters/bizhawk/pokemon/crystal/probes/run_second_client.lua",
	"../adapters/bizhawk/pokemon/emerald/probes/spawn_test.lua",
	"../adapters/bizhawk/pokemon/emerald/probes/object_slot_probe.lua",
	"../adapters/bizhawk/pokemon/emerald/probes/testkit.lua",
	"../adapters/bizhawk/pokemon/emerald/probes/oamshadow_probe.lua",
	"../adapters/bizhawk/pokemon/emerald/probes/oaminject_probe.lua",
	"../dev-scripts/bizhawk-cheat-clear.lua",
	"../dev-scripts/bizhawk-dev-loader.lua",
}

local function scriptDir()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end

local DIR = scriptDir()
local logfile = io.open(DIR .. "/bizhawk-syntax-check.log", "w")

local function log(msg)
	console.log(msg)
	if logfile then
		logfile:write(msg, "\n")
		logfile:flush()
	end
end

log("=== MeshGhost syntax check (compile only, nothing is executed) ===")

local failures = 0
for _, rel in ipairs(FILES) do
	local path = DIR .. "/" .. rel
	local chunk, err = loadfile(path)
	if chunk then
		log(string.format("  OK      %s", rel))
	else
		failures = failures + 1
		log(string.format("  FAILED  %s", rel))
		log(string.format("          %s", tostring(err)))
	end
end

if failures == 0 then
	log(string.format("All %d files compile.", #FILES))
else
	log(string.format("%d of %d files FAILED to compile.", failures, #FILES))
end

if logfile then
	logfile:close()
	logfile = nil
end

-- Nothing to do per frame; the loader just holds an idle tick.
MESHGHOST_DEV_TICK = function() end
