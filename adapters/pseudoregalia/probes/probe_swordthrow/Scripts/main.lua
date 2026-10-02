-- Sword-throw capture: on change, every pawn's weapon fields and the two thrown-sword classes' state, plus a TRACK
-- line per sample while one flies (a bounce is a velocity sign flip). Throw, let it bounce, pick it up, repeat.
-- Named reads only, no UFunction on a FindAllOf result; 3 classes at 250ms is heavier than a shipped path may be.

local TAG = "[MeshGhostSwordThrow]"
local INTERVAL_MS = 250

local last = {} -- change-detection: key -> last printed value

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
    if not pcall(function() v = obj[name] end) then return nil end
    return v
end

local function vec_text(v)
    if not v then return "?" end
    local x, y, z
    pcall(function() x, y, z = v.X, v.Y, v.Z end)
    if x == nil then return "?" end
    return string.format("%.0f,%.0f,%.0f", x, y, z)
end

local function on_change(key, value)
    if last[key] ~= value then
        last[key] = value
        print(string.format("%s CHANGE %s = %s t=%.1f\n", TAG, key, value, os.clock()))
    end
end

local samples = 0

local function sample()
    samples = samples + 1

    -- Keyed by each pawn's own instance name, so the player and the ghost stay separate columns.
    local pawns = FindAllOf("BP_PlayerGoatMain_C")
    local pawn_count = 0
    if pawns then
        for _, pawn in pairs(pawns) do
            local pname = short(full_name(pawn))
            if pname ~= "<nil>" then
                pawn_count = pawn_count + 1
                on_change(pname .. ".weaponEquipped?", tostring(prop(pawn, "weaponEquipped?")))
                -- A ghost's animBPref on the player's anim instance would send every ghost anim write to the player.
                local abp = prop(pawn, "animBPref")
                on_change(pname .. ".animBPref", abp and (full_name(abp) or "<unnamed>") or "<none>")
                local vm = prop(pawn, "VisualMesh")
                if vm then
                    local ai = prop(vm, "AnimScriptInstance")
                    on_change(pname .. ".AnimScriptInstance", ai and (full_name(ai) or "<unnamed>") or "<none>")
                end
                local wref = prop(pawn, "weaponRef")
                on_change(pname .. ".weaponRef", wref and short(full_name(wref)) or "<none>")
                local wmesh = prop(pawn, "WeaponMesh")
                if wmesh then
                    on_change(pname .. ".WeaponMesh.bVisible", tostring(prop(wmesh, "bVisible")))
                end
            end
        end
    end

    local classes = {
        {name = "BP_looseWeapon_C"},
        {name = "PRJ_PlayerCutter_C"},
    }
    local counts = {}
    for _, cls in ipairs(classes) do
        local found = FindAllOf(cls.name)
        local n = 0
        if found then
            for _, actor in pairs(found) do
                local aname = short(full_name(actor))
                local root = prop(actor, "RootComponent")
                if root then -- no RootComponent = the class default object, not a thing in the world
                    n = n + 1
                    local state = prop(actor, "weaponState")
                    if state ~= nil then
                        on_change(aname .. ".weaponState", tostring(state))
                    end
                    local pm = prop(actor, "ProjectileMovement")
                    local active, vel = "n/a", nil
                    if pm then
                        active = tostring(prop(pm, "bIsActive"))
                        vel = prop(pm, "Velocity")
                    end
                    -- Only a moving actor logs per sample; a parked pooled one logs once, on change.
                    local loc = vec_text(prop(root, "RelativeLocation"))
                    local vtxt = vel and vec_text(vel) or "?"
                    if pm and active == "true" then
                        print(string.format("%s TRACK %s loc=%s vel=%s t=%.1f\n", TAG, aname, loc, vtxt, os.clock()))
                    else
                        on_change(aname .. ".TRACK", string.format("parked loc=%s pmActive=%s", loc, active))
                    end
                end
            end
        end
        counts[#counts + 1] = string.format("%s=%d", cls.name, n)
    end

    if samples % 40 == 1 then
        print(string.format("%s WATCHING pawns=%d %s samples=%d\n", TAG, pawn_count, table.concat(counts, " "), samples))
    end
end

LoopAsync(INTERVAL_MS, function()
    ExecuteInGameThread(sample)
    return false
end)

print(string.format("%s loaded -- throw the sword, let it bounce, pick it up, a few times. Hand/flight/pickup state logs on change; flight tracks per sample.\n", TAG))
