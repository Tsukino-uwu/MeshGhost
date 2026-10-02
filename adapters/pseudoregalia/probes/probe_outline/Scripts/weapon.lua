-- Read-only: every 2 s for 120 s, on change, the player's and each ghost's WeaponMesh (class, the asset under the
-- three names this build might use, attach parent and socket, relative transform, bVisible), VisualMesh's asset,
-- and the pawn's weaponRef and weaponEquipped?; once, every pawn function whose name mentions weapon or sword.
-- Deploy over the scratch slot and trigger the reloader.

local TAG = "[MeshGhostWeaponProbe]"
local PAWN_CLASS = "BP_PlayerGoatMain_C"
local INTERVAL_MS = 2000
local DURATION_S = 120
local ASSET_NAMES = { "SkeletalMesh", "SkinnedAsset", "SkeletalMeshAsset" }

local samples, clock_samples = 0, 0
local last_line = {}
local ended = false
local verbs_dumped = false

local function full_name(obj) local n; pcall(function() n = obj:GetFullName() end); return n or "?" end
local function short(name) return (tostring(name):gsub("^.*[/%.]([^/%.]+%.[^/%.]+)$", "%1")) end
local function valid(obj) local ok, v = pcall(function() return obj:IsValid() end); return ok and v == true end
local function prop(obj, name) local v; if not pcall(function() v = obj[name] end) then return nil end; return v end
local function is_obj(v) return v ~= nil and type(v) ~= "boolean" and type(v) ~= "number" and type(v) ~= "string" and valid(v) end
local function is_default(obj) return full_name(obj):find("Default__", 1, true) ~= nil end
local function emit(key, line)
    if last_line[key] ~= line then last_line[key] = line; print(string.format("%s #%d %s\n", TAG, samples, line)) end
end

local function player_pawn()
    for _, pc in pairs(FindAllOf("PlayerController") or {}) do
        if valid(pc) then
            for _, field in ipairs({ "AcknowledgedPawn", "Pawn" }) do
                local pawn = prop(pc, field)
                if pawn ~= nil and valid(pawn) then return pawn end
            end
        end
    end
    return nil
end

