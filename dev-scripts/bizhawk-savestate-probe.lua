-- MeshGhost — BizHawk savestate API probe (READ-ONLY: reports, changes nothing)
--
-- A doc string in BizHawk's DLL is not proof a function is callable -- memory.hash_region had one
-- and was nil at runtime (agent_docs/environment.md). So before relying on savestates for
-- testing, ask the live host what it actually has. This SAVES NOTHING and LOADS NOTHING.
local names = { "save", "load", "saveslot", "loadslot", "saveslots" }
local out = { "=== savestate API, as this host actually reports it ===" }
if savestate == nil then
    out[#out + 1] = "  no `savestate` library in this Lua host"
else
    for _, n in ipairs(names) do
        out[#out + 1] = string.format("  savestate.%-10s -> %s", n, type(savestate[n]))
    end
end
local f = io.open("bizhawk-savestate-probe.log", "w")
for _, line in ipairs(out) do
    console.log(line)
    if f then f:write(line, "\n") end
end
if f then f:close() end
MESHGHOST_DEV_TICK = function() end
