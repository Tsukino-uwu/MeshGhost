-- Outfit echo watch, read-only: after a peer's costume swap, does the local player's real mesh change, and what changed
-- just before it? Logs on change every player-class pawn's VisualMesh, and every property of the local pawn and its
-- game instance, unfiltered: scalars by value, objects as an address only (never a pointee), arrays as a length;
-- structs are skipped. The property list is built once per object, then read by name each sample. Runs 240 s.

local TAG = "[MeshGhostEchoWatch]"
local PERIOD_MS = 200
local TOTAL_MS = 240000

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*[\\/])") or "./"
end
local OUT_PATH = scriptDir() .. "../echowatch-" .. os.date("%H%M%S") .. ".log"
local out = io.open(OUT_PATH, "a")
local function log(line) print(TAG .. " " .. line .. "\n") end
local function stamp() return os.date("%H:%M:%S") .. string.format(".%03d", math.floor((os.clock() % 1) * 1000)) end
local function fout(line) if out then out:write(stamp(), " ", line, "\n") end end

local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end
local function prop(obj, name)
    local v
    if not obj or not pcall(function() v = obj[name] end) then return nil end
    return v
end
local function addr_of(obj)
    local ok, a = pcall(function() return obj:GetAddress() end)
    if ok and a then return string.format("0x%x", a) end
    return nil
end
local function fname_str(x) local s pcall(function() s = x:GetFName():ToString() end) return s or "?" end
local function full_str(x)
    if x == nil or not valid(x) then return "none" end
    local s pcall(function() s = x:GetFullName() end) return s or "?"
end

local SCALAR = {
    BoolProperty = true, IntProperty = true, Int8Property = true, Int16Property = true, Int64Property = true,
    UInt16Property = true, UInt32Property = true, UInt64Property = true, FloatProperty = true,
    DoubleProperty = true, ByteProperty = true, EnumProperty = true, StrProperty = true,
    NameProperty = true, TextProperty = true,
}
local OBJECTISH = {
    ObjectProperty = true, WeakObjectProperty = true, SoftObjectProperty = true, LazyObjectProperty = true,
    ClassProperty = true, SoftClassProperty = true, InterfaceProperty = true,
}

local function build_plan(obj)
    local plan = {}
    local cls = nil
    pcall(function() cls = obj:GetClass() end)
    while cls ~= nil and valid(cls) do
        pcall(function()
            cls:ForEachProperty(function(p)
                -- Append only inside the callback: a Lua error in here aborts past any pcall.
                local pc, pn = "?", "?"
                pcall(function() pc = p:GetClass():GetFName():ToString() end)
                pcall(function() pn = p:GetFName():ToString() end)
                plan[#plan + 1] = { name = pn, kind = pc }
            end)
        end)
        local sup = nil
        pcall(function() sup = cls:GetSuperStruct() end)
        if sup ~= nil and valid(sup) and addr_of(sup) ~= addr_of(cls) then cls = sup else cls = nil end
    end
    return plan
end

local function read_value(obj, entry)
    local v = prop(obj, entry.name)
    if SCALAR[entry.kind] then
        if v == nil then return "nil" end
        local t = type(v)
        if t == "boolean" or t == "number" or t == "string" then return tostring(v) end
        local s pcall(function() s = v:ToString() end)
        return s or tostring(v)
    elseif OBJECTISH[entry.kind] then
        if v == nil then return "null" end
        return addr_of(v) or "<no address>"
    elseif entry.kind == "ArrayProperty" then
        if v == nil then return "nil" end
        local n = "?"
        pcall(function() n = tostring(#v) end)
        return "len=" .. n
    end
    return nil -- skipped kind
end

local watched = {}   -- label -> {obj_addr, plan, last = {name -> value}}

local function watch_object(label, obj)
    if obj == nil or not valid(obj) then return end
    local a = addr_of(obj)
    local w = watched[label]
    if w == nil or w.addr ~= a then
        local plan = build_plan(obj)
        w = { addr = a, plan = plan, last = {} }
        watched[label] = w
        local n = 0
        for _, e in ipairs(plan) do
            local v = read_value(obj, e)
            if v ~= nil then w.last[e.name] = v n = n + 1 end
        end
        fout(string.format("WATCH %s = %s (%s) : %d readable properties baselined", label, a, full_str(obj), n))
        return
    end
    for _, e in ipairs(w.plan) do
        local v = read_value(obj, e)
        if v ~= nil and w.last[e.name] ~= v then
            fout(string.format("CHANGE %s.%s [%s]: %s -> %s", label, e.name, e.kind, tostring(w.last[e.name]), v))
            w.last[e.name] = v
        end
    end
end

local last_mesh = {}   -- pawn addr -> mesh full name
local elapsed = 0

log("loaded. " .. (TOTAL_MS / 1000) .. " s, read-only. Swap costume on the OTHER client and watch.")
log("full log: " .. OUT_PATH)

LoopAsync(PERIOD_MS, function()
    elapsed = elapsed + PERIOD_MS
    local ok, err = pcall(function()
        local pc = nil
        pcall(function() pc = FindFirstOf("PlayerController") end)
        local player = (pc ~= nil and valid(pc)) and prop(pc, "Pawn") or nil
        if player == nil or not valid(player) then return end
        local player_addr = addr_of(player)

        local cls_name = "BP_PlayerGoatMain_C"
        local all = nil
        pcall(function() all = FindAllOf(cls_name) end)
        if all ~= nil then
            for _, p in ipairs(all) do
                if p ~= nil and valid(p) then
                    local pa = addr_of(p)
                    local vm = prop(p, "VisualMesh")
                    local mesh = (vm ~= nil and valid(vm)) and prop(vm, "SkeletalMesh") or nil
                    local mname = full_str(mesh)
                    if last_mesh[pa] ~= mname then
                        local who = (pa == player_addr) and "LOCAL PLAYER" or "ghost"
                        local gi = prop(p, "As MV Game Instance Ref")
                        fout(string.format("MESH %s %s: %s -> %s   (game instance %s)",
                            who, pa, tostring(last_mesh[pa]), mname, addr_of(gi) or "none"))
                        last_mesh[pa] = mname
                    end
                end
            end
        end

        watch_object("player", player)
        watch_object("gameinstance", prop(player, "As MV Game Instance Ref"))
        if out then out:flush() end
    end)
    if not ok then
        log("error: " .. tostring(err))
        fout("PROBE ERROR: " .. tostring(err))
        if out then out:flush() end
        return true
    end
    if elapsed >= TOTAL_MS then
        fout("DONE")
        if out then out:flush() end
        log("DONE -- " .. OUT_PATH)
        return true
    end
    return false
end)
