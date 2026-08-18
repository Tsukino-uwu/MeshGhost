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
-- script path that file names gets loaded and ticked; change the file and the loader swaps to the
-- new script on the next poll, with no relaunch and without disturbing the running game.
--
-- CONTRACT FOR A LOADABLE SCRIPT
-- A script written for this loader must NOT run its own `while true ... emu.frameadvance()` loop
-- (two such loops cannot coexist). Instead it sets one global:
--
--     MESHGHOST_DEV_TICK = function() ... end   -- called once per frame by the loader
--
-- and may check the global `MESHGHOST_DEV_LOADER` (true here) to decide whether to run its own
-- standalone loop, so the same file still works when opened directly in the Lua Console.
-- Optionally it may also set:
--
--     MESHGHOST_DEV_UNLOAD = function() ... end -- called when the loader drops it (close files,
--                                              -- clear gui.*), best-effort, errors ignored.
--
-- CONTROL FILE
-- Default: bizhawk-dev-loader.target next to this file. One line, either
--   - a path to a .lua file (absolute, or relative to the control file's own directory), or
--   - the word `none` / an empty file, meaning "run nothing" -- the detach case.
-- The path may be followed by nothing else; leading/trailing whitespace is ignored.
--
-- SAFETY
-- The loader never touches game memory itself. A target's error is caught, logged, and the target
-- is dropped rather than being allowed to kill the session -- an infinite reload of a broken
-- script would otherwise spam the console and hide the real error. A dropped target is not
-- retried until the control file changes again.

local POLL_FRAMES = 30 -- half a second at 60fps; the control file is tiny and this is a dev tool

local function scriptDir()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end

local DIR = scriptDir()
local CONTROL_FILE = DIR .. "/bizhawk-dev-loader.target"

local logfile
do
	local f = io.open(DIR .. "/bizhawk-dev-loader.log", "a")
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
	if not f then return nil end
	local line = f:read("l")
	f:close()
	if not line then return nil end
	line = line:match("^%s*(.-)%s*$")
	if line == "" or line:lower() == "none" then return nil end
	if not line:match("^%a:[/\\]") and not line:match("^[/\\]") then
		line = DIR .. "/" .. line -- relative paths resolve against the control file's directory
	end
	return line
end

local currentPath, currentTick, currentUnload = nil, nil, nil
local failedPath = nil -- a target that errored; not retried until the control file changes

local function dropCurrent(why)
	if currentUnload then
		pcall(currentUnload)
	end
	if currentPath then
		log(string.format("dropped %s (%s)", currentPath, why))
	end
	currentPath, currentTick, currentUnload = nil, nil, nil
	MESHGHOST_DEV_TICK, MESHGHOST_DEV_UNLOAD = nil, nil
	-- A dropped script may have left an overlay behind; clearing here means a swap never leaves
	-- stale graphics on screen being misread as the new script's output.
	pcall(gui.clearGraphics)
end

local function loadTarget(path)
	MESHGHOST_DEV_TICK, MESHGHOST_DEV_UNLOAD = nil, nil
	local chunk, err = loadfile(path)
	if not chunk then
		log("LOAD FAILED: " .. tostring(err))
		failedPath = path
		return false
	end
	local ok, runErr = pcall(chunk)
	if not ok then
		log("RUN FAILED: " .. tostring(runErr))
		failedPath = path
		return false
	end
	if type(MESHGHOST_DEV_TICK) ~= "function" then
		log("LOADED but set no MESHGHOST_DEV_TICK -- it ran once and will not be ticked.")
		log("  (a loader target must set MESHGHOST_DEV_TICK; see this loader's header)")
	end
	currentPath = path
	currentTick = MESHGHOST_DEV_TICK
	currentUnload = MESHGHOST_DEV_UNLOAD
	failedPath = nil
	log("loaded " .. path)
	return true
end

MESHGHOST_DEV_LOADER = true

log("=== MeshGhost BizHawk dev loader ===")
log("control file: " .. CONTROL_FILE)
log("write a .lua path into it to attach; write `none` to detach.")

local frames = 0

while true do
	frames = frames + 1

	if frames % POLL_FRAMES == 0 then
		local want = readControl()
		if want ~= currentPath then
			if currentPath then dropCurrent("control file changed") end
			if want == nil then
				-- Detached. Clear the failure memory too: pointing away and back again is the
				-- obvious way to say "I fixed it, try once more", and without this the loader
				-- silently ignored the retry -- which looks exactly like the fix not working.
				-- Found live 2026-08-18, chasing a path bug that was already fixed.
				failedPath = nil
			elseif want ~= failedPath then
				loadTarget(want)
			end
		end
	end

	if currentTick then
		local ok, err = pcall(currentTick)
		if not ok then
			log("TICK ERROR in " .. tostring(currentPath) .. ": " .. tostring(err))
			local broken = currentPath
			dropCurrent("tick error")
			failedPath = broken
		end
	end

	emu.frameadvance()
end
