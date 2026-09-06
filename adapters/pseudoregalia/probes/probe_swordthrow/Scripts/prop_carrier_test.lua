-- Carrier test #3 (2026-09-01). The whole-prop subtraction PROVED the thrown-weapon prop path
-- carries the cross-wire (toggle armed on the watcher -> the player kept their sword,
-- user-confirmed live). This splits it one level finer, with no peer and no adapter edge:
--
--   step 1: SPAWN a bare BP_looseWeapon_C near the ghost (exactly what tick_remote_weapon
--           does first) and sample the PLAYER's weapon flags for 3s.
--   step 2: call the game's "Change Weapon State"(0 = thrown/in-flight) on it -- the mirror's
--           second act -- and sample 3s more.
--   step 3: destroy the spawned actor (cleanup), report.
--
-- Whichever step flips the player's flags is the claimer. If NEITHER does, the carrier needs
-- the real sequence (spawn + state + position writes) and the next split runs on the C++ side.
--
-- The class object is taken from a LIVE BP_looseWeapon_C instance (the level keeps parked
-- ones), not from a remembered path -- CLAUDE.md's no-paths-from-memory rule.

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
    -- Fallback: any pawn's weaponRef keeps pointing at the LAST thrown loose weapon even after
    -- pickup (measured -- it is why "weaponRef ~= nil" alone never meant thrown), so a session
    -- where anyone has ever thrown still hands us the class.
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
