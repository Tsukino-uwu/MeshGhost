-- MeshGhost PAWN DIFF (2026-09-09): READ-ONLY. Every 4 s for 120 s, every plain-valued property
-- (bool, int, float, double, byte, enum, name, string) of the PLAYER's pawn class is read on the
-- player's pawn and on every OTHER pawn of that class (the ghosts), and the ones that DIFFER are
-- written in full to `pawndiff-<HHMMSS>.log` beside this mod; the same for the game-instance
-- object each pawn holds as `As MV Game Instance Ref`. The question: with health 80 on the driven
-- ghost's own instance, what ELSE differs between the player and the ghost that a sit could read.
-- Nothing is filtered before the file; the UE4SS.log line per snapshot is a count plus the ghost's
-- moveState/actionState so the sit's snapshot can be found. Named reads only; nothing written,
-- nothing called, no object-valued property dereferenced except the game-instance ref (an object
-- this adapter itself constructed or the game's own singleton, both live). Hot-loaded over the
-- scratch slot; restore the stub afterwards. Dev-only; never ships.

local TAG = "[MeshGhostPawnDiff]"
local PERIOD_MS = 4000
local TOTAL_S = 120
local PLAIN = { BoolProperty = true, IntProperty = true, FloatProperty = true, DoubleProperty = true,
                ByteProperty = true, EnumProperty = true, NameProperty = true, StrProperty = true,
                Int64Property = true, UInt32Property = true, Int8Property = true, Int16Property = true, UInt16Property = true }

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*[\\/])") or "./"
end
local OUT_PATH = scriptDir() .. "../pawndiff-" .. os.date("%H%M%S") .. ".log"
local out = io.open(OUT_PATH, "a")
local function log(line) print(TAG .. " " .. line .. "\n") end
local function fout(line) if out then out:write(line, "\n") end end

local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end
local function fname_str(x)
    local s
    pcall(function() s = x:GetFName():ToString() end)
    return s or "?"
end
local function addr_of(x)
    local a
    pcall(function() a = x:GetAddress() end)
    return a
end
local function plain(value)
    local t = type(value)
    if t == "boolean" or t == "number" or t == "string" or t == "nil" then return value end
    if t == "userdata" then
        local got
        if pcall(function() got = value:get() end) and got ~= nil and type(got) ~= "userdata" then return got end
        local s
        if pcall(function() s = value:ToString() end) and type(s) == "string" then return s end
        return "<userdata>"
    end
    return "<" .. t .. ">"
end

