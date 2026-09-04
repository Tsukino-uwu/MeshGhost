-- Which teardown verbs actually EXIST on a NiagaraComponent in this build (2026-09-04).
--
-- THE QUESTION. The adapter's despawn cleanup hides, stops, then destroys, and its log reported
-- `0 world-spawned component(s) destroyed` on a despawn the user watched come out clean. Two
-- explanations fit that equally: `DestroyComponent` does not resolve on this build (so the HIDE is
-- what cleared the screen and the object is still resident), or the candidate list never held the
-- things that matter. This separates them without a rebuild.
--
-- The precedent is not a guess: this build already lacks `DeactivateImmediate` -- measured
-- 2026-09-04 and logged by the adapter itself -- so "the obvious teardown function is missing here"
-- has happened once already in this exact family.
--
-- SAFETY, and it is the whole design of this probe. It NEVER CALLS any of these. It asks whether
-- the member resolves, which is a named lookup, and prints the answer. `CLAUDE.md`'s standing rule
-- is that calling a UFunction on something `FindAllOf` handed you dereferences state that may not
-- be there and a Lua pcall does not catch an access violation -- that crashed live sessions twice
-- on 2026-08-29. Existence is the entire question here, so nothing needs to be invoked.
--
-- WHAT IT CANNOT SEE: whether a verb that resolves actually WORKS. `K2_DestroyActor` "was reflected
-- and called" on ghosts that then took a garbage collection to disappear, so resolution is a
-- necessary condition and not a sufficient one.
--
-- Read-only. Dev-only tooling; never ships.

local TAG = "[MeshGhostVerbs]"
local VERBS = {
    "DestroyComponent", "K2_DestroyComponent", "Deactivate", "DeactivateImmediate",
    "SetVisibility", "SetHiddenInGame", "SetAutoDestroy", "Activate",
}
local SAMPLE_COMPONENTS = 3

local function has_member(obj, name)
    local v
    if not pcall(function() v = obj[name] end) then return "ERROR" end
    if v == nil then return "no" end
    return "YES"
end

local function report()
    local comps = FindAllOf("NiagaraComponent")
    if not comps then
        print(string.format("%s no NiagaraComponent in the world yet\n", TAG))
        return
    end
    local n = 0
    for _, c in pairs(comps) do
        n = n + 1
        if n > SAMPLE_COMPONENTS then break end
        local name
        pcall(function() name = c:GetFullName() end)
        local parts = {}
        for _, verb in ipairs(VERBS) do
            parts[#parts + 1] = verb .. "=" .. has_member(c, verb)
        end
        -- The component is NAMED in the same line as its verbs: a verb table with no subject is
        -- unfalsifiable, and three components are printed because one could be atypical.
        print(string.format("%s %s\n%s   %s\n", TAG, name or "<unnamed>", TAG, table.concat(parts, "  ")))
    end
    print(string.format("%s (sampled %d of the components present)\n", TAG, math.min(n, SAMPLE_COMPONENTS)))
end

ExecuteInGameThread(report)
print(string.format("%s asked once at load -- existence only, nothing was called.\n", TAG))
