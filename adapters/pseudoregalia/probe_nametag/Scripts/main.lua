-- MeshGhost nametag-colour probe. ONE question, from UNVERIFIED.md's 2026-08-28 entry: is there
-- a material on this build that samples BOTH a texture we can point at the font atlas AND a
-- colour we can drive? The shipped nametag's colour plumbing is correct end to end and the text
-- still renders black; the material was identified as the untested half.
--
-- What one run does, in order:
--   1. CENSUS: dumps every loaded MaterialInstanceConstant/Dynamic with its parent and its
--      Scalar/Vector/TextureParameterValues arrays -- the parameter NAMES the game's master
--      materials actually expose, which the 2026-08-28 C++ census (base Materials only) never
--      captured. Dump everything, filter afterwards (probes.md rule).
--   2. EXPERIMENT: spawns a row of TextRenderActors in front of the player, one per candidate
--      material. Each gets the same text (its own label, so the screen is self-identifying),
--      the same TextRenderColor, and -- for MID candidates -- a MaterialInstanceDynamic of that
--      master with the RobotoDistanceField font texture set on every plausible texture
--      parameter name and the target colour on every plausible colour parameter name.
--      Two KNOWN-ANSWER controls anchor the method (probes.md: validate on a case you know):
--      DEFAULT (component's own material -- known BLACK) and EMISSIVE
--      (EmissiveMeshMaterial -- known solid WHITE BOX, no glyphs, 2026-08-28).
--   3. READBACK: independently re-reads each component's text, colour bytes and material and
--      logs them -- never the value just written.
--
-- Hot-reloadable (dev-scripts\pseudo-hotreload.ps1): each load first destroys every
-- TextRenderActor in the world (the game itself has none -- census 2026-08-28 counted 0
-- TextRenderComponent instances), so reloads are idempotent and no orphan outlives an iteration.
--
-- Grounded APIs. Everything engine-side is either confirmed live in this repo's own probes
-- (SpawnActor, K2_GetActorLocation/Rotation, GetComponentByClass, direct UPROPERTY reads/writes:
-- probe_ghost/Scripts/main.lua) or confirmed on this build by the 2026-08-28 NAMETAGCENSUS
-- (CreateDynamicMaterialInstance=found, SetTextMaterial=found, SetTextRenderColor=found,
-- RobotoDistanceField Textures=1). The reflected property/function names come from Epic's public
-- API documentation, and every single one is pcall-guarded and REPORTED if absent, because
-- availability on this build is a runtime question (adapters/pseudoregalia/CLAUDE.md):
--   UMaterialInstance::{Scalar,Vector,Texture}ParameterValues  -- docs.unrealengine.com, UMaterialInstance
--   FMaterialParameterInfo::Name                               -- docs.unrealengine.com, FMaterialParameterInfo
--   UMaterialInstanceDynamic::SetTextureParameterValue/SetVectorParameterValue -- docs.unrealengine.com
--   UPrimitiveComponent::CreateDynamicMaterialInstance         -- docs.unrealengine.com
--   UFont::Textures                                            -- docs.unrealengine.com, UFont
--   ATextRenderActor / UTextRenderComponent (Text, WorldSize, TextRenderColor, SetTextMaterial)
--                                                              -- docs.unrealengine.com
-- UE4SS Lua surface (FText, FName, TArray:ForEach, StaticFindObject, FindAllOf,
-- ExecuteInGameThread, LoopAsync) -- vendored RE-UE4SS/docs/lua-api, checked not remembered.
--
-- Deploy: copy probe_nametag/ to <install>\...\Win64\ue4ss\Mods\MeshGhostNametagProbe\ (the
-- folder carries its own enabled.txt). Dev-only tooling; never ships.

local UEHelpers = require("UEHelpers")

local TAG = "[MeshGhostNametagProbe]"

-- The target colour: the same cyan (#33CCFF) the 2026-08-28 session drove, so results compare.
local COLOR_BYTES = { R = 51, G = 204, B = 255, A = 255 }   -- FColor, for SetTextRenderColor
local COLOR_LINEAR = { R = 0.2, G = 0.8, B = 1.0, A = 1.0 } -- FLinearColor, for vector params

-- Candidate materials, all from the 2026-08-28 census of what is LOADED on this build.
-- label doubles as the on-screen text, so a screenshot needs no legend.
-- ROUND 4 (2026-08-29). Screen results so far, judged by the user in ZONE_Dungeon:
--   Round 2: base-colour materials all render the atlas RED (distance field lives in the red
--   channel); vertex colour reaches nothing; M_Cracks passes colour through cleanly but
--   INVERTED (cyan background box, dark soft glyphs).
--   Round 3: SPIRIT overlays its own aura noise; TRANS renders fully transparent (probably an
--   opacity param defaulting to 0 -- schema dump below will say); DARKCIR is a cyan gradient,
--   no glyphs; LENSFLR/LIGHTBB distort the mesh; ANIMSPR = CRACKS-but-red; the widget pair are
--   red boxes (SlateUI texture RGB), black from behind. Only DEFAULT and ANIMSPR render
--   two-sided -- academic for the shipped tag, which billboards to face the camera every tick.
-- This round: the engine's own TRANSLUCENT text material (never loaded, so never tried -- the
-- proper distance-field shader, LoadAsset'd on demand), a MID of the default text material
-- (its SHADER may expose parameters that the C++ property walk of the material OBJECT could
-- never see), and the two colour-through game masters kept for the schema dump.
-- The user's direction (2026-08-29): the likely ship shape is crisp DEFAULT text over a
-- coloured background plate, "1 with the background of 7". A `plate` entry spawns a PAIR:
-- crisp default-material text in front, and 4 units behind it a second text component
-- rendering the same string through a colour-driven MID whose texture params are forced to
-- the game's own flat-white texture (T_White) -- solid peer-coloured blocks exactly the
-- word's width, i.e. a plate that sizes itself.
-- ROUND 6 (2026-08-29): the user picked the PLT-EMIS pair on screen -- crisp default-material
-- text over an EmissiveMeshMaterial plate, which stays evenly lit in a dark room. TEXTMID
-- proved black even with every parameter forced (the default text material has none), and
-- DefaultTextMaterialTranslucent is not cooked. Remaining question: WHICH single vector
-- parameter name actually coloured the emissive plate. Each tag below sets exactly one --
-- the label IS the name under test, so a cyan plate names its own parameter.
-- ROUND 7 (2026-08-29): "Color" was the winning parameter (its tag alone went cyan). Now the
-- DEFAULT plate colour for a peer who set none -- candidates the user judges by eye, each tag
-- both labeled with and painted in the colour it proposes. Criteria: black text must read on
-- it, it must not glare like white, and it should sit well against this game's muted castle
-- palette. Dimmer values also glow less (the plate is emissive).
local EMISSIVE_PATH = "/Engine/EngineMaterials/EmissiveMeshMaterial.EmissiveMeshMaterial"
local CANDIDATES = {
    { label = "PARCHMENT", plate = EMISSIVE_PATH, vecName = "Color", rgb = { 0.66, 0.60, 0.46 } }, -- ~#CFC6AE
    { label = "LAVENDER",  plate = EMISSIVE_PATH, vecName = "Color", rgb = { 0.38, 0.34, 0.59 } }, -- ~#9C94C4
    { label = "SLATE",     plate = EMISSIVE_PATH, vecName = "Color", rgb = { 0.45, 0.50, 0.55 } }, -- cool grey
    { label = "DIMWHITE",  plate = EMISSIVE_PATH, vecName = "Color", rgb = { 0.55, 0.55, 0.52 } }, -- white at ~55%
}

local WHITE_TEX_PATH = "/Game/RetroGraphics/Textures/T_White.T_White" -- census 2026-08-29
local PLATE_BEHIND_UNITS = 4.0

-- Masters whose FULL cooked parameter schema round 4 dumps. The census can only see parameters
-- an instance OVERRODE; the complete list lives in the master's CachedExpressionData
-- (docs.unrealengine.com, UMaterialInterface::CachedExpressionData), and M_trans/M_Cracks may
-- hold an opacity/invert switch no instance ever touched.
-- EMPTY, and staying so: measured 2026-08-29, `CachedExpressionData` reads as nil through this
-- build's reflection on every master tried -- the cooked parameter tables are not reachable
-- this way, so parameter names come from instance overrides (census) and guesses only.
local SCHEMA_TARGETS = {}

-- Parameter-name guesses tried on EVERY candidate MID; setting a name a master does not use is
-- inert, so over-asking costs nothing and under-asking silently fails. The census (step 1)
-- ADDS to these lists at runtime: any name an instance of the same master exposes.
local TEX_PARAM_GUESSES = { "SpriteTexture", "Texture", "BaseTexture", "MainTexture", "Tex",
                            "Albedo", "Diffuse", "BaseColorTexture", "T_Base", "Sprite",
                            "SlateUI" } -- the widget materials' texture slot

-- Scalars that gate visibility on the translucent candidates: full opacity, mid mask cutoff.
-- Only these two -- blind-setting scalars like "Sprite Size" would distort the mesh.
local SCALAR_PARAMS = { { name = "Opacity", value = 1.0 }, { name = "Cutoff", value = 0.5 } }
local VEC_PARAM_GUESSES = { "Color", "Colour", "Tint", "TintColor", "BaseColor", "SpriteColor",
                            "EmissiveColor", "Emissive", "MainColor", "GlowColor",
                            -- Seen in the 2026-08-29 census of this game's own instances:
                            "DieColor", "InnerColor" }

local ROW_DISTANCE = 400.0   -- units ahead of the player
local ROW_SPACING = 160.0    -- lateral spacing between actors
local TEXT_WORLD_SIZE = 26.0
local HEIGHT_OFFSET = 120.0

----------------------------------------------------------------------------
-- Census: what parameter names do the game's material instances actually expose?
----------------------------------------------------------------------------

-- masterFullName -> { tex = {name,...}, vec = {name,...} }, harvested for the experiment.
local harvested = {}

local function harvest(masterName, kind, paramName)
    local h = harvested[masterName]
    if not h then h = { tex = {}, vec = {} }; harvested[masterName] = h end
    table.insert(h[kind], paramName)
end

local function dumpParamArray(inst, instName, parentName, arrayName, kind, describeValue)
    local ok, err = pcall(function()
        local arr = inst[arrayName]
        if arr == nil then
            print(string.format("%s CENSUS:   %s = NO SUCH PROPERTY\n", TAG, arrayName))
            return
        end
        arr:ForEach(function(index, elem)
            local entryOk, entryErr = pcall(function()
                local entry = elem:get()
                local name = entry.ParameterInfo.Name:ToString()
                local valueText = describeValue(entry)
                print(string.format("%s CENSUS:   %s[%d] %s = %s\n", TAG, arrayName, index, name, valueText))
                if kind and parentName then harvest(parentName, kind, name) end
            end)
            if not entryOk then
                print(string.format("%s CENSUS:   %s[%d] UNREADABLE: %s\n", TAG, arrayName, index, tostring(entryErr)))
            end
        end)
    end)
    if not ok then
        print(string.format("%s CENSUS:   %s read FAILED: %s\n", TAG, arrayName, tostring(err)))
    end
end

local function describeTexture(entry)
    local ok, result = pcall(function()
        local tex = entry.ParameterValue
        if tex ~= nil and tex:IsValid() then return tex:GetFullName() end
        return "<null>"
    end)
    return ok and result or ("<error: " .. tostring(result) .. ">")
end

local function describeVector(entry)
    local ok, result = pcall(function()
        local v = entry.ParameterValue
        return string.format("(%.3f, %.3f, %.3f, %.3f)", v.R, v.G, v.B, v.A)
    end)
    return ok and result or ("<error: " .. tostring(result) .. ">")
end

local function describeScalar(entry)
    local ok, result = pcall(function() return string.format("%.4f", entry.ParameterValue) end)
    return ok and result or ("<error: " .. tostring(result) .. ">")
end

local function censusOneClass(className)
    local instances = FindAllOf(className) or {}
    print(string.format("%s CENSUS: %d %s instance(s) loaded.\n", TAG, #instances, className))
    for _, inst in ipairs(instances) do
        local nameOk, instName = pcall(function() return inst:GetFullName() end)
        if not nameOk then instName = "<unnameable>" end
        local parentName = nil
        pcall(function()
            local parent = inst.Parent
            if parent ~= nil and parent:IsValid() then parentName = parent:GetFullName() end
        end)
        print(string.format("%s CENSUS: %s (parent: %s)\n", TAG, instName, parentName or "<none>"))
        dumpParamArray(inst, instName, parentName, "TextureParameterValues", "tex", describeTexture)
        dumpParamArray(inst, instName, parentName, "VectorParameterValues", "vec", describeVector)
        dumpParamArray(inst, instName, parentName, "ScalarParameterValues", nil, describeScalar)
    end
end

----------------------------------------------------------------------------
-- Schema dump: the FULL parameter tables cooked into a master material.
----------------------------------------------------------------------------

-- Finds a named property anywhere on an object's class chain, via UStruct:ForEachProperty
-- (vendored RE-UE4SS docs, lua-api/classes/ustruct.md).
local function findPropOnClass(obj, name)
    local found = nil
    local ok = pcall(function()
        local cls = obj:GetClass()
        while cls ~= nil and cls:IsValid() do
            cls:ForEachProperty(function(prop)
                if prop:GetFName():ToString() == name then
                    found = prop
                    return true
                end
            end)
            if found then return end
            cls = cls:GetSuperStruct()
        end
    end)
    if not ok then return nil end
    return found
end

local function describeAny(value)
    local text = "<?>"
    pcall(function()
        local t = type(value)
        if t == "number" or t == "string" or t == "boolean" then
            text = tostring(value)
            return
        end
        -- Userdata: try the shapes we expect, most specific first.
        local done = false
        pcall(function() text = value:ToString(); done = true end)                  -- FName/FText
        if not done then
            pcall(function() text = value:GetFullName(); done = true end)           -- UObject
        end
        if not done then
            pcall(function()
                text = string.format("(%.3f, %.3f, %.3f, %.3f)", value.R, value.G, value.B, value.A)
                done = true
            end)                                                                    -- FLinearColor
        end
        if not done then text = tostring(value) end
    end)
    return text
end

-- Prints every member property of the struct held by `container.memberName`, then tries to dump
-- any member of THAT struct which turns out to be a TArray. Two levels is exactly deep enough to
-- reach CachedExpressionData -> Parameters -> the name/value arrays, without hardcoding a layout
-- this engine version may not have.
local function dumpStructMember(container, memberName, indent, depth)
    local prefix = TAG .. " SCHEMA:" .. indent
    local prop = findPropOnClass(container, memberName)
    local structType = nil
    if prop ~= nil then
        pcall(function() structType = prop:GetStruct() end)
    end
    local value = nil
    pcall(function() value = container[memberName] end)
    if value == nil then
        print(string.format("%s %s = <unreadable>\n", prefix, memberName))
        return
    end
    if structType == nil or not structType:IsValid() then
        print(string.format("%s %s = %s\n", prefix, memberName, describeAny(value)))
        return
    end
    print(string.format("%s %s (struct %s):\n", prefix, memberName, structType:GetFullName()))
    structType:ForEachProperty(function(member)
        local mName = member:GetFName():ToString()
        local mValue = nil
        pcall(function() mValue = value[mName] end)
        -- A TArray dumps element by element; anything else prints one line.
        local dumped = false
        pcall(function()
            mValue:ForEach(function(index, elem)
                local inner = nil
                pcall(function() inner = elem:get() end)
                print(string.format("%s   %s[%d] = %s\n", prefix, mName, index, describeAny(inner)))
                dumped = true
            end)
            if not dumped then
                print(string.format("%s   %s = <empty array>\n", prefix, mName))
                dumped = true
            end
        end)
        if not dumped then
            if depth > 0 then
                local mStruct = nil
                pcall(function() mStruct = member:GetStruct() end)
                if mStruct ~= nil and mStruct:IsValid() then
                    dumpStructMember(value, mName, indent .. "  ", depth - 1)
                    return
                end
            end
            print(string.format("%s   %s = %s\n", prefix, mName, describeAny(mValue)))
        end
    end)
end

local function dumpMasterSchemas()
    for _, path in ipairs(SCHEMA_TARGETS) do
        local master = StaticFindObject(path)
        if master == nil or not master:IsValid() then
            print(string.format("%s SCHEMA: %s NOT LOADED.\n", TAG, path))
        else
            print(string.format("%s SCHEMA: ===== %s =====\n", TAG, path))
            dumpStructMember(master, "CachedExpressionData", " ", 2)
        end
    end
end

----------------------------------------------------------------------------
-- The experiment row.
----------------------------------------------------------------------------

local function findFontTexture()
    local font = StaticFindObject("/Engine/EngineFonts/RobotoDistanceField.RobotoDistanceField")
    if font == nil or not font:IsValid() then
        print(TAG .. " font: RobotoDistanceField NOT LOADED -- experiment cannot set a font texture.\n")
        return nil
    end
    local found = nil
    local ok, err = pcall(function()
        font.Textures:ForEach(function(index, elem)
            local tex = elem:get()
            if tex ~= nil and tex:IsValid() then
                print(string.format("%s font: Textures[%d] = %s\n", TAG, index, tex:GetFullName()))
                if found == nil then found = tex end
            end
        end)
    end)
    if not ok then
        print(string.format("%s font: Textures read FAILED: %s\n", TAG, tostring(err)))
    end
    if found == nil then
        print(TAG .. " font: no valid texture page found in Font.Textures.\n")
    end
    return found
end

local function destroyPreviousRow()
    -- Idempotent reloads: the game ships zero TextRenderComponents (census 2026-08-28), so every
    -- TextRenderActor in the world is a leftover of a previous load of THIS probe. The shipped
    -- adapter's nametags are components on ghost pawns, not TextRenderActors, and are untouched.
    --
    -- Returns the OLD row's anchor (first actor's location/rotation, and the row direction from
    -- first to second) so the new row spawns in the same place. Re-anchoring to the player on
    -- every reload made the row jump to wherever they happened to stand, which makes comparing
    -- rounds needlessly hard (user, 2026-08-29: "hard to see if you move things around").
    local leftovers = FindAllOf("TextRenderActor") or {}
    local anchor = nil
    local locs = {}
    for _, actor in ipairs(leftovers) do
        pcall(function()
            if actor:IsValid() then
                local l = actor:K2_GetActorLocation()
                local r = actor:K2_GetActorRotation()
                table.insert(locs, { x = l.X, y = l.Y, z = l.Z, yaw = r.Yaw })
            end
        end)
    end
    if #locs >= 1 then
        -- Position and facing only. Deriving spacing/direction from the first two actors was a
        -- bug: a plate pair is two actors 4 units apart, so a pair-bearing row re-anchored the
        -- next round at 4-unit spacing -- 12 tags stacked into a z-fighting mess (2026-08-29).
        -- The row always runs perpendicular to the tags' facing, at ROW_SPACING.
        local yawRad = math.rad(locs[1].yaw)
        anchor = { x = locs[1].x, y = locs[1].y, z = locs[1].z, yaw = locs[1].yaw,
                   dirX = math.sin(yawRad), dirY = -math.cos(yawRad), spacing = ROW_SPACING }
    end
    local destroyed = 0
    for _, actor in ipairs(leftovers) do
        pcall(function()
            if actor:IsValid() then
                actor:K2_DestroyActor()
                destroyed = destroyed + 1
            end
        end)
    end
    if destroyed > 0 then
        print(string.format("%s cleanup: destroyed %d TextRenderActor(s); new row anchored %s.\n",
            TAG, destroyed, anchor and "to the old row" or "to the player (old row unreadable)"))
    end
    return anchor
end

local function setParamsFromLists(mid, masterFullName, fontTex)
    local texNames, vecNames = {}, {}
    local seen = {}
    local function add(list, name)
        if not seen[name] then seen[name] = true; table.insert(list, name) end
    end
    for _, n in ipairs(TEX_PARAM_GUESSES) do add(texNames, n) end
    for _, n in ipairs(VEC_PARAM_GUESSES) do add(vecNames, n) end
    local h = harvested[masterFullName]
    if h then
        for _, n in ipairs(h.tex) do add(texNames, n) end
        for _, n in ipairs(h.vec) do add(vecNames, n) end
    end
    local texSet, vecSet, scalarSet = 0, 0, 0
    for _, sp in ipairs(SCALAR_PARAMS) do
        local ok = pcall(function() mid:SetScalarParameterValue(FName(sp.name), sp.value) end)
        if ok then scalarSet = scalarSet + 1 end
    end
    if fontTex ~= nil then
        for _, n in ipairs(texNames) do
            local ok = pcall(function() mid:SetTextureParameterValue(FName(n), fontTex) end)
            if ok then texSet = texSet + 1 end
        end
    end
    for _, n in ipairs(vecNames) do
        local ok = pcall(function() mid:SetVectorParameterValue(FName(n), COLOR_LINEAR) end)
        if ok then vecSet = vecSet + 1 end
    end
    print(string.format("%s   params: %d/%d texture name(s) set, %d/%d vector name(s) set, %d scalar(s) set.\n",
        TAG, texSet, #texNames, vecSet, #vecNames, scalarSet))

    -- Independent readback: what the MID actually STORED, never the locals above. The first run
    -- rendered RED where cyan (0.2, 0.8, 1.0) was requested -- if the stored value is cyan the
    -- material's own logic made it red; if the stored value is garbage the table-to-FLinearColor
    -- marshaling is the bug. This line is what tells those two apart.
    dumpParamArray(mid, "MID", nil, "VectorParameterValues", nil, describeVector)
    dumpParamArray(mid, "MID", nil, "TextureParameterValues", nil, describeTexture)
end

local function applyText(component, label)
    -- SetText did not resolve on this build for the C++ mod (2026-08-28); the property write is
    -- the proven path there. Try the function first anyway -- Lua resolution has differed from
    -- C++ resolution before -- then fall back, and REPORT which one worked.
    local viaFn = pcall(function() component:SetText(FText(label)) end)
    if not viaFn then
        local viaProp, propErr = pcall(function() component.Text = FText(label) end)
        if not viaProp then
            print(string.format("%s   text: BOTH SetText and property write failed: %s\n", TAG, tostring(propErr)))
            return "FAILED"
        end
        return "property"
    end
    return "SetText"
end

local function forceRefresh(component)
    -- MarkRenderStateDirty is missing on this build; visibility off/on is the C++ mod's own
    -- confirmed rebuild-by-another-route.
    pcall(function()
        component:SetVisibility(false, false)
        component:SetVisibility(true, false)
    end)
end

local function spawnOne(world, pawn, index, candidate, fontTex, anchor, whiteTex)
    local loc, rot
    if anchor ~= nil then
        -- Same place as the previous round's row, walked along its own direction.
        loc = {
            X = anchor.x + anchor.dirX * (index - 1) * anchor.spacing,
            Y = anchor.y + anchor.dirY * (index - 1) * anchor.spacing,
            Z = anchor.z,
        }
        rot = { Pitch = 0.0, Yaw = anchor.yaw, Roll = 0.0 }
    else
        local pawnLoc = pawn:K2_GetActorLocation()
        local pawnRot = pawn:K2_GetActorRotation()
        local yawRad = math.rad(pawnRot.Yaw)
        local fwdX, fwdY = math.cos(yawRad), math.sin(yawRad)
        local rightX, rightY = -fwdY, fwdX
        local lateral = (index - (#CANDIDATES + 1) / 2) * ROW_SPACING
        loc = {
            X = pawnLoc.X + fwdX * ROW_DISTANCE + rightX * lateral,
            Y = pawnLoc.Y + fwdY * ROW_DISTANCE + rightY * lateral,
            Z = pawnLoc.Z + HEIGHT_OFFSET,
        }
        -- Face back toward the player so the glyphs are readable from where they stand.
        rot = { Pitch = 0.0, Yaw = pawnRot.Yaw + 180.0, Roll = 0.0 }
    end

    local actorClass = StaticFindObject("/Script/Engine.TextRenderActor")
    if actorClass == nil or not actorClass:IsValid() then
        print(TAG .. " spawn: /Script/Engine.TextRenderActor class NOT FOUND on this build.\n")
        return nil
    end
    local actor = world:SpawnActor(actorClass, loc, rot)
    if actor == nil or not actor:IsValid() then
        print(string.format("%s spawn: SpawnActor returned nil/invalid for %s.\n", TAG, candidate.label))
        return nil
    end

    local componentClass = StaticFindObject("/Script/Engine.TextRenderComponent")
    local component = nil
    pcall(function() component = actor:GetComponentByClass(componentClass) end)
    if component == nil or not component:IsValid() then
        print(string.format("%s spawn: %s has no reachable TextRenderComponent.\n", TAG, candidate.label))
        return actor
    end

    print(string.format("%s --- %s ---\n", TAG, candidate.label))
    local textPath = applyText(component, candidate.label)
    pcall(function() component.WorldSize = TEXT_WORLD_SIZE end)
    local colourOk = pcall(function() component:SetTextRenderColor(COLOR_BYTES) end)

    local materialReport = "component default"
    if candidate.path ~= nil then
        if candidate.load then
            -- Not in the loaded set; ask the engine to load it. Game-thread only (vendored
            -- docs, lua-api/global-functions/loadasset.md) -- runProbe already runs there.
            -- Both path shapes tried; if it still is not found, the asset is not cooked into
            -- this build and the candidate is dead.
            pcall(function() LoadAsset(candidate.path) end)
            pcall(function() LoadAsset(candidate.path:match("^(.*)%.") or candidate.path) end)
        end
        local master = StaticFindObject(candidate.path)
        if master == nil or not master:IsValid() then
            materialReport = "master NOT LOADED: " .. candidate.path
        else
            local mid = nil
            local midOk, midErr = pcall(function()
                mid = component:CreateDynamicMaterialInstance(0, master, FName("MeshGhostNametagMID_" .. candidate.label))
            end)
            if not midOk or mid == nil or not mid:IsValid() then
                -- Second route: the engine's material function library.
                local lib = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
                if lib ~= nil and lib:IsValid() then
                    pcall(function()
                        mid = lib:CreateDynamicMaterialInstance(world, master, FName("MeshGhostNametagMID2_" .. candidate.label))
                    end)
                end
            end
            if mid ~= nil and mid:IsValid() then
                setParamsFromLists(mid, master:GetFullName(), fontTex)
                local setOk = pcall(function() component:SetTextMaterial(mid) end)
                materialReport = string.format("MID of %s, SetTextMaterial %s", candidate.path, setOk and "ok" or "FAILED")
            else
                materialReport = string.format("MID creation FAILED for %s (%s)", candidate.path, tostring(midErr))
            end
        end
    end
    forceRefresh(component)

    -- The plate: a second text actor 4 units behind, same string, colour-driven MID with its
    -- texture params forced FLAT WHITE so the colour passes through as solid glyph blocks.
    if candidate.plate ~= nil then
        local yawRad2 = math.rad(rot.Yaw)
        local plateLoc = { X = loc.X - math.cos(yawRad2) * PLATE_BEHIND_UNITS,
                           Y = loc.Y - math.sin(yawRad2) * PLATE_BEHIND_UNITS,
                           Z = loc.Z }
        local plateActor = world:SpawnActor(actorClass, plateLoc, rot)
        if plateActor ~= nil and plateActor:IsValid() then
            local plateComponent = nil
            pcall(function() plateComponent = plateActor:GetComponentByClass(componentClass) end)
            if plateComponent ~= nil and plateComponent:IsValid() then
                applyText(plateComponent, candidate.label)
                pcall(function() plateComponent.WorldSize = TEXT_WORLD_SIZE end)
                pcall(function() plateComponent:SetTextRenderColor(COLOR_BYTES) end)
                local plateMaster = StaticFindObject(candidate.plate)
                if plateMaster ~= nil and plateMaster:IsValid() then
                    local plateMid = nil
                    pcall(function()
                        plateMid = plateComponent:CreateDynamicMaterialInstance(0, plateMaster,
                            FName("MeshGhostPlateMID_" .. candidate.label))
                    end)
                    if plateMid ~= nil and plateMid:IsValid() then
                        if candidate.vecName ~= nil then
                            -- Narrowing mode: exactly one vector parameter, nothing else.
                            local c = COLOR_LINEAR
                            if candidate.rgb then
                                c = { R = candidate.rgb[1], G = candidate.rgb[2], B = candidate.rgb[3], A = 1.0 }
                            end
                            local one = pcall(function()
                                plateMid:SetVectorParameterValue(FName(candidate.vecName), c)
                            end)
                            print(string.format("%s   plate: single param %s set %s.\n",
                                TAG, candidate.vecName, one and "ok" or "FAILED"))
                        else
                            setParamsFromLists(plateMid, plateMaster:GetFullName(), whiteTex)
                            print(string.format("%s   plate: MID of %s, white tex %s.\n",
                                TAG, candidate.plate, whiteTex ~= nil and "set" or "MISSING"))
                        end
                        pcall(function() plateComponent:SetTextMaterial(plateMid) end)
                    else
                        print(string.format("%s   plate: MID creation FAILED for %s.\n", TAG, candidate.plate))
                    end
                else
                    print(string.format("%s   plate: master NOT LOADED: %s\n", TAG, candidate.plate))
                end
                forceRefresh(plateComponent)
            end
        else
            print(string.format("%s   plate: SpawnActor failed for %s.\n", TAG, candidate.label))
        end
    end

    -- Independent readback -- a real re-read of the component, never the locals written above.
    local readText, readColour, readMaterial = "<unread>", "<unread>", "<unread>"
    pcall(function() readText = component.Text:ToString() end)
    pcall(function()
        local c = component.TextRenderColor
        readColour = string.format("R=%d G=%d B=%d A=%d", c.R, c.G, c.B, c.A)
    end)
    pcall(function()
        local m = component.TextMaterial
        if m ~= nil and m:IsValid() then readMaterial = m:GetFullName() end
    end)
    print(string.format("%s   text via %s -> %q | colour set %s -> %s | material: %s\n",
        TAG, textPath, readText, colourOk and "ok" or "FAILED", readColour, materialReport))
    print(string.format("%s   readback material: %s | at (%.0f, %.0f, %.0f)\n",
        TAG, readMaterial, loc.X, loc.Y, loc.Z))
    return actor
end

----------------------------------------------------------------------------
-- Entry: wait for a placed player pawn, then run everything once.
----------------------------------------------------------------------------

local ran = false

local function runProbe()
    local ok, err = pcall(function()
        print(TAG .. " ===== run start =====\n")
        local anchor = destroyPreviousRow()
        censusOneClass("MaterialInstanceConstant")
        censusOneClass("MaterialInstanceDynamic")
        local fontTex = findFontTexture()
        dumpMasterSchemas()
        local whiteTex = StaticFindObject(WHITE_TEX_PATH)
        if whiteTex == nil or not whiteTex:IsValid() then
            whiteTex = nil
            print(string.format("%s %s not loaded -- plates will keep the font texture.\n", TAG, WHITE_TEX_PATH))
        end

        local pawn = UEHelpers.GetPlayer()
        local world = UEHelpers.GetWorld()
        if pawn == nil or not pawn:IsValid() or world == nil or not world:IsValid() then
            print(TAG .. " no valid pawn/world at run time -- experiment skipped, census above stands.\n")
            return
        end
        local spawned = 0
        for index, candidate in ipairs(CANDIDATES) do
            local actor = spawnOne(world, pawn, index, candidate, fontTex, anchor, whiteTex)
            if actor ~= nil then spawned = spawned + 1 end
        end
        print(string.format("%s ===== run end: %d/%d actor(s) spawned. Judge ON SCREEN. =====\n",
            TAG, spawned, #CANDIDATES))
    end)
    if not ok then
        print(string.format("%s run FAILED: %s\n", TAG, tostring(err)))
    end
end

-- Poll until the player pawn exists (fresh launch sits in menus for a while), then run once per
-- load. A hot reload resets this mod's Lua state, so each reload runs once more -- after
-- destroying the previous row.
LoopAsync(1000, function()
    if ran then return true end
    local ready = false
    pcall(function()
        local pawn = UEHelpers.GetPlayer()
        if pawn == nil or not pawn:IsValid() then return end
        -- The title screen map has a pawn too (measured 2026-08-29 -- two runs spawned their
        -- rows into /Game/Maps/TitleScreen), so a pawn alone is not "in the game". Wait for a
        -- real zone.
        local world = UEHelpers.GetWorld()
        if world == nil or not world:IsValid() then return end
        if world:GetFullName():find("TitleScreen") then return end
        ready = true
    end)
    if not ready then return false end
    ran = true
    ExecuteInGameThread(runProbe)
    return true
end)

print(TAG .. " loaded; waiting for a player pawn.\n")
