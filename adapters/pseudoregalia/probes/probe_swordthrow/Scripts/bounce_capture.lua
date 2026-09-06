-- Capture round for the two remaining thrown-sword gaps (2026-09-01, user):
--   1. the flyer's in-air POSE/SPIN is wrong -- so log the REAL loose sword's actor rotation
--      AND its mesh's RelativeLocation/RelativeRotation through a flight: whatever offset the
--      real one carries between actor and mesh is what the flyer must compose in.
--   2. the wall-bounce VFX is unmirrored -- so log every Niagara appearance while a sword is in
--      flight, with position relative to the sword: the one that appears at the sword on a
--      velocity flip is the bounce burst, by name.
--
-- Passive, named-property reads only (the safe census shape). Throw at walls a few times on
-- THIS client; no timing to hit.

local TAG = "[MeshGhostBounceCapture]"
local INTERVAL_MS = 150

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

local function rot_text(r)
    if not r then return "?" end
    local p, y, ro
    pcall(function() p, y, ro = r.Pitch, r.Yaw, r.Roll end)
    if p == nil then return "?" end
    return string.format("%.1f,%.1f,%.1f", p, y, ro)
end

local seen_fx = {}
local samples = 0
local flight_pos = nil -- last known in-flight sword position, for attributing new VFX

local function sample()
    samples = samples + 1

    local in_flight = false
    local weapons = FindAllOf("BP_looseWeapon_C")
    if weapons then
        for _, actor in pairs(weapons) do
            local root = prop(actor, "RootComponent")
            if root then
                local state = prop(actor, "weaponState")
                local pm = prop(actor, "ProjectileMovement")
                local active = pm and prop(pm, "bIsActive")
                if state == 0 or active == true then
                    in_flight = true
                    local loc = prop(root, "RelativeLocation")
                    flight_pos = loc
                    -- The pose question, all in one line: actor-root rotation vs the visual
                    -- mesh's own relative offset. 'SkeletalMesh' is the prop's visual component
                    -- (its own reflection dump named it).
                    local mesh = prop(actor, "SkeletalMesh")
                    print(string.format("%s FLIGHT %s loc=%s rootRot=%s meshRelLoc=%s meshRelRot=%s vel=%s\n",
                                        TAG, short(full_name(actor)), vec_text(loc),
                                        rot_text(prop(root, "RelativeRotation")),
                                        mesh and vec_text(prop(mesh, "RelativeLocation")) or "?",
                                        mesh and rot_text(prop(mesh, "RelativeRotation")) or "?",
                                        pm and vec_text(prop(pm, "Velocity")) or "?"))
                end
            end
        end
    end

    -- Niagara appearances, attributed against the in-flight sword's position -- the bounce
    -- burst is whichever system shows up at the sword mid-flight.
    local effects = FindAllOf("NiagaraComponent")
    if effects then
        for _, fx in pairs(effects) do
            local name = full_name(fx)
            if name and not seen_fx[name] then
                seen_fx[name] = true
                if samples > 1 then
                    local asset = prop(fx, "Asset")
                    print(string.format("%s FXAPPEAR asset='%s' at=%s swordAt=%s inFlight=%s\n",
                                        TAG, asset and (full_name(asset) or "?") or "<none>",
                                        vec_text(prop(fx, "RelativeLocation")),
                                        flight_pos and vec_text(flight_pos) or "?",
                                        tostring(in_flight)))
                end
            end
        end
    end

    if samples % 66 == 1 then
        print(string.format("%s WATCHING samples=%d (throw at walls on this client)\n", TAG, samples))
    end
end

LoopAsync(INTERVAL_MS, function()
    ExecuteInGameThread(sample)
    return false
end)

print(string.format("%s loaded -- throw the sword at walls a few times on this client.\n", TAG))
