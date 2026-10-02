-- Is a luanet spawn invisible? os.execute and io.popen always flash (they run cmd /c, whose window is the shell's), and
-- luanet reaches System.Diagnostics.Process once System is loaded; only a person watching can say whether a hidden
-- spawn shows anything. Three counted-down phases:
--   1. cmd.exe, CreateNoWindow=true, UseShellExecute=false   expected invisible
--   2. the same, launching meshghost.exe -h                  expected invisible
--   3. control: Process.Start("cmd.exe", args)               should flash
-- If phase 3 does not flash, discard the run: phases 1-2 proved nothing.

local DIR = os.getenv("MESHGHOST_SCRIPT_DIR")
if not DIR or DIR == "" then
    local info = debug.getinfo(1, "S")
    DIR = (info and info.source and info.source:sub(1, 1) == "@"
        and info.source:sub(2):match("^(.*)[/\\]")) or "."
end
local REPO = DIR:match("^(.*)[/\\][^/\\]*$") or DIR

local logfile = io.open(DIR .. "/../dev-logs/bizhawk-spawn-probe.log", "w")
local function log(m)
    console.log(m)
    if logfile then logfile:write(tostring(m), "\n") logfile:flush() end
end

local function marker(tag) return DIR .. "\\spawn_" .. tag .. ".txt" end

luanet.load_assembly("System")
local Process = luanet.import_type("System.Diagnostics.Process")
local StartInfo = luanet.import_type("System.Diagnostics.ProcessStartInfo")

local function hiddenSpawn(file, args)
    local si = StartInfo()
    si.FileName = file
    si.Arguments = args
    si.UseShellExecute = false
    si.CreateNoWindow = true
    Process.Start(si)
end

local PHASES = {
    {
        name = "1. cmd.exe with CreateNoWindow=true  -- expected INVISIBLE",
        run = function()
            os.remove(marker("hidden1"))
            hiddenSpawn("cmd.exe", '/c echo hidden1 > "' .. marker("hidden1") .. '"')
        end,
    },
    {
        name = "2. meshghost.exe -h, CreateNoWindow=true  -- the real case, expected INVISIBLE",
        run = function()
            os.remove(marker("hidden2"))
            -- -h prints usage and exits, so nothing is left running.
            hiddenSpawn(REPO .. "\\meshghost.exe", "-h")
            -- meshghost writes no marker; phase 1 already proves the mechanism works.
            local f = io.open(marker("hidden2"), "w")
            if f then f:write("attempted\n") f:close() end
        end,
    },
    {
        name = "3. CONTROL: Process.Start(cmd.exe, ...)  -- SHOULD FLASH",
        run = function()
            os.remove(marker("control"))
            Process.Start("cmd.exe", '/c echo control > "' .. marker("control") .. '"')
        end,
    },
}

log("=== spawn probe: is a luanet spawn invisible? ===")
log("Three phases, ~6s apart. Phase 3 is a control and SHOULD show a window.")
log("")

local frame, idx, phaseStart, state, finished = 0, 1, 0, "count", false

event.onframestart(function()
    frame = frame + 1
    if finished then return end

    if idx > #PHASES then
        log("")
        log("=== ran? (marker files) ===")
        for _, t in ipairs({ "hidden1", "hidden2", "control" }) do
            local f = io.open(marker(t), "r")
            log(string.format("  %-9s ran=%s", t, tostring(f ~= nil)))
            if f then f:close() end
        end
        log("")
        log("Now: which PHASE NUMBERS showed a window? Phase 3 should have.")
        finished = true
        return
    end

    local elapsed = frame - phaseStart
    if state == "count" then
        if elapsed == 1 then log("") log("--- " .. PHASES[idx].name) end
        local left = math.ceil((300 - elapsed) / 60)
        if elapsed % 60 == 0 and left > 0 then log("    in " .. left .. "...") end
        if elapsed >= 300 then
            log("    >>> NOW <<<")
            local ok, err = pcall(PHASES[idx].run)
            if not ok then log("    errored: " .. tostring(err)) end
            phaseStart, state = frame, "settle"
        end
    else
        if elapsed >= 120 then
            idx, phaseStart, state = idx + 1, frame, "count"
        end
    end
end)

log("Armed. First phase in ~5s.")
