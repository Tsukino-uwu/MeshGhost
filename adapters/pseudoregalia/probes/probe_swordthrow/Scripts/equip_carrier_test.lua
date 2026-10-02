-- Equip carrier test, and it changes state: does the game's changeEquippedWeapon, called on a ghost, reach the
-- player's hand? After a 5 s countdown it calls changeEquippedWeapon(false) on the ghost, then (true) 6 s later, with
-- the player's own flags read around each call. Load it in place of the passive capture for one round.

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

-- A ghost has a controller too: the player's is the PlayerController. Every pawn is logged, so a wrong pick shows.
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

-- The player's own flags before and after each call put the verdict in the log, not in a glance at the screen.
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
