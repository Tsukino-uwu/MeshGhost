-- MeshGhost FUNCTION PARAMS (2026-09-09): READ-ONLY, once. For the interact/sit/heal functions the
-- census listed on the pawn and on the chair (`BP_RestChair_C`, any live instance), logs each
-- UFunction's parameter list (name:type, with the return value marked) and its parms size --
-- so a call with zero-filled params is known to be a real call and not an early return on a
-- null actor. Nothing written, nothing called.

local TAG = "[MeshGhostFnParams]"
local PAWN_FNS = { "EndInteract", "BPI_EndInteract", "BPI_TryInteract", "BPI_InteractConfirm", "exitTransition", "enterTransition",
                   "trySitHeal", "tryFinishHeal", "healPlayer", "healDing", "InpActEvt_IA_Interact_K2Node_EnhancedInputActionEvent_10",
                   "InpActEvt_IA_Move_K2Node_EnhancedInputActionEvent_19" }
local CHAIR_FNS = { "BPI_EndInteract", "BPI_TryInteract", "BPI_InteractConfirm" }

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

local function find_fn(obj, name)
    local found = nil
    local cls = obj:GetClass()
    while cls and cls:IsValid() and not found do
        cls:ForEachFunction(function(fn)
            if not found and fname_str(fn) == name then found = fn end
        end)
        local sup = nil
        pcall(function() sup = cls:GetSuperStruct() end)
        if sup and sup ~= cls and sup:IsValid() then cls = sup else cls = nil end
    end
    return found
end

local function describe(fn)
    local parts = {}
    local size = "?"
    pcall(function() size = fn:GetPropertiesSize() end)
    fn:ForEachProperty(function(p)
        local n, t = fname_str(p), "?"
        pcall(function() t = p:GetClass():GetFName():ToString() end)
        local extra = ""
        pcall(function()
            local pc = p:GetPropertyClass()
            if pc then extra = "<" .. fname_str(pc) .. ">" end
        end)
        parts[#parts + 1] = n .. ":" .. t .. extra
    end)
    return string.format("parms=%s [%s]", tostring(size), table.concat(parts, ", "))
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

local done = false
log("loaded")
LoopAsync(1000, function()
    if done then return true end
    local me = player_pawn()
    if not me then return false end
    done = true
    for _, n in ipairs(PAWN_FNS) do
        local fn = find_fn(me, n)
        log("pawn." .. n .. ": " .. (fn and describe(fn) or "NOT FOUND"))
    end
    local chairs = FindAllOf("BP_RestChair_C") or {}
    local chair = nil
    for _, c in pairs(chairs) do if valid(c) then chair = c break end end
    if chair then
        for _, n in ipairs(CHAIR_FNS) do
            local fn = find_fn(chair, n)
            log("chair." .. n .. ": " .. (fn and describe(fn) or "NOT FOUND"))
        end
    else
        log("no live BP_RestChair_C to describe")
    end
    return true
end)
