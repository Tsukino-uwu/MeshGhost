-- What does the game do to the PLAYER's blob shadow during a chair sit? (2026-09-01, user:
-- the ghost keeps its shadow while sitting; the real player's goes away.) Log every
-- StaticMeshComponent name-owned by each pawn (the shadow is one of them -- the subtraction
-- sweeps found it by exactly this class+containment test), with its visibility-shaped fields,
-- ON CHANGE. Sit on a chair, stand up, sit again; whichever field flips names the mechanism.
--
-- Named property reads only. The bVisible byte is a known liar (bitfield) -- that is WHY three
-- fields are read side by side; agreement is the evidence, not any one of them.

local TAG = "[MeshGhostShadowSit]"
local INTERVAL_MS = 250

local last = {}

local function full_name(obj)
    local n
    pcall(function() n = obj:GetFullName() end)
    return n
end

local function short(n)
    if not n then return "<nil>" end
    return n:match("([^%.:]+)$") or n
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
    return string.format("%.2f,%.2f,%.2f", x, y, z)
end

local function on_change(key, value)
    if last[key] ~= value then
        last[key] = value
        print(string.format("%s CHANGE %s = %s\n", TAG, key, value))
    end
end

local samples = 0
LoopAsync(INTERVAL_MS, function()
    ExecuteInGameThread(function()
        samples = samples + 1
        local pawn_names = {}
        local pawns = FindAllOf("BP_PlayerGoatMain_C")
        if pawns then
            for _, pawn in pairs(pawns) do
                if prop(pawn, "RootComponent") then
                    local n = full_name(pawn)
                    if n then pawn_names[#pawn_names + 1] = n:match("(BP_PlayerGoatMain_C_%d+)") end
                end
            end
        end
        local comps = FindAllOf("StaticMeshComponent")
        local watched = 0
        if comps then
            for _, comp in pairs(comps) do
                local cname = full_name(comp)
                if cname then
                    for _, pn in ipairs(pawn_names) do
                        if pn and cname:find(pn, 1, true) then
                            watched = watched + 1
                            local key = pn .. "/" .. short(cname)
                            on_change(key .. ".bVisible", tostring(prop(comp, "bVisible")))
                            on_change(key .. ".bHiddenInGame", tostring(prop(comp, "bHiddenInGame")))
                            on_change(key .. ".scale", vec_text(prop(comp, "RelativeScale3D")))
                            break
                        end
                    end
                end
            end
        end
        if samples % 40 == 1 then
            print(string.format("%s WATCHING pawns=%d staticMeshComps=%d -- sit on a chair, stand, sit again.\n",
                                TAG, #pawn_names, watched))
        end
    end)
    return false
end)

print(string.format("%s loaded -- sit on a chair, stand up, sit again.\n", TAG))
