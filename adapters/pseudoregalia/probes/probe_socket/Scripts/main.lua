-- Socket probe, stage 1: does package.loadlib exist and is it callable under UE4SS's embedded Lua?
-- Loads no DLL and touches no network; stage 2 is the one that loads LuaSocket.

print("[MeshGhostSocketProbe] Stage 1: checking Lua environment capabilities.\n")
print(string.format("[MeshGhostSocketProbe] _VERSION = %s\n", tostring(_VERSION)))
print(string.format("[MeshGhostSocketProbe] type(package) = %s\n", type(package)))

if type(package) == "table" then
    print(string.format("[MeshGhostSocketProbe] package.config (path separator info) = %s\n", tostring(package.config)))
    print(string.format("[MeshGhostSocketProbe] type(package.loadlib) = %s\n", type(package.loadlib)))
    print(string.format("[MeshGhostSocketProbe] type(package.cpath) = %s (%s)\n", type(package.cpath), tostring(package.cpath)))
    print(string.format("[MeshGhostSocketProbe] type(require) = %s\n", type(require)))
else
    print("[MeshGhostSocketProbe] package table is not available at all -- loadlib is definitively impossible.\n")
end

print("[MeshGhostSocketProbe] Stage 1 complete. Do NOT proceed to a DLL-loading Stage 2 without\n")
print("[MeshGhostSocketProbe] reviewing the result with the user first -- see agent_docs/phases/phase7.md.\n")
