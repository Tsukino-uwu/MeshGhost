-- One-shot: does the pawn expose its BlobShadow component under a reflected PROPERTY name, and
-- which one? The shadow mirror read pawn["BlobShadow"] and did nothing on screen (2026-09-01)
-- -- a missing property reads as nil and both sides silently no-op. Candidates tested by name;
-- read-only.

local TAG = "[MeshGhostShadowProp]"

local CANDIDATES = {
    "BlobShadow", "blobShadow", "ShadowMesh", "shadowMesh", "blobShadowMesh",
    "DropShadow", "dropShadow", "Shadow", "shadow", "shadowRef", "ShadowRef",
    "blobShadowRef", "CharShadow", "charShadow", "fakeShadow", "FakeShadow",
}

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
        if prop(pawn, "RootComponent") then
            local pname = full_name(pawn) or "?"
            local hits = 0
            for _, cand in ipairs(CANDIDATES) do
                local v = prop(pawn, cand)
                if v ~= nil then
                    print(string.format("%s %s.%s = %s\n", TAG, pname:match("(BP_%w+_C_%d+)") or pname, cand,
                                        full_name(v) or tostring(v)))
                    hits = hits + 1
                end
            end
            print(string.format("%s pawn done, %d candidate propert(ies) resolved.\n", TAG, hits))
            return -- one pawn is enough; both are the same class
        end
    end
end)

print(string.format("%s loaded.\n", TAG))
