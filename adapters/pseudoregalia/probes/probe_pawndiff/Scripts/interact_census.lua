-- MeshGhost INTERACT FUNCTION CENSUS (2026-09-09): READ-ONLY listing, hot-loaded beside the
-- hitable restore. Lists, once, every UFunction on the player's pawn class chain whose name
-- contains interact/sit/stand/chair/rest/heal (case-insensitive), and -- the first time any pawn
-- of that class holds a non-null `Interaction Target` -- that target's class chain and ALL of its
-- functions and plain-valued property names. The question: what the game calls to end a sit.
-- Named reads only; nothing written, nothing called. The listing is by name filter AFTER the
-- full walk (the count of everything walked is logged too).

local TAG = "[MeshGhostInteractFns]"
local PATTERNS = { "nteract", "sit", "Sit", "stand", "Stand", "hair", "rest", "Rest", "heal", "Heal", "seat", "Seat" }

local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end
local function fname_str(x)
    local s
    pcall(function() s = x:GetFName():ToString() end)
    return s or "?"
end
local function prop(obj, name)
    local v
    if not obj or not pcall(function() v = obj[name] end) then return nil end
    return v
end
local function log(line) print(TAG .. " " .. line .. "\n") end
local function matches(name)
    for _, p in ipairs(PATTERNS) do if name:find(p, 1, true) then return true end end
    return false
end

local function walk_class(obj, filter)
    local fns, props, walked_f, walked_p = {}, {}, 0, 0
    local cls = obj:GetClass()
    while cls and cls:IsValid() do
        local cname = fname_str(cls)
        cls:ForEachFunction(function(fn)
            walked_f = walked_f + 1
            local n = fname_str(fn)
            if not filter or matches(n) then fns[#fns + 1] = cname .. "." .. n end
        end)
        cls:ForEachProperty(function(pr)
            walked_p = walked_p + 1
            local n = fname_str(pr)
            local pc = "?"
            pcall(function() pc = pr:GetClass():GetFName():ToString() end)
            if not filter or matches(n) then props[#props + 1] = cname .. "." .. n .. ":" .. pc end
        end)
        local sup = nil
        pcall(function() sup = cls:GetSuperStruct() end)
        if sup and sup ~= cls and sup:IsValid() then cls = sup else cls = nil end
    end
    return fns, props, walked_f, walked_p
end

local function player_pawn()
    local pcs = FindAllOf("PlayerController")
    if not pcs then return nil end
    for _, pc in pairs(pcs) do
        if valid(pc) then
            for _, field in ipairs({ "AcknowledgedPawn", "Pawn" }) do
                local pawn = prop(pc, field)
                if pawn ~= nil and valid(pawn) then return pawn end
            end
        end
    end
    return nil
end

local pawn_listed, target_listed = false, false
log("loaded")

LoopAsync(3000, function()
    local me = player_pawn()
    if not me then return false end
    if not pawn_listed then
        pawn_listed = true
        local fns, props, wf, wp = walk_class(me, true)
        log(string.format("pawn class chain: %d functions, %d properties walked; %d function(s) and %d property(ies) match the filter", wf, wp, #fns, #props))
        for _, f in ipairs(fns) do log("  fn " .. f) end
        for _, p in ipairs(props) do log("  prop " .. p) end
    end
    if not target_listed then
        local my_class = "?"
        pcall(function() my_class = me:GetClass():GetFName():ToString() end)
        for _, p in pairs(FindAllOf(my_class) or {}) do
            if valid(p) then
                local t = prop(p, "Interaction Target")
                if t ~= nil and valid(t) then
                    target_listed = true
                    local fns, props, wf, wp = walk_class(t, false)
                    log(string.format("Interaction Target on %s = %s: %d function(s), %d property(ies) (all listed)", fname_str(p), fname_str(t), wf, wp))
                    for _, f in ipairs(fns) do log("  target fn " .. f) end
                    for _, pr in ipairs(props) do log("  target prop " .. pr) end
                    break
                end
            end
        end
    end
    return target_listed
end)
