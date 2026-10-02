-- Object census and frame time: what stays resident after a ghost leaves, and what it costs. Request files beside
-- the mod's Scripts folder, each consumed once:
--   census_request.txt  <label>    -- FindAllOf counts of the WATCH classes below; the instrument for every cycle.
--   ft_request.txt      <label>    -- the world's last frame delta 20x/s for FT_SECONDS: mean, median, p95, worst.
--   walk_request.txt    <label>    -- the full walk: every UObject bucketed by class (ForEachUObject), diffed
--                                     against the first walk, new objects named with their flags.
--   cmd_request.txt     <command>  -- one console command on the game thread, the one thing here that is not a read.
-- A Lua error inside ForEachUObject's callback aborts the game past any pcall, so the callback only appends, and
-- the walk is a fresh-launch instrument: never hot-reload a changed copy and then walk.

local TAG = "[MeshGhostCensus]"
local TICK_MS = 50
local FT_SECONDS = 10
local MAX_NAMES_PER_CLASS = 40

local WATCH = {
    "BP_PlayerCam_C", "SpringArmComponent", "CameraComponent", "TimelineComponent",
    "BP_PlayerGoatMain_C", "AIController", "NiagaraComponent",
}
local FLAG_FIELDS = { "bHiddenInGame", "bIsActive", "bVisible", "bAutoActivate", "bHidden", "bActorIsBeingDestroyed" }

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*[\\/])") or "./"
end
local MOD_ROOT = scriptDir() .. "../"
local LOG_PATH = MOD_ROOT .. "census.log"
local REQUESTS = {
    census = MOD_ROOT .. "census_request.txt",
    ft     = MOD_ROOT .. "ft_request.txt",
    walk   = MOD_ROOT .. "walk_request.txt",
    cmd    = MOD_ROOT .. "cmd_request.txt",
}

local UEHelpers = require("UEHelpers")

local function out(line)
    print(TAG .. " " .. line .. "\n")
    local f = io.open(LOG_PATH, "a")
    if f then f:write(line, "\n"); f:close() end
end

