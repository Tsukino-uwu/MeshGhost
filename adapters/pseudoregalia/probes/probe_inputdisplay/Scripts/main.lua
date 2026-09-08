-- MeshGhost INPUT DISPLAY prototype -- the player's inputs as a scrolling HISTORY on screen, judged
-- live before it is built into the C++ mod. 2026-09-08, the user's design: a fighting-game-style
-- list (each row is the input state and how many frames it lasted), the player's own on the LEFT,
-- a ghost's fed by its recording's input track on the RIGHT (that half needs the core and comes
-- after), each with an on/off in the client config, and the player's showable with no recording
-- running. This prototype is the player half's LOOK; the C++ reads the same edges it already
-- sends the core (ADR 0056) and needs no second read.
--
-- WHAT IT READS, every poll (the input census's proven path, 2026-09-08): `IsInputKeyDown` per key
-- that `IMC_Default` (the live bindings; `IMC_Reference` is the factory copy) maps to each action,
-- OR'd into the action; the move direction from W/A/S/D and the left stick's vector state. A row
-- starts when the held set changes and grows by one poll while it does not; ~60 polls a second,
-- so "frames" here are polls -- the C++ counts real engine frames from its own edge queue.
--
-- WHAT IT DRAWS: one UserWidget, a Border root (dark, translucent) holding one TextBlock whose
-- text is the rows joined by newlines, newest at the TOP. Row: frames, direction arrows, then the
-- held buttons as short tokens: J jump, A attack, C crouch, W cling (wall ride), T throw, G guard,
-- I interact, L lock-on, P power, M map, V view (perspective). Placed from the top-left with
-- positive offsets (the indicator's lesson: anchored placement goes off-screen on this build).
--
-- LIVE TUNING: `input_display.txt` beside this mod's Scripts folder, re-read every 500 ms:
--     x=200 y=300     top-left of the panel, pixels at 1920x1080
--     text=22         font size
--     rows=10         rows shown
--     pad=6           panel padding
--     bg=#000000      panel colour, alpha=0.55 its opacity (0..1), bg_on=1 (0 = no panel)
--     ink=#FFFFFF     text colour
--     show=1
-- Missing keys keep the defaults.
--
-- COST: ~25 IsInputKeyDown calls plus one vector read per poll (33 ms), one SetText per row change.
-- A SESSION WITH THIS LOADED CRASHED ONCE (2026-09-08 14:41, "Abort signal received", 63 s after a
-- reload; the tune callback below was unguarded then). Unattributed; see UNVERIFIED.md.
-- Read-only in the game; constructs UI objects and removes its own on reload. Dev-only; never ships.

local TAG = "[MeshGhostInputDisplay]"
local POLL_MS = 33 -- was 16; halved after the 14:41 abort, and the controller is cached below
local TUNE_MS = 500
local NAME_PANEL = "MeshGhostInputPanel"

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*[\\/])") or "./"
end
local MOD_ROOT = scriptDir() .. "../"
local TUNING_PATH = MOD_ROOT .. "input_display.txt"

local function log(line) print(TAG .. " " .. line .. "\n") end
local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end
local function full_name(obj)
    local n
    pcall(function() n = obj:GetFullName() end)
    return n or "?"
end

---------------------------------------------------------------------------- tuning

local tuning = { x = 200, y = 300, text = 22, rows = 10, pad = 6, bg = "#000000", alpha = 0.55, bg_on = 1, ink = "#FFFFFF", show = 1 }
local tuning_sig = ""
local function read_tuning()
    local f = io.open(TUNING_PATH, "r")
    if not f then return false end
    local text = f:read("*a") or ""
    f:close()
    if text == tuning_sig then return false end
    tuning_sig = text
    for line in text:gmatch("[^\r\n]+") do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and v and v ~= "" then
            if k == "bg" or k == "ink" then tuning[k] = v else
                local n = tonumber(v)
                if n then tuning[k] = n end
            end
        end
    end
    return true
end
local function color_of(hex, alpha)
    local r, g, b = hex:match("^#?(%x%x)(%x%x)(%x%x)$")
    if not r then return { R = 1.0, G = 1.0, B = 1.0, A = alpha or 1.0 } end
    local function lin(c)
        local x = tonumber(c, 16) / 255.0
        if x <= 0.04045 then return x / 12.92 end
        return ((x + 0.055) / 1.055) ^ 2.4
    end
    return { R = lin(r), G = lin(g), B = lin(b), A = alpha or 1.0 }
end

---------------------------------------------------------------------------- the key table

-- action name -> token, in row order
local ACTIONS = {
    { ia = "IA_Jump", tok = "J" }, { ia = "IA_Attack", tok = "A" }, { ia = "IA_Crouch", tok = "C" },
    { ia = "IA_WallRide", tok = "W" }, { ia = "IA_Throw", tok = "T" }, { ia = "IA_Guard", tok = "G" },
    { ia = "IA_Interact", tok = "I" }, { ia = "IA_LockOn", tok = "L" }, { ia = "IA_Power", tok = "P" },
    { ia = "IA_QuickMap", tok = "M" }, { ia = "IA_PerspectiveToggle", tok = "V" },
}
local keys = {}      -- { name = "SpaceBar", bits = {J=true,...} }
local move_keys = {} -- keys mapped to IA_Move (W/A/S/D and the stick)
local table_built = false

local function build_key_table()
    local ctxs = FindAllOf("InputMappingContext")
    if not ctxs then return false end
    local found = 0
    for _, c in pairs(ctxs) do
        if valid(c) and full_name(c):find("IMC_Default", 1, true) then
            local maps = c.Mappings
            local n = 0
            pcall(function() n = maps:GetArrayNum() end)
            for i = 1, n do
                local m
                if pcall(function() m = maps[i] end) and m then
                    local action, key = nil, nil
                    pcall(function() local a = m.Action; if a and valid(a) then action = a:GetFName():ToString() end end)
                    pcall(function() key = m.Key.KeyName:ToString() end)
                    if action and key then
                        found = found + 1
                        if action == "IA_Move" then
                            move_keys[#move_keys + 1] = key
                        else
                            local tok
                            for _, a in ipairs(ACTIONS) do if a.ia == action then tok = a.tok end end
                            if tok then
                                local entry
                                for _, k in ipairs(keys) do if k.name == key then entry = k end end
                                if not entry then entry = { name = key, toks = {} }; keys[#keys + 1] = entry end
                                entry.toks[tok] = true
                            end
                        end
                    end
                end
            end
        end
    end
    if found == 0 then return false end
    log(string.format("key table from IMC_Default: %d keys for buttons, %d move keys", #keys, #move_keys))
    return true
end

---------------------------------------------------------------------------- the widget

local panel, panel_text = nil, nil
local shown = false
local failed = {}
local function try(name, fn)
    local ok, err = pcall(fn)
    if not ok and not failed[name] then
        failed[name] = tostring(err)
        log("CALL FAILED " .. name .. ": " .. tostring(err))
    end
    return ok
end
local function construct(class_path, outer, name)
    local cls = StaticFindObject(class_path)
    if not cls or not valid(cls) then log("class not found: " .. class_path); return nil end
    local obj
    local ok, err = pcall(function() obj = StaticConstructObject(cls, outer, FName(name)) end)
    if not ok or not obj or not valid(obj) then log("construct failed " .. name .. ": " .. tostring(err)); return nil end
    return obj
end
local function remove_leftovers()
    local all = FindAllOf("UserWidget")
    if not all then return end
    for _, w in pairs(all) do
        -- ours, and the indicator prototype's leftovers (its control text outlived it)
        local n = full_name(w)
        if valid(w) and (n:find(NAME_PANEL, 1, true) or n:find("MeshGhostHud", 1, true)) then
            try("RemoveFromParent(leftover)", function() w:RemoveFromParent() end)
        end
    end
end
local function build()
    local gi = FindFirstOf("MV_GameInstance_C")
    if not gi or not valid(gi) then return false end
    panel = construct("/Script/UMG.UserWidget", gi, NAME_PANEL)
    if not panel then return false end
    local tree = construct("/Script/UMG.WidgetTree", panel, NAME_PANEL .. "_Tree")
    local border = tree and construct("/Script/UMG.Border", tree, NAME_PANEL .. "_Border")
    panel_text = tree and construct("/Script/UMG.TextBlock", tree, NAME_PANEL .. "_Text")
    if not tree or not border or not panel_text then return false end
    panel.WidgetTree = tree
    tree.RootWidget = border
    try("Border:SetContent", function() border:SetContent(panel_text) end)
    try("TextBlock.Font.Size", function() panel_text.Font.Size = tuning.text end)
    try("TextBlock:SetText", function() panel_text:SetText(FText("")) end)
    log("built " .. full_name(panel))
    return true
end
local function apply()
    if not panel or not valid(panel) then return end
    local t = tuning
    local border = panel.WidgetTree.RootWidget
    -- bg_on=0 draws no panel at all (alpha 0), the user's toggle; in the client config it is
    -- input_display.background, on by default
    try("Border:SetBrushColor", function() border:SetBrushColor(color_of(t.bg, (t.bg_on ~= 0) and t.alpha or 0.0)) end)
    try("Border:SetPadding", function() border:SetPadding({ Left = t.pad, Top = t.pad, Right = t.pad, Bottom = t.pad }) end)
    try("TextBlock:SetColorAndOpacity", function() panel_text:SetColorAndOpacity({ SpecifiedColor = color_of(t.ink, 1.0), ColorUseRule = 0 }) end)
    try("UserWidget:SetPositionInViewport", function() panel:SetPositionInViewport({ X = t.x, Y = t.y }, true) end)
    if t.show ~= 0 and not shown then
        try("UserWidget:AddToViewport", function() panel:AddToViewport(1000) end)
        shown = true
    elseif t.show == 0 and shown then
        try("UserWidget:RemoveFromParent", function() panel:RemoveFromParent() end)
        shown = false
    end
    local n = 0
    for _ in pairs(failed) do n = n + 1 end
    log(string.format("applied x=%g y=%g text=%g rows=%g pad=%g bg=%s alpha=%g ink=%s show=%g | %d call(s) failing",
        t.x, t.y, t.text, t.rows, t.pad, t.bg, t.alpha, t.ink, t.show, n))
end

---------------------------------------------------------------------------- the history

local rows = {}          -- newest first: { text = "↑ J A", frames = n }
local current = nil      -- the row being extended
local last_render = ""

local function direction_text(pc)
    local up, down, left, right = false, false, false, false
    local sx, sy = 0.0, 0.0
    for _, k in ipairs(move_keys) do
        if k == "W" or k == "A" or k == "S" or k == "D" then
            local d = false
            pcall(function() d = pc:IsInputKeyDown({ KeyName = FName(k) }) == true end)
            if k == "W" then up = up or d elseif k == "S" then down = down or d elseif k == "A" then left = left or d elseif k == "D" then right = right or d end
        else
            pcall(function()
                local v = pc:GetInputVectorKeyState({ KeyName = FName(k) })
                if v and v.X then sx, sy = sx + v.X, sy + v.Y end
            end)
        end
    end
    if sx > 0.35 then right = true elseif sx < -0.35 then left = true end
    if sy > 0.35 then up = true elseif sy < -0.35 then down = true end
    local s = ""
    if up then s = s .. "\226\134\145" end      -- ↑
    if down then s = s .. "\226\134\147" end    -- ↓
    if left then s = s .. "\226\134\144" end    -- ←
    if right then s = s .. "\226\134\146" end   -- →
    return s
end

local cached_pc = nil
local function sample()
    if not cached_pc or not valid(cached_pc) then cached_pc = FindFirstOf("MainPlayerController_C") end
    local pc = cached_pc
    if not pc or not valid(pc) then return end
    local held = {}
    for _, k in ipairs(keys) do
        local d = false
        pcall(function() d = pc:IsInputKeyDown({ KeyName = FName(k.name) }) == true end)
        if d then for tok in pairs(k.toks) do held[tok] = true end end
    end
    local parts = {}
    for _, a in ipairs(ACTIONS) do if held[a.tok] then parts[#parts + 1] = a.tok end end
    local dir = direction_text(pc)
    local state = dir .. " " .. table.concat(parts, " ")
    if current and current.state == state then
        current.frames = current.frames + 1
    else
        current = { state = state, frames = 1 }
        table.insert(rows, 1, current)
        while #rows > tuning.rows do table.remove(rows) end
    end
    -- render, on change only
    local lines = {}
    for _, r in ipairs(rows) do
        lines[#lines + 1] = string.format("%4d  %s", r.frames, r.state)
    end
    local text = table.concat(lines, "\n")
    if text ~= last_render and panel_text and valid(panel_text) then
        last_render = text
        try("TextBlock:SetText(rows)", function() panel_text:SetText(FText(text)) end)
    end
end

local built = false
LoopAsync(POLL_MS, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            if not table_built then
                table_built = build_key_table()
                if not table_built then return end
                remove_leftovers()
            end
            if built and (not panel or not valid(panel) or not panel_text or not valid(panel_text)) then
                log("panel lost (transition or collection) -- rebuilding")
                built, shown, panel, panel_text, last_render = false, false, nil, nil, ""
            end
            if not built then
                built = build()
                if built then read_tuning(); apply() end
                return
            end
            sample()
        end)
        if not ok then log("tick error: " .. tostring(err)) end
    end)
    return false
end)
LoopAsync(TUNE_MS, function()
    ExecuteInGameThread(function()
        -- EVERYTHING on the game thread inside a pcall. The first version left this callback bare,
        -- and the session it ran in ended in "Abort signal received" 63 s after the reload
        -- (2026-09-08 14:41) -- the 2026-09-06 signature of a Lua error raised inside a callback
        -- the engine cannot unwind. Not attributed to this line (nothing logged an error, and the
        -- Archipelago mod was live too), but it is the one unguarded path this probe had.
        local ok, err = pcall(function()
            if built and read_tuning() then
                if tuning.text ~= (tuning._built_text or tuning.text) then
                    try("UserWidget:RemoveFromParent(rebuild)", function() panel:RemoveFromParent() end)
                    built, shown, panel, panel_text, last_render = false, false, nil, nil, ""
                else
                    apply()
                end
            end
            tuning._built_text = tuning.text
        end)
        if not ok then log("tune error: " .. tostring(err)) end
    end)
    return false
end)

log("loaded -- the player's input history appears at the left once in gameplay; tune via " .. TUNING_PATH)
