-- Outline probe, stage 1, read-only: who turns the player's through-walls outline on and off? Every 500 ms for 90 s
-- from the player pawn's arrival, on change: custom depth, stencil, main pass and visibility on the player's and each
-- ghost's VisualMesh, WeaponMesh and LightMesh; every 10th sample, each ghost's object properties whose value carries
-- a custom-depth flag and has another owner; and every live afterimage. It reads flags, never what is drawn.
-- Run over the scratch slot through probe_reloader; restore the stub after.

local TAG = "[MeshGhostOutlineProbe]"
local PAWN_CLASS = "BP_PlayerGoatMain_C"
local IMAGE_CLASS = "BP_AfterImage_C"
local MESHES = { "VisualMesh", "WeaponMesh", "LightMesh" }
local FIELDS = { "bRenderCustomDepth", "CustomDepthStencilValue", "bRenderInMainPass", "bVisible" }
local INTERVAL_MS = 500
local DURATION_S = 90
local CROSS_EVERY = 10 -- samples

local samples = 0
local clock_samples = 0   -- counts only once the player pawn exists: the run starts when play does
local last_line = {}      -- key -> last printed line, for on-change printing
local cross_found = 0
local cross_walked = 0
local announced_end = false

local function full_name(obj)
    local n
    pcall(function() n = obj:GetFullName() end)
    return n or "?"
end

local function short(name)
    return (tostring(name):gsub("^.*[/%.]([^/%.]+%.[^/%.]+)$", "%1"))
end

local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

local function prop(obj, name)
    local v
    local ok = pcall(function() v = obj[name] end)
    if not ok then return nil end
    return v
end

local function is_default(obj)
    return full_name(obj):find("Default__", 1, true) ~= nil
end

local function player_pawn()
    local pcs = FindAllOf("PlayerController")
    if not pcs then return nil end
    for _, pc in pairs(pcs) do
        if valid(pc) then
            for _, field in ipairs({ "AcknowledgedPawn", "Pawn" }) do
                local pawn = prop(pc, field)
                if pawn ~= nil and valid(pawn) then return pawn end
            end
        end
    end
    return nil
end

local function outer_name(obj)
    local outer
    pcall(function() outer = obj:GetOuter() end)
    if outer == nil or not valid(outer) then return "?" end
    return full_name(outer)
end

local function emit(key, line)
    if last_line[key] ~= line then
        last_line[key] = line
        print(string.format("%s #%d %s\n", TAG, samples, line))
    end
end

