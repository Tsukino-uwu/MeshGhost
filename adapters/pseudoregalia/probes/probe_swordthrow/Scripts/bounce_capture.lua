-- Thrown-sword capture: the loose sword's actor rotation and its mesh's relative offset through a flight (the
-- offset a ghost's flyer must compose in), and every Niagara appearance beside the sword's position (the one
-- at the sword on a velocity flip is the wall-bounce burst). Named reads only; throw at walls on this client.

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
                    -- SkeletalMesh is the prop's visual component, as its own reflection dump named it.
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
