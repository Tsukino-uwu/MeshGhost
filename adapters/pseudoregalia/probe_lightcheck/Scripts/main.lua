-- MeshGhost light-check probe. ONE question, and the previous seven stages are gone.
--
-- **The question, from the user 2026-08-29:** *"when i connected the 2nd client, it got bright
-- around the 1st clients game... even before i could walk over there"*, and solo play has no such
-- brightness. A light attached to a ghost cannot brighten a room the ghost is not in, so the
-- suspect is no longer a component on the ghost at all -- it is something SCENE-WIDE that changes
-- when a second player pawn exists.
--
-- That also explains every negative before it: the ghost's `PointLight` really is 0, its model can
-- be hidden entirely, and its materials and effects match the player's -- none of which matters if
-- the thing that changed is the level's own lighting.
--
-- So this reads the handful of things that light a whole scene, plus the character count, and
-- prints ONLY when one of them changes. Connect a second client while it runs and the answer is
-- whichever value moves in the same sample that the character count goes up.
--
-- **Deliberately small, because the last version of this file was not** (2026-08-29): it grew to
-- seven stages and about eleven whole-world `FindAllOf` calls a second -- every static mesh in the
-- level, each paying a name lookup and an attach walk, on the game thread -- and the user felt it
-- as mouse stutter before any metric reported it. These five classes hold a handful of objects
-- between them. `../../_template/probes.md`, the cost warning.
--
-- Read-only, named properties only, no UFunction call on anything. The stage that walked
-- `ForEachProperty` and stringified whatever it found CRASHED THE GAME, and `preflight.ps1` now
-- refuses that shape in any armed probe.
--
-- Grounded APIs (docs.unrealengine.com, checked not remembered):
--   UExponentialHeightFogComponent::{FogDensity, FogHeightFalloff, FogMaxOpacity, StartDistance}
--   USkyLightComponent::Intensity, ULightComponentBase::{Intensity, bAffectsWorld, bVisible}
--   UPostProcessComponent::{bEnabled, BlendWeight, Priority, bUnbound}
--   UE4SS Lua: FindAllOf, ExecuteInGameThread, LoopAsync -- vendored RE-UE4SS/docs/lua-api.
--
-- Deploy: copy probe_lightcheck/ to <install>\...\Win64\ue4ss\Mods\MeshGhostLightCheck\. It ships
-- WITHOUT an enabled.txt -- create one to arm it, and remove it once the question is answered.

local TAG = "[MeshGhostLightCheck]"

local PROBE_ENABLED = true

-- One second is plenty: the event being caught is a client connecting, not a per-frame effect.
local INTERVAL_MS = 1000

-- Each entry is a class and the named properties worth reading off it. NAMED, because a probe that
-- reads whatever an object happens to hold is what crashed this game.
local WATCH = {
    {class = "ExponentialHeightFogComponent",
     props = {"FogDensity", "FogHeightFalloff", "FogMaxOpacity", "StartDistance"}},
    {class = "SkyLightComponent",         props = {"Intensity", "bAffectsWorld", "bVisible"}},
    {class = "PostProcessComponent",      props = {"bEnabled", "BlendWeight", "Priority", "bUnbound"}},
    {class = "DirectionalLightComponent", props = {"Intensity", "bAffectsWorld", "bVisible"}},
    {class = "PointLightComponent",       props = {"Intensity"}},
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

    -- The character count shares the line on purpose: it is the CLOCK for this measurement.
    -- Whatever moves in the same sample where this goes 1 -> 2 is what a connecting peer changed,
    -- and reading it separately would leave that correlation to guesswork.
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
