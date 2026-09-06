-- MeshGhost sword-throw capture probe. The question, from the user 2026-09-01, four parts:
--
--   how does the thrown Dream Breaker work -- (1) what removes the sword from the HAND on a
--   throw, (2) what actor is the sword IN THE AIR and how does it track/bounce, (3) what puts
--   it back in the hand on pickup -- so the ghost can do all three; and (4) evidence for the
--   pickup CROSS-WIRE (a peer's pickup animating the LOCAL player -- UNVERIFIED.md, OPEN).
--
-- Method: watch the two thrown-sword actor classes (BP_looseWeapon_C, PRJ_PlayerCutter_C) and
-- every pawn's weapon fields, log ON CHANGE -- plus a position line per sample while a thrown
-- actor exists, which IS the flight track (bounces show as velocity sign flips). Dump both
-- pawns (player and ghost) rather than guessing which is which -- filter after, never before.
--
-- Throw the sword, let it bounce, pick it up, a few times. No timing to hit.
--
-- Safe shape: NAMED property reads only, no UFunction on anything FindAllOf returned, no
-- ForEachProperty. ~12 object-space walks/s while armed (3 classes at 250ms) -- heavier than a
-- shipped path is allowed to be, fine for a two-minute capture; unload it after.
--
-- Grounded field names (this repo's own measured records, PLAYER_FIELDS.md / documentation.md):
-- pawn 'weaponEquipped?', 'weaponRef', 'WeaponMesh'; BP_looseWeapon_C 'weaponState';
-- PRJ_PlayerCutter_C 'ProjectileMovement' (UProjectileMovementComponent: Velocity, bIsActive --
-- docs.unrealengine.com).
--
-- Deploy: overwrites the resident MeshGhostSlashVfx slot (a NEW mod folder cannot join a
-- running game; an existing mod reloads via probe_reloader) -- the log tag below is what
-- identifies it, not the mod name.

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

    -- Every pawn's weapon-facing state, keyed by the pawn's own instance name so the player and
    -- the ghost stay separate columns of the same capture.
    local pawns = FindAllOf("BP_PlayerGoatMain_C")
    local pawn_count = 0
    if pawns then
        for _, pawn in pairs(pawns) do
            local pname = short(full_name(pawn))
            if pname ~= "<nil>" then
                pawn_count = pawn_count + 1
                on_change(pname .. ".weaponEquipped?", tostring(prop(pawn, "weaponEquipped?")))
                -- WHOSE anim instance does this pawn's animBPref point at? If the ghost's points
                -- at the PLAYER's, every anim write the mirror aims at the ghost lands on the
                -- player -- which is the 2026-09-01 two-peer symptom set exactly (player loses
                -- the sword and plays the pickup montage; the ghost's hand never changes).
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

    -- The two candidate airborne/landed actors. Presence, state, and a position line per sample
    -- while one exists -- the per-sample lines are the flight track.
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
                    -- Only a MOVING actor earns a per-sample line; a parked pooled one logs its
                    -- appearance (via on_change of TRACK -> parked) and then stays quiet.
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
