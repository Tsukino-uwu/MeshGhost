-- Writes every Lua function the build implements (client.getluafunctionslist) to the log, read-only, where the build
-- has that call; bizhawk-api-dump.lua is the fallback where it does not.
local path = "bizhawk-capabilities.log"
local f = io.open(path, "w")
local function out(s)
    console.log(s)
    if f then f:write(s, "\n") end
end

out("=== BizHawk Lua functions, as this build reports them ===")
local ok, list = pcall(function() return client.getluafunctionslist() end)
if ok and type(list) == "string" then
    -- One big string: split to one name per line so it greps.
    for name in list:gmatch("[^%s]+") do out(name) end
elseif ok and type(list) == "table" then
    for _, name in ipairs(list) do out(tostring(name)) end
else
    out("client.getluafunctionslist() unavailable: " .. tostring(list))
end
if f then f:close() end
MESHGHOST_DEV_TICK = function() end