local function flags_line(comp)
    local parts = {}
    for _, f in ipairs(FIELDS) do
        local v = prop(comp, f)
        parts[#parts + 1] = f:gsub("^b", "") .. "=" .. (v == nil and "?" or tostring(v))
    end
    return table.concat(parts, " ")
end

local function sample_flags(pawns, player)
    for _, pawn in ipairs(pawns) do
        local role = (player and full_name(pawn) == full_name(player)) and "PLAYER" or "GHOST "
        for _, m in ipairs(MESHES) do
            local comp = prop(pawn, m)
            if comp ~= nil and valid(comp) then
                emit(full_name(pawn) .. "/" .. m,
                     string.format("%s %s.%s: %s outer=%s", role, short(full_name(pawn)), m,
                                   flags_line(comp), short(outer_name(comp))))
            else
                emit(full_name(pawn) .. "/" .. m,
                     string.format("%s %s.%s: (absent)", role, short(full_name(pawn)), m))
            end
        end
    end
end

-- This filter is wrong: a missing property reads back as a placeholder object, not nil; hooks.lua checks for a boolean.
local function sample_cross_owner(pawns, player)
    local player_name = player and full_name(player) or ""
    for _, pawn in ipairs(pawns) do
        local pawn_name = full_name(pawn)
        if pawn_name ~= player_name then
            local walked, found = 0, 0
            local c = nil
            pcall(function() c = pawn:GetClass() end)
            local depth = 0
            while c and valid(c) and depth < 12 do
                depth = depth + 1
                pcall(function()
                    c:ForEachProperty(function(p)
                        walked = walked + 1
                        pcall(function()
                            if p:GetClass():GetFName():ToString() ~= "ObjectProperty" then return end
                            local pname = p:GetFName():ToString()
                            local v = pawn[pname]
                            if v == nil or not valid(v) then return end
                            local cd = prop(v, "bRenderCustomDepth")
                            if cd == nil then return end
                            local o = outer_name(v)
                            if o ~= pawn_name then
                                found = found + 1
                                local whose = (o == player_name) and "THE PLAYER'S" or "another actor's"
                                emit("cross/" .. pawn_name .. "/" .. pname,
                                     string.format("CROSS-OWNER on %s: property '%s' -> %s (customdepth=%s) owned by %s: %s",
                                                   short(pawn_name), pname, short(full_name(v)), tostring(cd), whose, short(o)))
                            end
                        end)
                    end)
                end)
                local sup = nil
                pcall(function() sup = c:GetSuperStruct() end)
                if sup and sup ~= c and valid(sup) then c = sup else c = nil end
            end
            cross_walked = cross_walked + walked
            cross_found = cross_found + found
            emit("coverage/" .. pawn_name,
                 string.format("coverage %s: %d properties walked over %d class level(s), %d cross-owner value(s)",
                               short(pawn_name), walked, depth, found))
        end
    end
end

local function sample_afterimages(player)
    local images = FindAllOf(IMAGE_CLASS)
    if not images then return end
    local n = 0
    for _, img in pairs(images) do
        if valid(img) and not is_default(img) then
            n = n + 1
            if n <= 24 then
                local copy = prop(img, "copyActor")
                local copy_name = (copy ~= nil and valid(copy)) and short(full_name(copy)) or "nil"
                local pm = prop(img, "PoseableMesh")
                local cd = (pm ~= nil and valid(pm)) and tostring(prop(pm, "bRenderCustomDepth")) or "?"
                local whose = (copy ~= nil and valid(copy) and player and full_name(copy) == full_name(player)) and " (PLAYER'S)" or ""
                emit("img/" .. full_name(img),
                     string.format("afterimage %s: copyActor=%s%s PoseableMesh.customdepth=%s", short(full_name(img)), copy_name, whose, cd))
            end
        end
    end
    emit("img/count", string.format("afterimages alive: %d", n))
end

local function sample()
    samples = samples + 1
    local player = player_pawn()
    local pawns = {}
    for _, p in pairs(FindAllOf(PAWN_CLASS) or {}) do
        if valid(p) and not is_default(p) then pawns[#pawns + 1] = p end
    end
    if samples == 1 then
        print(string.format("%s START: %d pawn(s) of %s, player=%s. Full dump now, then changes only.\n",
                            TAG, #pawns, PAWN_CLASS, player and short(full_name(player)) or "NOT FOUND"))
    end
    sample_flags(pawns, player)
    if samples % CROSS_EVERY == 1 then sample_cross_owner(pawns, player) end
    sample_afterimages(player)

    if player then clock_samples = clock_samples + 1 end
    local left = DURATION_S - (clock_samples * INTERVAL_MS) / 1000
    if left == 60 or left == 30 or left == 10 then
        print(string.format("%s %ds left.\n", TAG, left))
    end
    if left <= 0 and not announced_end then
        announced_end = true
        print(string.format("%s END after %d samples: %d cross-owner value(s) over %d properties walked. Stopped; nothing left running.\n",
                            TAG, samples, cross_found, cross_walked))
    end
end

LoopAsync(INTERVAL_MS, function()
    if announced_end then return true end
    local ok, err = pcall(sample)
    if not ok then print(string.format("%s sample error: %s\n", TAG, tostring(err))) end
    return false
end)

print(string.format("%s loaded: %d s at %d ms, read-only.\n", TAG, DURATION_S, INTERVAL_MS))
