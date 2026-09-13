-- MeshGhost OUTFIT ECHO HOOK (2026-09-13). READ-ONLY: a native-function pre-hook that only logs.
--
-- The echo: after a peer's costume swap, the watcher's own character takes that costume at a later
-- ghost spawn (echo_watch.lua, measured). echo_source.lua then set a ghost's mesh locally and saw no
-- copy -- but in that run the player's costume setup never re-ran at all, so it was inconclusive,
-- not a negative.
--
-- This catches the WRITE itself. `SetSkeletalMeshAsset` is a native engine UFunction, the allowed
-- kind of hook on this host (host CLAUDE.md: never a Blueprint one). Every call is printed straight
-- to UE4SS.log, so its millisecond timestamp sits in the same file as the adapter's own
-- `outfit mesh applied for ghost pN` and `spawned ghost for remote` lines: a call on the PLAYER's
-- VisualMesh at the same instant as an adapter apply is our code; one at a spawn with no apply
-- beside it is the game's own setup. The player's mesh and dynamicEyesMat are polled as a backstop,
-- in case the player's mesh changes by a path that never calls the function.
--
-- Two game processes can share this install and this log, so every line names the player pawn it
-- was seen from.
--
-- The hook body only formats and prints -- no lookups, no calls -- because it runs inside the
-- engine's call. Remove by restoring the scratch stub; RestartMod drops the hook with the mod.
-- Dev-only tooling; never ships.

local TAG = "[EchoHook]"

local function valid(o) local ok, v = pcall(function() return o:IsValid() end) return ok and v == true end
local function prop(o, n) local v if not o or not pcall(function() v = o[n] end) then return nil end return v end
local function addr(o) local ok, a = pcall(function() return o:GetAddress() end) return (ok and a) and string.format("0x%x", a) or "nil" end
local function full(o) if o == nil or not valid(o) then return "none" end local s pcall(function() s = o:GetFullName() end) return s or "?" end
local function short(o) local f = full(o) return f:match("([^/]+)%.[^%.]*$") or f end

-- Cached per poll, read in the hook (the hook must not search the world).
local player_addr, player_vm_addr = "nil", "nil"

local function on_set(Context, NewMesh)
    local comp, mesh = nil, nil
    pcall(function() comp = Context:get() end)
    pcall(function() mesh = NewMesh:get() end)
    local ca = addr(comp)
    local who = (ca == player_vm_addr) and "PLAYER VisualMesh" or "other"
    -- The component's full name carries its owning pawn (name containment, host CLAUDE.md).
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
