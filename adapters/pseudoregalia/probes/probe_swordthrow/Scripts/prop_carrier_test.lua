-- Prop carrier test, and it spawns: a bare BP_looseWeapon_C 200 above a ghost, the player's weapon flags sampled for
-- 3 s, then the game's "Change Weapon State"(0, thrown) on it and 3 s more, then the actor destroyed. The step that
-- flips the player's flags carries the cross-wire. It crashed a live client: never re-run it as written.
-- The class comes from a live BP_looseWeapon_C (the level keeps parked ones), never a remembered path.

local UEHelpers = require("UEHelpers")

local TAG = "[MeshGhostPropCarrier]"

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

local function pawns_by_role()
    local player, ghost = nil, nil
    local pawns = FindAllOf("BP_PlayerGoatMain_C")
    if pawns then
        for _, pawn in pairs(pawns) do
            if prop(pawn, "RootComponent") then
                local controller = prop(pawn, "Controller")
                local cname = controller and (full_name(controller) or "?") or "<none>"
                if cname:find("PlayerController") then player = pawn else ghost = pawn end
            end
        end
    end
    return player, ghost
end

local function flags_line(player)
    if not player then return "no player pawn" end
    local wmesh = prop(player, "WeaponMesh")
    local wref = prop(player, "weaponRef")
    return string.format("player equipped=%s meshVisible=%s weaponRef=%s",
                         tostring(prop(player, "weaponEquipped?")),
                         wmesh and tostring(prop(wmesh, "bVisible")) or "?",
                         wref and (full_name(wref) or "?") or "<none>")
end

local function find_loose_class()
    local found = FindAllOf("BP_looseWeapon_C")
    if found then
        for _, actor in pairs(found) do
            if prop(actor, "RootComponent") then
                local cls
                pcall(function() cls = actor:GetClass() end)
                if cls then return cls end
            end
        end
    end
    -- Else from a pawn's weaponRef, which keeps the last thrown loose weapon even after pickup.
    local pawns = FindAllOf("BP_PlayerGoatMain_C")
    if pawns then
        for _, pawn in pairs(pawns) do
            local wref = prop(pawn, "weaponRef")
            if wref then
                local cls
                pcall(function() cls = wref:GetClass() end)
                if cls then return cls end
            end
        end
    end
    return nil
end

local spawned = nil
local step = 0

LoopAsync(250, function()
    step = step + 1
    ExecuteInGameThread(function()
        local player, ghost = pawns_by_role()
        if step == 1 then
            if not ghost then
                print(string.format("%s no ghost pawn -- aborting.\n", TAG))
                step = 999
                return
            end
            local cls = find_loose_class()
            if not cls then
                print(string.format("%s no live BP_looseWeapon_C to take the class from -- aborting.\n", TAG))
                step = 999
                return
            end
            local world = UEHelpers.GetWorld()
            if not world or not world:IsValid() then
                print(string.format("%s no world -- aborting.\n", TAG))
                step = 999
                return
            end
            local groot = prop(ghost, "RootComponent")
            local gloc = groot and prop(groot, "RelativeLocation")
            local x = gloc and gloc.X or 0
            local y = gloc and gloc.Y or 0
            local z = (gloc and gloc.Z or 0) + 200
            print(string.format("%s BEFORE spawn: %s\n", TAG, flags_line(player)))
            local ok, err = pcall(function()
                spawned = world:SpawnActor(cls, {X = x, Y = y, Z = z}, {Pitch = 0, Yaw = 0, Roll = 0})
            end)
            print(string.format("%s SPAWNED bare looseWeapon at ghost+200z: ok=%s err=%s actor=%s\n",
                                TAG, tostring(ok), tostring(err),
                                spawned and (full_name(spawned) or "?") or "<nil>"))
        elseif step <= 12 then
            print(string.format("%s after SPAWN +%dms: %s\n", TAG, (step - 1) * 250, flags_line(player)))
        elseif step == 13 then
            if not spawned then
                step = 999
                return
            end
            local ok, err = pcall(function()
                spawned["Change Weapon State"](spawned, 0)
            end)
            print(string.format("%s called 'Change Weapon State'(0) on the spawned prop: ok=%s err=%s\n",
                                TAG, tostring(ok), tostring(err)))
        elseif step <= 24 then
            print(string.format("%s after STATE +%dms: %s\n", TAG, (step - 13) * 250, flags_line(player)))
        elseif step == 25 then
            if spawned then
                local ok = pcall(function()
                    spawned:K2_DestroyActor()
                end)
                print(string.format("%s cleanup destroy: ok=%s\n", TAG, tostring(ok)))
            end
            print(string.format("%s done -- the step whose samples flipped the flags is the claimer.\n", TAG))
        end
    end)
    return step >= 25
end)

print(string.format("%s loaded -- bare spawn, then the state call, player flags sampled through both.\n", TAG))
