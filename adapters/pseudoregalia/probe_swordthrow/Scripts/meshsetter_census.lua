-- One-shot: what is the SET-MESH function actually called on this build's SkeletalMeshComponent?
-- The weapon flyer resolved the asset ('mainWeapon') but 'SetSkeletalMesh'/'NewMesh' did not
-- apply (applied=NO, 17:00:13). Names only -- no calls, no value reads; the safe census shape.

local TAG = "[MeshGhostMeshSetterCensus]"

local function full_name(obj)
    local n
    pcall(function() n = obj:GetFullName() end)
    return n
end

local function prop(obj, name)
    local v
    if not pcall(function() v = obj[name] end) then return nil end
    return v
end

ExecuteInGameThread(function()
    local pawns = FindAllOf("BP_PlayerGoatMain_C")
    if not pawns then
        print(string.format("%s no pawns.\n", TAG))
        return
    end
    for _, pawn in pairs(pawns) do
        local wmesh = prop(pawn, "WeaponMesh")
        if wmesh then
            local cls
            pcall(function() cls = wmesh:GetClass() end)
            if cls then
                print(string.format("%s WeaponMesh class: %s\n", TAG, full_name(cls) or "?"))
                local listed = 0
                local ok, err = pcall(function()
                    -- re-fetch through StaticFindObject: the wrapper GetClass() hands back has not
                    -- always exposed UStruct methods, and the path was printed by the line above.
                    local walker = StaticFindObject("/Script/Engine.SkeletalMeshComponent") or cls
                    while walker and walker:IsValid() do
                        walker:ForEachFunction(function(fn)
                            local fname
                            pcall(function() fname = fn:GetFName():ToString() end)
                            if fname and (fname:find("Mesh") or fname:find("Skinned") or fname:find("Skeletal")) and fname:find("Set") then
                                -- parameter names too, so the buffer write matches by name
                                local params = {}
                                pcall(function()
                                    fn:ForEachProperty(function(p)
                                        local pn
                                        pcall(function() pn = p:GetFName():ToString() end)
                                        params[#params + 1] = pn or "?"
                                        return false
                                    end)
                                end)
                                print(string.format("%s   %s(%s)\n", TAG, fname, table.concat(params, ", ")))
                                listed = listed + 1
                            end
                            return false
                        end)
                        local super
                        pcall(function() super = walker:GetSuperStruct() end)
                        walker = super
                    end
                end)
                print(string.format("%s done: %d candidate setter(s); walk ok=%s err=%s\n", TAG, listed, tostring(ok), tostring(err)))
                return
            end
        end
    end
    print(string.format("%s no pawn had a WeaponMesh.\n", TAG))
end)

print(string.format("%s loaded.\n", TAG))
