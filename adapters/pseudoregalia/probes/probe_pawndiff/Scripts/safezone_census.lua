-- MeshGhost SAFE-ZONE CENSUS (2026-09-09): READ-ONLY, once, hot-loaded over the scratch slot. The
-- pit fall returns the player to `respawnTransform` (a Transform on the pawn, -6550,6300,1100 at
-- 12:44 -- a placed, round number) and the driven clone's stays at zero, so its reset lands at the
-- world origin. The question: WHAT writes it -- a placed actor the player overlaps, most likely,
-- and the clone's capsule generates no overlap events. This walks every object once
-- (`ForEachUObject`, the callback only appends -- a Lua error inside it aborts the game) and
-- buckets by class name, then lists the classes whose names contain any of a few words and, for
-- each live actor of those classes, its name and location. Filtered AFTER the walk; the full
-- class count is logged too.

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
                        -- Only actors that are NOT class defaults: a CDO's name starts with Default__.
                        if not oname:find("^Default__") then
                            -- An ACTOR only: a named property read first (`RootComponent` exists on
                            -- every actor and on nothing else here); a UFunction is called on
                            -- nothing that fails it (host CLAUDE.md, FindAllOf/ForEachUObject rule).
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
