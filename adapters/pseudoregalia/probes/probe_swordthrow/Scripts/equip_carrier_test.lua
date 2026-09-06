-- One-shot carrier test for the equip cross-wire (2026-09-01). Loaded IN PLACE of the passive
-- capture for one round, then removed.
--
-- Theory to prove or kill: the game's own `changeEquippedWeapon` Blueprint routes through
-- shared state (save/GameInstance), so calling it on ANY pawn reaches THE player. The adapter
-- calls it on the ghost on every peer throw/pickup -- if the theory holds, that is the whole
-- cross-wire ("fully removes the weapon from another player's hand").
--
-- What it does: finds the GHOST pawn (the BP_PlayerGoatMain_C with no Controller -- a ghost is
-- never possessed), waits 5 seconds (countdown printed), calls changeEquippedWeapon(false) on
-- it, waits 5 more, calls changeEquippedWeapon(true). NO throw happens anywhere. The user
-- watches their OWN character's hand:
--   - sword vanishes from the PLAYER's hand at the first call -> carrier PROVEN.
--   - only the ghost's hand changes -> theory dead, next suspect.
--
-- Dev-only, state-changing by design (a probe may cheat); the second call puts the flag back.

local TAG = "[MeshGhostEquipCarrier]"

local function full_name(obj)
    local n
    pcall(function() n = obj:GetFullName() end)
    return n
end

local function prop(obj, name)
    local v
    if not pcall(function() v = obj[name] end) then return nil end
    return v
end

-- The ghost IS possessed (the adapter gives it a controller), so absence-of-controller was
-- wrong -- first run said "all pawns have controllers". The player's controller is a
-- PlayerController; the ghost's is not. Log both so a wrong pick is visible in the record.
local function find_ghost()
    local pawns = FindAllOf("BP_PlayerGoatMain_C")
    if not pawns then return nil end
    local ghost = nil
    for _, pawn in pairs(pawns) do
        local root = prop(pawn, "RootComponent")
        if root then
            local controller = prop(pawn, "Controller")
            local cname = controller and (full_name(controller) or "?") or "<none>"
            print(string.format("%s pawn %s controller=%s\n", TAG, full_name(pawn) or "?", cname))
            if not cname:find("PlayerController") then
                ghost = pawn
            end
        end
    end
    return ghost
end

-- Self-measuring since the second round: read the PLAYER pawn's own flags before and after
-- the call on the GHOST, so the verdict comes from the record instead of a timed human glance.
local function player_flags()
    local pawns = FindAllOf("BP_PlayerGoatMain_C")
    if not pawns then return "no pawns" end
    for _, pawn in pairs(pawns) do
        local controller = prop(pawn, "Controller")
        local cname = controller and (full_name(controller) or "?") or "<none>"
        if cname:find("PlayerController") then
            local wmesh = prop(pawn, "WeaponMesh")
            return string.format("player equipped=%s meshVisible=%s",
                                 tostring(prop(pawn, "weaponEquipped?")),
                                 wmesh and tostring(prop(wmesh, "bVisible")) or "?")
        end
    end
    return "no player pawn"
end

local function call_equip(pawn, value)
    print(string.format("%s BEFORE call: %s\n", TAG, player_flags()))
    local ok, err = pcall(function()
        pawn:changeEquippedWeapon(value)
    end)
    print(string.format("%s called changeEquippedWeapon(%s) on ghost: ok=%s err=%s\n",
                        TAG, tostring(value), tostring(ok), tostring(err)))
    print(string.format("%s AFTER call: %s\n", TAG, player_flags()))
end

local step = 0
LoopAsync(1000, function()
    step = step + 1
    if step <= 5 then
        ExecuteInGameThread(function()
            local ghost = find_ghost()
            print(string.format("%s T-minus %d -- watch the PLAYER's hand. ghost=%s\n",
                                TAG, 6 - step, ghost and (full_name(ghost) or "?") or "NOT FOUND"))
        end)
        return false
    elseif step == 6 then
        ExecuteInGameThread(function()
            local ghost = find_ghost()
            if not ghost then
                print(string.format("%s no ghost pawn found (all pawns have controllers) -- aborting.\n", TAG))
                return
            end
            call_equip(ghost, false)
        end)
        return false
    elseif step <= 11 then
        print(string.format("%s restoring in %d...\n", TAG, 12 - step))
        return false
    elseif step == 12 then
        ExecuteInGameThread(function()
            local ghost = find_ghost()
            if ghost then
                call_equip(ghost, true)
            end
            print(string.format("%s done -- report what the PLAYER's hand did at each call.\n", TAG))
        end)
        return true
    end
    return true
end)

print(string.format("%s loaded -- 5 second countdown, then changeEquippedWeapon(false) on the GHOST only. Watch your OWN character's hand.\n", TAG))
