-- MeshGhost blade-glow census probe. One question, asked of every pawn at once, 2026-09-04.
--
-- THE REPORT: a replay ghost holding the Dream Breaker wears the blade aura, which the user says
-- belongs to Ascendant Light and should not be there without it.
--
-- THE SUSPECT IS MY OWN CHANGE, which is why this measures instead of assuming. The weapon-mesh
-- mirror shipped the same day calls the adapter's `call_set_visibility`, and that helper writes
-- the SetVisibility call's second parameter as 1 -- `bPropagateToChildren`. So showing a ghost's
-- WeaponMesh may be showing everything hanging off it, and `LightMesh` (the M_SpiritAura blade
-- aura, census 2026-08-29) is a candidate child. The competing explanation is that the aura is
-- not LightMesh at all and my change is innocent.
--
-- WHAT SETTLES IT, and it is one line of output: is the GHOST's LightMesh visible while the
-- PLAYER's is not, and is LightMesh's AttachParent the WeaponMesh? Both pawns are read in the
-- same pass, because the last three wrong theories in this adapter all came from reasoning about
-- one pawn and the right answer came from diffing two.
--
-- WHAT THIS CANNOT SEE, said up front:
--   * `bVisible`/`bHiddenInGame` are STOCK ENGINE BOOLS, and PLAYER_FIELDS.md records that this
--     game's stock bools read as garbage through a byte-wide reflection read (bHidden and
--     bActorIsBeingDestroyed both read true on a live actor). Both are printed so they can
--     disagree out loud rather than one of them being quietly trusted.
--   * It reads a NAMED list of three meshes. If the aura is a fourth component nobody has named,
--     this probe reports three clean meshes and the aura is still on screen -- which is the
--     "widen the subsystem" signal, not a negative result.
--   * It never calls a UFunction on anything FindAllOf returned, and never walks properties
--     blindly. Both crashed live sessions on 2026-08-29.
--
-- NO WINDOW TO HIT. It prints a full census as soon as pawns exist, then only on change. Stand
-- anywhere, look at whichever ghost has a sword, take as long as you like.
--
-- Dev-only tooling; never ships. UNLOAD IT before judging anything else.

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

-- A PAWN's short name, and a COMPONENT's must not use it.
--
-- The first version of this probe reused probe_pickup's `short()` for both, and it silently
-- answered the wrong question: that helper matches `[%w_]+_C_%d+` FIRST, which is the ACTOR
-- portion of a component's full name -- so `...BP_PlayerGoatMain_C_2147481501.WeaponMesh` came
-- back as `BP_PlayerGoatMain_C_2147481501`, and every AttachParent in the census collapsed to the
-- pawn. The attach chain was the whole question, and the instrument could not print it.
-- Same shape as the pickup probe's swallowed first sighting: an instrument that hides the thing
-- being measured still produces a complete-looking result.
local function short(n)
    if not n then return "<nil>" end
    return n:match("([%w_]+_C_%d+)") or n:match("([^%.:%s]+)$") or n
end

-- Keeps the trailing member, so a component prints as `<Actor>.<Component>` and a parent that is
-- a component is distinguishable from a parent that is the actor's root.
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
            -- After the census, a key's FIRST sighting is a new actor arriving -- a ghost
            -- spawning -- and its STARTING state is the whole question here. The pickup probe
            -- swallowed exactly this and had nothing to say about the thing being measured.
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

            -- WHICH PAWN IS THIS? A ghost is a pawn nobody drives, so a Controller separates the
            -- local player from every ghost without our code having to tell the probe which is
            -- which -- the probe decides from a value it prints, not from an assumption.
            local controller = prop(pawn, "Controller")
            on_change(p .. "isLocalPlayer", tostring(controller ~= nil))

            -- The unlock flag the user's report is about. A Blueprint bool, so unlike the stock
            -- engine bools it is expected to read correctly (PLAYER_FIELDS.md).
            on_change(p .. "obtainedLight?", tostring(read(pawn, "obtainedLight?", "obtainedLight?")))
            on_change(p .. "weaponEquipped?", tostring(read(pawn, "weaponEquipped?", "weaponEquipped?")))

            for _, mesh_name in ipairs(MESHES) do
                local mesh = read(pawn, mesh_name, mesh_name)
                if mesh then
                    local m = p .. mesh_name .. "."
                    on_change(m .. "bVisible", tostring(prop(mesh, "bVisible")))
                    on_change(m .. "bHiddenInGame", tostring(prop(mesh, "bHiddenInGame")))
                    -- THE PROPAGATION QUESTION. If LightMesh's parent is WeaponMesh, then
                    -- showing the weapon with bPropagateToChildren=1 shows the aura too, and the
                    -- fix is a non-propagating write rather than anything about lights.
                    local parent = prop(mesh, "AttachParent")
                    on_change(m .. "AttachParent", parent and short_component(full_name(parent)) or "<none>")
                    -- The component's OWN name printed beside its parent's, so the chain can be
                    -- read without trusting either matcher: if these two ever look identical,
                    -- the matcher is eating the member again rather than the game being odd.
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
