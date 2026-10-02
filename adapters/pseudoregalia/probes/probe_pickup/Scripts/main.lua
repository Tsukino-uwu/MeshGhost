-- Item-pickup capture: on change, each pawn's weapon fields and the fields the adapter puts on the wire, with a
-- TRACK line per sample for a few seconds around any change, and a baseline census once a pawn exists (the
-- pre-pickup state). A named list only: it can prove weaponEquipped? the wrong signal, never find the right one.
-- Stand around a moment, then pick the sword up; no window to hit. Named reads only; unload it afterwards.

local TAG = "[MeshGhostPickup]"
local INTERVAL_MS = 100
local CONTEXT_SAMPLES = 30

local last = {}
local samples = 0
local context_left = 0
local missing = {}
local seen_any = {}

local function full_name(obj)
    local n
    pcall(function() n = obj:GetFullName() end)
    return n
end

local function short(n)
    if not n then return "<nil>" end
    return n:match("([%w_]+_C_%d+)") or n:match("([^%.:%s]+)$") or n
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

local function vec_text(v)
    if not v then return "?" end
    local x, y, z
    pcall(function() x, y, z = v.X, v.Y, v.Z end)
    if x == nil then return "?" end
    return string.format("%.0f,%.0f,%.0f", x, y, z)
end

local function num(v)
    local n = tonumber(v)
    if n == nil then return -999999 end
    return n
end

-- After the baseline census, a key's first sighting is a new actor (a replay ghost spawning): its start is data.
local function on_change(key, value)
    if last[key] ~= value then
        local was = last[key]
        last[key] = value
        if was ~= nil then
            print(string.format("%s CHANGE %s: %s -> %s  t=%.1f s=%d\n", TAG, key, tostring(was), value, os.clock(), samples))
            context_left = CONTEXT_SAMPLES
        elseif last["__census"] then
            print(string.format("%s FIRST %s = %s  t=%.1f s=%d\n", TAG, key, value, os.clock(), samples))
            context_left = CONTEXT_SAMPLES
        end
    end
end

local function sample()
    samples = samples + 1
    local pawns = FindAllOf("BP_PlayerGoatMain_C")
    if not pawns then
        if samples % 100 == 1 then
            print(string.format("%s no pawn yet (menu/loading) s=%d\n", TAG, samples))
        end
        return
    end

    local pawn_count = 0
    for _, pawn in pairs(pawns) do
        local pname = short(full_name(pawn))
        if pname ~= "<nil>" then
            pawn_count = pawn_count + 1
            local p = pname .. "."

            on_change(p .. "weaponEquipped?", tostring(read(pawn, "weaponEquipped?", "weaponEquipped?")))
            local wref = read(pawn, "weaponRef", "weaponRef")
            on_change(p .. "weaponRef", wref and short(full_name(wref)) or "<none>")
            local wmesh = read(pawn, "WeaponMesh", "WeaponMesh")
            if wmesh then
                on_change(p .. "WeaponMesh.bVisible", tostring(prop(wmesh, "bVisible")))
            end

            -- The fields the adapter puts on the wire, so a recording can be read back against them.
            on_change(p .. "moveState", tostring(read(pawn, "moveState", "moveState")))
            on_change(p .. "actionState", tostring(read(pawn, "actionState", "actionState")))
            on_change(p .. "animJumpType", tostring(read(pawn, "animJumpType", "animJumpType")))
            local cm = read(pawn, "CharacterMovement", "CharacterMovement")
            if cm then
                on_change(p .. "MovementMode", tostring(prop(cm, "MovementMode")))
            end
            local abp = read(pawn, "animBPref", "animBPref")
            if abp then
                on_change(p .. "animEquippedWeapon", tostring(prop(abp, "animEquippedWeapon")))
                on_change(p .. "landed?", tostring(prop(abp, "landed?")))
                on_change(p .. "jumped?", tostring(prop(abp, "jumped?")))
            end

            if context_left > 0 or samples % 50 == 1 then
                local root = prop(pawn, "RootComponent")
                local caps = read(pawn, "CapsuleComponent", "CapsuleComponent")
                print(string.format("%s TRACK %s loc=%s h=%.1f v=%.1f move=%s act=%s caps=%s s=%d\n",
                    TAG, pname,
                    vec_text(root and prop(root, "RelativeLocation")),
                    num(read(pawn, "horizontalSpeed", "horizontalSpeed")),
                    num(read(pawn, "verticalSpeed", "verticalSpeed")),
                    tostring(prop(pawn, "moveState")), tostring(prop(pawn, "actionState")),
                    tostring(caps and prop(caps, "CapsuleHalfHeight")), samples))
            end
        end
    end

    if context_left > 0 then context_left = context_left - 1 end

    if pawn_count > 0 and not last["__census"] then
        last["__census"] = "done"
        print(string.format("%s ===== BASELINE -- pawn exists; if you have not picked up the sword, this is the PRE-PICKUP state =====\n", TAG))
        local keys = {}
        for k in pairs(last) do
            if k ~= "__census" then keys[#keys + 1] = k end
        end
        table.sort(keys)
        for _, k in ipairs(keys) do
            print(string.format("%s BASE %s = %s\n", TAG, k, tostring(last[k])))
        end
        local unresolved = {}
        for k in pairs(missing) do unresolved[#unresolved + 1] = k end
        table.sort(unresolved)
        print(string.format("%s COVERAGE: %d named field(s) did not resolve%s\n", TAG,
            #unresolved, (#unresolved > 0) and (": " .. table.concat(unresolved, ", ")) or ""))
        print(string.format("%s ===== now go and pick up the Dream Breaker, no rush =====\n", TAG))
    end

    if samples % 100 == 1 then
        print(string.format("%s watching pawns=%d s=%d t=%.1f\n", TAG, pawn_count, samples, os.clock()))
    end
end

LoopAsync(INTERVAL_MS, function()
    ExecuteInGameThread(sample)
    return false
end)

print(string.format("%s loaded -- stand around a moment, then go pick up the Dream Breaker. Everything logs on change; no window to hit.\n", TAG))
