-- MeshGhost — Pokémon Emerald: replays the start of surfing, frame by frame (dev tool, drives the pad, never shipped).
-- Loads savestate slot 2 (saved facing the water; never slot 1), taps A until the player's graphic leaves the walking
-- one, then screenshots SHOOT_FRAMES frames into shots/ beside this file. A shot shows the spawned and hardware tiers,
-- never the drawn one. Never load it beside another probe that presses buttons.

local SLOT = 2
local SHOOT_FRAMES = 150             -- 2.5s: the field move, the hop, and settled surfing
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
        -- MESHGHOST_SURFDRIVE_NO_LOAD: the state was loaded before the adapter, so only tap and shoot.
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
        -- Tapped, not held: the game reads a new press.
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
        -- The emulator frame number, to lay a shot against the adapter log's frame-stamped lines.
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
