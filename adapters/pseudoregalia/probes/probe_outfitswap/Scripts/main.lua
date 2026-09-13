-- MeshGhost OUTFIT-SWAP ANIM PROBE (2026-09-13). DRIVES the local player's own mesh -- not
-- read-only. Unload it before judging anything on screen.
--
-- THE QUESTION. A peer who takes damage and swaps costume during the hurt/blink leaves the
-- watcher's ghost with a glitched model, and it PERSISTS until a save reset (user, 2026-09-13).
-- The watcher's UE4SS.log calls that same swap `outfit mesh applied` with a readback matching the
-- target, and carries zero `WARNING: SetSkeletalMeshAsset` lines -- so the mesh reference lands
-- and the setter fires. Two ways that still ends in a broken model, both inside Plugin.cpp's
-- outfit ghost-write block:
--
--   A. the setter runs but its anim RE-BIND does not take while a montage is playing, and the two
--      raw `SkeletalMesh`/`SkinnedAsset` writes kept after it as a safety net leave exactly the
--      mesh-without-a-binding that `call_set_skeletal_mesh_asset` was written to prevent; or
--   B. the setter REPLACES the anim instance, and the pawn's `animBPref` -- a Blueprint variable
--      the engine does not update -- is left pointing at the dead one, so every later montage
--      write from the adapter goes nowhere.
--
-- Both survive a readback (it reads the property that was written, never the render state), both
-- persist (`last_synced_outfit_mesh` now equals the target, so nothing retries), and both clear on
-- a save reset (a fresh ghost sets its mesh at construction, before it has any montage). The
-- adapter's own T-pose record (VERIFIED.md, 2026-08-15) confirmed the setter on an IDLE swap only,
-- which is the case that works -- the montage was never in the picture.
--
-- WHY THE LOCAL PLAYER AND NOT A GHOST. The ghost is a clone of `BP_PlayerGoatMain_C`, the class
-- the player's own pawn is (every `spawned ghost` line in UE4SS.log names it). Whether this
-- build's `SetSkeletalMeshAsset` replaces an anim instance is a fact about that class and this
-- engine, not about who owns the actor -- so it is answerable on one client with no relay, no
-- peer, and no second install. If it reproduces here it is the bug; if it does NOT, the theory is
-- wrong and the subsystem widens rather than the measurement deepening.
--
-- WHAT IT DOES TO YOUR GAME. It swaps your own character's mesh four times and plays the flinch
-- montage on you, then puts the original mesh back and says whether the restore took. No damage is
-- dealt, no save is touched, nothing is written to disk but this probe's own log.
--
-- ENDURANCE, NOT TIMING. Fixed phases on a countdown; there is no window to hit. Stand anywhere
-- with control of your character and leave it alone for 40 s.
--
-- Named reads and native getters only. No reflection walk -- that crashed this adapter four times
-- (pitfalls.md). Every engine touch is pcall'd, and every ExecuteInGameThread body is pcall'd
-- separately because an error inside one escapes the caller's pcall (probe_ghost/main.lua:589).
--
-- Dev-only tooling; never ships.

local TAG = "[MeshGhostOutfitSwap]"

local SAMPLE_MS      = 50     -- sampling cadence inside a window
local WINDOW_MS      = 1500   -- how long to sample after an event
local BASELINE_S     = 8      -- idle observation before anything is driven
local FLINCH_LEAD_MS = 200    -- how far into the montage the swap lands
local FLUSH_MS       = 1000

local MONTAGE_NEEDLE = "Flinch"            -- the damage montage; matched, not assumed, see pick_montage
local MESH_PREFIX    = "/Game/Meshes/Characters/"

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*[\\/])") or "./"
end
local OUT_PATH = scriptDir() .. "../outfitswap-" .. os.date("%H%M%S") .. ".log"
local out = io.open(OUT_PATH, "a")
local buffered = 0
local function log(line) print(TAG .. " " .. line .. "\n") end
local function fout(line)
    if out then out:write(line, "\n") buffered = buffered + 1 end
end
local function flush() if out and buffered > 0 then out:flush() buffered = 0 end end

local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end
local function prop(obj, name)
    local v
    if not obj or not pcall(function() v = obj[name] end) then return nil end
    return v
end
local function addr_of(x)
    local a
    pcall(function() a = x:GetAddress() end)
    return a
end
local function addr_str(x)
    if x == nil or not valid(x) then return "none" end
    local a = addr_of(x)
    return a and string.format("0x%x", a) or "?"
end
local function fname_str(x)
    local s
    pcall(function() s = x:GetFName():ToString() end)
    return s or "?"
end
local function full_str(x)
    local s
    pcall(function() s = x:GetFullName() end)
    return s or "?"
