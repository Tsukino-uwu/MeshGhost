-- DEV: does the game treat the edited tile as water? Walk into it and see.
-- Grass is walkable, water is not (without surfing), so "blocked" is the answer we are looking
-- for -- a behavioural test that needs no redraw and no menus.
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local DIRNAME = { [1] = "Down", [2] = "Up", [3] = "Left", [4] = "Right" }

local function pos()
    local sb1 = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
    if sb1 == 0 then return nil end
    return memory.read_s16_le(sb1 + 0x00), memory.read_s16_le(sb1 + 0x02)
end

local f = io.open("C:/dev/MeshGhost/dev-scripts/walk-into-tile.log", "w")
local function log(m) console.log(m) if f then f:write(m, "\n") f:flush() end end

local frames, phase, sx, sy, dir = 0, "wait", nil, nil, nil
MESHGHOST_DEV_TICK = function()
    frames = frames + 1
    if phase == "wait" then
        if frames < 420 then return end -- let watertile.lua place the tile first
        local objId = memory.read_u8(GPLAYERAVATAR_ADDR + 0x05)
        dir = memory.read_u8(GOBJECTEVENTS_ADDR + objId * OBJECTEVENT_SIZE + 0x18) & 0x0f
        sx, sy = pos()
        log(string.format("walking %s into the edited tile from (%s,%s)",
            tostring(DIRNAME[dir]), tostring(sx), tostring(sy)))
        phase, frames = "push", 0
        return
    end
    if phase == "push" then
        pcall(function() joypad.set({ [DIRNAME[dir]] = true }) end)
        if frames >= 60 then
            local ex, ey = pos()
            log(string.format("after 60 frames: (%d,%d) -> (%s,%s)", sx, sy, tostring(ex), tostring(ey)))
            if ex == sx and ey == sy then
                log("BLOCKED -- the game is treating the edited tile as water (or as solid).")
            else
                log("MOVED -- the tile is still walkable, so the edit did not take behaviourally.")
            end
            pcall(function() client.screenshot("C:/dev/MeshGhost/dev-scripts/shot.png") end)
            phase = "done"
            if f then f:close() f = nil end
        end
    end
end
