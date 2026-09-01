-- MeshGhost slash-VFX capture probe. ONE question, from the user 2026-09-01:
--
--   *"its a vfx we haven't added before, like a curved slash ish going outward when attacking
--   with the sword"* -- a ghost playing the attack montage shows no such thing.
--
-- So: what does a LOCAL melee swing actually spawn? This logs every Niagara/Cascade component
-- APPEARING or ACTIVATING, with the asset it plays, what it is attached to, and where it sits
-- relative to the player -- exactly the fields a MIRRORED_EFFECTS row needs (asset path, attach
-- point or world-spawned, offset). Swing the sword a few times while it runs; every event is
-- timestamped, so no timing to hit and no phases to follow.
--
-- Pooled components REACTIVATE rather than appear (documentation.md, the projectile lesson:
-- "existence is not activity"), so appearance alone would miss a pooled slash -- activation
-- transitions are logged too, and are labelled differently so the mirror knows which lifetime
-- model it is copying.
--
-- Safe shape, per PROBES.md's dustlight post-mortem and preflight's rules: NAMED property reads
-- only, no UFunction calls on FindAllOf results (GetFullName via the UE4SS wrapper inside pcall,
-- the probe_lightcheck pattern), no ForEachProperty, two watched classes at 5Hz. It reports its
-- own coverage every 10s so "no events" is distinguishable from "not looking".
--
-- Grounded APIs: UNiagaraComponent::Asset, UParticleSystemComponent::Template,
-- USceneComponent::{RelativeLocation, AttachParent}, UActorComponent::bIsActive
-- (docs.unrealengine.com); UE4SS Lua FindAllOf/ExecuteInGameThread/LoopAsync (vendored
-- RE-UE4SS/docs/lua-api).
--
-- Deploy: copy probe_slashvfx/ to <install>\...\Win64\ue4ss\Mods\MeshGhostSlashVfx\ and create
-- an enabled.txt to arm it; remove it once the question is answered. Reload via
-- probe_reloader ("MeshGhostSlashVfx <nonce>").

local TAG = "[MeshGhostSlashVfx]"

local INTERVAL_MS = 200 -- 2 classes x 5Hz; FindAllOf walks object space per call, keep this low

local WATCH = {
    {class = "NiagaraComponent", asset_prop = "Asset"},
    {class = "ParticleSystemComponent", asset_prop = "Template"},
}

local seen = {}       -- full name -> true, so a component logs its appearance once
local last_active = {} -- full name -> last bIsActive read, for activation transitions
local samples = 0

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

local function vec_text(v)
    if not v then return "?" end
    local x, y, z
    pcall(function() x, y, z = v.X, v.Y, v.Z end)
    if x == nil then return "?" end
    return string.format("%.0f,%.0f,%.0f", x, y, z)
end

-- The player's own position is the reference frame every event is reported against; the pawn's
-- RootComponent RelativeLocation IS its world location (it is attached to nothing).
local function player_pos_text()
    local pawns = FindAllOf("BP_PlayerGoatMain_C")
    if not pawns then return "?" end
    for _, pawn in pairs(pawns) do
        local root = prop(pawn, "RootComponent")
        if root then
            local loc = prop(root, "RelativeLocation")
            if loc then return vec_text(loc) end
        end
    end
    return "?"
end

local function describe(obj, asset_prop, kind)
    local name = full_name(obj) or "<unnamed>"
    local asset = prop(obj, asset_prop)
    local asset_name = asset and (full_name(asset) or "<asset unnamed>") or "<no asset>"
    local parent = prop(obj, "AttachParent")
    local parent_name = parent and (full_name(parent) or "<parent unnamed>") or "<none>"
    local rel = vec_text(prop(obj, "RelativeLocation"))
    print(string.format("%s %s comp='%s' asset='%s' attach='%s' rel=%s player=%s t=%.1f\n",
                        TAG, kind, name, asset_name, parent_name, rel, player_pos_text(),
                        os.clock()))
end

local function sample()
    samples = samples + 1
    local counts = {}
    for _, entry in ipairs(WATCH) do
        local found = FindAllOf(entry.class)
        local n = 0
        if found then
            for _, obj in pairs(found) do
                n = n + 1
                local name = full_name(obj)
                if name then
                    if not seen[name] then
                        seen[name] = true
                        -- Baseline components (the first sample sees the whole level) are logged
                        -- as BASELINE, not APPEAR, so the level's standing population cannot be
                        -- mistaken for something a swing produced.
                        describe(obj, entry.asset_prop, samples == 1 and "BASELINE" or "APPEAR")
                    end
                    local active = prop(obj, "bIsActive")
                    if active ~= nil then
                        local was = last_active[name]
                        if was ~= nil and was ~= active and active == true then
                            describe(obj, entry.asset_prop, "ACTIVATE")
                        end
                        last_active[name] = active
                    end
                end
            end
        end
        counts[#counts + 1] = string.format("%s=%d", entry.class, n)
    end
    -- Coverage line every ~10s: an instrument reports what it is watching, so a quiet log reads
    -- as "nothing appeared", never as "nothing was looked at".
    if samples % 50 == 1 then
        print(string.format("%s WATCHING %s samples=%d\n", TAG, table.concat(counts, " "), samples))
    end
end

LoopAsync(INTERVAL_MS, function()
    ExecuteInGameThread(sample)
    return false
end)

print(string.format("%s loaded -- swing the sword a few times; every Niagara/Cascade appearance or activation is logged with asset, attach and offsets.\n", TAG))
