-- Logs every live UserWidget's class and Visibility, on change only: read-only, named reads, no UFunction call.
-- Blind to a widget added to or removed from the viewport with its Visibility unchanged, and to non-UserWidget UI.
-- Hot-load over the scratch slot; talk to an NPC start to finish, read a note, sit on a chair. Restore the stub.

local TAG = "[MeshGhostWidgetWatch]"
local POLL_MS = 250

local function log(line) print(TAG .. " " .. os.date("%H:%M:%S") .. " " .. line .. "\n") end
local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

-- Full names for these: one UI_DialoguePrompt_C exists at rest, and the owner chain tells a conversation's apart.
local NAMED = { UI_DialoguePrompt_C = true, BP_ExpressiveTextWidget_C = true, UI_ExaminePrompt_C = true }

local function snapshot()
    local counts = {}
    local names = {}
    local all = FindAllOf("UserWidget")
    local n = 0
    if all then
        for _, w in pairs(all) do
            if valid(w) then
                local cls = "?"
                pcall(function() cls = w:GetClass():GetFName():ToString() end)
                local vis
                pcall(function() vis = w.Visibility end)
                if type(vis) == "userdata" then pcall(function() vis = vis:get() end) end
                if NAMED[cls] then
                    local full = "?"
                    pcall(function() full = w:GetFullName() end)
                    names[#names + 1] = full .. " vis=" .. tostring(vis)
                end
                local key = cls .. "=" .. tostring(vis)
                counts[key] = (counts[key] or 0) + 1
                n = n + 1
            end
        end
    end
    table.sort(names)
    return counts, n, names
end

local last = nil
local polls = 0
log("loaded -- READ-ONLY widget census every " .. POLL_MS .. " ms; logs changes only. Talk to an NPC, read a note, sit on a chair.")

LoopAsync(POLL_MS, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local now, n, names = snapshot()
            polls = polls + 1
            if last == nil then
                local keys = {}
                for k, c in pairs(now) do keys[#keys + 1] = k .. " x" .. c end
                table.sort(keys)
                log("COVERAGE: " .. n .. " live UserWidget(s) at load: " .. table.concat(keys, ", "))
                for _, nm in ipairs(names) do log("  NAMED: " .. nm) end
            else
                local changes = {}
                for k, c in pairs(now) do
                    if (last[k] or 0) ~= c then changes[#changes + 1] = string.format("%s %d->%d", k, last[k] or 0, c) end
                end
                for k, c in pairs(last) do
                    if now[k] == nil then changes[#changes + 1] = string.format("%s %d->0", k, c) end
                end
                if #changes > 0 then
                    table.sort(changes)
                    log("CHANGE: " .. table.concat(changes, " | "))
                    for _, nm in ipairs(names) do log("  NAMED: " .. nm) end
                end
            end
            last = now
            if polls % 40 == 0 then log("alive: " .. polls .. " polls, " .. n .. " widgets") end
        end)
        if not ok then log("tick error: " .. tostring(err)) end
    end)
    return false
end)
