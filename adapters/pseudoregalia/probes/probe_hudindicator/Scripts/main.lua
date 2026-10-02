-- HUD indicator prototype: the recording indicator (red square, white clock box, black digits, top right) as two
-- screen-space UserWidgets with Border roots, so geometry cannot hide it and a field-of-view change cannot move it.
-- It first dumps the UMG classes' functions to hud_census-*.log and calls only names found there; a call that raises
-- is reported once. The clock shows seconds since load. Writes no game state, and removes its own widgets left by a
-- previous load. Tuned live by hud_indicator.txt beside Scripts, key=value, re-read every 500 ms:
--   x, y: pixels in from the top-right corner; gap: square to box; text: font size; pad: box padding;
--   z: viewport z-order; dot, box, ink: #RRGGBB colours; show: 0 hides both.

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
                    -- Return nothing: UE4SS stops the walk on any returned value.
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
    try("Border:SetBrushColor(dot)", function() dot.WidgetTree.RootWidget:SetBrushColor(color_of(t.dot)) end)
    try("Border:SetBrushColor(box)", function() clock.WidgetTree.RootWidget:SetBrushColor(color_of(t.box)) end)
    try("TextBlock:SetColorAndOpacity", function()
        clock_text:SetColorAndOpacity({ SpecifiedColor = color_of(t.ink), ColorUseRule = 0 })
    end)
    try("TextBlock.Font.Size", function() clock_text.Font.Size = t.text end)
    try("Border:SetPadding", function()
        clock.WidgetTree.RootWidget:SetPadding({ Left = t.pad, Top = t.pad, Right = t.pad, Bottom = t.pad })
    end)
    -- Top-right anchors put both widgets off-screen on this build, so the corner is computed: positive offsets from
    -- the top-left, from GetViewportSize, re-read so a window resize follows.
    for label, w in pairs({ dot = dot, clock = clock }) do
        try("UserWidget:SetAnchorsInViewport(" .. label .. ")", function()
            w:SetAnchorsInViewport({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 0.0, Y = 0.0 } })
        end)
        try("UserWidget:SetAlignmentInViewport(" .. label .. ")", function() w:SetAlignmentInViewport({ X = 0.0, Y = 0.0 }) end)
    end
    local vw, vh = viewport_size()
    -- The box is never sized (a Border fits its text); until it lays out, its size is estimated from the digits on
    -- screen (0.6 em each) to place the box and the square left of it, and re-placed when the digit count changes.
    local glyphs = math.max(4, #last_text)
    local clock_w = t.text * 0.6 * glyphs + t.pad * 2
    local clock_h = t.text * 1.2 + t.pad * 2
    -- Once laid out, the box's real size replaces the estimate, and the square takes its height so their edges align.
    if measured_w and measured_w > 0 and measured_h and measured_h > 0 then
        clock_w, clock_h = measured_w, measured_h
    end
    local size = clock_h
    placed_glyphs = glyphs
    -- x is the clock's right edge from the viewport's; with no viewport size yet, place from the left.
    local clock_x = vw and (vw - t.x - clock_w) or (t.x + size + t.gap)
    local dot_x = vw and (clock_x - t.gap - size) or t.x
    try("UserWidget:SetPositionInViewport(clock)", function() clock:SetPositionInViewport({ X = clock_x, Y = t.y }, true) end)
    try("UserWidget:SetPositionInViewport(dot)", function() dot:SetPositionInViewport({ X = dot_x, Y = t.y }, true) end)
    try("UserWidget:SetDesiredSizeInViewport(dot)", function() dot:SetDesiredSizeInViewport({ X = size, Y = size }) end)
    if t.show ~= 0 and not shown then
        try("UserWidget:AddToViewport(dot)", function() dot:AddToViewport(t.z) end)
        try("UserWidget:AddToViewport(clock)", function() clock:AddToViewport(t.z) end)
        shown = true
    elseif t.show == 0 and shown then
        try("UserWidget:RemoveFromParent(dot)", function() dot:RemoveFromParent() end)
        try("UserWidget:RemoveFromParent(clock)", function() clock:RemoveFromParent() end)
        shown = false
    end
    -- What the engine says about each widget, beside a control built the tester's way (a TextBlock root, position
    -- only), so a difference between the two names itself.
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
            -- A level transition takes the viewport's widgets, or the collector does: rebuild.
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
            -- Re-placed whenever the box's laid-out size changes (first layout, 10:00).
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
