-- MeshGhost OBJECT DUMP -- any live UObject's reflected properties as JSON, without crashing the game.
--
-- WHY (user, 2026-09-06): a tester compares objects with the UE4SS GUI console's object dump; the
-- user wants the same from a probe, "especially if it avoids us to kinda dump things without
-- crashing the game", and as the tool for vetting a ghost's components one at a time.
--
-- THE RULE THAT KEEPS IT SAFE. Every crash this repo has had from a reflection walk (three on
-- 2026-08-29, one on 2026-09-05) came from DEREFERENCING an object-valued property: stringifying
-- the pointee, calling GetFullName on it, calling a UFunction on it. The pointee may be a torn-down
-- object, and a pcall does not catch an access violation. So this dump NEVER touches what an object
-- property points at: it records the pointer's address and the property's DECLARED class (metadata
-- on the property, not the pointee). Scalars are read and written out in full; known structs
-- (Vector, Rotator, Quat, Vector2D, LinearColor, Color, Transform) by field; arrays of scalars by
-- element (up to ARRAY_MAX), arrays of objects as addresses; everything else by type name only.
-- The only objects it follows are the target's OWN components, reached through the arrays the
-- actor itself owns (RootComponent, BlueprintCreatedComponents, InstanceComponents, and each scene
-- component's AttachChildren) -- a live actor's owned components are live.
--
-- REQUEST. Write to `dump_request.txt` beside this mod's Scripts folder, one key=value per line:
--     path=<full object path>          StaticFindObject; e.g. the name a census printed
--     class=<ClassName>                every instance of that class (FindAllOf) ...
--     name=<substring>                 ... whose full name contains this (optional)
--     components=1                     also dump the target's own components (actors only)
--     out=<label>                       file name stem (optional; default: the object's name)
-- Output: `dumps/<label>-<HHMMSS>.json` beside the request file, keys sorted so two dumps `diff`
-- cleanly, and one summary line in the log (properties read / refs / errors / coverage). A property
-- that cannot be read is written as {"error": "..."} rather than dropped -- the dump says what it
-- could not see.
--
-- COST. Nothing runs but a 500ms poll for the request file. A dump of one actor with its
-- components is a few hundred property reads, once. Read-only: no property is written, no
-- UFunction is called on anything. Unreal/UE4SS only -- a future Unreal game can copy this folder
-- as is. Dev-only tooling; never ships.

local TAG = "[MeshGhostDump]"
local POLL_MS = 500
local ARRAY_MAX = 32
local COMPONENT_MAX = 64

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*[\\/])") or "./"
end
local MOD_ROOT = scriptDir() .. "../"
local REQUEST_PATH = MOD_ROOT .. "dump_request.txt"
local OUT_DIR = MOD_ROOT .. "dumps/"

local function log(line) print(TAG .. " " .. line .. "\n") end

---------------------------------------------------------------------------- JSON, keys sorted

local function json_escape(s)
    s = tostring(s)
    s = s:gsub('[%c"\\]', function(ch)
        if ch == '"' then return '\\"' elseif ch == "\\" then return "\\\\"
        elseif ch == "\n" then return "\\n" elseif ch == "\r" then return "\\r" elseif ch == "\t" then return "\\t"
        else return string.format("\\u%04x", ch:byte()) end
    end)
    return '"' .. s .. '"'
end

local function to_json(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return json_escape(tostring(v)) end
        if math.type and math.type(v) == "integer" then return tostring(v) end
        return string.format("%.6g", v)
    end
    if t == "string" then return json_escape(v) end
    if t == "table" then
        if v.__array then
            local parts = {}
            for i = 1, #v do parts[#parts + 1] = to_json(v[i], indent .. "  ") end
            if #parts == 0 then return "[]" end
            return "[" .. table.concat(parts, ", ") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = indent .. "  " .. json_escape(k) .. ": " .. to_json(v[k], indent .. "  ")
        end
        if #parts == 0 then return "{}" end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    end
    return json_escape(tostring(v))
end

local function arr(list) list.__array = true; return list end

---------------------------------------------------------------------------- safe reads

local SCALAR = {
    BoolProperty = true, Int8Property = true, Int16Property = true, IntProperty = true, Int64Property = true,
    UInt16Property = true, UInt32Property = true, UInt64Property = true, FloatProperty = true,
    DoubleProperty = true, ByteProperty = true, EnumProperty = true, StrProperty = true,
    NameProperty = true, TextProperty = true,
}
local OBJECTISH = {
    ObjectProperty = true, WeakObjectProperty = true, SoftObjectProperty = true, LazyObjectProperty = true,
    ClassProperty = true, SoftClassProperty = true, InterfaceProperty = true,
}
local STRUCT_FIELDS = {
    Vector = { "X", "Y", "Z" }, Vector2D = { "X", "Y" }, Vector4 = { "X", "Y", "Z", "W" },
    Rotator = { "Pitch", "Yaw", "Roll" }, Quat = { "X", "Y", "Z", "W" },
    LinearColor = { "R", "G", "B", "A" }, Color = { "R", "G", "B", "A" },
    IntPoint = { "X", "Y" }, IntVector = { "X", "Y", "Z" },
}

local stats = { read = 0, refs = 0, errors = 0, skipped = 0 }

local function addr_of(obj)
    -- GetAddress reads the wrapper's own pointer; it never dereferences the pointee.
    local ok, a = pcall(function() return obj:GetAddress() end)
    if ok and a then return string.format("0x%x", a) end
    return nil
end

local function scalar_value(v)
    local t = type(v)
    if t == "boolean" or t == "number" or t == "string" then return v end
    if t == "nil" then return nil end
    -- FName / FString / FText wrappers stringify through their own ToString; a plain tostring on
    -- one gives the userdata label instead.
    local ok, s = pcall(function() return v:ToString() end)
    if ok and s then return s end
    return tostring(v)
end

local function struct_value(v, struct_name)
    local fields = STRUCT_FIELDS[struct_name]
    if not fields then return { struct = struct_name } end
    local out = { struct = struct_name }
    for _, f in ipairs(fields) do
        local ok, x = pcall(function() return v[f] end)
        if ok and type(x) == "number" then out[f] = x else out[f] = "<unread>" end
    end
    return out
end

local function object_ref(v, declared_class)
    local out = { ref = "null", class_declared = declared_class }
    if v == nil then return out end
    local a = addr_of(v)
    if a == nil then out.ref = "<no address>" else out.ref = a end
    if a == "0x0" then out.ref = "null" end
    if out.ref ~= "null" then stats.refs = stats.refs + 1 end
    return out
end

local function array_value(v, inner_class, inner_prop)
    local out = { array = inner_class }
    local ok, n = pcall(function() return v:GetArrayNum() end)
    if not ok or type(n) ~= "number" then out.count = "<unread>"; return out end
    out.count = n
    local items = arr({})
    local limit = math.min(n, ARRAY_MAX)
    if SCALAR[inner_class] then
        for i = 1, limit do
            local ok2, x = pcall(function() return v[i] end)
            items[#items + 1] = ok2 and scalar_value(x) or "<unread>"
        end
    elseif OBJECTISH[inner_class] then
        local declared = "?"
        pcall(function() declared = inner_prop:GetPropertyClass():GetFName():ToString() end)
        for i = 1, limit do
            local ok2, x = pcall(function() return v[i] end)
            items[#items + 1] = ok2 and object_ref(x, declared) or "<unread>"
        end
    elseif inner_class == "StructProperty" then
        local sname = "?"
        pcall(function() sname = inner_prop:GetStruct():GetFName():ToString() end)
        for i = 1, limit do
            local ok2, x = pcall(function() return v[i] end)
            items[#items + 1] = ok2 and struct_value(x, sname) or "<unread>"
        end
    else
        return out
    end
    if n > limit then out.truncated_to = limit end
    out.items = items
    return out
end

-- Reads one property of obj by its reflected description. Never dereferences an object value.
local function property_value(obj, prop)
    local pclass = prop:GetClass():GetFName():ToString()
    local pname = prop:GetFName():ToString()
    if SCALAR[pclass] then
        local v = obj[pname]
        return scalar_value(v)
    elseif OBJECTISH[pclass] then
        local declared = "?"
        pcall(function() declared = prop:GetPropertyClass():GetFName():ToString() end)
        return object_ref(obj[pname], declared)
    elseif pclass == "StructProperty" then
        local sname = "?"
        pcall(function() sname = prop:GetStruct():GetFName():ToString() end)
        return struct_value(obj[pname], sname)
    elseif pclass == "ArrayProperty" then
        local inner = prop:GetInner()
        local iclass = inner:GetClass():GetFName():ToString()
        return array_value(obj[pname], iclass, inner)
    else
        stats.skipped = stats.skipped + 1
        return { type = pclass }
    end
end

-- Every reflected property of obj, walking the class chain, into a table keyed "Class.Property"
-- so a property redeclared in a subclass never hides the parent's, and the owner class is on the key.
local function dump_properties(obj)
    local props = {}
    local walked = 0
    local cls = obj:GetClass()
    while cls and cls:IsValid() do
        local cname = cls:GetFName():ToString()
        cls:ForEachProperty(function(prop)
            walked = walked + 1
            local pname = "?"
            pcall(function() pname = prop:GetFName():ToString() end)
            local key = cname .. "." .. pname
            local ok, v = pcall(property_value, obj, prop)
            if ok then
                stats.read = stats.read + 1
                props[key] = v
            else
                stats.errors = stats.errors + 1
                props[key] = { error = tostring(v) }
            end
        end)
        local sup = nil
        pcall(function() sup = cls:GetSuperStruct() end)
        if sup and sup ~= cls and sup:IsValid() then cls = sup else cls = nil end
    end
    return props, walked
end

local function describe(obj)
    local d = {}
    d.address = addr_of(obj) or "?"
    pcall(function() d.full_name = obj:GetFullName() end)
    pcall(function() d.class = obj:GetClass():GetFName():ToString() end)
    return d
end

-- The target's OWN components, through the arrays the actor owns. Each entry is followed exactly
-- once; nothing beyond an owned component is ever dereferenced.
local function owned_components(actor)
    local found, seen = {}, {}
    local function add(c)
        if c == nil then return end
        local a = addr_of(c)
        if a == nil or a == "0x0" or seen[a] then return end
        seen[a] = true
        found[#found + 1] = c
    end
    local function add_array(holder, field)
        local ok, list = pcall(function() return holder[field] end)
        if not ok or list == nil then return end
        local ok2, n = pcall(function() return list:GetArrayNum() end)
        if not ok2 or type(n) ~= "number" then return end
        for i = 1, math.min(n, COMPONENT_MAX) do
            local ok3, c = pcall(function() return list[i] end)
            if ok3 then add(c) end
        end
    end
    pcall(function() add(actor.RootComponent) end)
    add_array(actor, "BlueprintCreatedComponents")
    add_array(actor, "InstanceComponents")
    -- attach tree, one level at a time, bounded
    local i = 1
    while i <= #found and #found < COMPONENT_MAX do
        add_array(found[i], "AttachChildren")
        i = i + 1
    end
    return found
end

---------------------------------------------------------------------------- the dump

local function resolve_targets(req)
    local targets = {}
    if req.path then
        local ok, obj = pcall(StaticFindObject, req.path)
        if ok and obj and obj:IsValid() then targets[#targets + 1] = obj end
        return targets, string.format("path=%s", req.path)
    end
    if req.class then
        local ok, objs = pcall(FindAllOf, req.class)
        if ok and objs then
            for _, o in ipairs(objs) do
                local keep = true
                if req.name then
                    local ok2, fn = pcall(function() return o:GetFullName() end)
                    keep = ok2 and fn and fn:find(req.name, 1, true) ~= nil
                end
                if keep then targets[#targets + 1] = o end
            end
        end
        return targets, string.format("class=%s name=%s", req.class, req.name or "*")
    end
    return targets, "(no path= or class= in the request)"
end

local function take_dump(req)
    stats = { read = 0, refs = 0, errors = 0, skipped = 0 }
    local targets, how = resolve_targets(req)
    if #targets == 0 then
        log("nothing matched " .. how .. " -- no dump written")
        return
    end
    local doc = { request = how, taken_at = os.date("%Y-%m-%d %H:%M:%S"), objects = arr({}) }
    local walked_total = 0
    for _, obj in ipairs(targets) do
        local entry = describe(obj)
        local props, walked = dump_properties(obj)
        walked_total = walked_total + walked
        entry.properties = props
        if req.components then
            local comps = arr({})
            for _, c in ipairs(owned_components(obj)) do
                local ce = describe(c)
                local cprops, cwalked = dump_properties(c)
                walked_total = walked_total + cwalked
                ce.properties = cprops
                comps[#comps + 1] = ce
            end
            entry.components = comps
            entry.component_count = #comps
        end
        doc.objects[#doc.objects + 1] = entry
    end
    doc.coverage = { properties_walked = walked_total, read = stats.read, object_refs = stats.refs,
                     errors = stats.errors, skipped_types = stats.skipped }

    local label = req.out
    if not label then
        label = "dump"
        pcall(function() label = targets[1]:GetFName():ToString() end)
    end
    label = label:gsub("[^%w%-_.]", "_")
    os.execute(string.format('mkdir "%s" >nul 2>&1', OUT_DIR:gsub("/", "\\")))
    local path = string.format("%s%s-%s.json", OUT_DIR, label, os.date("%H%M%S"))
    local f = io.open(path, "w")
    if not f then log("could not open " .. path); return end
    f:write(to_json(doc), "\n")
    f:close()
    log(string.format("dumped %d object(s) for %s -> %s | properties walked %d, read %d, refs %d, errors %d, skipped types %d",
        #targets, how, path, walked_total, stats.read, stats.refs, stats.errors, stats.skipped))
end

local function read_request()
    local f = io.open(REQUEST_PATH, "r")
    if not f then return nil end
    local text = f:read("*a") or ""
    f:close()
    os.remove(REQUEST_PATH)
    local req = {}
    for line in text:gmatch("[^\r\n]+") do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k then
            if v == "1" or v == "true" then req[k] = true elseif v ~= "" then req[k] = v end
        end
    end
    if req.components == "0" or req.components == "false" then req.components = nil end
    return req
end

LoopAsync(POLL_MS, function()
    local req = read_request()
    if req ~= nil then
        ExecuteInGameThread(function()
            local ok, err = pcall(take_dump, req)
            if not ok then log("dump FAILED: " .. tostring(err)) end
        end)
    end
    return false
end)

log(string.format("dump probe loaded -- write path=/class=[+name=][+components=1] to %s; output in %s", REQUEST_PATH, OUT_DIR))
