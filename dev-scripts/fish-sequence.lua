-- Drives "use the Super Rod on water", screenshotting every step: START, BAG, the last pocket (KEY ITEMS), the rod as
-- the test kit's third key item. Only the setup: fishing branches, and that part is watched rather than scripted.
local MESHGHOST_DIR = (function()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end)()

local STEPS = {
    -- Reach the overworld first, whatever the last run left open: B backs out one level and does nothing there.
    { wait = 120, press = "B",     shot = "00a-neutral" },
    { wait = 20,  press = "B",     shot = "00b-neutral" },
    { wait = 20,  press = "B",     shot = "00c-neutral" },
    { wait = 20,  press = "B",     shot = "00d-neutral" },
    { wait = 300, press = nil,     shot = "01-start" },   -- water placed by watertile.lua by now
    { wait = 45,  press = "Start", shot = "02-menu" },
    -- The START menu keeps its cursor between openings: drive it to the top and count from there.
    { wait = 25,  press = "Up",    shot = "02a-up" },
    { wait = 20,  press = "Up",    shot = "02b-up" },
    { wait = 20,  press = "Up",    shot = "02c-up" },
    { wait = 20,  press = "Up",    shot = "02d-top" },
    { wait = 45,  press = "A",     shot = "03-bag" },
    { wait = 60,  press = "Right", shot = "04-pocket2" },
    { wait = 45,  press = "Right", shot = "05-pocket3" },
    { wait = 45,  press = "Right", shot = "06-pocket4" },
    { wait = 45,  press = "Right", shot = "07-keyitems" },
    { wait = 45,  press = "Down",  shot = "08-down" },
    { wait = 45,  press = "Down",  shot = "09-onrod" },
    { wait = 45,  press = "A",     shot = "10-submenu" },
    { wait = 60,  press = "A",     shot = "11-used" },
    { wait = 150, press = nil,     shot = "12-after" },
    -- B past the menu's depth always ends in the overworld, whether or not the USE landed: never leave a menu open.
    { wait = 30,  press = "B",     shot = "13-back1" },
    { wait = 30,  press = "B",     shot = "14-back2" },
    { wait = 30,  press = "B",     shot = "15-back3" },
    { wait = 30,  press = "B",     shot = "16-overworld" },
}
local i, frames, held = 1, 0, 0
MESHGHOST_DEV_TICK = function()
    if i > #STEPS then return end
    frames = frames + 1
    local step = STEPS[i]
    if frames < step.wait then return end
    if step.press and held < 5 then
        pcall(function() joypad.set({ [step.press] = true }) end)
        held = held + 1
        return
    end
    if held < 14 then held = held + 1 return end -- release, and let the UI settle
    pcall(function()
        client.screenshot(MESHGHOST_DIR .. "/shots/emerald/step-" .. step.shot .. ".png")
    end)
    console.log("MeshGhost: step " .. step.shot)
    i, frames, held = i + 1, 0, 0
end
