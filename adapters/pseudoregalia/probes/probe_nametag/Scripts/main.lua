-- Which loaded material renders a nametag in a colour we drive: a census of every material instance's parameters,
-- then one labelled TextRenderActor per candidate in front of the player, each read back. Hot-reloadable; deploy by
-- copying probe_nametag/ to ue4ss\Mods\MeshGhostNametagProbe\ (it carries its own enabled.txt). Dev-only tooling.

local UEHelpers = require("UEHelpers")

local TAG = "[MeshGhostNametagProbe]"

-- False destroys every row this probe spawned and spawns nothing; with a reload it is the only way to clear a
-- running game's rows without closing it.
local PROBE_ENABLED = false

-- The cyan the C++ attempts drove, so results compare.
local COLOR_BYTES = { R = 51, G = 204, B = 255, A = 255 }   -- FColor, for SetTextRenderColor
-- Parchment, the shipped default plate colour, so each candidate is judged in the colour it would ship in.
local COLOR_LINEAR = { R = 0.66, G = 0.60, B = 0.46, A = 1.0 } -- FLinearColor, for vector params

-- Each label is also the on-screen text, so a screenshot needs no legend. A `plate` entry spawns a pair: default text
-- in front and the same string behind it through a colour-driven MID, a plate that sizes itself to the word. `vecName`
-- sets that one vector parameter and nothing else, so the plate that turns parchment names its own parameter.
local EMISSIVE_PATH = "/Engine/EngineMaterials/EmissiveMeshMaterial.EmissiveMeshMaterial"
local CANDIDATES = {
    { label = "GIZMO-GC",  plate = "/Engine/EngineMaterials/GizmoMaterial.GizmoMaterial", vecName = "GizmoColor" },
    { label = "GIZMO-COL", plate = "/Engine/EngineMaterials/GizmoMaterial.GizmoMaterial", vecName = "Color" },
    { label = "DBG-COL",   plate = "/Engine/EngineDebugMaterials/DebugMeshMaterial.DebugMeshMaterial", vecName = "Color" },
    { label = "DBG-GC",    plate = "/Engine/EngineDebugMaterials/DebugMeshMaterial.DebugMeshMaterial", vecName = "GizmoColor" },
}

local WHITE_TEX_PATH = "/Game/RetroGraphics/Textures/T_White.T_White" -- the game's own flat white
local PLATE_BEHIND_UNITS = 4.0

-- Empty: CachedExpressionData reads nil through this build's reflection, so names come from the census and guesses.
local SCHEMA_TARGETS = {}

-- Setting a name a master does not use is inert, so over-asking costs nothing and under-asking silently fails.
-- The census adds any name an instance of the same master exposes.
local TEX_PARAM_GUESSES = { "SpriteTexture", "Texture", "BaseTexture", "MainTexture", "Tex",
                            "Albedo", "Diffuse", "BaseColorTexture", "T_Base", "Sprite",
                            "SlateUI" } -- the widget materials' texture slot

-- Full opacity and a mid mask cutoff, only: blind-setting a scalar like "Sprite Size" distorts the mesh.
local SCALAR_PARAMS = { { name = "Opacity", value = 1.0 }, { name = "Cutoff", value = 0.5 } }
local VEC_PARAM_GUESSES = { "Color", "Colour", "Tint", "TintColor", "BaseColor", "SpriteColor",
                            "EmissiveColor", "Emissive", "MainColor", "GlowColor",
                            -- Seen on this game's own instances:
                            "DieColor", "InnerColor",
                            -- The engine gizmo material's conventional parameter name:
                            "GizmoColor" }

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
-- Schema dump: the full parameter tables cooked into a master material.
----------------------------------------------------------------------------

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

-- Two levels reach CachedExpressionData -> Parameters -> the name/value arrays without hardcoding a layout.
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
    -- The game ships no TextRenderComponent and the adapter's nametags are components on ghost pawns, so every
    -- TextRenderActor is this probe's. Returns the old row's anchor, so a reload respawns where rounds can be compared.
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
        -- Position and facing only: a plate pair is two actors 4 units apart, so spacing taken from the first two
        -- would stack the row. It runs perpendicular to the tags' facing, at ROW_SPACING.
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

    -- What the MID stored, never the locals: tells a material that ignores the colour from a marshalling bug.
    dumpParamArray(mid, "MID", nil, "VectorParameterValues", nil, describeVector)
    dumpParamArray(mid, "MID", nil, "TextureParameterValues", nil, describeTexture)
end

local function applyText(component, label)
    -- SetText did not resolve for the C++ mod, but Lua resolution has differed from C++ before: try it, then the
    -- property write, and report which worked.
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
    -- MarkRenderStateDirty is missing on this build; visibility off and on rebuilds the render state instead.
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
            -- LoadAsset is game-thread only, where runProbe runs. Both path shapes are tried; still not found means
            -- the asset is not cooked into this build.
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

    -- Texture params forced flat white, so the colour passes through as solid glyph blocks.
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
                if candidate.prio ~= nil then
                    local applied = "<unread>"
                    pcall(function()
                        plateComponent.TranslucencySortPriority = candidate.prio
                        applied = tostring(plateComponent.TranslucencySortPriority) -- independent readback
                    end)
                    print(string.format("%s   plate: TranslucencySortPriority -> %s (wanted %d)\n",
                        TAG, applied, candidate.prio))
                end
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
                        if candidate.scalars ~= nil then
                            for scalarName, scalarValue in pairs(candidate.scalars) do
                                local sOk = pcall(function()
                                    plateMid:SetScalarParameterValue(FName(scalarName), scalarValue)
                                end)
                                print(string.format("%s   plate: scalar %s=%.2f set %s.\n",
                                    TAG, scalarName, scalarValue, sOk and "ok" or "FAILED"))
                            end
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
        if not PROBE_ENABLED then
            print(TAG .. " PROBE_ENABLED=false -- previous row destroyed, spawning nothing.\n")
            return
        end
        -- False for one deploy when the inherited spot is inside geometry; true keeps rows in place across reloads.
        local ANCHOR_TO_PREVIOUS_ROW = false
        if not ANCHOR_TO_PREVIOUS_ROW then anchor = nil end
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

-- Once per load: a hot reload resets this mod's Lua state, so each reload runs again after clearing the old row.
LoopAsync(1000, function()
    if ran then return true end
    local ready = false
    pcall(function()
        local pawn = UEHelpers.GetPlayer()
        if pawn == nil or not pawn:IsValid() then return end
        -- The title screen map has a pawn too, so wait for a real zone.
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
