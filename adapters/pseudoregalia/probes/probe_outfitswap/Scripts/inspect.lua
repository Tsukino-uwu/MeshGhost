-- Run while a ghost is visibly glitched and standing still: for the player and every other pawn of its class,
-- dumps the anim binding (VisualMesh.AnimScriptInstance against animBPref), the component's OverrideMaterials
-- against the mesh asset's own slots, and SkeletalMesh against SkinnedAsset. The player in the same costume is
-- the control. Read-only, named reads and native getters; it reads state, never the render output.

local TAG = "[MeshGhostInspect]"
local SNAPSHOTS = 3
local PERIOD_MS = 2000

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*[\\/])") or "./"
end
local OUT_PATH = scriptDir() .. "../inspect-" .. os.date("%H%M%S") .. ".log"
local out = io.open(OUT_PATH, "a")
local function log(line) print(TAG .. " " .. line .. "\n") end
local function fout(line) if out then out:write(line, "\n") end end

local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end
local function prop(obj, name)
    local v
    if not obj or not pcall(function() v = obj[name] end) then return nil end
    return v
end
local function addr_of(x) local a pcall(function() a = x:GetAddress() end) return a end
local function addr_str(x)
    if x == nil or not valid(x) then return "none" end
    local a = addr_of(x)
    return a and string.format("0x%x", a) or "?"
end
local function full_str(x)
    if x == nil or not valid(x) then return "none" end
    local s pcall(function() s = x:GetFullName() end) return s or "?"
end
local function class_str(x)
    if x == nil or not valid(x) then return "none" end
    local c pcall(function() c = x:GetClass() end)
    if c == nil or not valid(c) then return "?" end
    local s pcall(function() s = c:GetFName():ToString() end) return s or "?"
end

-- Each native getter is pcall'd alone, so one missing on this build costs a single "?", not the line.
local function material_text(vm, mesh)
    local comp_n, mesh_n = "?", "?"
    pcall(function() comp_n = tostring(vm:GetNumMaterials()) end)

    -- The component's own array: length, and each entry's address and class; nothing is followed past that.
    local ov = prop(vm, "OverrideMaterials")
    local ov_n, ov_list = "?", {}
    if ov ~= nil then
        pcall(function() ov_n = tostring(#ov) end)
        pcall(function()
            for i = 1, math.min(#ov, 12) do
                local m = ov[i]
                ov_list[#ov_list + 1] = string.format("[%d]=%s(%s)", i, addr_str(m), class_str(m))
            end
        end)
    end

    -- The mesh asset's own slot count, for the mismatch.
    if mesh ~= nil and valid(mesh) then
        local mm = prop(mesh, "Materials")
        if mm ~= nil then pcall(function() mesh_n = tostring(#mm) end) end
    end

    local verdict = ""
    local c, m = tonumber(comp_n), tonumber(mesh_n)
    if c and m and c ~= m then verdict = "  <<< COUNT MISMATCH" end

    return string.format("component_materials=%s mesh_material_slots=%s overrides=%s %s%s",
        comp_n, mesh_n, ov_n, table.concat(ov_list, " "), verdict)
end

local function dump_pawn(pawn, label)
    fout("")
    fout("--- " .. label .. " : " .. class_str(pawn) .. " at " .. addr_str(pawn))
    if pawn == nil or not valid(pawn) then fout("    (gone)") return end

    local vm   = prop(pawn, "VisualMesh")
    local skel = (vm ~= nil and valid(vm)) and prop(vm, "SkeletalMesh") or nil
    local skin = (vm ~= nil and valid(vm)) and prop(vm, "SkinnedAsset") or nil
    local anim = (vm ~= nil and valid(vm)) and prop(vm, "AnimScriptInstance") or nil
    local abp  = prop(pawn, "animBPref")

    fout("    VisualMesh     : " .. addr_str(vm) .. " (" .. class_str(vm) .. ")")
    fout("    SkeletalMesh   : " .. full_str(skel))
    fout("    SkinnedAsset   : " .. full_str(skin))
    if addr_of(skel) ~= addr_of(skin) then
        fout("    <<< SkeletalMesh and SkinnedAsset are DIFFERENT assets")
    end

    local anim_a, abp_a = addr_of(anim), addr_of(abp)
    fout("    AnimScriptInstance : " .. addr_str(anim) .. " (" .. class_str(anim) .. ")")
    fout("    animBPref          : " .. addr_str(abp) .. " (" .. class_str(abp) .. ")")
    if anim_a and abp_a then
        fout("    binding        : " .. ((anim_a == abp_a) and "SAME object"
             or "<<< DIVERGED -- animBPref is not the live anim instance"))
    else
        fout("    binding        : UNREADABLE (anim=" .. tostring(anim_a) .. " abp=" .. tostring(abp_a) .. ")")
    end

    if anim ~= nil and valid(anim) then
        local playing, montage = "?", "none"
        pcall(function() playing = tostring(anim:IsAnyMontagePlaying()) end)
        pcall(function()
            local m = anim:GetCurrentActiveMontage()
            if m ~= nil and valid(m) then montage = full_str(m) end
        end)
        fout("    montage        : playing=" .. playing .. " current=" .. montage)
    end

    if vm ~= nil and valid(vm) then
        fout("    materials      : " .. material_text(vm, skel))
        local vis, hidden = "?", "?"
        pcall(function() vis = tostring(vm.bVisible) end)
        pcall(function() hidden = tostring(vm.bHiddenInGame) end)
        fout("    visibility     : bVisible=" .. vis .. " bHiddenInGame=" .. hidden)
    end
end

local snaps = 0
log("loaded. " .. SNAPSHOTS .. " snapshots, " .. (PERIOD_MS / 1000) .. " s apart. Read-only.")
log("full log: " .. OUT_PATH)

LoopAsync(PERIOD_MS, function()
    local ok, err = pcall(function()
        snaps = snaps + 1
        local pc = nil
        pcall(function() pc = FindFirstOf("PlayerController") end)
        local player = (pc ~= nil and valid(pc)) and prop(pc, "Pawn") or nil
        if player == nil or not valid(player) then
            log("no player pawn yet")
            snaps = snaps - 1
            return
        end

        fout("")
        fout("================ snapshot " .. snaps .. " at " .. os.date("%H:%M:%S") .. " ================")
        dump_pawn(player, "LOCAL PLAYER (the control)")

        -- Every other pawn of the player's class is a ghost this adapter spawned.
        local cls_name = class_str(player)
        local others = 0
        pcall(function()
            local all = FindAllOf(cls_name)
            if all == nil then fout("FindAllOf(" .. cls_name .. ") returned nothing") return end
            for _, p in ipairs(all) do
                if p ~= nil and valid(p) and addr_of(p) ~= addr_of(player) then
                    others = others + 1
                    dump_pawn(p, "GHOST #" .. others)
                end
            end
        end)
        fout("")
        fout("(" .. others .. " ghost(s) beside the local player)")
        log("snapshot " .. snaps .. ": " .. others .. " ghost(s) recorded")
        if out then out:flush() end
    end)
    if not ok then
        log("inspect error: " .. tostring(err))
        fout("PROBE ERROR: " .. tostring(err))
        if out then out:flush() end
        return true
    end
    if snaps >= SNAPSHOTS then
        log("DONE -- full log at " .. OUT_PATH)
        if out then out:flush() end
        return true
    end
    return false
end)
