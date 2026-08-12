-- MeshGhost Phase 7 socket-capability probe, Stage 1 (SAFE): only checks whether
-- package.loadlib exists and is callable at all under UE4SS's embedded Lua. Does NOT attempt
-- to load any DLL yet -- that's a separate, riskier Stage 2 script, only to be run after this
-- one confirms loadlib is even present. Never writes memory, never touches the network.
--
-- Why this matters: agent_docs/risks.md and agent_docs/phases/phase7.md record that UE4SS's
-- own Lua API docs list no networking/socket capability, and RE-UE4SS's repo has zero
-- luasocket references -- but that doesn't prove package.loadlib itself is unavailable, only
-- that no first-party socket library ships. This probe checks the actual capability directly
-- rather than continuing to infer it from absence of documentation.

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
