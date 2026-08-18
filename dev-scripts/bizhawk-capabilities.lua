-- MeshGhost — BizHawk capability dump (READ-ONLY: reports, changes nothing)
--
-- "What else can we drive from here?" answered from the host itself rather than from memory or a
-- DLL string dump. BizHawk exposes client.getluafunctionslist(), which returns every function it
-- actually implements in this build -- the authoritative answer, and it costs one call.
--
-- Written 2026-08-18 after savestates and input turned out to be available and useful, on the
-- reasoning that if two capabilities were sitting unused there are probably others.
local path = "bizhawk-capabilities.log"
local f = io.open(path, "w")
local function out(s)
    console.log(s)
    if f then f:write(s, "\n") end
end

out("=== BizHawk Lua functions, as this build reports them ===")
local ok, list = pcall(function() return client.getluafunctionslist() end)
if ok and type(list) == "string" then
    -- Returned as one big string; normalise so it is greppable one per line.
    for name in list:gmatch("[^%s]+") do out(name) end
elseif ok and type(list) == "table" then
    for _, name in ipairs(list) do out(tostring(name)) end
else
    out("client.getluafunctionslist() unavailable: " .. tostring(list))
end
if f then f:close() end
MESHGHOST_DEV_TICK = function() end
