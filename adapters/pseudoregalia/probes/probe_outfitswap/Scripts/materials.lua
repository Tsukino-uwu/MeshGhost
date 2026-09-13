-- MeshGhost MATERIAL-ORIGIN INSPECTOR (2026-09-13). READ-ONLY.
--
-- The question the counts could not answer. A glitched ghost wears `Kindred` with four
-- MaterialInstanceDynamic entries in the COMPONENT's `OverrideMaterials`, and `Kindred` has four
-- material slots -- so a count check passes while the model is visibly wrong. The counts matching
-- is a coincidence of two costumes having four slots each; what matters is what those overrides
-- are PARENTED to.
--
-- The adapter mirrors a peer's hurt reaction by running the game's own
-- `BPI_PerformDamageResponse` on the ghost (Plugin.cpp, MIRROR_HURT_REACTION). If that flash
-- builds dynamic material instances over whatever costume is worn AT THAT MOMENT, and an outfit
-- swap then replaces the mesh underneath them, `OverrideMaterials` is not cleared -- the previous
-- costume's materials stay bound to the new costume's slots, permanently. That is a mangled model
-- that survives every later swap and clears only when the ghost is respawned, which is what a save
-- reset does.
--
-- So this prints, per slot: what is actually RENDERING (`GetMaterial`), what the MESH ITSELF
-- declares for that slot, and, when the renderer's material is a dynamic instance, its `Parent`.
-- A parent naming a costume the ghost is NOT wearing is the bug, stated by the engine.
--
-- The local player is dumped as the control, same as the binding check -- a field is only
-- evidence if the player wearing a costume normally does not show it too.
--
-- WHAT THIS CANNOT SEE: whether the model looks right. It reads material bindings, never pixels.
--
-- Dev-only tooling; never ships.

local TAG = "[MeshGhostMaterials]"

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*[\\/])") or "./"
end
local OUT_PATH = scriptDir() .. "../materials-" .. os.date("%H%M%S") .. ".log"
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

-- The costume a path belongs to, for the mismatch line. Deliberately the LAST path segment before
-- the dot rather than a hand-kept list of costume names -- a list is a guess about which costumes
-- can be involved, and every modded one would be missing from it.
local function asset_of(full)
    return (full:match("([^/]+)%.[^%.]*$")) or full
end

-- Every mesh the pawn owns, not just the body. The outfit swap and the WEAPON swap use the same
-- recipe in Plugin.cpp (setter, then raw writes, never touching OverrideMaterials), so whether the
-- hurt flash strands materials on the weapon too is a question to ask the engine rather than to
-- assume from the body's answer -- the flash may well only touch the body.
local MESHES = { "VisualMesh", "WeaponMesh", "LightMesh" }

local function dump_mesh(pawn, vm, mesh_name, label)
    fout("")
    fout("--- " .. label .. " / " .. mesh_name)
    if vm == nil or not valid(vm) then fout("    (absent on this pawn)") return end

    local mesh = prop(vm, "SkeletalMesh")
    local mesh_full = full_str(mesh)
    local worn = asset_of(mesh_full)
    fout("    wearing: " .. mesh_full)

    local n = 0
    pcall(function() n = vm:GetNumMaterials() end)
    if type(n) ~= "number" then n = 0 end
    fout("    slots reported by the component: " .. tostring(n))

    local mismatches = 0
    for i = 0, n - 1 do
        -- What is actually rendering in this slot.
        local rendering = nil
        pcall(function() rendering = vm:GetMaterial(i) end)
        local rendering_full = full_str(rendering)

        -- If it is a dynamic instance, what was it built FROM.
        local parent_full = "-"
        if rendering ~= nil and valid(rendering) then
            local p = prop(rendering, "Parent")
            if p ~= nil then parent_full = full_str(p) end
        end

        -- What the MESH ASSET itself declares for this slot, for comparison.
        local declared_full = "-"
        if mesh ~= nil and valid(mesh) then
            pcall(function()
                local mats = mesh.Materials
                if mats ~= nil then
                    local entry = mats[i + 1]      -- lua arrays from UE are 1-based here
                    if entry ~= nil then
                        local mi = entry.MaterialInterface
                        if mi ~= nil then declared_full = full_str(mi) end
                    end
                end
            end)
        end

        -- The finding: a material whose origin names a costume the pawn is not wearing.
        local origin = (parent_full ~= "-" and parent_full ~= "none") and parent_full or rendering_full
        local flag = ""
        if origin ~= "none" and origin ~= "?" and worn ~= nil then
            local o = asset_of(origin)
            if o and not origin:find(worn, 1, true) and not (declared_full ~= "-" and origin:find(asset_of(declared_full), 1, true)) then
                flag = "   <<< FOREIGN: built from '" .. tostring(o) .. "' while wearing '" .. tostring(worn) .. "'"
                mismatches = mismatches + 1
            end
        end

        fout(string.format("    slot %d:", i))
        fout("        rendering : " .. rendering_full .. " (" .. class_str(rendering) .. ")")
        fout("        parent    : " .. parent_full)
        fout("        mesh says : " .. declared_full .. flag)
    end
    fout("    FOREIGN slots: " .. mismatches .. (mismatches > 0 and "   <<<<<< these materials do not belong to this mesh" or ""))
end

local function dump(pawn, label)
    fout("")
    fout("=== " .. label .. " : " .. class_str(pawn))
    if pawn == nil or not valid(pawn) then fout("    (gone)") return end
    for _, mesh_name in ipairs(MESHES) do
        dump_mesh(pawn, prop(pawn, mesh_name), mesh_name, label)
    end
end

log("loaded. One pass, read-only.")
log("full log: " .. OUT_PATH)

LoopAsync(1500, function()
    local ok, err = pcall(function()
        local pc = nil
        pcall(function() pc = FindFirstOf("PlayerController") end)
        local player = (pc ~= nil and valid(pc)) and prop(pc, "Pawn") or nil
        if player == nil or not valid(player) then log("no player pawn") return end

        fout("================ material origins at " .. os.date("%H:%M:%S") .. " ================")
        dump(player, "LOCAL PLAYER (the control)")

        local cls = class_str(player)
        local pa pcall(function() pa = player:GetAddress() end)
        local n = 0
        pcall(function()
            local all = FindAllOf(cls)
            if all == nil then return end
            for _, p in ipairs(all) do
                local a pcall(function() a = p:GetAddress() end)
                if p ~= nil and valid(p) and a ~= pa then
                    n = n + 1
                    dump(p, "GHOST #" .. n)
                end
            end
        end)
        fout("")
        log("done -- " .. n .. " ghost(s)")
        if out then out:flush() end
    end)
    if not ok then
        log("error: " .. tostring(err))
        fout("PROBE ERROR: " .. tostring(err))
        if out then out:flush() end
    end
    return true   -- one pass only
end)
