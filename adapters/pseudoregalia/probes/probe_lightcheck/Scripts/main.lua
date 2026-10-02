-- Light check, read-only: what lights a whole scene (fog, sky light, post-process, the directional and point lights,
-- cameras) beside the character count, one line printed only on a change. A connecting client brightened a room its
-- ghost was not in, so whatever moves in the sample the count rises is the suspect. Named properties only, as
-- Unreal's docs give them for each component class; kept to a handful of objects, since each class is a world walk.
-- Deploy as ue4ss\Mods\MeshGhostLightCheck; it ships without an enabled.txt, so create one to arm it.

local TAG = "[MeshGhostLightCheck]"

local PROBE_ENABLED = true

local INTERVAL_MS = 1000 -- the event is a client connecting, not a per-frame effect

-- Named properties: reading whatever an object holds is what crashed this game.
local WATCH = {
    {class = "ExponentialHeightFogComponent",
     props = {"FogDensity", "FogHeightFalloff", "FogMaxOpacity", "StartDistance"}},
    {class = "SkyLightComponent",         props = {"Intensity", "bAffectsWorld", "bVisible"}},
    {class = "PostProcessComponent",      props = {"bEnabled", "BlendWeight", "Priority", "bUnbound"}},
    {class = "DirectionalLightComponent", props = {"Intensity", "bAffectsWorld", "bVisible"}},
    {class = "PointLightComponent",       props = {"Intensity"}},
    -- A pawn clone brings its own camera, and its post-process blending into the view would brighten the whole screen.
    {class = "CameraComponent",
     props = {"PostProcessBlendWeight", "bIsActive", "bAutoActivate", "FieldOfView"}},
}

local last = nil

local function shortName(obj)
    local n
    pcall(function() n = obj:GetFullName() end)
    if not n then return "<unnamed>" end
    return n:match("([^%.]+%.[^%.]+)$") or n
end

local function prop(obj, name)
    local v
    local ok = pcall(function() v = obj[name] end)
    if not ok then return nil end
    return v
end

local function valueText(v)
    if type(v) == "number" then return string.format("%.3f", v) end
    return tostring(v)
end

local function sample()
    local parts = {}

    -- The character count shares the line: it is the clock this measurement is read against.
    local pawns = FindAllOf("BP_PlayerGoatMain_C")
    local count = 0
    if pawns then for _ in pairs(pawns) do count = count + 1 end end
    if count == 0 then
        return    -- no level yet; nothing to compare
    end
    parts[#parts + 1] = string.format("characters=%d", count)

    for _, entry in ipairs(WATCH) do
        local found = FindAllOf(entry.class)
        if found then
            for _, obj in pairs(found) do
                local name = shortName(obj)
                if name ~= "<unnamed>" then
                    local fields = {}
                    for _, p in ipairs(entry.props) do
                        local v = prop(obj, p)
                        if v ~= nil then
                            fields[#fields + 1] = string.format("%s=%s", p, valueText(v))
                        end
                    end
                    if #fields > 0 then
                        parts[#parts + 1] = string.format("%s{%s}", name, table.concat(fields, ","))
                    end
                end
            end
        end
    end

    table.sort(parts)
    local line = string.format("%s SCENE %s", TAG, table.concat(parts, " "))
    if line ~= last then
        last = line
        print(line .. "\n")
    end
end

LoopAsync(INTERVAL_MS, function()
    if not PROBE_ENABLED then
        return true
    end
    ExecuteInGameThread(sample)
    return false
end)

print(string.format("%s loaded -- scene lighting and character count, printed on CHANGE only.\n", TAG))
