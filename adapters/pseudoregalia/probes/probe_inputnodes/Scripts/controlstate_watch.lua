-- Logs the player pawn's controlState and moveState on every change: read-only, two named reads.
-- Hot-loaded over the scratch slot; restore the stub afterwards.

local TAG = "[MeshGhostControlState]"
local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end
local function num(obj, name)
    local v
    pcall(function() v = obj[name] end)
    if type(v) == "userdata" then pcall(function() v = v:get() end) end
    return v
end
local function player_pawn()
    local pcs = FindAllOf("PlayerController")
    if not pcs then return nil end
    for _, pc in pairs(pcs) do
        if valid(pc) then
            for _, field in ipairs({ "AcknowledgedPawn", "Pawn" }) do
                local pawn
                pcall(function() pawn = pc[field] end)
                if pawn ~= nil and valid(pawn) then return pawn end
            end
        end
    end
    return nil
end

local last_cs, last_ms
print(TAG .. " loaded -- READ-ONLY. Talk to an NPC, read a book, sit on a chair, open the pause menu.\n")
LoopAsync(33, function()
    ExecuteInGameThread(function()
        pcall(function()
            local pawn = player_pawn()
            if not pawn then return end
            local cs, ms = num(pawn, "controlState"), num(pawn, "moveState")
            if cs ~= last_cs or ms ~= last_ms then
                print(string.format("%s %s controlState=%s moveState=%s\n", TAG, os.date("%H:%M:%S"), tostring(cs), tostring(ms)))
                last_cs, last_ms = cs, ms
            end
        end)
    end)
    return false
end)
