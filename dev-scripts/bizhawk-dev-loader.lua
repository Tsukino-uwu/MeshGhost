-- The BizHawk dev loader (never shipped): attached once at launch, it loads, ticks and drops whatever scripts a
-- control file names, so a script is swapped on a running emulator with no relaunch.
--
-- The control file (bizhawk-dev-loader.target beside this file, or MESHGHOST_DEV_LOADER_TARGET) holds one .lua path
-- per line, all loaded and ticked in order, or `none` or nothing to run nothing; `#` lines are ignored. A relative
-- path resolves against this folder. Prefer absolute: a target that loads a DLL relative to its own path fails with
-- "The specified module could not be found" when that path is relative. It reloads when the set of paths changes,
-- not the bytes, so to re-run an edited target, drop its line and add it back.
--
-- A target sets MESHGHOST_DEV_TICK (called once a frame) instead of running its own frame loop, may set
-- MESHGHOST_DEV_UNLOAD (called when it is dropped), and may check MESHGHOST_DEV_LOADER to run standalone otherwise.
-- One that errors in its tick is dropped and not retried until the control file changes.

local POLL_FRAMES = 30 -- half a second at 60fps

local function scriptDir()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end

local DIR = scriptDir()

-- One control file per emulator: two sharing one would load the same set and write one interleaved log.
local CONTROL_FILE = os.getenv("MESHGHOST_DEV_LOADER_TARGET")
if CONTROL_FILE and CONTROL_FILE ~= "" then
	if not CONTROL_FILE:match("^%a:[/\\]") and not CONTROL_FILE:match("^[/\\]") then
		CONTROL_FILE = DIR .. "/" .. CONTROL_FILE
	end
else
	CONTROL_FILE = DIR .. "/bizhawk-dev-loader.target"
end

-- The log goes to dev-logs/, named after the control file, which stays in dev-scripts/ where instructions name it.
local LOG_FILE = CONTROL_FILE:gsub("%.target$", ""):gsub("([/\\])([^/\\]+)$", "%1..%1dev-logs%1%2") .. ".log"
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
	-- A dropped script's leftover overlay would be misread as the new script's output.
	pcall(gui.clearGraphics)
end

-- A target with its own frame loop and no MESHGHOST_DEV_TICK never returns from loadTarget's pcall, silently freezing
-- the loader and every other target until the emulator restarts. Read as text: once the chunk runs it is too late.
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
			-- Every change clears the failures: editing the file is how a fixed target asks to be retried.
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
