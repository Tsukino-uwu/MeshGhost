-- One-shot carrier test: plays the throw montage on the ghost's pawn, as the adapter's montage mirror does on
-- a peer throw, then samples the player's weaponEquipped? and WeaponMesh.bVisible every 250ms for 4s.
-- A notify runs mid-montage, so a flip it carries lands a beat after play; the next real pickup undoes one.

local TAG = "[MeshGhostMontageCarrier]"
local MONTAGE_PATH = "/Game/Animations/Player/dreamLady_WeaponThrow_Montage.dreamLady_WeaponThrow_Montage"

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
    return string.format("player equipped=%s meshVisible=%s",
                         tostring(prop(player, "weaponEquipped?")),
                         wmesh and tostring(prop(wmesh, "bVisible")) or "?")
end

local fired = false
local samples_after = 0

LoopAsync(250, function()
    ExecuteInGameThread(function()
        local player, ghost = pawns_by_role()
        if not fired then
            if not ghost then
                print(string.format("%s no ghost pawn -- waiting.\n", TAG))
                return
            end
            local montage = StaticFindObject(MONTAGE_PATH)
            if not montage or not montage:IsValid() then
                print(string.format("%s montage did not resolve at '%s' -- aborting (is the asset loaded?).\n", TAG, MONTAGE_PATH))
                fired = true
                samples_after = 999
                return
            end
            print(string.format("%s BEFORE: %s\n", TAG, flags_line(player)))
            -- The game's own wrapper on the pawn, the call the adapter's montage mirror makes.
            local ok, err = pcall(function()
                ghost:CustomPlayMontage(montage)
            end)
            print(string.format("%s CustomPlayMontage(throw) on GHOST %s: ok=%s err=%s\n",
                                TAG, full_name(ghost) or "?", tostring(ok), tostring(err)))
            fired = true
            return
        end
        samples_after = samples_after + 1
        if samples_after <= 16 then
            print(string.format("%s +%dms: %s\n", TAG, samples_after * 250, flags_line(player)))
        end
    end)
    return samples_after > 16
end)

print(string.format("%s loaded -- plays the throw montage on the ghost only, then samples the player's flags for 4s.\n", TAG))
