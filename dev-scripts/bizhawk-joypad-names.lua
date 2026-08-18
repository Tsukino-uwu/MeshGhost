-- MeshGhost — what does this core call its buttons? (READ-ONLY)
-- joypad.set silently did nothing for two directions. Rather than guess a third button spelling,
-- ask the host: joypad.get() returns the CURRENT input as a table, so its KEYS are the exact
-- names this core expects. Also dumps joypad.getimmediate() for comparison.
local f = io.open("C:/dev/MeshGhost/dev-scripts/joypad-names.log", "w")
local function out(s)
    console.log(s)
    if f then f:write(s, "\n") end
end

for _, fn in ipairs({ "get", "getimmediate" }) do
    local ok, t = pcall(function() return joypad[fn]() end)
    out(string.format("=== joypad.%s() -> %s", fn, type(t)))
    if ok and type(t) == "table" then
        local keys = {}
        for k, v in pairs(t) do keys[#keys + 1] = string.format("%s=%s", tostring(k), tostring(v)) end
        table.sort(keys)
        for _, k in ipairs(keys) do out("   " .. k) end
    else
        out("   " .. tostring(t))
    end
end
if f then f:close() end
MESHGHOST_DEV_TICK = function() end
