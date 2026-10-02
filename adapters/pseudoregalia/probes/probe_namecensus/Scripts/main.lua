-- A census of what exists, unfiltered: world inventories by class, MPC_PlayerRelated's parameters, each pawn's
-- PlayerLight child actor and its meshes' materials, flags, CustomPrimitiveData and OverlayMaterial, and the
-- level's light state. Read-only: named reads and GetFullName()/GetName(), values only off bool and number
-- properties, never a UFunction on a FindAllOf result. One census 3s after each (re)load; reload for another.

local TAG = "[MeshGhostNameCensus]"

local function census()
    local ok, err = pcall(function()
        print(string.format("%s census begins.\n", TAG))

        local tags = FindAllOf("TextRenderComponent") or {}
        print(string.format("%s %d TextRenderComponent instance(s).\n", TAG, #tags))
        for i, comp in ipairs(tags) do
            if comp and comp:IsValid() then
                print(string.format("%s tag %d full=%s\n", TAG, i, comp:GetFullName()))
            else
                print(string.format("%s tag %d INVALID\n", TAG, i))
            end
        end

        local pawns = FindAllOf("BP_PlayerGoatMain_C") or {}
        print(string.format("%s %d BP_PlayerGoatMain_C pawn(s).\n", TAG, #pawns))
        for i, pawn in ipairs(pawns) do
            if pawn and pawn:IsValid() then
                print(string.format("%s pawn %d short=%s full=%s\n", TAG, i,
                                    pawn:GetFName():ToString(), pawn:GetFullName()))
            else
                print(string.format("%s pawn %d INVALID\n", TAG, i))
            end
        end

        -- Scene-wide channels a light census cannot see (parameter collections, decals) and the lights, by name.
        for _, klass in ipairs({"MaterialParameterCollection", "MaterialParameterCollectionInstance",
                                "DecalComponent", "PointLightComponent", "SpotLightComponent",
                                "RectLightComponent", "ChildActorComponent"}) do
            local objs = FindAllOf(klass) or {}
            print(string.format("%s %d %s instance(s).\n", TAG, #objs, klass))
            for i, o in ipairs(objs) do
                if o and o:IsValid() then
                    print(string.format("%s %s %d full=%s\n", TAG, klass, i, o:GetFullName()))
                end
            end
        end

        -- Parameter names and defaults off the asset; the live instance's values are a TMap, left unread.
        local mpc = StaticFindObject("/Game/MatTex/Materials/MPC_PlayerRelated.MPC_PlayerRelated")
        if mpc and mpc:IsValid() then
            for _, listName in ipairs({"ScalarParameters", "VectorParameters"}) do
                local ok2, arr = pcall(function() return mpc[listName] end)
                if ok2 and arr then
                    local n = 0
                    pcall(function() n = #arr end)
                    print(string.format("%s MPC_PlayerRelated.%s: %d entries.\n", TAG, listName, n))
                    for i = 1, n do
                        pcall(function()
                            local p = arr[i]
                            local nm = p.ParameterName:ToString()
                            local dv = ""
                            if listName == "ScalarParameters" then
                                dv = tostring(p.DefaultValue)
                            else
                                local v = p.DefaultValue
                                dv = string.format("(%.3f, %.3f, %.3f, %.3f)", v.R, v.G, v.B, v.A)
                            end
                            print(string.format("%s   %s[%d] name=%s default=%s\n", TAG, listName, i, nm, dv))
                        end)
                    end
                else
                    print(string.format("%s MPC_PlayerRelated.%s: UNREADABLE.\n", TAG, listName))
                end
            end
        else
            print(string.format("%s MPC_PlayerRelated: NOT FOUND by StaticFindObject.\n", TAG))
        end

        -- What each pawn's PlayerLight ChildActorComponent holds.
        for i, pawn in ipairs(FindAllOf("BP_PlayerGoatMain_C") or {}) do
            if pawn and pawn:IsValid() then
                pcall(function()
                    local cac = pawn.PlayerLight
                    if cac and cac:IsValid() then
                        print(string.format("%s pawn %d PlayerLight CAC full=%s\n", TAG, i, cac:GetFullName()))
                        local child = cac.ChildActor
                        if child and child:IsValid() then
                            print(string.format("%s pawn %d PlayerLight child actor full=%s\n", TAG, i, child:GetFullName()))
                        else
                            print(string.format("%s pawn %d PlayerLight child actor: none/invalid\n", TAG, i))
                        end
                    else
                        print(string.format("%s pawn %d has no readable PlayerLight property\n", TAG, i))
                    end
                end)
            end
        end

        -- Every NiagaraComponent with its Asset and attach parent: the chain says why a ghost-name match misses one.
        for i, nc in ipairs(FindAllOf("NiagaraComponent") or {}) do
            if nc and nc:IsValid() then
                pcall(function()
                    local asset_name = "<none>"
                    pcall(function()
                        local a = nc.Asset
                        if a and a:IsValid() then asset_name = a:GetFullName() end
                    end)
                    local parent_name = "<none>"
                    pcall(function()
                        local p = nc.AttachParent
                        if p and p:IsValid() then parent_name = p:GetFullName() end
                    end)
                    print(string.format("%s niagara %d full=%s\n%s   asset=%s\n%s   attach=%s\n",
                                        TAG, i, nc:GetFullName(), TAG, asset_name, TAG, parent_name))
                end)
            end
        end

        -- Per pawn, WeaponMesh and VisualMesh: OverrideMaterials (an MID's Parent and scalar parameters), the asset's
        -- default materials, and the visibility and render flags, player and ghost in one block.
        local function dump_mid_parent(m)
            pcall(function()
                local p = m.Parent
                if p and p:IsValid() then
                    print(string.format("%s     parent=%s\n", TAG, p:GetFullName()))
                end
            end)
        end
        local function dump_mesh_asset_materials(wm)
            pcall(function()
                local sk = wm.SkeletalMesh
                if sk and sk:IsValid() then
                    print(string.format("%s   asset=%s\n", TAG, sk:GetFullName()))
                    local mats = sk.Materials
                    local n = 0
                    pcall(function() n = #mats end)
                    for j = 1, n do
                        pcall(function()
                            local mi = mats[j].MaterialInterface
                            if mi and mi:IsValid() then
                                print(string.format("%s   asset mat[%d]=%s\n", TAG, j, mi:GetFullName()))
                            end
                        end)
                    end
                end
            end)
        end
        local function dump_mid_scalars(m)
            pcall(function()
                local svals = m.ScalarParameterValues
                local n = 0
                pcall(function() n = #svals end)
                for j = 1, n do
                    pcall(function()
                        local sp = svals[j]
                        print(string.format("%s     scalar %s = %s\n", TAG,
                                            sp.ParameterInfo.Name:ToString(), tostring(sp.ParameterValue)))
                    end)
                end
                local vvals = m.VectorParameterValues
                n = 0
                pcall(function() n = #vvals end)
                for j = 1, n do
                    pcall(function()
                        local vp = vvals[j]
                        local v = vp.ParameterValue
                        print(string.format("%s     vector %s = (%.3f, %.3f, %.3f, %.3f)\n", TAG,
                                            vp.ParameterInfo.Name:ToString(), v.R, v.G, v.B, v.A))
                    end)
                end
            end)
        end
        for i, pawn in ipairs(FindAllOf("BP_PlayerGoatMain_C") or {}) do
            if pawn and pawn:IsValid() then
                for _, mesh_prop in ipairs({"WeaponMesh", "VisualMesh", "LightMesh"}) do
                    pcall(function()
                        local wm = pawn[mesh_prop]
                        if wm and wm:IsValid() then
                            print(string.format("%s pawn %d (%s) %s full=%s\n", TAG, i,
                                                pawn:GetFName():ToString(), mesh_prop, wm:GetFullName()))
                            dump_mesh_asset_materials(wm)
                            pcall(function()
                                local mats = wm.OverrideMaterials
                                local n = 0
                                pcall(function() n = #mats end)
                                print(string.format("%s   OverrideMaterials: %d\n", TAG, n))
                                for j = 1, n do
                                    pcall(function()
                                        local m = mats[j]
                                        if m and m:IsValid() then
                                            print(string.format("%s   mat[%d]=%s\n", TAG, j, m:GetFullName()))
                                            dump_mid_parent(m)
                                            dump_mid_scalars(m)
                                        else
                                            print(string.format("%s   mat[%d]=<null>\n", TAG, j))
                                        end
                                    end)
                                end
                            end)
                            for _, prop in ipairs({"bVisible", "bHiddenInGame", "bRenderCustomDepth"}) do
                                pcall(function()
                                    print(string.format("%s   %s=%s\n", TAG, prop, tostring(wm[prop])))
                                end)
                            end
                            -- OverlayMaterial: UE5's channel for a shimmer drawn over a mesh.
                            pcall(function()
                                local om = wm.OverlayMaterial
                                if om and om:IsValid() then
                                    print(string.format("%s   OverlayMaterial=%s\n", TAG, om:GetFullName()))
                                else
                                    print(string.format("%s   OverlayMaterial=<none>\n", TAG))
                                end
                            end)
                            -- CustomPrimitiveData: the per-mesh channel a vertex-light system could write.
                            pcall(function()
                                local cpd = wm.CustomPrimitiveData
                                local vals = cpd.Data
                                local n = 0
                                pcall(function() n = #vals end)
                                local s = ""
                                for j = 1, math.min(n, 16) do
                                    pcall(function() s = s .. string.format("%.3f ", vals[j]) end)
                                end
                                print(string.format("%s   CustomPrimitiveData: %d float(s) [%s]\n", TAG, n, s))
                            end)
                        else
                            print(string.format("%s pawn %d (%s): no readable %s\n", TAG, i,
                                                pawn:GetFName():ToString(), mesh_prop))
                        end
                    end)
                end
            end
        end

        -- The live MPC_PlayerRelated.PlayerLocation beside every pawn's position: whichever it tracks is the writer.
        -- KismetMaterialLibrary by exact path, not FindAllOf; GetVectorParameterValue is a static pure read.
        pcall(function()
            local kml = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
            local mpc2 = StaticFindObject("/Game/MatTex/Materials/MPC_PlayerRelated.MPC_PlayerRelated")
            local pawns2 = FindAllOf("BP_PlayerGoatMain_C") or {}
            if kml and kml:IsValid() and mpc2 and mpc2:IsValid() and pawns2[1] then
                local v = kml:GetVectorParameterValue(pawns2[1], mpc2, FName("PlayerLocation"))
                if v then
                    print(string.format("%s MPC PlayerLocation LIVE = (%.1f, %.1f, %.1f)\n",
                                        TAG, v.R, v.G, v.B))
                end
                for i, pawn in ipairs(pawns2) do
                    pcall(function()
                        local root = pawn.RootComponent
                        local loc = root.RelativeLocation
                        print(string.format("%s pawn %d (%s) at (%.1f, %.1f, %.1f)\n", TAG, i,
                                            pawn:GetFName():ToString(), loc.X, loc.Y, loc.Z))
                    end)
                end
            else
                print(string.format("%s stage 10: KML/MPC/pawn unavailable, nothing read.\n", TAG))
            end
        end)

        -- The level script actor's state: names enumerated, values read only off bool, float, int and byte properties.
        for _, klass in ipairs({"ZONE_Dungeon_C", "LevelScriptActor"}) do
            for i, lsa in ipairs(FindAllOf(klass) or {}) do
                if lsa and lsa:IsValid() then
                    pcall(function()
                        print(string.format("%s levelscript %s %d full=%s\n", TAG, klass, i, lsa:GetFullName()))
                        -- ForEachProperty lives on the class; on an instance it iterates nothing, silently.
                        local seen, printed = 0, 0
                        local c = lsa:GetClass()
                        while c and c:IsValid() do
                            c:ForEachProperty(function(prop)
                                seen = seen + 1
                                pcall(function()
                                    local pclass = prop:GetClass():GetFName():ToString()
                                    if pclass == "BoolProperty" or pclass == "FloatProperty"
                                       or pclass == "DoubleProperty" or pclass == "IntProperty"
                                       or pclass == "ByteProperty" then
                                        local pname = prop:GetFName():ToString()
                                        local v = lsa[pname]
                                        printed = printed + 1
                                        print(string.format("%s   %s (%s) = %s\n", TAG, pname, pclass, tostring(v)))
                                    end
                                end)
                            end)
                            local sup = nil
                            pcall(function() sup = c:GetSuperStruct() end)
                            if sup and sup ~= c and sup:IsValid() and sup:GetFName():ToString():find("ZONE") then
                                c = sup
                            else
                                c = nil
                            end
                        end
                        print(string.format("%s   levelscript coverage: %d properties walked, %d value(s) printed.\n",
                                            TAG, seen, printed))
                    end)
                end
            end
        end

        -- The light manager and transition volumes, with the same bool-and-number discipline.
        for _, klass in ipairs({"BP_LightManager_C", "BP_LightTransition_C"}) do
            for i, mgr in ipairs(FindAllOf(klass) or {}) do
                if mgr and mgr:IsValid() then
                    pcall(function()
                        print(string.format("%s %s %d full=%s\n", TAG, klass, i, mgr:GetFullName()))
                        local seen, printed = 0, 0
                        local c = mgr:GetClass()
                        local hops = 0
                        while c and c:IsValid() and hops < 4 do
                            c:ForEachProperty(function(prop)
                                seen = seen + 1
                                pcall(function()
                                    local pclass = prop:GetClass():GetFName():ToString()
                                    if pclass == "BoolProperty" or pclass == "FloatProperty"
                                       or pclass == "DoubleProperty" or pclass == "IntProperty"
                                       or pclass == "ByteProperty" then
                                        local pname = prop:GetFName():ToString()
                                        local v = mgr[pname]
                                        printed = printed + 1
                                        print(string.format("%s   %s (%s) = %s\n", TAG, pname, pclass, tostring(v)))
                                    else
                                        print(string.format("%s   %s (%s) = <unread>\n", TAG,
                                                            prop:GetFName():ToString(), pclass))
                                    end
                                end)
                            end)
                            local sup = nil
                            pcall(function() sup = c:GetSuperStruct() end)
                            if sup and sup ~= c and sup:IsValid() then c = sup; hops = hops + 1 else c = nil end
                        end
                        print(string.format("%s   %s coverage: %d walked, %d printed.\n", TAG, klass, seen, printed))
                    end)
                end
            end
        end

        -- Every actor class in the world, names only, one line per class.
        pcall(function()
            local classes = {}
            for _, a in ipairs(FindAllOf("Actor") or {}) do
                if a and a:IsValid() then
                    pcall(function()
                        local cn = a:GetClass():GetFName():ToString()
                        classes[cn] = (classes[cn] or 0) + 1
                    end)
                end
            end
            local sorted = {}
            for cn, n in pairs(classes) do table.insert(sorted, string.format("%s x%d", cn, n)) end
            table.sort(sorted)
            print(string.format("%s actor class inventory (%d unique):\n", TAG, #sorted))
            for _, line in ipairs(sorted) do
                print(string.format("%s   %s\n", TAG, line))
            end
        end)

        print(string.format("%s census ends.\n", TAG))
    end)
    if not ok then
        print(string.format("%s census FAILED: %s\n", TAG, tostring(err)))
    end
end

-- 3s keeps the census clear of the reload itself.
LoopAsync(3000, function()
    ExecuteInGameThread(census)
    return true -- stop after one shot; reload the probe for another
end)

print(string.format("%s loaded; census in 3s.\n", TAG))