local function vec(v)
    if type(v) ~= "table" and type(v) ~= "userdata" then return "?" end
    local x, y, z
    pcall(function() x, y, z = v.X, v.Y, v.Z end)
    if x == nil then pcall(function() x, y, z = v.Pitch, v.Yaw, v.Roll end) end
    if x == nil then return "?" end
    return string.format("(%.1f,%.1f,%.1f)", tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
end

local function asset_line(comp)
    local parts = {}
    for _, n in ipairs(ASSET_NAMES) do
        local a = prop(comp, n)
        parts[#parts + 1] = n .. "=" .. (is_obj(a) and short(full_name(a)) or (a == nil and "?" or "nil/placeholder"))
    end
    return table.concat(parts, " ")
end

local function describe_pawn(pawn, role)
    local pn = full_name(pawn)
    local wm = prop(pawn, "WeaponMesh")
    if is_obj(wm) then
        local cls = "?"; pcall(function() cls = wm:GetClass():GetFName():ToString() end)
        local parent = prop(wm, "AttachParent")
        local sock = prop(wm, "AttachSocketName")
        local sock_s = "?"; pcall(function() sock_s = sock:ToString() end)
        emit(pn .. "/wm/asset", string.format("%s %s WeaponMesh (%s): %s", role, short(pn), cls, asset_line(wm)))
        emit(pn .. "/wm/where", string.format("%s %s WeaponMesh attach: parent=%s socket=%s relLoc=%s relRot=%s relScale=%s visible=%s",
             role, short(pn), is_obj(parent) and short(full_name(parent)) or "?", sock_s,
             vec(prop(wm, "RelativeLocation")), vec(prop(wm, "RelativeRotation")), vec(prop(wm, "RelativeScale3D")), tostring(prop(wm, "bVisible"))))
    else
        emit(pn .. "/wm/asset", string.format("%s %s WeaponMesh: (absent)", role, short(pn)))
    end
    local vm = prop(pawn, "VisualMesh")
    if is_obj(vm) then emit(pn .. "/vm", string.format("%s %s VisualMesh: %s", role, short(pn), asset_line(vm))) end
    local wref = prop(pawn, "weaponRef")
    local wref_s = "nil"
    if is_obj(wref) then
        local c = "?"; pcall(function() c = wref:GetClass():GetFName():ToString() end)
        wref_s = short(full_name(wref)) .. " (" .. c .. ")"
        local wref_mesh = nil
        for _, n in ipairs({ "WeaponMesh", "Mesh", "SkeletalMesh", "StaticMesh" }) do
            local m = prop(wref, n)
            if is_obj(m) then wref_mesh = n .. "=" .. short(full_name(m)) .. " [" .. asset_line(m) .. "]"; break end
        end
        if wref_mesh then emit(pn .. "/wref/mesh", string.format("%s %s weaponRef mesh: %s", role, short(pn), wref_mesh)) end
    end
    emit(pn .. "/wref", string.format("%s %s weaponRef=%s weaponEquipped?=%s", role, short(pn), wref_s, tostring(prop(pawn, "weaponEquipped?"))))
end

local function dump_verbs(pawn)
    if verbs_dumped then return end
    verbs_dumped = true
    local c = nil; pcall(function() c = pawn:GetClass() end)
    local depth, walked, hits = 0, 0, 0
    while c and valid(c) and depth < 12 do
        depth = depth + 1
        local cname = "?"; pcall(function() cname = c:GetFName():ToString() end)
        pcall(function()
            c:ForEachFunction(function(fn)
                walked = walked + 1
                pcall(function()
                    local n = fn:GetFName():ToString()
                    local l = n:lower()
                    if l:find("weapon", 1, true) or l:find("sword", 1, true) or l:find("equip", 1, true) then
                        hits = hits + 1
                        print(string.format("%s VERB %s::%s\n", TAG, cname, n))
                    end
                end)
            end)
        end)
        local sup = nil; pcall(function() sup = c:GetSuperStruct() end)
        if sup and sup ~= c and valid(sup) then c = sup else c = nil end
    end
    print(string.format("%s VERB coverage: %d functions walked over %d class level(s), %d matched weapon/sword/equip.\n", TAG, walked, depth, hits))
end

local function sample()
    samples = samples + 1
    local player = player_pawn()
    if not player then return end
    clock_samples = clock_samples + 1
    local pn = full_name(player)
    if clock_samples == 1 then print(string.format("%s START: player=%s\n", TAG, short(pn))) end
    describe_pawn(player, "PLAYER")
    dump_verbs(player)
    local ghosts = 0
    for _, pawn in pairs(FindAllOf(PAWN_CLASS) or {}) do
        if valid(pawn) and not is_default(pawn) and full_name(pawn) ~= pn then
            ghosts = ghosts + 1
            describe_pawn(pawn, "GHOST ")
        end
    end
    emit("ghosts", string.format("ghost pawns alive: %d", ghosts))
    local loose = 0
    for _, w in pairs(FindAllOf("BP_looseWeapon_C") or {}) do
        if valid(w) and not is_default(w) then
            loose = loose + 1
            for _, n in ipairs({ "WeaponMesh", "Mesh", "SkeletalMesh", "StaticMesh" }) do
                local m = prop(w, n)
                if is_obj(m) then emit("loose/" .. full_name(w), string.format("LOOSE %s %s: %s", short(full_name(w)), n, asset_line(m))); break end
            end
        end
    end
    emit("loose/count", string.format("loose weapons in world: %d", loose))
    local left = DURATION_S - (clock_samples * INTERVAL_MS) / 1000
    if left == 60 or left == 30 or left == 10 then print(string.format("%s %ds left.\n", TAG, left)) end
    if left <= 0 and not ended then
        ended = true
        print(string.format("%s END after %d samples. Stopped; nothing left running.\n", TAG, samples))
    end
end

LoopAsync(INTERVAL_MS, function()
    if ended then return true end
    local ok, err = pcall(sample)
    if not ok then print(string.format("%s sample error: %s\n", TAG, tostring(err))) end
    return false
end)
print(string.format("%s loaded: %d s at %d ms, read-only.\n", TAG, DURATION_S, INTERVAL_MS))
