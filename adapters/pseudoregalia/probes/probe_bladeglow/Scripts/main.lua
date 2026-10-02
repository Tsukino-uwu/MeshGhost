-- Blade-glow census probe: on every pawn at 2Hz, the visibility and AttachParent of VisualMesh, WeaponMesh and
-- LightMesh (the blade aura), to see whether showing a ghost's WeaponMesh with bPropagateToChildren shows the aura.
-- It reads three named meshes, so an aura on a fourth component reads clean. A census first, then on change only.
-- Named reads only, no UFunction on a FindAllOf result. Dev-only; unload it before judging anything else.

local TAG = "[MeshGhostBladeGlow]"
local INTERVAL_MS = 500
local MESHES = { "VisualMesh", "WeaponMesh", "LightMesh" }

local last = {}
local samples = 0
local censused = false
local missing = {}
local seen_any = {}

local function full_name(obj)
    local n
    pcall(function() n = obj:GetFullName() end)
    return n
end

-- A pawn's short name only: it matches the actor part first, so a component would collapse to its pawn.
local function short(n)
    if not n then return "<nil>" end
    return n:match("([%w_]+_C_%d+)") or n:match("([^%.:%s]+)$") or n
end

-- Prints <Actor>.<Component>, so a parent component is distinguishable from the actor's root.
local function short_component(n)
    if not n then return "<nil>" end
    local actor, member = n:match("([%w_]+_C_%d+)%.([%w_%.]+)$")
    if actor and member then return actor .. "." .. member end
    return n:match("([^%.:%s]+)$") or n
end

local function prop(obj, name)
    local v
    if not obj or not pcall(function() v = obj[name] end) then return nil end
    return v
end

local function read(obj, name, key)
    local v = prop(obj, name)
    if v == nil then
        if not seen_any[key] then missing[key] = true end
    else
        seen_any[key] = true
        missing[key] = nil
    end
    return v
end

local function on_change(key, value)
    if last[key] ~= value then
        local was = last[key]
        last[key] = value
        if was ~= nil then
            print(string.format("%s CHANGE %s: %s -> %s  s=%d\n", TAG, key, tostring(was), value, samples))
        elseif censused then
            -- After the census a first sighting is a ghost spawning, and its starting state is the question.
            print(string.format("%s FIRST %s = %s  s=%d\n", TAG, key, value, samples))
        end
    end
end

local function sample()
    samples = samples + 1
    local pawns = FindAllOf("BP_PlayerGoatMain_C")
    if not pawns then
        if samples % 20 == 1 then
            print(string.format("%s no pawn yet (main menu / loading) s=%d\n", TAG, samples))
        end
        return
    end

    local count = 0
    for _, pawn in pairs(pawns) do
        local pname = short(full_name(pawn))
        if pname ~= "<nil>" then
            count = count + 1
            local p = pname .. "."

            -- Printed, not trusted: a ghost can read as possessed too.
            local controller = prop(pawn, "Controller")
            on_change(p .. "isLocalPlayer", tostring(controller ~= nil))

            -- A Blueprint bool, so unlike the packed engine bools it reads correctly.
            on_change(p .. "obtainedLight?", tostring(read(pawn, "obtainedLight?", "obtainedLight?")))
            on_change(p .. "weaponEquipped?", tostring(read(pawn, "weaponEquipped?", "weaponEquipped?")))

            for _, mesh_name in ipairs(MESHES) do
                local mesh = read(pawn, mesh_name, mesh_name)
                if mesh then
                    local m = p .. mesh_name .. "."
                    -- Both printed: packed engine bools can read as garbage through a byte-wide read here.
                    on_change(m .. "bVisible", tostring(prop(mesh, "bVisible")))
                    on_change(m .. "bHiddenInGame", tostring(prop(mesh, "bHiddenInGame")))
                    local parent = prop(mesh, "AttachParent")
                    on_change(m .. "AttachParent", parent and short_component(full_name(parent)) or "<none>")
                    -- Its own name beside its parent's: if the two ever match, the matcher ate the member.
                    on_change(m .. "self", short_component(full_name(mesh)))
                end
            end
        end
    end

    if count > 0 and not censused then
        censused = true
        print(string.format("%s ===== CENSUS: %d pawn(s). Ghost vs player, side by side =====\n", TAG, count))
        local keys = {}
        for k in pairs(last) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            print(string.format("%s BASE %s = %s\n", TAG, k, tostring(last[k])))
        end
        local unresolved = {}
        for k in pairs(missing) do unresolved[#unresolved + 1] = k end
        table.sort(unresolved)
        print(string.format("%s COVERAGE: %d named field(s) did not resolve%s\n", TAG,
            #unresolved, (#unresolved > 0) and (": " .. table.concat(unresolved, ", ")) or ""))
        print(string.format("%s ===== everything else prints on change only =====\n", TAG))
    end

    if samples % 60 == 1 then
        print(string.format("%s watching pawns=%d s=%d\n", TAG, count, samples))
    end
end

LoopAsync(INTERVAL_MS, function()
    ExecuteInGameThread(sample)
    return false
end)

print(string.format("%s loaded -- census prints as soon as pawns exist; nothing to time.\n", TAG))