-- Every plain-valued property name of a class chain: { {key=Class.Prop, name=Prop}, ... }.
local function plain_props(obj)
    local list, walked = {}, 0
    local cls = obj:GetClass()
    while cls and cls:IsValid() do
        local cname = fname_str(cls)
        cls:ForEachProperty(function(prop)
            walked = walked + 1
            local pclass, pname = "?", "?"
            pcall(function() pclass = prop:GetClass():GetFName():ToString() end)
            pcall(function() pname = prop:GetFName():ToString() end)
            if PLAIN[pclass] then
                list[#list + 1] = { key = cname .. "." .. pname, name = pname, ptype = pclass }
            end
        end)
        local sup = nil
        pcall(function() sup = cls:GetSuperStruct() end)
        if sup and sup ~= cls and sup:IsValid() then cls = sup else cls = nil end
    end
    return list, walked
end

local function read_all(obj, props)
    local vals, errors = {}, 0
    for _, p in ipairs(props) do
        local ok, v = pcall(function() return plain(obj[p.name]) end)
        if ok then vals[p.key] = v else vals[p.key] = "<error>"; errors = errors + 1 end
    end
    return vals, errors
end

local function fmt(v)
    if type(v) == "number" then return string.format("%.4g", v) end
    return tostring(v)
end

local function diff_report(label, a_vals, b_vals, props)
    local n = 0
    for _, p in ipairs(props) do
        local a, b = a_vals[p.key], b_vals[p.key]
        if a ~= b then
            n = n + 1
            fout(string.format("  %s %s (%s): player=%s ghost=%s", label, p.key, p.ptype, fmt(a), fmt(b)))
        end
    end
    return n
end

local function player_pawn()
    local pcs = FindAllOf("PlayerController")
    if not pcs then return nil end
    for _, pc in pairs(pcs) do
        if valid(pc) then
            for _, field in ipairs({ "AcknowledgedPawn", "Pawn" }) do
                local pawn
                pcall(function() pawn = pc[field] end)
                if pawn ~= nil and valid(pawn) then return pawn end
            end
        end
    end
    return nil
end

local function controller_class(pawn)
    local c
    pcall(function() c = pawn.Controller end)
    if c == nil or not valid(c) then return "<none>" end
    local cn = "?"
    pcall(function() cn = c:GetClass():GetFName():ToString() end)
    return cn
end

local t_start = os.clock()
local snapshots = 0
local pawn_props, gi_props = nil, nil
log("loaded -- " .. TOTAL_S .. " s of snapshots every " .. PERIOD_MS .. " ms, full diffs to " .. OUT_PATH)
fout("pawndiff started " .. os.date("%H:%M:%S"))

LoopAsync(PERIOD_MS, function()
    local elapsed = os.clock() - t_start
    if elapsed > TOTAL_S then
        log("done after " .. snapshots .. " snapshot(s); file " .. OUT_PATH)
        fout("pawndiff done " .. os.date("%H:%M:%S"))
        if out then out:close(); out = nil end
        return true
    end
    local me = player_pawn()
    if not me then log("no player pawn this snapshot"); return false end
    local my_class = "?"
    pcall(function() my_class = me:GetClass():GetFName():ToString() end)
    local my_addr = addr_of(me)
    if not pawn_props then
        local walked
        pawn_props, walked = plain_props(me)
        log(string.format("pawn class %s: %d plain-valued of %d properties walked", my_class, #pawn_props, walked))
    end
    local my_vals, my_err = read_all(me, pawn_props)
    local my_gi
    pcall(function() my_gi = me["As MV Game Instance Ref"] end)
    local my_gi_vals = nil
    if my_gi ~= nil and valid(my_gi) then
        if not gi_props then
            local walked
            gi_props, walked = plain_props(my_gi)
            log(string.format("game instance class %s: %d plain-valued of %d walked", fname_str(my_gi:GetClass()), #gi_props, walked))
        end
        my_gi_vals = read_all(my_gi, gi_props)
    end
    local all = FindAllOf(my_class) or {}
    snapshots = snapshots + 1
    fout(string.format("--- snapshot %d at t=%.0fs %s (player %s, %d pawn(s) of class %s, %d read errors on the player)",
        snapshots, elapsed, os.date("%H:%M:%S"), tostring(my_addr), #all, my_class, my_err))
    local ghosts = 0
    for _, p in pairs(all) do
        if valid(p) and addr_of(p) ~= my_addr then
            ghosts = ghosts + 1
            local gname = fname_str(p)
            local cc = controller_class(p)
            local vals, err = read_all(p, pawn_props)
            fout(string.format(" ghost %s controller=%s moveState=%s actionState=%s (%d read errors)",
                gname, cc, fmt(vals[my_class .. ".moveState"]), fmt(vals[my_class .. ".actionState"]), err))
            local n = diff_report("PAWN", my_vals, vals, pawn_props)
            local gi_line = "gi=<none>"
            local g_gi
            pcall(function() g_gi = p["As MV Game Instance Ref"] end)
            local gn = -1
            if g_gi ~= nil and valid(g_gi) and my_gi_vals and gi_props then
                local same = (addr_of(g_gi) == addr_of(my_gi))
                local gvals = read_all(g_gi, gi_props)
                gn = diff_report("GI", my_gi_vals, gvals, gi_props)
                gi_line = string.format("gi=%s%s", fname_str(g_gi), same and " (SHARED with the player)" or " (private)")
            end
            fout(string.format("  => %s: %d pawn field(s) differ, %d game-instance field(s) differ, %s", gname, n, gn, gi_line))
            log(string.format("snapshot %d %s ctl=%s moveState=%s actionState=%s: %d pawn diffs, %d gi diffs, %s",
                snapshots, gname, cc, fmt(vals[my_class .. ".moveState"]), fmt(vals[my_class .. ".actionState"]), n, gn, gi_line))
        end
    end
    if ghosts == 0 then log("snapshot " .. snapshots .. ": no other pawn of class " .. my_class) end
    if out then out:flush() end
    return false
end)