local function consume(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("*a") or ""
    f:close()
    os.remove(path)
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then text = "unlabelled" end
    return text
end

local function count_of(class_name)
    local ok, objs = pcall(FindAllOf, class_name)
    if not ok or not objs then return 0 end
    local n = 0
    for _ in pairs(objs) do n = n + 1 end
    return n
end

local function watch_line()
    local parts = {}
    for _, cls in ipairs(WATCH) do
        parts[#parts + 1] = string.format("%s=%d", cls, count_of(cls))
    end
    return table.concat(parts, " ")
end

---------------------------------------------------------------------------- counts

local function take_counts(label)
    out(string.format("COUNTS '%s' at %s: %s", label, os.date("%H:%M:%S"), watch_line()))
end

---------------------------------------------------------------------------- frame time

local ft = nil -- { label=, samples={}, ends_at= }

local function ft_sample()
    if ft == nil then return end
    local ok, dt = pcall(function()
        local world = UEHelpers.GetWorld()
        if world == nil or not world:IsValid() then return nil end
        local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        if statics == nil or not statics:IsValid() then return nil end
        return statics:GetWorldDeltaSeconds(world)
    end)
    if ok and dt ~= nil and dt > 0 then
        ft.samples[#ft.samples + 1] = dt * 1000.0
    end
    if os.time() >= ft.ends_at then
        local s = ft.samples
        table.sort(s)
        local n = #s
        if n == 0 then
            out(string.format("FRAMETIME '%s': no samples (GetWorldDeltaSeconds unavailable or world nil)", ft.label))
        else
            local sum = 0
            for _, v in ipairs(s) do sum = sum + v end
            local mean = sum / n
            local median = s[math.max(1, math.floor(n * 0.5))]
            local p95 = s[math.max(1, math.floor(n * 0.95))]
            out(string.format("FRAMETIME '%s': %d samples over %ds -- mean %.2f ms (%.1f fps), median %.2f, p95 %.2f, worst %.2f | %s",
                ft.label, n, FT_SECONDS, mean, 1000.0 / mean, median, p95, s[n], watch_line()))
        end
        ft = nil
    end
end

---------------------------------------------------------------------------- full walk

local function safe_full_name(obj)
    local ok, name = pcall(function() return obj:GetFullName() end)
    if ok and name then return name end
    return "<GetFullName failed>"
end

local function safe_class_name(obj)
    local ok, name = pcall(function() return obj:GetClass():GetFName():ToString() end)
    if ok and name then return name end
    return "<class?>"
end

local function safe_addr(obj)
    local ok, addr = pcall(function() return obj:GetAddress() end)
    if ok then return addr end
    return nil
end

local function flags_of(obj)
    local parts = {}
    for _, field in ipairs(FLAG_FIELDS) do
        local ok, v = pcall(function() return obj[field] end)
        if ok and v ~= nil and type(v) ~= "userdata" then
            parts[#parts + 1] = string.format("%s=%s", field, tostring(v))
        end
    end
    if #parts == 0 then return "" end
    return "  [" .. table.concat(parts, " ") .. "]"
end

local baseline = nil   -- { label=, counts={class->n}, addrs={class->{addr->true}}, no= }
local previous = nil
local walk_no = 0

local function take_walk(label)
    walk_no = walk_no + 1
    -- Collect only: an error in here aborts the game, and a table append cannot raise.
    local everything = {}
    local t0 = os.clock()
    ForEachUObject(function(obj, chunk_index, object_index)
        everything[#everything + 1] = obj
    end)
    local walk_ms = (os.clock() - t0) * 1000.0

    local counts, addrs, objs = {}, {}, {}
    for _, obj in ipairs(everything) do
        local cls = safe_class_name(obj)
        counts[cls] = (counts[cls] or 0) + 1
        local addr = safe_addr(obj)
        if addr ~= nil then
            local set = addrs[cls]
            if set == nil then set = {}; addrs[cls] = set end
            set[addr] = true
            local list = objs[cls]
            if list == nil then list = {}; objs[cls] = list end
            list[#list + 1] = { addr = addr, obj = obj }
        end
    end
    local snap = { label = label, counts = counts, addrs = addrs, no = walk_no }

    out(string.format("===== walk #%d '%s' at %s: %d objects, walk %.0f ms =====",
        walk_no, label, os.date("%H:%M:%S"), #everything, walk_ms))

    local function diff_against(ref, ref_name, with_names)
        if ref == nil then return end
        local moved = {}
        local all_classes = {}
        for cls in pairs(counts) do all_classes[cls] = true end
        for cls in pairs(ref.counts) do all_classes[cls] = true end
        for cls in pairs(all_classes) do
            local d = (counts[cls] or 0) - (ref.counts[cls] or 0)
            if d ~= 0 then moved[#moved + 1] = { cls = cls, d = d, n = counts[cls] or 0 } end
        end
        table.sort(moved, function(a, b)
            if math.abs(a.d) ~= math.abs(b.d) then return math.abs(a.d) > math.abs(b.d) end
            return a.cls < b.cls
        end)
        out(string.format("-- vs %s '%s' (#%d): %d class(es) moved", ref_name, ref.label, ref.no, #moved))
        for _, m in ipairs(moved) do
            out(string.format("   %+5d  %-40s now %d", m.d, m.cls, m.n))
        end
        if not with_names then return end
        for _, m in ipairs(moved) do
            if m.d > 0 then
                local ref_set = ref.addrs[m.cls] or {}
                local shown, new_total = 0, 0
                for _, entry in ipairs(objs[m.cls] or {}) do
                    if not ref_set[entry.addr] then
                        new_total = new_total + 1
                        if shown < MAX_NAMES_PER_CLASS then
                            shown = shown + 1
                            out(string.format("      NEW %s%s", safe_full_name(entry.obj), flags_of(entry.obj)))
                        end
                    end
                end
                if new_total > shown then
                    out(string.format("      ... %d more new %s not listed", new_total - shown, m.cls))
                end
            end
        end
    end

    diff_against(previous, "previous", false)
    if baseline ~= nil then diff_against(baseline, "BASELINE", true) end
    if baseline == nil then
        baseline = snap
        out("   (this walk is the BASELINE; every later one lists what is new since it)")
    end
    previous = snap
    out(string.format("===== end walk #%d =====", walk_no))
end

---------------------------------------------------------------------------- console command

-- For t.MaxFPS 0 while measuring: at the 144 cap the frame delta is a flat line and a leaked tick is invisible.
-- Session-only, nothing reaches GameUserSettings.ini; t.MaxFPS 144 puts the cap back.
local function run_console(cmd)
    local ok, err = pcall(function()
        local world = UEHelpers.GetWorld()
        local ksl = UEHelpers.GetKismetSystemLibrary()
        ksl:ExecuteConsoleCommand(world, cmd, nil)
    end)
    out(string.format("CONSOLE '%s': %s", cmd, ok and "sent (confirm by the next FRAMETIME line, not by this)" or ("FAILED " .. tostring(err))))
end

---------------------------------------------------------------------------- one loop, never two

-- One loop services every request, at most one started per tick, so nothing this probe does overlaps.
LoopAsync(TICK_MS, function()
    if ft ~= nil then
        ExecuteInGameThread(ft_sample)
        return false
    end
    local label = consume(REQUESTS.ft)
    if label ~= nil then
        ft = { label = label, samples = {}, ends_at = os.time() + FT_SECONDS }
        out(string.format("FRAMETIME '%s': sampling for %ds...", label, FT_SECONDS))
        return false
    end
    label = consume(REQUESTS.cmd)
    if label ~= nil then
        ExecuteInGameThread(function() run_console(label) end)
        return false
    end
    label = consume(REQUESTS.census)
    if label ~= nil then
        ExecuteInGameThread(function()
            local ok, err = pcall(take_counts, label)
            if not ok then out("COUNTS FAILED: " .. tostring(err)) end
        end)
        return false
    end
    label = consume(REQUESTS.walk)
    if label ~= nil then
        ExecuteInGameThread(function()
            local ok, err = pcall(take_walk, label)
            if not ok then out("WALK FAILED: " .. tostring(err)) end
        end)
        return false
    end
    return false
end)

out(string.format("census probe loaded -- requests: census_request.txt / ft_request.txt / walk_request.txt beside %s; log at %s", MOD_ROOT, LOG_PATH))
