-- MeshGhost pause-menu watch. Written 2026-08-31, in Lua rather than C++ on the user's point:
-- *"why do i have to restart the game so much, are we even using the lua things?"* -- fair. Every
-- question this session was answered by rebuilding the C++ mod (~4 minutes) and asking the user to
-- relaunch, twenty-odd times, when this adapter already ships Lua probes and UE4SS reloads them.
--
-- TWO jobs, both aimed at the open reset crash (`../../UNVERIFIED.md`):
--
--   1. NAME THE "MENU OPENED" EVENT. The C++ side hooked `Construct` and it armed but never fired,
--      because that runs once when the widget is CREATED -- the pause menu lives under the
--      GameInstance and is merely shown again. Rather than guess a second name, this prints the
--      widget's Visibility every time it CHANGES, so the transition that means "open" is measured.
--
--   2. RUN THE EXPERIMENT. When the menu looks open, destroy every ghost pawn -- seconds before any
--      Reset click, which is the point: the crash is a RACE (it does not reproduce while a heavy
--      trace slows the game down), and our C++ destroy currently lands in the same frame as the
--      reset. If separating them in time stops the crash, that is the answer; if it does not, that
--      is just as useful and cost nobody a rebuild.
--
-- A ghost is identified as a BP_PlayerGoatMain_C with NO controller: MeshGhost spawns its clones
-- with AutoPossessPlayer disabled, so the real player is the only one that has one. That test is
-- read-only and needs no knowledge of MeshGhost's internals.
--
-- Nothing here writes save state. It destroys ghost actors, which the mod itself does routinely.

local POLL_MS = 200

local last_visibility = nil
local destroyed_for_this_open = false

local function log(msg)
    print("[MeshGhostMenuWatch] " .. msg .. "\n")
end

--- Returns the live pause-menu widget, or nil.
local function find_menu()
    local menus = FindAllOf("UI_PauseMenu_C")
    if not menus then
        return nil
    end
    for _, m in ipairs(menus) do
        if m:IsValid() then
            return m
        end
    end
    return nil
end

--- Every BP_PlayerGoatMain_C that has no controller, i.e. every ghost.
local function find_ghost_pawns()
    local out = {}
    local pawns = FindAllOf("BP_PlayerGoatMain_C")
    if not pawns then
        return out
    end
    for _, p in ipairs(pawns) do
        if p:IsValid() then
            local ok, controller = pcall(function() return p.Controller end)
            local has_controller = ok and controller and controller:IsValid()
            if not has_controller then
                table.insert(out, p)
            end
        end
    end
    return out
end

local function destroy_ghost_pawns(reason)
    local ghosts = find_ghost_pawns()
    if #ghosts == 0 then
        log("no ghost pawns to destroy (" .. reason .. ")")
        return
    end
    log("destroying " .. #ghosts .. " ghost pawn(s) -- " .. reason)
    for _, g in ipairs(ghosts) do
        local name = g:GetFullName()
        pcall(function() g:K2_DestroyActor() end)
        log("  destroyed " .. name)
    end
end

LoopAsync(POLL_MS, function()
    local menu = find_menu()
    if not menu then
        return false
    end

    -- ESlateVisibility, read straight off the widget. Printed on CHANGE only, so the log stays
    -- readable and the open/close transition is unambiguous rather than inferred.
    local ok, vis = pcall(function() return menu.Visibility end)
    if not ok then
        return false
    end
    local v = tonumber(vis) or -1

    if v ~= last_visibility then
        log("pause menu Visibility " .. tostring(last_visibility) .. " -> " .. tostring(v))
        last_visibility = v
    end

    -- 0 = Visible, 4 = SelfHitTestInvisible: both mean it is on screen. Collapsed/Hidden are 1/2.
    local open = (v == 0 or v == 4)
    if open and not destroyed_for_this_open then
        destroyed_for_this_open = true
        destroy_ghost_pawns("pause menu opened")
    elseif not open then
        destroyed_for_this_open = false
    end

    return false
end)

log("armed -- watching UI_PauseMenu_C visibility every " .. POLL_MS .. "ms")
