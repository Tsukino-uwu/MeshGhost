-- MeshGhost name-census probe. ONE question (2026-08-29): why does the C++ nametag subtraction's
-- name-containment test match 0 of 12 TextRenderComponents, when the nametag components are
-- created ON the ghost via AddComponentByClass and the user can see them on screen?
--
-- The test in Plugin.cpp is: component:GetFullName() contains ghost:GetName(). This probe prints
-- both sides of that comparison for EVERYTHING -- every TextRenderComponent's full name, every
-- BP_PlayerGoatMain_C pawn's short name and full name -- unfiltered, so the mismatch is visible
-- in the log instead of guessed at. Dump everything; filter afterwards (probes.md rule 3).
--
-- Read-only. Named reads and GetFullName()/GetName() only -- the identity calls are the same ones
-- GHOST_HOLD_OUTLINE_OFF makes on FindAllOf results every tick and have never crashed. No
-- UFunction is called on anything, no property enumeration, no object-valued stringify
-- (../CLAUDE.md, "Never call a UFunction on something FindAllOf handed you").
--
-- Cost: one FindAllOf over two small classes per census, one census 3s after each (re)load, then
-- nothing. Reload the probe (probe_reloader) to take another census.
--
-- Deploy: copy probe_namecensus/ to <install>\...\Win64\ue4ss\Mods\MeshGhostNameCensus\ with an
-- enabled.txt. Remove once the question is answered.

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

        -- Widened 2026-08-29 after the three named suspects fell: if the dark-area glow is
        -- MATERIAL-driven rather than light-driven, the mechanism is a MaterialParameterCollection
        -- -- scene-wide, per-frame writable, and invisible to every light/pawn/level census run so
        -- far. Names only here; what to read off one is the NEXT question, asked only if these
        -- exist. Same for decals (the blob shadow subtraction matched 0 of 879 StaticMeshComponents,
        -- so the shadow is probably a decal) and the game's own light components by full name.
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

        -- Stage 2 (2026-08-29): MPC_PlayerRelated exists -- the one scene-wide, per-frame-writable
        -- channel every earlier census was blind to. Read its parameter NAMES and defaults off the
        -- asset (named property reads on structs in arrays, no UFunction). The live instance's
        -- values are a TMap and stay unread here; names tell us what question to ask next.
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

        -- Stage 3: what lives inside each pawn's PlayerLight ChildActorComponent. Named property
        -- reads only (PlayerLight -> ChildActor), no UFunction -- the safe side of the crash line.
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

        -- Stage 4: every NiagaraComponent, with its Asset and attach parent. The ghost's weapon
        -- glow (user, 2026-08-29, first visible once the darkness worked) reached the screen while
        -- the recall-glow sweep cleared nothing and we spawned nothing -- so SOMETHING carries it,
        -- and its full name plus attach chain says why every ghost-name attribution missed it.
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

        -- Stage 6 rides on stage 5's loop below: VisualMesh gets the same dump as WeaponMesh, and
        -- any MaterialInstanceDynamic prints its scalar parameters (named struct-array reads, the
        -- MPC pattern). The stage-5 finding: the player's WeaponMesh carries an MID override, the
        -- ghost's carries none -- the body renders dark correctly, so the question is whether the
        -- body has an MID on both and what the weapon MID drives.
        -- Stage 5: the weapon glow (user, 2026-08-29) is not a Niagara (stage 4: none but
        -- NE_Particles_System exists, and hiding that changed nothing). Next suspect is the
        -- WeaponMesh's own material state. Named reads only: OverrideMaterials plus the visibility
        -- and render flags on each pawn's WeaponMesh, printed for player and ghost alike so the
        -- diff is in one log block.
        -- Stage 7: an MID's Parent, and the mesh ASSET's default material list. The ghost's body
        -- is dark with no overrides, so darkness is not the MID -- the question is which BASE
        -- material each weapon resolves to.
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
                            -- Stage 9: OverlayMaterial -- the UE5 channel for a shimmer drawn
                            -- over a mesh, which is what the ghost's blade glow looks like
                            -- (user screenshot, 2026-08-29). Read on every mesh so player vs
                            -- ghost prints as a pair.
                            pcall(function()
                                local om = wm.OverlayMaterial
                                if om and om:IsValid() then
                                    print(string.format("%s   OverlayMaterial=%s\n", TAG, om:GetFullName()))
                                else
                                    print(string.format("%s   OverlayMaterial=<none>\n", TAG))
                                end
                            end)
                            -- Stage 8: per-component CustomPrimitiveData -- the one per-mesh
                            -- channel a vertex-light system could write brightness into, and the
                            -- ghost's body darkens while its weapon does not with identical
                            -- materials, so a per-component diff is all that is left.
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

        print(string.format("%s census ends.\n", TAG))
    end)
    if not ok then
        print(string.format("%s census FAILED: %s\n", TAG, tostring(err)))
    end
end

-- One census shortly after load, on the game thread. 3s keeps it clear of the reload itself.
LoopAsync(3000, function()
    ExecuteInGameThread(census)
    return true -- stop after one shot; reload the probe for another
end)

print(string.format("%s loaded; census in 3s.\n", TAG))
