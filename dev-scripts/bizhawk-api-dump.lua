-- Lists what this BizHawk build exposes by walking its global tables, for a build with no client.getluafunctionslist.
local dir = os.getenv("MESHGHOST_SCRIPT_DIR") or "."
local f = io.open(dir .. "/../dev-logs/bizhawk-api-dump.log", "w")

local function dump(name, t)
    if type(t) ~= "table" then
        f:write(name .. " = " .. type(t) .. "\n")
        return
    end
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    f:write(name .. ": " .. table.concat(keys, ", ") .. "\n\n")
end

for _, n in ipairs({ "client", "emu", "os", "io", "comm", "bizstring" }) do
    local ok, v = pcall(function() return _G[n] end)
    if ok and v ~= nil then dump(n, v) else f:write(n .. " = (absent)\n") end
end

local g = {}
for k in pairs(_G) do g[#g + 1] = tostring(k) end
table.sort(g)
f:write("\n_G: " .. table.concat(g, ", ") .. "\n")
f:close()
console.log("MeshGhost: API dump written.")
