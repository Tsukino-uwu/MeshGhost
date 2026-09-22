-- MeshGhost DIALOGUE WATCH (2026-09-23): READ-ONLY, on the PLAYER's own pawn. Part C of
-- agent_docs/chaser-planning.md: which field marks talking to an NPC and reading a note, so the
-- chaser pack can hold there the way it holds for the pause menu and a chair (`moveState` 8).
-- `sit_watch.lua` (2026-09-09) plus the plan's candidates: the pawn's `DialogueCam` component
-- active, the camera manager's view target, the controller's mouse cursor. Logs on change only,
-- with a wall-clock stamp so a line pairs with what the user saw. Named reads only, no call, no
-- write. Hot-loaded over the scratch slot; restore the stub afterwards. Dev-only; never ships.
--
-- WHAT IT CANNOT SEE: a flag on the NPC or on a widget rather than on the player, pawn and
-- controller. If none of these move across a conversation, widen to those, not deeper here.

local TAG = "[MeshGhostDialogueWatch]"
local FIELDS = { "foundInteracter", "hasMovementInput?", "moveInputAmount", "moveState", "actionState", "bIsCrouched" }

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
local function plain(value)
    local t = type(value)
    if t == "boolean" or t == "number" or t == "string" or t == "nil" then return value end
    if t == "userdata" then
        local got
        if pcall(function() got = value:get() end) and got ~= nil and type(got) ~= "userdata" then return got end
        local okv, isvalid = pcall(function() return value:IsValid() end)
        if okv and isvalid == false then return "<unresolved>" end
        return "<obj " .. fname_str(value) .. ">"
    end
    return "<" .. t .. ">"
end
local function vec_text(v)
    local x, y, z
    pcall(function() x, y, z = v.X, v.Y, v.Z end)
    if type(x) ~= "number" then return tostring(plain(v)) end
    return string.format("%.2f,%.2f,%.2f", x, y, z or 0)
end
local function player_controller_and_pawn()
    local pcs = FindAllOf("PlayerController")
    if not pcs then return nil end
    for _, pc in pairs(pcs) do
        if valid(pc) then
            for _, field in ipairs({ "AcknowledgedPawn", "Pawn" }) do
                local pawn = prop(pc, field)
                if pawn ~= nil and valid(pawn) then return pc, pawn end
            end
        end
    end
    return nil
end

local last = {}
local t_start = os.clock()
local function tick()
    local pc, pawn = player_controller_and_pawn()
    if not pc or not pawn then return end
    local now = {}
    for _, f in ipairs(FIELDS) do now[f] = tostring(plain(prop(pawn, f))) end
    local target = prop(pawn, "Interaction Target")
    now["Interaction Target"] = (target ~= nil and valid(target)) and fname_str(target) or "none"
    now["inputVectorWorld"] = vec_text(prop(pawn, "inputVectorWorld"))
    local mv = prop(pawn, "CharacterMovement")
    now["MovementMode"] = mv and tostring(plain(prop(mv, "MovementMode"))) or "?"
    -- The dialogue candidates (chaser-planning.md, Part C). Named reads, never a walk.
    local cam = prop(pawn, "DialogueCam")
    now["DialogueCam.bIsActive"] = (cam ~= nil and valid(cam)) and tostring(plain(prop(cam, "bIsActive"))) or "none"
    local pcm = prop(pc, "PlayerCameraManager")
    local vt = (pcm ~= nil and valid(pcm)) and prop(pcm, "ViewTarget") or nil
    local vt_target = vt and prop(vt, "Target") or nil
    now["ViewTarget.Target"] = (vt_target ~= nil and valid(vt_target)) and fname_str(vt_target) or "none"
    now["bShowMouseCursor"] = tostring(plain(prop(pc, "bShowMouseCursor")))
    local changes = {}
    for k, v in pairs(now) do
        -- the input vector and amount change every frame while moving: log those only on
        -- zero <-> non-zero transitions, the rest on any change
        local coarse = v
        if k == "inputVectorWorld" then coarse = (v == "0.00,0.00,0.00") and "zero" or "moving" end
        if k == "moveInputAmount" then coarse = (v == "0" or v == "0.0") and "zero" or "moving" end
        if last[k] ~= coarse then
            changes[#changes + 1] = string.format("%s=%s", k, (k == "inputVectorWorld" or k == "moveInputAmount") and coarse or v)
            last[k] = coarse
        end
    end
    if #changes > 0 then
        table.sort(changes)
        print(string.format("%s %s t=%6.1fs %s\n", TAG, os.date("%H:%M:%S"), os.clock() - t_start, table.concat(changes, " | ")))
    end
end

print(TAG .. " loaded -- watching the PLAYER pawn, camera and controller (read-only). Talk to an NPC, read a note, sit on a chair.\n")
LoopAsync(33, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(tick)
        if not ok then print(TAG .. " tick error: " .. tostring(err) .. "\n") end
    end)
    return false
end)
