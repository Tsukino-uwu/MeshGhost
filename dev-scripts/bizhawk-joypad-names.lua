-- Dumps the keys of joypad.get() and joypad.getimmediate(), read-only: the exact button names this core expects.
local MESHGHOST_DIR = (function()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end)()

local f = io.open(MESHGHOST_DIR .. "/../dev-logs/joypad-names.log", "w")
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
