-- MeshGhost — BizHawk input API probe (READ-ONLY: reports, presses nothing)
--
-- If input can be driven from Lua, an unattended test can do more than restore a savestate: it
-- could walk the player, open a menu, trigger a warp. This only asks what the host HAS -- it
-- presses nothing, because doing so while someone is playing would fight them for the controller.
local out = { "=== input API, as this host actually reports it ===" }
for _, lib in ipairs({ "joypad", "input" }) do
    local t = _G[lib]
    if t == nil then
        out[#out + 1] = string.format("  no `%s` library", lib)
    else
        for _, n in ipairs({ "set", "get", "getimmediate", "setanalog", "getmouse" }) do
            local v = nil
            local ok = pcall(function() v = t[n] end)
            if ok and v ~= nil then
                out[#out + 1] = string.format("  %s.%-13s -> %s", lib, n, type(v))
            end
        end
    end
end
local f = io.open("bizhawk-input-probe.log", "w")
for _, line in ipairs(out) do
    console.log(line)
    if f then f:write(line, "\n") end
end
if f then f:close() end
MESHGHOST_DEV_TICK = function() end
