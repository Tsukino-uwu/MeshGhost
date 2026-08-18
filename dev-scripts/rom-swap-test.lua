-- MeshGhost — DEV: prove client.openrom loads an ARBITRARY rom, measuring both in one run.
--
-- The first attempt compared "before" against "after" across two SEPARATE runs and got identical
-- readings -- because the earlier run had already left the other rom loaded, so both samples were
-- the same cartridge. A carried-over state made a real difference invisible. Measure both inside
-- one run, from a known starting point you set yourself.
local ROM_VANILLA = "C:/ProgramData/Archipelago/bizhawk roms/Roms/gba/Pokemon - Emerald Version (USA, Europe).gba"
local ROM_AP = "C:/Users/nyden/Downloads/P1_Tsukino_N2LVKSRcSG-V8oZzd11ehg.gba"

-- The cartridge header title is the same on both (a patch keeps it), so fingerprint CODE: the
-- region around CB2_Overworld is recompiled by the Archipelago patch (verified.md 2026-08-14).
local function fingerprint()
    local parts = {}
    for _, addr in ipairs({ 0x08085e5c, 0x08086800, 0x080867f0 }) do
        parts[#parts + 1] = string.format("%08X", memory.read_u32_le(addr))
    end
    return table.concat(parts, " ")
end

local f = io.open("C:/dev/MeshGhost/dev-scripts/rom-swap.log", "w")
local function log(m) console.log(m) if f then f:write(m, "\n") f:flush() end end

local steps = {
    { after = 30,  act = function() client.openrom(ROM_VANILLA) end, label = "opened vanilla" },
    { after = 180, act = function() log("vanilla fingerprint: " .. fingerprint()) end },
    { after = 30,  act = function() client.openrom(ROM_AP) end,      label = "opened AP seed" },
    { after = 180, act = function() log("AP      fingerprint: " .. fingerprint()) end },
    { after = 30,  act = function() client.openrom(ROM_VANILLA) end, label = "back to vanilla" },
    { after = 180, act = function()
        log("restored fingerprint: " .. fingerprint())
        local ok = pcall(function() savestate.loadslot(6) end)
        log("restored slot 6 -> " .. tostring(ok))
    end },
}

local i, frames = 1, 0
MESHGHOST_DEV_TICK = function()
    if i > #steps then return end
    frames = frames + 1
    if frames < steps[i].after then return end
    local ok, err = pcall(steps[i].act)
    if steps[i].label then log(steps[i].label .. " -> " .. tostring(ok)) end
    if not ok then log("  error: " .. tostring(err)) end
    i, frames = i + 1, 0
    if i > #steps and f then f:close() f = nil end
end
