-- MeshGhost — Pokémon Emerald: replay the START OF SURFING, frame by frame (DEV TOOL, never shipped)
--
-- WHY
-- The user reports the ghosts glitching *as surfing begins* — not while surfing, which is
-- confirmed good (verified.md, 2026-08-21). A transition that lasts about two seconds cannot be
-- judged by asking someone to do it again and describe it; it has to be replayed and looked at.
--
-- So: load the checkpoint the user saved facing the water (slot 2), tap A until the field move
-- starts, and then screenshot EVERY frame of the transition. A screenshot cannot see the painted
-- tier (a Lua overlay painted after the frame) but it does see the spawned and hardware tiers,
-- which are real sprites — status.md, and the reason a screenshot diff is useful at all.
--
-- SLOT 2 IS THE AGENT'S (slot 1 is the user's, playing.md). Loading it discards nothing of
-- theirs; they saved it for exactly this.
--
-- WHAT IT DOES, in order: load slot 2 → tap A until the player's graphicsId leaves normal →
-- shoot every frame for SHOOT_FRAMES → stop and say so. It drives input, so it must be the ONLY
-- input-driving script in the loader's target list.

local SLOT = 2
local SHOOT_FRAMES = 150             -- 2.5s: the field move, the hop, and settled surfing
-- Beside this script, never an absolute path: this repo is public (CLAUDE.md).
local BS = string.char(92)
local OUT_DIR = (debug.getinfo(1, "S").source:sub(2)
    :match("^(.*)[/" .. BS .. "][^/" .. BS .. "]*$") or ".") .. "/shots"
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24

local phase, n, shots = "load", 0, 0

local function playerGfx()
    local objId = memory.read_u8(GPLAYERAVATAR_ADDR + 0x05)
    if objId >= 16 then return nil end
    return memory.read_u8(GOBJECTEVENTS_ADDR + objId * OBJECTEVENT_SIZE + 0x05)
end

local function tick()
    n = n + 1
    if phase == "load" then
        -- SKIP THE LOAD when somebody else has already done it. Our OBJ-tile bookkeeping does not
        -- survive a savestate load -- the engine's allocation bitmap rewinds and ours does not --
        -- so the honest sequence is: load the state, THEN load the adapter, then drive. Set
        -- MESHGHOST_SURFDRIVE_NO_LOAD and this script only taps and shoots.
        if MESHGHOST_SURFDRIVE_NO_LOAD then
            console.log("surfstart_drive: state already loaded, tapping A")
            phase, n = "tap", 0
            return
        end
        if n < 30 then return end     -- let the adapter settle before yanking the state
        pcall(function() savestate.loadslot(SLOT) end)
        console.log("surfstart_drive: loaded slot " .. SLOT .. ", tapping A")
        phase, n = "tap", 0
        return
    end
    if phase == "tap" then
        -- Tapped, not held: the game reads a NEW press (probes/press_a.lua).
        joypad.set({ A = (n % 20) < 10 })
        local g = playerGfx()
        if g and g ~= 0 and g ~= 89 then
            joypad.set({})
            console.log("surfstart_drive: gfx -> " .. g .. " at tap frame " .. n .. ", shooting")
            phase, n = "shoot", 0
        elseif n > 60 * 20 then
            joypad.set({})
            console.log("surfstart_drive: gave up waiting for the field move")
            phase = "done"
        end
        return
    end
    if phase == "shoot" then
        shots = shots + 1
        -- The EMULATOR frame number in the filename, so a garbled shot can be laid against the
        -- adapter log's own frame-stamped lines instead of guessed at.
        pcall(function()
            client.screenshot(string.format("%s/surf_%03d_f%d.png", OUT_DIR, shots,
                emu.framecount()))
        end)
        if shots >= SHOOT_FRAMES then
            console.log("surfstart_drive: " .. shots .. " frames written to " .. OUT_DIR)
            phase = "done"
        end
    end
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function() joypad.set({}) end
else
    while true do tick() emu.frameadvance() end
end
