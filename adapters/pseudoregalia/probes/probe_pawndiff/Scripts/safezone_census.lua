-- Safe-zone census, read-only, once: what writes respawnTransform, the spot a pit fall returns the player to? Walks
-- every object, buckets by class, then lists the classes named like safe/respawn/zone/hazard with each live actor's
-- location. The walk's callback only appends: a Lua error inside it aborts the game. Run over the scratch slot.

local TAG = "[MeshGhostSafeZone]"
local WORDS = { "Safe", "safe", "Respawn", "respawn", "Checkpoint", "checkpoint", "Zone", "Kill", "Hazard", "Death", "Pit" }

local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end
local function fname_str(x)
    local s
    pcall(function() s = x:GetFName():ToString() end)
    return s or "?"
end
local function log(line) print(TAG .. " " .. line .. "\n") end
local function matches(name)
    for _, w in ipairs(WORDS) do if name:find(w, 1, true) then return true end end
    return false
end

local done = false
log("loaded -- one class census; classes named like safe/respawn/checkpoint/zone/kill/hazard listed with their live actors")

LoopAsync(1500, function()
    if done then return true end
    done = true
    local objects = {}
    local ok, err = pcall(function()
        ForEachUObject(function(obj)
            objects[#objects + 1] = obj
        end)
    end)
    if not ok then log("walk error: " .. tostring(err)) return true end
    local by_class = {}
    local total = 0
    for _, obj in ipairs(objects) do
        total = total + 1
        local cname = "?"
        pcall(function() cname = obj:GetClass():GetFName():ToString() end)
        by_class[cname] = (by_class[cname] or 0) + 1
    end
    local names = {}
    for cname in pairs(by_class) do names[#names + 1] = cname end
    table.sort(names)
    log(string.format("%d objects in %d classes", total, #names))
    local hits = 0
    for _, cname in ipairs(names) do
        if matches(cname) then
            hits = hits + 1
            log(string.format("  class %s x%d", cname, by_class[cname]))
            for _, obj in ipairs(objects) do
                local ok2 = pcall(function()
                    if obj:GetClass():GetFName():ToString() == cname and valid(obj) then
                        local oname = fname_str(obj)
                        -- A class default object's name starts with Default__.
                        if not oname:find("^Default__") then
                            -- Only an actor has a RootComponent, read first: nothing else gets a UFunction call.
                            local root = nil
                            local is_actor = pcall(function() root = obj.RootComponent end) and root ~= nil
                            local loc = is_actor and "?" or "(not an actor)"
                            if is_actor then
                                pcall(function()
                                    local v = obj:K2_GetActorLocation()
                                    loc = string.format("%.0f,%.0f,%.0f", v.X, v.Y, v.Z)
                                end)
                            end
                            log(string.format("     %s at %s", oname, loc))
                        end
                    end
                end)
                if not ok2 then log("     (read error on one object)") end
            end
        end
    end
    log(string.format("%d class(es) matched the words; done", hits))
    return true
end)
