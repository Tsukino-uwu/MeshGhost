-- MeshGhost — BizHawk dev loader (DEVELOPMENT TOOL, never shipped)
--
-- WHY THIS EXISTS
-- BizHawk can be handed a Lua script on the command line (--lua=...), but attaching, swapping or
-- stopping a script on an ALREADY-RUNNING instance is a Lua Console GUI action, which nothing
-- outside the emulator can drive. During adapter work that means one full emulator relaunch per
-- script revision -- Crystal's spawn investigation went through seven spawn_test scripts, so
-- seven relaunches, each one a real interruption to whoever is holding the controller.
--
-- This loader is attached ONCE at launch and then watches a plain text control file. Whatever
-- scripts that file names get loaded and ticked; change the file and the loader swaps to the new
-- set on the next poll, with no relaunch and without disturbing the running game.
--
-- CONTROL FILE
-- Default: bizhawk-dev-loader.target next to this file. Either
--   - one or more paths to .lua files, ONE PER LINE (absolute, or relative to the control file's
--     own directory). ALL of them load and ALL of them tick, in order -- so an adapter and a
--     test-state script can run at the same time; or
--   - the word `none` / an empty file, meaning "run nothing" -- the detach case.
-- Lines starting with # are ignored, as is leading/trailing whitespace.
--
-- The loader reloads when the resulting SET OF PATHS changes, not when the file's bytes do -- so
-- touching the file, or editing a comment in it, does NOT re-run anything. To force a reload of
-- an unchanged set (after editing a target script), drop a path and add it back. Worth knowing:
-- it looks exactly like the loader having stopped polling.
--
-- With TWO emulators open at once (a two-game session), set MESHGHOST_DEV_LOADER_TARGET per
-- instance before launching it -- otherwise both poll the same file, load the same scripts and
-- write one interleaved log, so neither can be driven on its own. The log is named after the
-- control file.
--
-- Multiple targets were added 2026-08-18, because one slot turned out to be a false constraint:
-- keeping a test-state script alive (it tops up a countdown every frame) meant dropping the
-- adapter, so the two could never run together and each swap silently undid the other's work.
--
-- PREFER ABSOLUTE PATHS. A relative path is resolved against BizHawk's working directory, which
-- is not necessarily this folder -- and a script that then loads a DLL relative to itself fails
-- with "The specified module could not be found", an error that reads as a missing file when the
-- file is present. Found live 2026-08-18 loading the Emerald adapter, which loads LuaSocket.
--
-- CONTRACT FOR A LOADABLE SCRIPT
-- A script written for this loader must NOT run its own `while true ... emu.frameadvance()` loop
-- (two such loops cannot coexist). Instead it sets:
--
--     MESHGHOST_DEV_TICK = function() ... end   -- called once per frame by the loader
--
-- and may check the global `MESHGHOST_DEV_LOADER` (true here) to decide whether to run its own
-- standalone loop, so the same file still works when opened directly in the Lua Console.
-- Optionally it may also set:
--
--     MESHGHOST_DEV_UNLOAD = function() ... end -- called when the loader drops it (close files,
--                                              -- despawn what it created), best-effort.
--
-- SAFETY
-- The loader never touches game memory itself. A target that errors during its tick is unloaded
-- and skipped rather than being allowed to kill the session or spam the console every frame; the
-- others keep running. A failed target is not retried until the control file changes.

local POLL_FRAMES = 30 -- half a second at 60fps; the control file is tiny and this is a dev tool

local function scriptDir()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end

local DIR = scriptDir()

-- One control file per emulator, when there is more than one. Two BizHawk instances (a
-- two-game session -- Emerald and Crystal side by side) share this folder, so a single
-- hardcoded control file makes them load the SAME target set and write into one interleaved
-- log: neither can be driven independently, which is the whole point of the loader. Set
-- MESHGHOST_DEV_LOADER_TARGET before launching an instance to give it its own. Absolute, or
-- relative to this folder. The log follows the control file's name so the pairing is obvious.
local CONTROL_FILE = os.getenv("MESHGHOST_DEV_LOADER_TARGET")
if CONTROL_FILE and CONTROL_FILE ~= "" then
	if not CONTROL_FILE:match("^%a:[/\\]") and not CONTROL_FILE:match("^[/\\]") then
		CONTROL_FILE = DIR .. "/" .. CONTROL_FILE
	end
else
	CONTROL_FILE = DIR .. "/bizhawk-dev-loader.target"
end

local LOG_FILE = CONTROL_FILE:gsub("%.target$", "") .. ".log"
if LOG_FILE == CONTROL_FILE then
	LOG_FILE = CONTROL_FILE .. ".log"
end

local logfile
do
	local f = io.open(LOG_FILE, "a")
	if f then logfile = f end
end

local function log(msg)
	local line = string.format("[loader] %s", msg)
	console.log(line)
	if logfile then
		logfile:write(os.date("%Y-%m-%d %H:%M:%S "), line, "\n")
		logfile:flush()
	end
end

