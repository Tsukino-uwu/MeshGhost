-- Outfit echo hook, read-only: a pre-hook on the native SetSkeletalMeshAsset that prints every call into UE4SS.log,
-- beside the adapter's own lines, so a write on the player's VisualMesh with no adapter apply beside it is the game's.
-- The player's mesh and dynamicEyesMat are polled too, for a change that never calls the function. Two game
-- processes can share one log, so every line names the player it was seen from. Restore the scratch stub to remove.

local TAG = "[EchoHook]"

local function valid(o) local ok, v = pcall(function() return o:IsValid() end) return ok and v == true end
local function prop(o, n) local v if not o or not pcall(function() v = o[n] end) then return nil end return v end
local function addr(o) local ok, a = pcall(function() return o:GetAddress() end) return (ok and a) and string.format("0x%x", a) or "nil" end
local function full(o) if o == nil or not valid(o) then return "none" end local s pcall(function() s = o:GetFullName() end) return s or "?" end
local function short(o) local f = full(o) return f:match("([^/]+)%.[^%.]*$") or f end

-- Cached per poll: the hook runs inside the engine's call, so it only formats and prints.
local player_addr, player_vm_addr = "nil", "nil"

local function on_set(Context, NewMesh)
    local comp, mesh = nil, nil
    pcall(function() comp = Context:get() end)
    pcall(function() mesh = NewMesh:get() end)
    local ca = addr(comp)
    local who = (ca == player_vm_addr) and "PLAYER VisualMesh" or "other"
    -- The component's full name carries its owning pawn.
    local cname = full(comp):match("(BP_PlayerGoatMain_C_%d+%.[%w_]+)") or full(comp)
    print(string.format("%s SetSkeletalMeshAsset %s on %s -> %s   (seen from player %s)\n",
        TAG, who, cname, short(mesh), player_addr))
end

local registered = {}
for _, path in ipairs({ "/Script/Engine.SkeletalMeshComponent:SetSkeletalMeshAsset",
                        "/Script/Engine.SkinnedMeshComponent:SetSkeletalMeshAsset" }) do
    local ok, err = pcall(function() RegisterHook(path, on_set) end)
    registered[#registered + 1] = path .. "=" .. (ok and "hooked" or ("FAILED " .. tostring(err)))
end
print(TAG .. " loaded: " .. table.concat(registered, " ; ") .. "\n")

local last_mesh, last_eyes = nil, nil
LoopAsync(100, function()
    pcall(function()
        local pc = FindFirstOf("PlayerController")
        local player = (pc ~= nil and valid(pc)) and prop(pc, "Pawn") or nil
        if player == nil or not valid(player) then return end
        player_addr = addr(player)
        local vm = prop(player, "VisualMesh")
        player_vm_addr = addr(vm)
        local m = (vm ~= nil and valid(vm)) and short(prop(vm, "SkeletalMesh")) or "none"
        local e = addr(prop(player, "dynamicEyesMat"))
        if last_mesh ~= nil and m ~= last_mesh then
            print(string.format("%s POLL player %s mesh %s -> %s\n", TAG, player_addr, last_mesh, m))
        end
        if last_eyes ~= nil and e ~= last_eyes then
            print(string.format("%s POLL player %s costume setup re-ran (dynamicEyesMat %s)\n", TAG, player_addr, e))
        end
        last_mesh, last_eyes = m, e
    end)
    return false
end)
