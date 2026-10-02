-- Asks which cheat-code formats this build's client.addcheat accepts, before cheats are used to reach a game state.
-- The build has a GameShark decoder and no CodeBreaker one, and a code fed to the wrong decoder does not fail: it
-- decodes to a different address and writes there. Presses nothing; the codes stay in the list for the Cheats dialog
-- to be read, and bizhawk-cheat-clear.lua removes them.

local CODES = {
	{ name = "Littleroot Town warp (GameShark-style pair)", code = "F89BD08B ED8D449E" },
	{ name = "Route 101 warp (GameShark-style pair)", code = "7DE5E94F 91EB4C93" },
	{ name = "Surf, line 1 of 4 (CodeBreaker-style)", code = "D0000020 0004" },
	{ name = "Surf, line 2 of 4 (CodeBreaker-style)", code = "83000E48 1ED2" },
	{ name = "Dive, line 1 of 4 (CodeBreaker-style)", code = "74000130 02FB" },
	{ name = "Dive, line 2 of 4 (CodeBreaker-style)", code = "83000E48 0B45" },
}

local function scriptDir()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end

local logfile = io.open(scriptDir() .. "/../dev-logs/bizhawk-cheat-probe.log", "w")

local function log(msg)
	console.log(msg)
	if logfile then
		logfile:write(msg, "\n")
	end
end

log("=== MeshGhost BizHawk cheat-API probe ===")
log("Codes are added and LEFT in the list so the Cheats dialog can be read. None is armed.")

-- A doc string in the DLL is not proof a function is callable, so report what exists first.
for _, name in ipairs({ "addcheat", "removecheat", "opencheats" }) do
	log(string.format("  client.%-12s -> %s", name, type(client and client[name])))
end

if type(client) ~= "table" and type(client) ~= "userdata" then
	log("FATAL: no `client` library in this Lua host.")
	MESHGHOST_DEV_TICK = function() end
	return
end

-- NLua exposes a .NET method as userdata, still callable, so only nil rules it out.
if client.addcheat == nil then
	log("client.addcheat does not exist in this build -- cheats would have to be entered by hand")
	log("in the Cheats dialog (Tools -> Cheats), or loaded from a .cht file.")
	MESHGHOST_DEV_TICK = function() end
	return
end

-- addcheat adds a code "if supported": true only means no throw, so the Cheats dialog opened at the end is the verdict.
for _, entry in ipairs(CODES) do
	local ok, err = pcall(client.addcheat, entry.code)
	log(string.format("  %-46s called -> %s%s", entry.name, tostring(ok),
		(not ok) and (" (" .. tostring(err) .. ")") or ""))
end

log("")
log("Opening Tools -> Cheats. WHAT IS LISTED THERE IS THE ANSWER, not the `true`s above.")
log("Expectation to test, not to trust: the 8+8 map-warp pairs are GameShark GBA format and")
log("this build ships GbaGameSharkDecoder, so those should appear. The surf/dive lines are 8+4")
log("CodeBreaker format and I found no CodeBreaker decoder here, so those probably will not.")
log("Codes are left ADDED so they can be read; none of them is armed, since each needs its own")
log("button combination to fire. Clear them in that dialog when you are done looking.")
pcall(client.opencheats)

if logfile then
	pcall(function() logfile:flush() end)
		logfile:close()
	logfile = nil
end

MESHGHOST_DEV_TICK = function() end
