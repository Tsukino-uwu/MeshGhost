-- Asks which teardown verbs resolve on a NiagaraComponent in this build, without calling any: a UFunction
-- call on a FindAllOf result can fault past pcall. A verb that resolves is not yet a verb that works.

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
        -- Three components, each named beside its verbs, because one could be atypical.
        print(string.format("%s %s\n%s   %s\n", TAG, name or "<unnamed>", TAG, table.concat(parts, "  ")))
    end
    print(string.format("%s (sampled %d of the components present)\n", TAG, math.min(n, SAMPLE_COMPONENTS)))
end

ExecuteInGameThread(report)
print(string.format("%s asked once at load -- existence only, nothing was called.\n", TAG))
