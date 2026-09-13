-- MeshGhost MESH-COMPONENT FUNCTION DUMP (2026-09-13). READ-ONLY.
--
-- What can this build actually be asked to do about a mesh component's materials? The fix for the
-- stranded-materials bug needs to clear `OverrideMaterials` after a mesh swap, and "the engine has
-- EmptyOverrideMaterials" is general UE knowledge, not a fact about THIS build -- which has
-- already shown many UFunctions silently missing from reflection while direct property writes work
-- (Plugin.cpp's own SetSkeletalMeshAsset comment: no SetSkeletalMesh, InitAnim,
-- MarkRenderStateDirty or RecreateRenderState exist here at all).
--
-- So: every function name on the VisualMesh component's class chain, written in full and sorted.
-- NOT filtered to material-shaped names first -- a candidate list built by a name filter running
-- dry is how this adapter missed `change Move State` (probes.md, 2026-09-09), and the shortlist
-- printed at the end is a convenience on top of the full dump, never instead of it.
--
-- Also prints the parameter names of a handful of material entry points if they exist, because a
-- call's parameters come from a dump rather than from engine knowledge.
--
-- Dev-only tooling; never ships.

local TAG = "[MeshGhostMeshFns]"

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*[\\/])") or "./"
end
local OUT_PATH = scriptDir() .. "../meshfns-" .. os.date("%H%M%S") .. ".log"
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
local function fname_str(x)
    local s pcall(function() s = x:GetFName():ToString() end) return s or "?"
end

-- The shortlist needles, applied AFTER the full dump is written.
local NEEDLES = { "Material", "material", "Override", "override", "Empty", "empty",
                  "RenderState", "Dirty", "Dynamic" }

LoopAsync(1500, function()
    local ok, err = pcall(function()
        local pc = nil
        pcall(function() pc = FindFirstOf("PlayerController") end)
        local player = (pc ~= nil and valid(pc)) and prop(pc, "Pawn") or nil
        if player == nil or not valid(player) then log("no player pawn") return end
        local vm = prop(player, "VisualMesh")
        if vm == nil or not valid(vm) then log("no VisualMesh") return end

        fout("=== every function on VisualMesh's class chain, " .. os.date("%Y-%m-%d %H:%M:%S"))

        local names, seen = {}, {}
        local cls = nil
        pcall(function() cls = vm:GetClass() end)
        local depth = 0
        while cls ~= nil and valid(cls) do
            depth = depth + 1
            fout("-- class " .. depth .. ": " .. fname_str(cls))
            pcall(function()
                cls:ForEachFunction(function(fn)
                    -- Append only. A Lua error inside ForEachFunction aborts the game past any
                    -- pcall (probes.md, 2026-09-06), so nothing is decided in here.
                    local n = fname_str(fn)
                    if not seen[n] then seen[n] = true names[#names + 1] = n end
                end)
            end)
            local nxt = nil
            pcall(function() nxt = cls:GetSuperStruct() end)
            if nxt == nil or not valid(nxt) then break end
            cls = nxt
            if depth > 12 then break end
        end

        table.sort(names)
        fout("")
        fout("total distinct functions: " .. #names)
        for _, n in ipairs(names) do fout("   " .. n) end

        fout("")
        fout("=== shortlist (applied AFTER the full dump above) ===")
        local hits = 0
        for _, n in ipairs(names) do
            for _, needle in ipairs(NEEDLES) do
                if n:find(needle, 1, true) then
                    hits = hits + 1
                    fout("   " .. n)
                    break
                end
            end
        end
        fout("shortlist hits: " .. hits)

        log("dumped " .. #names .. " function(s), " .. hits .. " material-shaped. -> " .. OUT_PATH)
        if out then out:flush() end
    end)
    if not ok then
        log("error: " .. tostring(err))
        fout("PROBE ERROR: " .. tostring(err))
        if out then out:flush() end
    end
    return true
end)
