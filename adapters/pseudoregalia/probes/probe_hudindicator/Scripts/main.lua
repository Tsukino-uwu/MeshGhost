-- MeshGhost HUD INDICATOR prototype -- the recording indicator as a SCREEN-SPACE widget, judged
-- live before it is built into the C++ mod. 2026-09-08, the user's call: keep the current look
-- (red square, white clock box with black digits, top right) and fix where it is DRAWN.
--
-- THE TWO FAULTS THIS ANSWERS (`../../UNVERIFIED.md`, the indicator entry, both the user's own):
--   1. it hides behind world geometry -- the current indicator is two TextRenderComponents placed
--      in the camera's frame each tick, and a world-space thing takes part in depth testing;
--   2. it drifts off its corner during a move that changes speed or field of view -- fixed camera
--      offsets are only screen-fixed at the field of view they were tuned at.
-- A UMG widget added to the viewport is composited over the scene and laid out in screen space,
-- so both faults are gone by construction. That route is known to work in THIS game: a tester's
-- MIT mod draws its readout that way (`../../documentation.md`, "What a tester's MIT-licensed mod
-- showed") -- a UserWidget constructed at runtime from reflection, no widget asset needed.
--
-- WHAT IT BUILDS. Two UserWidgets, each with a Border as its root (a Border IS a coloured
-- rectangle): the SQUARE (red brush) and the CLOCK (white brush containing a black TextBlock).
-- Both are anchored to the top-right corner of the viewport (anchors 1,0 / alignment 1,0) and
-- offset from it in pixels, so a resolution change keeps them in the corner. The clock text is a
-- FAKE elapsed time (seconds since this probe loaded) -- the look is what is being judged, and
-- the real state lives in the C++ mod; the port reads `g_recording_time_text` instead.
--
-- NO API FROM MEMORY. Before a single call, the probe dumps EVERY function on UserWidget, Widget,
-- PanelWidget, ContentWidget, Border, TextBlock, CanvasPanel and WidgetTree to a file (the
-- 2026-08-30 "dump the function vocabulary" method), and every call it makes is by a name that
-- dump can be grepped for; a call that raises is reported once and skipped, never retried blind.
-- The dev.epicgames.com pages for these classes refused the fetch tool today, so the running game
-- is the reference, which is what `CLAUDE.md` prefers anyway ("availability is a runtime question").
--
-- LIVE TUNING, the indicator's own rule ("a bit more to the right is not worth a rebuild"):
-- `hud_indicator.txt` beside this mod's Scripts folder, key=value per line, re-read every 500 ms:
--     x=24 y=24         pixels in from the top-right corner (of the square's right/top edge)
--     size=18           the square's side, pixels
--     gap=8             pixels between the square and the clock box
--     text=16           the digits' font size
--     pad=4             the box's padding around the digits, pixels
--     z=100             viewport z-order (higher draws over the game's own HUD)
--     dot=#EE4B2B box=#FFFFFF ink=#000000     colours
--     show=1            0 hides both (RemoveFromParent), 1 shows
-- Missing keys keep the defaults above.
--
-- PROTOCOL FOR THE PERSON AT THE GAME. Load in gameplay. The pair appears top right at once.
-- Then, at your own pace: (a) put a wall or object between the camera and the corner -- it must
-- stay drawn; (b) do the moves that used to shift it (the ultra hop, the slide, a charged attack,
-- a cling) -- it must not move; (c) press the record hotkey so the OLD indicator draws too, and
-- say what differs. Every number above is one file edit away.
--
-- COST: one 500 ms file poll, one text update a second, nothing per frame. It writes no game
-- state; it constructs UI objects the engine owns and removes them on reload (a probe global
-- outlives the probe: the first thing this does is remove any widget of its own name left by a
-- previous load). Dev-only tooling; never ships.

local TAG = "[MeshGhostHudIndicator]"
local POLL_MS = 500
local NAME_DOT = "MeshGhostHudDot"
local NAME_CLOCK = "MeshGhostHudClock"

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*[\\/])") or "./"
end
local MOD_ROOT = scriptDir() .. "../"
local TUNING_PATH = MOD_ROOT .. "hud_indicator.txt"
local CENSUS_PATH = MOD_ROOT .. "hud_census-" .. os.date("%H%M%S") .. ".log"

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

local tuning = { x = 24, y = 24, size = 18, gap = 8, text = 16, pad = 4, z = 100,
                 dot = "#EE4B2B", box = "#FFFFFF", ink = "#000000", show = 1 }
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
            if k == "dot" or k == "box" or k == "ink" then
                tuning[k] = v
            else
                local n = tonumber(v)
                if n then tuning[k] = n end
            end
        end
    end
    return true
end

local function color_of(hex)
    local r, g, b = hex:match("^#?(%x%x)(%x%x)(%x%x)$")
    if not r then return { R = 1.0, G = 1.0, B = 1.0, A = 1.0 } end
    -- sRGB bytes to linear, the way a colour picker's hex reaches a LinearColor
    local function lin(c)
        local x = tonumber(c, 16) / 255.0
        if x <= 0.04045 then return x / 12.92 end
        return ((x + 0.055) / 1.055) ^ 2.4
    end
    return { R = lin(r), G = lin(g), B = lin(b), A = 1.0 }
end

---------------------------------------------------------------------------- census

local function census_class(path, out)
    local cls = StaticFindObject(path)
    if not cls or not valid(cls) then
        out[#out + 1] = "CLASS " .. path .. " NOT FOUND"
        return
    end
    local n = 0
    pcall(function()
        cls:ForEachFunction(function(fn)
            n = n + 1
            local params = {}
            pcall(function()
                fn:ForEachProperty(function(p)
                    local t = "?"
                    pcall(function() t = p:GetClass():GetFName():ToString() end)
                    local extra = ""
                    if t == "StructProperty" then pcall(function() extra = "<" .. p:GetStruct():GetFName():ToString() .. ">" end) end
                    params[#params + 1] = p:GetFName():ToString() .. ":" .. t .. extra
                    -- return NOTHING: UE4SS stops the walk on any returned value (2026-09-08)
                end)
            end)
            out[#out + 1] = string.format("FUNC %s.%s (%s)", path:match("([%w_]+)$"), fn:GetFName():ToString(), table.concat(params, ", "))
        end)
    end)
    out[#out + 1] = string.format("CLASS %s: %d functions", path, n)
end

local function run_census()
    local out = {}
    for _, p in ipairs({ "/Script/UMG.UserWidget", "/Script/UMG.Widget", "/Script/UMG.PanelWidget",
                         "/Script/UMG.ContentWidget", "/Script/UMG.Border", "/Script/UMG.TextBlock",
                         "/Script/UMG.CanvasPanel", "/Script/UMG.WidgetTree" }) do
        census_class(p, out)
    end
    local f = io.open(CENSUS_PATH, "w")
    if f then
        f:write(table.concat(out, "\n"), "\n")
        f:close()
    end
    local summary = {}
    for _, l in ipairs(out) do if l:sub(1, 5) == "CLASS" then summary[#summary + 1] = l end end
    log("census -> " .. CENSUS_PATH .. " :: " .. table.concat(summary, " | "))
end

---------------------------------------------------------------------------- the widgets

local dot, clock, clock_text = nil, nil, nil
local control_widget = nil
local shown = false
local failed = {}   -- call name -> first error, reported once
local t0 = os.clock()
local last_second = -1
local last_text = "0:00"
local placed_glyphs = 0
local measured_w, measured_h = nil, nil

local function try(name, fn)
    local ok, err = pcall(fn)
    if not ok and not failed[name] then
        failed[name] = tostring(err)
        log("CALL FAILED " .. name .. ": " .. tostring(err))
    end
    return ok
end

local function remove_leftovers()
    local all = FindAllOf("UserWidget")
    if not all then return end
    local removed = 0
    for _, w in pairs(all) do
        if valid(w) then
            local n = full_name(w)
            if n:find(NAME_DOT, 1, true) or n:find(NAME_CLOCK, 1, true) then
                if try("RemoveFromParent(leftover)", function() w:RemoveFromParent() end) then removed = removed + 1 end
            end
        end
    end
    if removed > 0 then log(string.format("removed %d leftover widget(s) from a previous load", removed)) end
end

local function construct(class_path, outer, name)
    local cls = StaticFindObject(class_path)
    if not cls or not valid(cls) then
        log("class not found: " .. class_path)
        return nil
    end
    local obj
    local ok, err = pcall(function() obj = StaticConstructObject(cls, outer, FName(name)) end)
    if not ok or not obj or not valid(obj) then
        log("construct failed " .. class_path .. " '" .. name .. "': " .. tostring(err))
        return nil
    end
    return obj
end

local function make_border_widget(name, outer)
    local w = construct("/Script/UMG.UserWidget", outer, name)
    if not w then return nil, nil end
    local tree = construct("/Script/UMG.WidgetTree", w, name .. "_Tree")
    if not tree then return nil, nil end
    w.WidgetTree = tree
    local border = construct("/Script/UMG.Border", tree, name .. "_Border")
    if not border then return nil, nil end
    tree.RootWidget = border
    return w, border
end

local function build()
    local gi = FindFirstOf("MV_GameInstance_C")
    if not gi or not valid(gi) then
        log("no MV_GameInstance_C yet")
        return false
    end
    local dot_border, clock_border
    dot, dot_border = make_border_widget(NAME_DOT, gi)
    clock, clock_border = make_border_widget(NAME_CLOCK, gi)
    if not dot or not clock then return false end
    clock_text = construct("/Script/UMG.TextBlock", clock.WidgetTree, NAME_CLOCK .. "_Text")
    if not clock_text then return false end
    try("Border:SetContent", function() clock_border:SetContent(clock_text) end)
    try("TextBlock:SetText", function() clock_text:SetText(FText("0:00")) end)
    log(string.format("built: dot=%s clock=%s text=%s", full_name(dot), full_name(clock), full_name(clock_text)))
    return true
end

local last_vw, last_vh = nil, nil
local function viewport_size()
    local lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    local gi = FindFirstOf("MV_GameInstance_C")
    if not lib or not valid(lib) or not gi or not valid(gi) then return nil, nil end
    local w, h
    local ok = pcall(function()
        local v = lib:GetViewportSize(gi)
        w, h = v.X, v.Y
    end)
    if not ok or type(w) ~= "number" or w <= 0 then return nil, nil end
    return w, h
end

local function apply()
    if not dot or not clock then return end
    local t = tuning
    -- colours
    try("Border:SetBrushColor(dot)", function() dot.WidgetTree.RootWidget:SetBrushColor(color_of(t.dot)) end)
    try("Border:SetBrushColor(box)", function() clock.WidgetTree.RootWidget:SetBrushColor(color_of(t.box)) end)
    try("TextBlock:SetColorAndOpacity", function()
        clock_text:SetColorAndOpacity({ SpecifiedColor = color_of(t.ink), ColorUseRule = 0 })
    end)
    -- font size: write the Font struct's Size in place, the simplest thing that can work
    try("TextBlock.Font.Size", function() clock_text.Font.Size = t.text end)
    try("Border:SetPadding", function()
        clock.WidgetTree.RootWidget:SetPadding({ Left = t.pad, Top = t.pad, Right = t.pad, Bottom = t.pad })
    end)
    -- placement: both anchored top-right, aligned by their own top-right corner
    -- CORNER PINNING WITHOUT ANCHORS. Anchored placement (SetAnchorsInViewport to the top-right,
    -- read back correctly as (1,0)/(1,0)) put both widgets OFF-SCREEN on this build, twice, while
    -- the same widgets placed from the top-left painted -- so the corner is computed instead:
    -- `UWidgetLayoutLibrary::GetViewportSize` (a BlueprintPure static on the library's default
    -- object; the census lists it) gives the viewport in pixels, and every position is a positive
    -- offset from the top-left, which is the one placement proven here. Re-read once a second, so
    -- a window resize follows.
    for label, w in pairs({ dot = dot, clock = clock }) do
        try("UserWidget:SetAnchorsInViewport(" .. label .. ")", function()
            w:SetAnchorsInViewport({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 0.0, Y = 0.0 } })
        end)
        try("UserWidget:SetAlignmentInViewport(" .. label .. ")", function() w:SetAlignmentInViewport({ X = 0.0, Y = 0.0 }) end)
    end
    local vw, vh = viewport_size()
    -- the clock sits in the corner; the square sits to its LEFT (dot, then time to its right,
    -- as the user's design says) -- so the square's offset is the clock's width plus the gap.
    -- The clock's width is not known until it lays out; approximate from the font (0.6 em a
    -- digit, four glyphs, plus padding) and let the tuning file correct it.
    -- The box is NOT given a size: a Border auto-sizes to its text plus padding, which is what
    -- "the white follows the digits" means (the user, 14:23, when 10:1x walked out of a box sized
    -- for four glyphs). The width is still estimated, by the digits on screen now, only to know
    -- where to put the box and the square; re-placed when the digit count changes.
    local glyphs = math.max(4, #last_text)
    local clock_w = t.text * 0.6 * glyphs + t.pad * 2
    local clock_h = t.text * 1.2 + t.pad * 2
    -- Once the box has laid out, its REAL size replaces both estimates, and the square takes the
    -- box's height so the two share their top and bottom edges (the old indicator's confirmed
    -- look; the user at 14:27: the square read "a bit mispositioned/small" against the estimate).
    if measured_w and measured_w > 0 and measured_h and measured_h > 0 then
        clock_w, clock_h = measured_w, measured_h
    end
    local size = clock_h
    placed_glyphs = glyphs
    -- x is the distance of the CLOCK's right edge from the viewport's right edge; the square sits
    -- to its left. Without a viewport size (nil before the first frame) place from the left.
    local clock_x = vw and (vw - t.x - clock_w) or (t.x + size + t.gap)
    local dot_x = vw and (clock_x - t.gap - size) or t.x
    try("UserWidget:SetPositionInViewport(clock)", function() clock:SetPositionInViewport({ X = clock_x, Y = t.y }, true) end)
    try("UserWidget:SetPositionInViewport(dot)", function() dot:SetPositionInViewport({ X = dot_x, Y = t.y }, true) end)
    try("UserWidget:SetDesiredSizeInViewport(dot)", function() dot:SetDesiredSizeInViewport({ X = size, Y = size }) end)
    -- shown or hidden
    if t.show ~= 0 and not shown then
        try("UserWidget:AddToViewport(dot)", function() dot:AddToViewport(t.z) end)
        try("UserWidget:AddToViewport(clock)", function() clock:AddToViewport(t.z) end)
        shown = true
    elseif t.show == 0 and shown then
        try("UserWidget:RemoveFromParent(dot)", function() dot:RemoveFromParent() end)
        try("UserWidget:RemoveFromParent(clock)", function() clock:RemoveFromParent() end)
        shown = false
    end
    -- DIAGNOSIS (added after the first look, 2026-09-08 14:10: the user saw nothing of ours at
    -- all while every call succeeded): what the engine says about the two widgets, plus a CONTROL
    -- built exactly the tester's way -- a TextBlock as the root, position only, no anchors, no
    -- desired size -- so whichever of Border / anchors / desired-size is the difference names itself.
    for label, w in pairs({ dot = dot, clock = clock }) do
        local inv, ds, vis, rvis = "?", "?", "?", "?"
        pcall(function() inv = tostring(w:IsInViewport()) end)
        pcall(function() local d = w:GetDesiredSize(); ds = string.format("%.1f,%.1f", d.X, d.Y) end)
        pcall(function() vis = tostring(w:GetVisibility()) end)
        pcall(function() rvis = tostring(w.WidgetTree.RootWidget:GetVisibility()) end)
        log(string.format("DIAG %s: IsInViewport=%s desired=%s vis=%s root_vis=%s", label, inv, ds, vis, rvis))
    end
    if not control_widget or not valid(control_widget) then
        local gi = FindFirstOf("MV_GameInstance_C")
        control_widget = construct("/Script/UMG.UserWidget", gi, "MeshGhostHudControl")
        if control_widget then
            local tree = construct("/Script/UMG.WidgetTree", control_widget, "MeshGhostHudControl_Tree")
            local txt = tree and construct("/Script/UMG.TextBlock", tree, "MeshGhostHudControl_Text")
            if tree and txt then
                control_widget.WidgetTree = tree
                tree.RootWidget = txt
                try("control:SetText", function() txt:SetText(FText("MESHGHOST CONTROL")) end)
                try("control:SetPositionInViewport", function() control_widget:SetPositionInViewport({ X = 200.0, Y = 300.0 }, true) end)
                try("control:AddToViewport", function() control_widget:AddToViewport(99) end)
                local inv = "?"
                pcall(function() inv = tostring(control_widget:IsInViewport()) end)
                log("DIAG control (tester's shape) built, IsInViewport=" .. inv)
            end
        end
    end
    local n = 0
    for _ in pairs(failed) do n = n + 1 end
    log(string.format("applied x=%g y=%g size=%g gap=%g text=%g pad=%g z=%g show=%g dot=%s box=%s ink=%s | %d call(s) failing",
        t.x, t.y, t.size, t.gap, t.text, t.pad, t.z, t.show, t.dot, t.box, t.ink, n))
end

local function tick_clock()
    if not clock_text or not shown then return end
    local s = math.floor(os.clock() - t0) + (tuning.fake_offset or 0)
    if s ~= last_second then
        last_second = s
        last_text = string.format("%d:%02d", s // 60, s % 60)
        try("TextBlock:SetText(tick)", function() clock_text:SetText(FText(last_text)) end)
        if math.max(4, #last_text) ~= placed_glyphs then apply() end
    end
end

local built = false
local census_done = false
LoopAsync(POLL_MS, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            if not census_done then
                census_done = true
                run_census()
                remove_leftovers()
            end
            -- A level transition (title -> gameplay, a zone change) takes the viewport's widgets
            -- with it, or the collector does: the first run lost the TextBlock ~20 s after load,
            -- at the first transition. Notice, and build again; the C++ port has the LoadMap hook.
            if built and (not valid(dot) or not valid(clock) or not valid(clock_text)) then
                log("widgets lost (transition or collection) -- rebuilding")
                built = false
                shown = false
                dot, clock, clock_text = nil, nil, nil
                last_second = -1
                measured_w, measured_h = nil, nil
            end
            if not built then
                built = build()
                if built then
                    read_tuning()
                    apply()
                end
                return
            end
            local changed = read_tuning()
            -- the box's laid-out size, re-placing whenever it changes (first layout, 10:00, ...)
            if clock and valid(clock) then
                local ok, d = pcall(function() return clock:GetDesiredSize() end)
                if ok and d and d.X and d.X > 0 and (d.X ~= measured_w or d.Y ~= measured_h) then
                    measured_w, measured_h = d.X, d.Y
                    changed = true
                end
            end
            local vw, vh = viewport_size()
            if vw and (vw ~= last_vw or vh ~= last_vh) then
                last_vw, last_vh = vw, vh
                log(string.format("viewport %gx%g", vw, vh))
                changed = true
            end
            if changed then apply() end
            tick_clock()
        end)
        if not ok then log("tick error: " .. tostring(err)) end
    end)
    return false
end)

log("loaded -- load into gameplay; the pair appears top right. Tune via " .. TUNING_PATH .. "; census of the widget classes on first tick.")
