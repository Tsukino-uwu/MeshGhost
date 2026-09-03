-- MeshGhost — BizHawk cheat-API probe (DEVELOPMENT TOOL, never shipped)
--
-- WHAT AND WHY
-- Reaching the game states an adapter still cannot handle -- surfing, both bikes, a specific map
-- on the far side of the region -- costs real hours of play per test. The emulator can shortcut
-- that with cheat codes, and BizHawk exposes its cheat engine to Lua (client.addcheat /
-- client.removecheat / client.opencheats, found in BizHawk.Client.Common.dll's API surface), so
-- the shortcut can be driven from here instead of typed into a dialog by hand.
--
-- This probe answers the question that has to come first: WHICH CODE FORMATS DOES THIS BUILD
-- ACTUALLY ACCEPT? BizHawk ships a `GbaGameSharkDecoder` and no CodeBreaker decoder that I can
-- find, while the surf/dive codes we have are documented as CodeBreaker-type. That is a real
-- difference, not a naming quibble: the two formats use different encryption, so a CodeBreaker
-- code fed to a GameShark decoder does not fail loudly -- it decodes to a DIFFERENT address and
-- writes there.
--
-- SAFETY
-- Each code here needs its own button combination to fire, and this probe presses nothing, so an
-- accepted code sits inert in the list. Codes are left added so the Cheats dialog can be read;
-- clear them there when done. The
-- MeshGhost adapter itself never touches cheats; this is the emulator's own feature, used by a
-- tester, and it is deliberately a separate file from any adapter.
--
-- HOW TO RUN
--   Point dev-scripts/bizhawk-dev-loader.target at this file. Results go to the Lua Console and
--   to bizhawk-cheat-probe.log beside this script, then it goes quiet.

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

-- Report the API surface before using it. A doc string in the DLL is not proof a function is
-- callable at runtime -- that exact trap was found live here on 2026-08-14, when
-- memory.hash_region turned out to be nil despite having a doc string (agent_docs/environment.md).
for _, name in ipairs({ "addcheat", "removecheat", "opencheats" }) do
	log(string.format("  client.%-12s -> %s", name, type(client and client[name])))
end

if type(client) ~= "table" and type(client) ~= "userdata" then
	log("FATAL: no `client` library in this Lua host.")
	MESHGHOST_DEV_TICK = function() end
	return
end

-- NLua exposes a .NET method as `userdata`, not `function`, and it is still callable -- so the
-- type name alone cannot decide this. Call it and see, which is the same posture the memory-API
-- trap above teaches.
if client.addcheat == nil then
	log("client.addcheat does not exist in this build -- cheats would have to be entered by hand")
	log("in the Cheats dialog (Tools -> Cheats), or loaded from a .cht file.")
	MESHGHOST_DEV_TICK = function() end
	return
end

-- addcheat's own doc string reads: client.addcheat("NNNPAK") -- "adds a cheat code, IF
-- SUPPORTED". That last clause is the whole question: a pcall returning true only means the Lua
-- call did not throw, and an unsupported format is a silent no-op. So the verdict cannot come
-- from this script -- it comes from the Cheats dialog, which is opened at the end.
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
