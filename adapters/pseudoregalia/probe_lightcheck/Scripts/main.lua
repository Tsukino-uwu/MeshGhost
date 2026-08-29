-- MeshGhost light-check probe. TWO stages, and stage 2 exists because stage 1 came back clean
-- while the user was looking straight at the symptom (2026-08-29, screenshot: a ghost blazing
-- white in a pitch-dark room, the local player beside it almost black -- reported in BOTH
-- directions, each instance seeing the other's ghost lit).
--
-- **Stage 1 -- the readback.** After `GHOST_HOLD_LIGHT_OFF` writes a ghost's `PointLight` down to
-- 0, does it STAY at 0? Answer, measured on two instances at once: yes, 5000 -> 0 within a second
-- of spawn, no flicker, nothing fights it. The shipping mod could not answer this about itself --
-- its hold announces a lit component once and is silent after, so a light the game re-lights every
-- frame looks exactly like one fixed on the first sweep (`../../CLAUDE.md`).
--
-- **Stage 2 -- so where is the brightness coming from?** `../../CLAUDE.md`'s rule for exactly this
-- shape: a clean instrument plus a symptom the user still sees means WIDEN THE SUBSYSTEM, never
-- deepen the measurement -- and for anything visual, ask whether it is in the wrong PLACE or the
-- right place doing the wrong THING. Two questions, one run:
--   a) IS THERE ANOTHER EMITTER? `PointLightComponent` was the only class stage 1 enumerated, and
--      the only one the census that started this ever looked at. Spot, Rect, Directional, Sky and
--      plain Light components were never once checked. The user names two ways a real player emits
--      light -- an item that grants it permanently, and throwing the sword and picking it up, which
--      grants it temporarily -- so more than one emitter is expected to exist somewhere.
--   b) IS IT THE MODEL? Every `BP_PlayerGoatMain_C` in the world, its meshes, and for each mesh the
--      material slots and the lighting-relevant flags -- printed for the local player AND every
--      ghost, so the answer is a DIFF between two characters standing in the same room rather than
--      a reading of one. If the ghost's material list or flags differ, that is the lead; if they
--      are identical, the brightness is somewhere neither question reaches, and that is a finding.
--
-- Read-only throughout, and deliberately so: no UFunction call on anything (`GetFullName` is
-- UE4SS's own; `OverrideMaterials`, `LightingChannels` and the rest are plain property reads).
-- Its ancestor `probe_dustlight/` called a UFunction on everything `FindAllOf` handed back and
-- CRASHED A LIVE SESSION TWICE the same day.
--
-- Grounded APIs (all docs.unrealengine.com, checked not remembered):
--   ULightComponentBase::Intensity
--   UMeshComponent::OverrideMaterials, UPrimitiveComponent::{LightingChannels, bCastDynamicShadow,
--     bRenderCustomDepth, bReceivesDecals, bVisible}, USceneComponent::AttachParent
--   UE4SS Lua: FindAllOf, ExecuteInGameThread, LoopAsync -- vendored RE-UE4SS/docs/lua-api.
--
-- Deploy: copy probe_lightcheck/ to <install>\...\Win64\ue4ss\Mods\MeshGhostLightCheck\ (the
-- folder carries its own enabled.txt). Dev-only tooling; never ships.

local UEHelpers = require("UEHelpers")

local TAG = "[MeshGhostLightCheck]"

-- OFF means print nothing at all. A probe still logging through somebody else's test is a suspect
-- in every report that follows -- see probe_nametag's own note.
local PROBE_ENABLED = true

-- Stage 1's budget, counted only where there was a world with lights in it -- the first run armed
-- at the main menu and would have spent its whole budget printing "nothing here" before the level
-- existed. A budget spent on an empty world is a probe that answers nothing while looking like it
-- ran.
local MAX_SAMPLES = 600

-- Every concrete light component class worth asking about. `LightComponent` is a base and is
-- included on purpose: if this build instantiates one directly, nothing else here would see it.
local LIGHT_CLASSES = {
    "PointLightComponent", "SpotLightComponent", "RectLightComponent",
    "DirectionalLightComponent", "SkyLightComponent", "LightComponent",
}

-- The flags that decide whether a mesh is lit by the room or ignores it. Read on the player's
-- meshes and on each ghost's, and compared between them -- one character in the same room is the
-- control for the other.
local MESH_FLAGS = {
    "bVisible", "bCastDynamicShadow", "bRenderCustomDepth", "bReceivesDecals",
    "bCastShadowAsTwoSided", "bAffectDynamicIndirectLighting", "CustomDepthStencilValue",
}

local samples = 0
local last_line = nil
local dumped_stage2 = false

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

-- Stage 1. Returns true only when a world with lights in it was actually read.
local function sampleLights()
    local total, names = 0, {}
    for _, className in ipairs(LIGHT_CLASSES) do
        local found = FindAllOf(className)
        if found then
            for _, light in pairs(found) do
                local name = shortName(light)
                local intensity = prop(light, "Intensity")
                if name ~= "<unnamed>" then
                    total = total + 1
                    if intensity and intensity ~= 0 then
                        names[#names + 1] = string.format("%s[%s]=%s", name, className, tostring(intensity))
                    end
                end
            end
        end
    end
    if total == 0 then
        return false
    end

    -- `lit=0` is the answer we hope for and it has to be PRINTED rather than inferred from silence:
    -- "the hold is working" and "the probe is dead" must not look the same in a log.
    local line = string.format("%s lights=%d lit=%d %s", TAG, total, #names, table.concat(names, " "))
    if line ~= last_line then
        last_line = line
        print(line .. "\n")
    end
    return true
end

-- Stage 2, printed ONCE per load. A per-second dump of this would bury stage 1's change lines, and
-- the question it asks -- how a ghost's model differs from the player's -- does not change from
-- second to second.
local function dumpCharacters()
    local pawns = FindAllOf("BP_PlayerGoatMain_C")
    if not pawns then
        print(string.format("%s CHARS: no BP_PlayerGoatMain_C found\n", TAG))
        return false
    end

    for _, pawn in pairs(pawns) do
        local pawnName = shortName(pawn)
        for _, meshProp in ipairs({"VisualMesh", "WeaponMesh"}) do
            local mesh = prop(pawn, meshProp)
            if mesh then
                local flags = {}
                for _, f in ipairs(MESH_FLAGS) do
                    local v = prop(mesh, f)
                    if v ~= nil then
                        flags[#flags + 1] = string.format("%s=%s", f, tostring(v))
                    end
                end

                -- Lighting channels are a struct of three bools; read them one by one rather than
                -- printing the struct, whose tostring is a pointer.
                local lc = prop(mesh, "LightingChannels")
                if lc then
                    for _, ch in ipairs({"bChannel0", "bChannel1", "bChannel2"}) do
                        local v = prop(lc, ch)
                        if v ~= nil then
                            flags[#flags + 1] = string.format("LC.%s=%s", ch, tostring(v))
                        end
                    end
                end

                -- The material slots as the component actually holds them. An override the game
                -- sets on a real player and never sets on a ghost would show up right here as a
                -- different list length or a different asset.
                local mats = {}
                local overrides = prop(mesh, "OverrideMaterials")
                if overrides then
                    pcall(function()
                        overrides:ForEach(function(i, elem)
                            local m = elem:get()
                            mats[#mats + 1] = string.format("[%d]%s", i, m and shortName(m) or "nil")
                        end)
                    end)
                end

                -- **What each side is ACTUALLY rendered with.** An empty `OverrideMaterials` is not
                -- "no material" -- it means the component falls through to the mesh asset's own
                -- defaults, which may or may not be the same assets the player's dynamic instances
                -- were made from. Printing the MID's `Parent` next to the asset's default list is
                -- what tells "the ghost uses a different material" apart from "the ghost uses the
                -- same material without an instance wrapper", and only the first would explain a
                -- brightness difference.
                local parents = {}
                if overrides then
                    pcall(function()
                        overrides:ForEach(function(i, elem)
                            local m = elem:get()
                            local p = m and prop(m, "Parent")
                            parents[#parents + 1] = string.format("[%d]parent=%s", i, p and shortName(p) or "nil")
                        end)
                    end)
                end
                local assetMats = {}
                local asset = prop(mesh, "SkeletalMesh")
                if asset then
                    local arr = prop(asset, "Materials")
                    if arr then
                        pcall(function()
                            arr:ForEach(function(i, elem)
                                local entry = elem:get()
                                local mi = entry and prop(entry, "MaterialInterface")
                                assetMats[#assetMats + 1] = string.format("[%d]%s", i, mi and shortName(mi) or "nil")
                            end)
                        end)
                    end
                end

                print(string.format("%s CHAR %s.%s %s materials=%d %s %s assetMats=%d %s\n",
                    TAG, pawnName, meshProp, table.concat(flags, " "), #mats, table.concat(mats, " "),
                    table.concat(parents, " "), #assetMats, table.concat(assetMats, " ")))
            end
        end
    end
    return true
end

-- Stage 3 -- what does the game DRIVE on those instances?
--
-- Stage 2 answered "the player's meshes carry four dynamic material instances and a ghost's carry
-- none", which names the difference without naming the parameter. This reads every scalar and
-- vector parameter off the player's own instances and prints ONLY when one moves, so walking from
-- a lit room into a dark one shows which parameter tracks the darkness -- and therefore which one a
-- ghost is missing. A ghost has no instances at all, so there is nothing here to read on one; the
-- player is both the subject and the control.
--
-- `entry.ParameterInfo.Name:ToString()` and `entry.ParameterValue` are the idiom probe_nametag
-- confirmed live on this build 2026-08-28.
local last_params = {}

local function describeValue(entry)
    local v = entry.ParameterValue
    if type(v) == "userdata" then
        -- An FLinearColor. Printed to two decimals: the question is which channel MOVES, and full
        -- float precision turns every frame of noise into a change line.
        local r, g, b, a
        pcall(function() r, g, b, a = v.R, v.G, v.B, v.A end)
        if r then
            return string.format("(%.2f,%.2f,%.2f,%.2f)", r, g, b, a)
        end
    end
    if type(v) == "number" then
        return string.format("%.3f", v)
    end
    return tostring(v)
end

local function dumpParams()
    local pawns = FindAllOf("BP_PlayerGoatMain_C")
    if not pawns then
        return
    end
    for _, pawn in pairs(pawns) do
        local pawnName = shortName(pawn)
        local parts = {}
        for _, meshProp in ipairs({"VisualMesh", "WeaponMesh"}) do
            local mesh = prop(pawn, meshProp)
            local overrides = mesh and prop(mesh, "OverrideMaterials")
            if overrides then
                pcall(function()
                    overrides:ForEach(function(slot, elem)
                        local mat = elem:get()
                        if not mat then return end
                        for _, arrayName in ipairs({"ScalarParameterValues", "VectorParameterValues"}) do
                            local arr = prop(mat, arrayName)
                            if arr then
                                pcall(function()
                                    arr:ForEach(function(_, pelem)
                                        local entry = pelem:get()
                                        local ok, name = pcall(function()
                                            return entry.ParameterInfo.Name:ToString()
                                        end)
                                        if ok and name then
                                            parts[#parts + 1] = string.format("%s[%d].%s=%s",
                                                meshProp, slot, name, describeValue(entry))
                                        end
                                    end)
                                end)
                            end
                        end
                    end)
                end)
            end
        end
        if #parts > 0 then
            local line = string.format("%s PARAMS %s %s", TAG, pawnName, table.concat(parts, " "))
            if last_params[pawnName] ~= line then
                last_params[pawnName] = line
                print(line .. "\n")
            end
        end
    end
end

-- Stage 4 -- what EFFECTS is each character carrying?
--
-- Reached by elimination, 2026-08-29, and every step of it was a measurement: the ghost's
-- `PointLight` is 0 and no other light class in the level is lit (stage 1); its meshes, material
-- parents, lighting channels and shadow flags match the player's exactly (stage 2); the only
-- parameters the game drives on those materials are `DieAmount` and `UVOffset` (stage 3); and
-- restoring `bRenderCustomDepth`, the single field that DID differ, changed nothing on screen.
-- So the brightness is not a light, not the material, and not the shading pass.
--
-- What is left is something ATTACHED. This adapter mirrors peer effects onto ghosts, one of them
-- is a recall GLOW that mirrors presence, and the dust fix moved several one-shot rows to counters
-- earlier on 2026-08-29 -- an effect turned on for a ghost and never turned off would look exactly
-- like this, and would be ours rather than the game's.
--
-- Lists every Niagara/Cascade component in the world with the character it hangs off, printed on
-- CHANGE. The comparison is the point: the player standing in the same room is the control, so an
-- effect present on a ghost and absent on the player is the answer.
local last_effects = nil

local EFFECT_CLASSES = {"NiagaraComponent", "ParticleSystemComponent"}

local function dumpEffects()
    local entries = {}
    for _, className in ipairs(EFFECT_CLASSES) do
        local found = FindAllOf(className)
        if found then
            for _, comp in pairs(found) do
                local name = shortName(comp)
                if name ~= "<unnamed>" then
                    -- Attributed up the attach chain, the same way the light census had to be: an
                    -- effect spawned as a child actor outers to the LEVEL and would otherwise
                    -- report as belonging to nobody.
                    local owner = "?"
                    local node = comp
                    for _ = 1, 8 do
                        local n = shortName(node)
                        local goat = n:match("(BP_PlayerGoatMain_C_%d+)")
                        if goat then owner = goat; break end
                        local parent = prop(node, "AttachParent")
                        if not parent then break end
                        node = parent
                    end
                    local active = prop(comp, "bIsActive")
                    local visible = prop(comp, "bVisible")
                    -- **The asset, which the first version of this census did not print -- and that
                    -- omission cost a round.** A Niagara component's NAME is auto-generated
                    -- (`NiagaraComponent_2147482189`), so "player has one, ghost has one" looked
                    -- symmetric while the two could be entirely different systems. A Niagara
                    -- emitter can carry a LIGHT RENDERER, which emits real light into the scene
                    -- without ever being a PointLightComponent -- exactly the shape that survives a
                    -- light census reading `lit=0` while the user watches a ghost light up a wall.
                    -- `Asset` is a named property this adapter already reads on this build
                    -- (`PLAYER_FIELDS.md`, the thrown sword's `idleGlowVFX`).
                    local asset = prop(comp, "Asset")
                    entries[#entries + 1] = string.format("%s@%s(asset=%s,active=%s,vis=%s)",
                        name, owner, asset and shortName(asset) or "<none>",
                        tostring(active), tostring(visible))
                end
            end
        end
    end

    table.sort(entries)
    local line = string.format("%s FX n=%d %s", TAG, #entries, table.concat(entries, " "))
    if line ~= last_effects then
        last_effects = line
        print(line .. "\n")
    end
end

-- Stage 5 -- WITHDRAWN. It CRASHED THE GAME (2026-08-29), and it is the same mistake as the one
-- this file's header already warns about, made one layer up.
--
-- What it did: `ForEachProperty` on the pawn class, then read EVERY named property off a live
-- player and a live ghost and stringified each one -- which for an object-valued property meant
-- `:GetClass():GetFName()` on whatever the pointer happened to be. `probe_dustlight/` died calling
-- a UFunction on everything `FindAllOf` handed back; this died dereferencing everything a live
-- actor points AT. The lesson generalises and the header's version of it did not: **enumerate what
-- you can name, never what an object happens to hold.** A `pcall` catches neither: an access
-- violation in native code is not a Lua error.
--
-- If the player-vs-ghost diff is still wanted, it needs a NAMED list of properties -- the way
-- MESH_FLAGS above is a named list -- read one at a time, with the list grown between runs. That
-- is slower and it is the only version of this that is allowed to run again.

-- Stage 6 -- character-shaped meshes that are NOT a character.
--
-- The effect census asked about Niagara and Cascade only, which assumes the brightness is a
-- particle system. This adapter also spawns AFTERIMAGES -- pooled skeletal-mesh actors with the
-- player's own model -- and one parked on top of a ghost and never released would read on screen
-- as "the ghost is bright", not as "there is a second character here", because it is the same
-- model in the same pose in the same place.
--
-- Lists every visible SkeletalMeshComponent whose owner is NOT a `BP_PlayerGoatMain_C`, printed on
-- CHANGE. One line, and the interesting outcome is any entry at all near the characters.
--
-- Named classes only, one property read each: the enumeration is scoped to a class this build is
-- known to have, and nothing here follows a pointer the object handed back.
local last_meshes = nil

local function dumpExtraMeshes()
    local found = FindAllOf("SkeletalMeshComponent")
    if not found then return end
    local entries = {}
    for _, comp in pairs(found) do
        local name = shortName(comp)
        if name ~= "<unnamed>" and not name:match("^BP_PlayerGoatMain_C_%d+%.") then
            if prop(comp, "bVisible") ~= false then
                entries[#entries + 1] = name
            end
        end
    end
    table.sort(entries)
    local line = string.format("%s MESHES notPawn=%d %s", TAG, #entries, table.concat(entries, " "))
    if line ~= last_meshes then
        last_meshes = line
        print(line .. "\n")
    end
end

LoopAsync(1000, function()
    if not PROBE_ENABLED then
        return true    -- stop the loop entirely
    end
    if samples >= MAX_SAMPLES then
        print(string.format("%s done -- %d samples taken, stopping.\n", TAG, MAX_SAMPLES))
        return true
    end
    ExecuteInGameThread(function()
        if sampleLights() then
            samples = samples + 1
        end
        dumpParams()
        dumpEffects()
        dumpExtraMeshes()
        if not dumped_stage2 then
            -- Held until a second character exists: a dump of the local player alone has no control
            -- to compare against, and it is the DIFFERENCE that is the finding.
            local pawns = FindAllOf("BP_PlayerGoatMain_C")
            if pawns and #pawns >= 2 then
                dumped_stage2 = dumpCharacters()
            end
        end
    end)
    return false
end)

print(string.format("%s loaded -- stage 1: every light class, printed on CHANGE. stage 2: player-vs-ghost mesh diff, once, as soon as two characters exist.\n", TAG))