end
local function class_str(x)
    if x == nil or not valid(x) then return "none" end
    local c
    pcall(function() c = x:GetClass() end)
    return (c ~= nil and valid(c)) and fname_str(c) or "?"
end

-- ---------------------------------------------------------------------------------------------
-- The sample. Every field this probe decides from, recorded every time -- a probe that returns a
-- verdict cannot be sanity-checked, so nothing here is reduced to a boolean that isn't printed
-- next to the two addresses it came from.
local function sample(pawn, label, t_ms)
    if pawn == nil or not valid(pawn) then
        fout(string.format("%-22s t=%-5d PAWN GONE", label, t_ms))
        return nil
    end
    local vm    = prop(pawn, "VisualMesh")
    local skel  = (vm ~= nil and valid(vm)) and prop(vm, "SkeletalMesh") or nil
    local skin  = (vm ~= nil and valid(vm)) and prop(vm, "SkinnedAsset") or nil
    local anim  = (vm ~= nil and valid(vm)) and prop(vm, "AnimScriptInstance") or nil
    local abp   = prop(pawn, "animBPref")

    local anim_a, abp_a = addr_of(anim), addr_of(abp)
    local bound = "?"
    if anim_a and abp_a then bound = (anim_a == abp_a) and "SAME" or "**DIVERGED**"
    elseif anim == nil or not valid(anim) then bound = "anim=NONE" end

    local playing, montage = "?", "none"
    if anim ~= nil and valid(anim) then
        pcall(function() playing = tostring(anim:IsAnyMontagePlaying()) end)
        pcall(function()
            local m = anim:GetCurrentActiveMontage()
            if m ~= nil and valid(m) then montage = fname_str(m) end
        end)
    end

    fout(string.format(
        "%-22s t=%-5d vm=%s skel=%s(%s) skinned=%s(%s) anim=%s(%s) animBPref=%s(%s) bind=%s montage_playing=%s montage=%s",
        label, t_ms, addr_str(vm),
        addr_str(skel), (skel ~= nil and valid(skel)) and fname_str(skel) or "-",
        addr_str(skin), (skin ~= nil and valid(skin)) and fname_str(skin) or "-",
        addr_str(anim), class_str(anim),
        addr_str(abp),  class_str(abp),
        bound, playing, montage))
    return { anim = anim_a, abp = abp_a, bound = bound, skel = addr_of(skel) }
end

