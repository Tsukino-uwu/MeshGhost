-- MeshGhost -- render a graphic's animation frames to PPM, straight from ROM (DEV TOOL)
--
-- WHY. The drawn ghost's hat vanishes at Mach top speed (user, 2026-08-20). The painter decodes
-- frames from ROM through the graphic's own anim table; this does the same decode independently
-- and writes each frame of the fast animation as a PPM image -- if the hat is missing HERE, the
-- decode or the anim-table walk is wrong; if it is present here, the painter clips it at paint
-- time and the hunt moves there. Palette read from the live OBJ palettes like the painter does.
--
-- Graphics info table 0x08505620, struct offsets as measured for this adapter (verified.md):
-- size +0x06, width +0x08, height +0x0A, paletteSlot +0x0C (low nibble), anims +0x18, images +0x1C.
local GFXTABLE = 0x08505620
local GFX = 1              -- Brendan on the Mach Bike
local ANIMS = { 12, 13, 14, 15 } -- the FAST family, all four directions: anim 13 is what a full-speed
                               -- ride resolves live, and its images (1,5,6) were never dumped
local OBJ_PAL = 0x05000200 -- OBJ palette RAM

local function r8(a) return memory.read_u8(a) end
local function r16(a) return memory.read_u16_le(a) end
local function r32(a) return memory.read_u32_le(a) end

local done, n = false, 0
local function tick()
    n = n + 1
    if done or n < 10 then return end
    done = true
    local info = r32(GFXTABLE + GFX * 4)
    local w, h = r16(info + 0x08), r16(info + 0x0a)
    local palSlot = r8(info + 0x0c) % 16
    local anims, images = r32(info + 0x18), r32(info + 0x1c)
    -- Output beside this probe, like every other probe artifact -- never a personal path
    -- (CLAUDE.md's public-repo rule). Override with MESHGHOST_FRAMEDUMP_DIR when a session wants
    -- them in a scratchpad instead.
    local BSLASH = string.char(92)
    local dir = (MESHGHOST_FRAMEDUMP_DIR or os.getenv("MESHGHOST_FRAMEDUMP_DIR")
        or (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/" .. BSLASH .. "][^/" .. BSLASH .. "]*$") or ".")) .. "/"
    for _, animNum in ipairs(ANIMS) do
        local animPtr = r32(anims + animNum * 4)
        for idx = 0, 3 do
            local cmd = r32(animPtr + idx * 4)
            local frame = cmd % 65536
            if frame * (w * h / 2) < 0x10000000 then
                local src = r32(images + frame * 8)
                local f = io.open(string.format("%sg%d_a%d_i%d_f%d.ppm", dir, GFX, animNum, idx, frame), "wb")
                if f then
                    f:write(string.format("P6 %d %d 255 ", w, h))
                    -- 4bpp tiles, 8x8, row-major tile order for a w x h frame
                    for py = 0, h - 1 do
                        for px = 0, w - 1 do
                            local tileRow, tileCol = math.floor(py / 8), math.floor(px / 8)
                            local tileN = tileRow * (w / 8) + tileCol
                            local iy, ix = py % 8, px % 8
                            local byte = r8(src + tileN * 32 + iy * 4 + math.floor(ix / 2))
                            local pix = (ix % 2 == 0) and (byte % 16) or math.floor(byte / 16)
                            local r, g, b = 255, 0, 255      -- transparent -> magenta
                            if pix ~= 0 then
                                local c = r16(OBJ_PAL + palSlot * 32 + pix * 2)
                                r = (c % 32) * 8
                                g = (math.floor(c / 32) % 32) * 8
                                b = (math.floor(c / 1024) % 32) * 8
                            end
                            f:write(string.char(r, g, b))
                        end
                    end
                    f:close()
                end
            end
        end
    end
    console.log("framedump: done")
end

if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