local function readControl()
	local f = io.open(CONTROL_FILE, "r")
	if not f then return {} end
	local paths = {}
	for line in f:lines() do
		line = line:match("^%s*(.-)%s*$")
		if line ~= "" and line:sub(1, 1) ~= "#" and line:lower() ~= "none" then
			if not line:match("^%a:[/\\]") and not line:match("^[/\\]") then
				line = DIR .. "/" .. line
			end
			paths[#paths + 1] = line
		end
	end
	f:close()
	return paths
end

local function sameList(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do
		if a[i] ~= b[i] then return false end
	end
	return true
end

-- loaded[i] = { path, tick, unload }, in control-file order.
local loaded = {}
local loadedPaths = {}
local failed = {} -- paths that errored; not retried until the control file changes

local function dropAll(why)
	for _, entry in ipairs(loaded) do
		if entry.unload then pcall(entry.unload) end
		log(string.format("dropped %s (%s)", entry.path, why))
	end
	loaded = {}
	loadedPaths = {}
	MESHGHOST_DEV_TICK, MESHGHOST_DEV_UNLOAD = nil, nil
	-- A dropped script may have left an overlay behind; clearing here means a swap never leaves
	-- stale graphics on screen being misread as the new script's output.
	pcall(gui.clearGraphics)
end

-- REFUSE A SCRIPT THAT WOULD NEVER GIVE THE FRAME LOOP BACK.
--
-- A target carrying its own `while true ... emu.frameadvance()` and no MESHGHOST_DEV_TICK does not
-- fail -- it runs, forever, INSIDE loadTarget's pcall. The loader never returns to its own loop, so
-- it stops polling the control file and every other target (the adapter included) silently stops
-- ticking while the game carries on at full speed. From outside that is indistinguishable from the
-- loader having died, and the only way out is restarting the emulator.
--
-- Found live 2026-08-19 with probes/surf_bike_probe.lua, one of ~33 probes written before this
-- loader existed and never updated to its contract. They still work standalone, which is why the
-- answer is a guard here rather than a rewrite of all of them: this file is the one place that
-- knows a script is about to be loaded into a shared frame loop.
--
-- Text inspection, not execution, because by the time the chunk runs it is already too late.
local function wouldHijackFrameLoop(path)
	local f = io.open(path, "r")
	if not f then return false end
	local src = f:read("*a") or ""
	f:close()
	local loops = src:match("while%s+true%s+do") or src:match("emu%.frameadvance")
	return loops ~= nil and not src:match("MESHGHOST_DEV_TICK")
end

local function loadTarget(path)
	if wouldHijackFrameLoop(path) then
		log("REFUSED " .. path .. " -- it runs its own frame loop and sets no MESHGHOST_DEV_TICK, "
			.. "so loading it here would freeze every other target. Open it directly in the Lua "
			.. "Console instead, or give it the `if MESHGHOST_DEV_LOADER then ... end` contract "
			.. "from this file's header.")
		failed[path] = true
		return false
	end
	MESHGHOST_DEV_TICK, MESHGHOST_DEV_UNLOAD = nil, nil
	local chunk, err = loadfile(path)
	if not chunk then
		log("LOAD FAILED: " .. tostring(err))
		failed[path] = true
		return false
	end
	local ok, runErr = pcall(chunk)
	if not ok then
		log("RUN FAILED: " .. tostring(runErr))
		failed[path] = true
		return false
	end
	if type(MESHGHOST_DEV_TICK) ~= "function" then
		log("LOADED but set no MESHGHOST_DEV_TICK -- it ran once and will not be ticked.")
	end
	loaded[#loaded + 1] = { path = path, tick = MESHGHOST_DEV_TICK, unload = MESHGHOST_DEV_UNLOAD }
	failed[path] = nil
	log("loaded " .. path)
	return true
end

MESHGHOST_DEV_LOADER = true

log("=== MeshGhost BizHawk dev loader ===")
log("control file: " .. CONTROL_FILE)
log("one .lua path per line to attach (absolute preferred); `none` to detach.")

local frames = 0

while true do
	frames = frames + 1

	if frames % POLL_FRAMES == 0 then
		local want = readControl()
		if not sameList(want, loadedPaths) then
			dropAll("control file changed")
			-- Clear the failure memory on every change: editing the file is how you say "I fixed
			-- it, try again". Without this the loader silently ignored the retry, which looks
			-- exactly like the fix not working -- found live 2026-08-18, chasing a path bug that
			-- had already been fixed.
			failed = {}
			for _, path in ipairs(want) do loadTarget(path) end
			loadedPaths = want
		end
	end

	-- Backwards so removing a broken target mid-loop cannot skip the next one.
	for i = #loaded, 1, -1 do
		local entry = loaded[i]
		if entry.tick then
			local ok, err = pcall(entry.tick)
			if not ok then
				log("TICK ERROR in " .. tostring(entry.path) .. ": " .. tostring(err))
				if entry.unload then pcall(entry.unload) end
				failed[entry.path] = true
				table.remove(loaded, i)
			end
		end
	end

	emu.frameadvance()
end
