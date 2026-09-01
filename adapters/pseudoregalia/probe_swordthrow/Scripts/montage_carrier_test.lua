-- Carrier test #2 for the equip cross-wire (2026-09-01). changeEquippedWeapon-on-ghost was
-- exonerated by carrier test #1 (player flags untouched, before/after reads); this one tests
-- the remaining suspect that fits every symptom: THE MIRRORED MONTAGE'S NOTIFIES.
--
-- It plays the real throw montage on the GHOST's own anim instance -- exactly what the
-- adapter's montage mirror does on a peer throw -- with no peer, no throw, no adapter edge,
-- then samples the PLAYER pawn's weaponEquipped?/WeaponMesh.bVisible every 250ms for 4s.
-- A notify runs mid-montage, so the flip (if this is the carrier) lands a beat after play.
--
-- Montage path read from this session's own log (the mirror logged it at 15:59:41), not from
-- memory: /Game/Animations/Player/dreamLady_WeaponThrow_Montage.
--
-- Dev-only and state-changing by design; if the player's flag flips it will come back on the
-- next real pickup (and proves the whole defect in one line).

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
            -- CustomPlayMontage on the PAWN -- the game's own wrapper, and exactly what the
            -- adapter's montage mirror calls on a peer throw (Plugin.cpp, call_custom_play_montage).
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
