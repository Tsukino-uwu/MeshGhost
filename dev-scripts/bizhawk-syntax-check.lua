-- loadfile()s each file in FILES and reports whether it compiles under this build's embedded Lua, running none of them.

local FILES = {
	"../adapters/emulator/pokemon/emerald/meshghost_emerald.lua",
	"../adapters/emulator/pokemon/crystal/meshghost_crystal.lua",
	"../adapters/emulator/pokemon/crystal/probes/run_second_client.lua",
	"../adapters/emulator/pokemon/crystal/probes/oam_probe.lua",
	"../adapters/emulator/pokemon/crystal/probes/square_drive.lua",
	"../adapters/emulator/pokemon/crystal/probes/action_probe.lua",
	"../adapters/emulator/pokemon/emerald/probes/spawn_test.lua",
	"../adapters/emulator/pokemon/emerald/probes/object_slot_probe.lua",
	"../adapters/emulator/pokemon/emerald/probes/testkit.lua",
	"../adapters/emulator/pokemon/emerald/probes/oamshadow_probe.lua",
	"../adapters/emulator/pokemon/emerald/probes/oaminject_probe.lua",
	"../adapters/emulator/pokemon/emerald/probes/fpshold.lua",
	"../adapters/emulator/pokemon/emerald/probes/shadowdust_probe.lua",
	"../adapters/emulator/pokemon/emerald/probes/noclip.lua",
	"../adapters/emulator/pokemon/emerald/probes/facing_probe.lua",
	"../adapters/emulator/pokemon/emerald/probes/acro_hop.lua",
	"../adapters/emulator/pokemon/emerald/probes/romvariant_probe.lua",
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
local logfile = io.open(DIR .. "/../dev-logs/bizhawk-syntax-check.log", "w")

local function log(msg)
	console.log(msg)
	if logfile then
		logfile:write(msg, "\n")
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
	pcall(function() logfile:flush() end)
		logfile:close()
	logfile = nil
end

MESHGHOST_DEV_TICK = function() end