-- ---------------------------------------------------------------------------------------------
-- Candidates. Dumped in FULL before anything picks from them -- a list filtered before you look is
-- a guess about the answer, and a wrong guess still produces a complete-looking result.
local function loaded_of_class(class_name)
    local found = {}
    pcall(function()
        local objs = FindAllOf(class_name)
        if objs == nil then return end
        for _, o in ipairs(objs) do
            if o ~= nil and valid(o) then found[#found + 1] = o end
        end
    end)
    return found
end

local function pick_mesh(current_addr)
    local all = loaded_of_class("SkeletalMesh")
    fout(string.format("-- loaded SkeletalMesh objects: %d", #all))
    local candidates = {}
    for _, m in ipairs(all) do
        local fn = full_str(m)
        fout("   " .. fn)
        if fn:find(MESH_PREFIX, 1, true) and addr_of(m) ~= current_addr then
            candidates[#candidates + 1] = m
        end
    end
    fout(string.format("-- under %s and not the one worn: %d", MESH_PREFIX, #candidates))
    return candidates[1], #all, #candidates
end

local function pick_montage()
    local all = loaded_of_class("AnimMontage")
    fout(string.format("-- loaded AnimMontage objects: %d", #all))
    local hit = nil
    for _, m in ipairs(all) do
        local fn = full_str(m)
        fout("   " .. fn)
        if hit == nil and fn:find(MONTAGE_NEEDLE, 1, true) then hit = m end
    end
    return hit, #all
end

-- ---------------------------------------------------------------------------------------------
-- The swap, done EXACTLY as Plugin.cpp's outfit ghost-write block does it: the real setter first,
-- then the two raw property writes kept after it as a safety net. Reproducing the adapter's own
-- order is the point -- a different order would measure a different bug.
-- The outcome is written by the CALLBACK, not by the caller. ExecuteInGameThread is deferred, so
-- reading the flags on the line after the call would report the initial values every time -- a
-- result that looks like a measurement and is only a default.
local function do_swap(pawn, mesh, note)
    local want = (mesh ~= nil and valid(mesh)) and fname_str(mesh) or "?"
    fout(string.format("== SWAP (%s) -> %s requested", note, want))
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local vm = prop(pawn, "VisualMesh")
            if vm == nil or not valid(vm) then
                fout("   swap SKIPPED: no VisualMesh")
                return
            end
            local setter_ok, setter_err = pcall(function() vm:SetSkeletalMeshAsset(mesh) end)
            local raw_ok, raw_err = pcall(function()
                vm.SkeletalMesh = mesh
                vm.SkinnedAsset = mesh
            end)
            fout(string.format("   setter_call_ok=%s%s raw_write_ok=%s%s",
                tostring(setter_ok), setter_ok and "" or (" (" .. tostring(setter_err) .. ")"),
                tostring(raw_ok), raw_ok and "" or (" (" .. tostring(raw_err) .. ")")))
            log(string.format("SWAP (%s) -> %s : setter=%s raw=%s",
                note, want, tostring(setter_ok), tostring(raw_ok)))
        end)
        if not ok then
            fout("   swap body FAILED: " .. tostring(err))
            log("swap body FAILED: " .. tostring(err))
        end
    end)
end

local function do_montage(pawn, montage)
    local want = fname_str(montage)
    fout("== MONTAGE " .. want .. " requested")
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local abp = prop(pawn, "animBPref")
            if abp == nil or not valid(abp) then
                fout("   montage SKIPPED: no animBPref")
                return
            end
            -- Montage_Play returns the length it started, or 0 when it refused -- the return is
            -- the signal, so it is recorded rather than discarded.
            local okp, len = pcall(function() return abp:Montage_Play(montage, 1.0) end)
            fout("   Montage_Play returned " .. (okp and tostring(len) or ("CALL FAILED: " .. tostring(len))))
            log("MONTAGE " .. want .. " -> " .. (okp and tostring(len) or "call failed"))
        end)
        if not ok then
            fout("   montage body FAILED: " .. tostring(err))
            log("montage body FAILED: " .. tostring(err))
        end
    end)
end

-- ---------------------------------------------------------------------------------------------
local function find_pawn()
    local pc = nil
    pcall(function() pc = FindFirstOf("PlayerController") end)
    if pc == nil or not valid(pc) then return nil end
    local pawn = prop(pc, "Pawn")
    if pawn ~= nil and valid(pawn) then return pawn end
    return nil
end

local started      = false
local elapsed_ms   = 0
local phase        = "countdown"
local phase_t      = 0
local window_until = -1
local next_sample  = 0
local label        = "baseline"
local pawn, orig_mesh, alt_mesh, flinch = nil, nil, nil, nil
local first_bound, diverged_at = nil, nil

local function report()
    fout("")
    fout("=== VERDICT =================================================================")
    fout("bind at rest (before anything was driven): " .. tostring(first_bound))
    if diverged_at then
        fout("animBPref DIVERGED from VisualMesh.AnimScriptInstance at: " .. diverged_at)
        fout("-> theory B: the setter replaces the anim instance and animBPref is left stale.")
    else
        fout("animBPref never diverged from AnimScriptInstance in any window sampled.")
        fout("-> theory B NOT reproduced here. If the model still glitches on screen, the")
        fout("   binding is not the mechanism -- widen the subsystem, do not deepen this probe.")
    end
    fout("WHAT THIS PROBE COULD NOT SEE: whether the model looks right. It reads the mesh and")
    fout("the anim instance, never the render state -- the same blind spot that makes the")
    fout("adapter's own readback log 'applied' for a model that is visibly broken. The screen")
    fout("is the user's to judge.")
    fout("=============================================================================")
    flush()
    log("DONE -- full log at " .. OUT_PATH)
    log("Restore the scratch stub before judging anything on screen.")
end

log("loaded. 40 s, fixed phases, nothing for you to hit -- just keep control of your character.")
log("full log: " .. OUT_PATH)

LoopAsync(SAMPLE_MS, function()
    elapsed_ms = elapsed_ms + SAMPLE_MS
    if phase == "done" then return false end

    local ok, err = pcall(function()
        if not started then
            pawn = find_pawn()
            if pawn == nil then
                if elapsed_ms % 2000 == 0 then log("waiting for a player pawn...") end
                return
            end
            started = true
            phase_t = elapsed_ms
            fout("=== MeshGhost outfit-swap anim probe, " .. os.date("%Y-%m-%d %H:%M:%S"))
            fout("pawn class: " .. class_str(pawn) .. " at " .. addr_str(pawn))

            local vm = prop(pawn, "VisualMesh")
            fout("VisualMesh: " .. addr_str(vm) .. " (" .. class_str(vm) .. ")")
            orig_mesh = (vm ~= nil and valid(vm)) and prop(vm, "SkeletalMesh") or nil
            fout("mesh worn at start: " .. ((orig_mesh ~= nil and valid(orig_mesh)) and full_str(orig_mesh) or "NONE"))

            -- Coverage: say what is reachable before deciding anything from it.
            local has_setter = false
            pcall(function() has_setter = (vm.SetSkeletalMeshAsset ~= nil) end)
            fout("SetSkeletalMeshAsset reachable on VisualMesh: " .. tostring(has_setter))

            local n_all, n_cand
            alt_mesh, n_all, n_cand = pick_mesh(addr_of(orig_mesh))
            flinch, _ = pick_montage()
            fout("chosen alternate mesh: " .. ((alt_mesh ~= nil) and full_str(alt_mesh) or "NONE FOUND"))
            fout("chosen montage: " .. ((flinch ~= nil) and full_str(flinch) or "NONE FOUND"))
            if alt_mesh == nil then
                fout("ABORT: no second costume is LOADED, so no swap can be driven. Wear a")
                fout("different costume once this session so its mesh loads, then re-run.")
                log("ABORT: no second loaded costume to swap to -- see the log.")
                phase = "done" report() return
            end
            log(string.format("armed. %d SkeletalMesh loaded, %d usable; flinch montage %s",
                n_all, n_cand, flinch ~= nil and "found" or "NOT FOUND"))
            label = "baseline" window_until = elapsed_ms + BASELINE_S * 1000
            return
        end

        -- sampling
        if elapsed_ms <= window_until and elapsed_ms >= next_sample then
            local s = sample(pawn, label, elapsed_ms - phase_t)
            next_sample = elapsed_ms + SAMPLE_MS
            if s then
                if first_bound == nil then first_bound = s.bound end
                if s.bound == "**DIVERGED**" and diverged_at == nil then
                    diverged_at = label .. " t=" .. (elapsed_ms - phase_t) .. "ms"
                    log("DIVERGED during " .. label .. " -- animBPref no longer is the anim instance.")
                end
            end
        end

        -- phase machine, countdown announced every second
        if elapsed_ms % 1000 == 0 and elapsed_ms <= window_until then
            log(string.format("%s ... %d s left", label, math.ceil((window_until - elapsed_ms) / 1000)))
        end
        if elapsed_ms <= window_until then return end

        if label == "baseline" then
            phase_t = elapsed_ms
            do_swap(pawn, alt_mesh, "IDLE -- no montage playing")
            label = "after-idle-swap" window_until = elapsed_ms + WINDOW_MS

        elseif label == "after-idle-swap" then
            phase_t = elapsed_ms
            do_swap(pawn, orig_mesh, "restore after the idle swap")
            label = "after-idle-restore" window_until = elapsed_ms + WINDOW_MS

        elseif label == "after-idle-restore" then
            if flinch == nil then
                fout("== the flinch montage is NOT loaded -- the mid-montage case cannot be driven.")
                log("flinch montage not loaded; skipping the damage case.")
                label = "wrapup" window_until = elapsed_ms
            else
                phase_t = elapsed_ms
                do_montage(pawn, flinch)
                label = "montage-running" window_until = elapsed_ms + FLINCH_LEAD_MS
            end

        elseif label == "montage-running" then
            phase_t = elapsed_ms
            do_swap(pawn, alt_mesh, "MID-MONTAGE -- the user's repro")
            label = "after-montage-swap" window_until = elapsed_ms + WINDOW_MS * 2

        elseif label == "after-montage-swap" then
            phase_t = elapsed_ms
            do_swap(pawn, orig_mesh, "restore after the mid-montage swap")
            label = "after-montage-restore" window_until = elapsed_ms + WINDOW_MS

        else
            -- Prove the restore took, through a fresh read, not the value we wrote.
            local vm = prop(pawn, "VisualMesh")
            local now = (vm ~= nil and valid(vm)) and prop(vm, "SkeletalMesh") or nil
            fout("")
            fout("restore readback: worn now = " .. ((now ~= nil and valid(now)) and full_str(now) or "NONE")
                 .. " ; started as " .. ((orig_mesh ~= nil and valid(orig_mesh)) and full_str(orig_mesh) or "NONE"))
            if addr_of(now) ~= addr_of(orig_mesh) then
                fout("RESTORE DID NOT TAKE -- your character is wearing the probe's mesh. A save")
                fout("reset puts it back; nothing was written to your save.")
                log("WARNING: the restore did not take -- see the log.")
            end
            report()
            phase = "done"
        end
    end)
    if not ok then
        log("probe error: " .. tostring(err))
        fout("PROBE ERROR: " .. tostring(err))
        flush()
        phase = "done"
    end
    return false
end)

LoopAsync(FLUSH_MS, function() flush() return false end)
