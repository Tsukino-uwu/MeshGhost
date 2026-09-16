-- MeshGhost — Pokémon Emerald: measure the numbers the adapter still borrows (2026-09-16)
--
-- DEVELOPMENT TOOL, read-only. It presses nothing and writes nothing but its own log.
--
-- WHY THIS EXISTS
-- The per-site audit (phases/phase12.md, 2026-09-16) left six VALUES in shipped code that came from
-- the decompilation alone (emerald/UNVERIFIED.md, the per-site audit entry): `DIRECTION_ANIM`,
-- `WALK_POSE_DURATIONS`/`RUN_POSE_DURATIONS`, `genderFrames.ctcVec`, `genderFrames.shadowDrop`,
-- `genderFrames.reflectiveBehaviour` and the branches of `fishingFrameShift`. Each is answered by
-- what the ENGINE builds for the PLAYER, so this probe records that and leaves the comparison to
-- whoever reads the log.
--
-- WHAT IT RECORDS, while the global `MESHGHOST_BV_REC` is truthy (set it from any script the dev
-- loader runs -- they share one Lua environment), once per frame, unfiltered:
--   * `F <frame> cb2 <gMain.callback2>`;
--   * `P` the player's object event, all 0x24 bytes;
--   * `S<nn>` every one of the 64 sprite slots whose bytes are not all zero, all 0x44 bytes;
--   * `V` a checksum of the VRAM OBJ tiles the player's sprite points at (attr2's tile number, 8
--     tiles for a 16x32 frame) -- what is DRAWN changes when this does.
-- A line `REC on/off` brackets each recording.
--
-- WHAT IT CANNOT SEE. Only the state after each frame: a between-frame write is invisible. It says
-- nothing about a ghost -- run it with the adapter unloaded, so every sprite is the game's own.
--
-- COST while recording: 64x0x44 + 0x24 + 256 bytes read and hex-formatted per frame, buffered,
-- flushed once a second. Idle when not recording. Not for judging pacing while recording.
--
-- ADDRESSES (vanilla, the adapter's own): gPlayerAvatar 02037590 {spriteId +4, objectEventId +5},
-- gObjectEvents 02037350 stride 0x24, gSprites 02020630 stride 0x44, gMain.callback2 030022C4.

local GPLAYERAVATAR, GOBJECTEVENTS, GSPRITES, GMAIN_CB2 = 0x02037590, 0x02037350, 0x02020630, 0x030022c4
local BUS = "System Bus"

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local path = dir .. "/borrowed_values_" .. os.date("%Y%m%d_%H%M%S") .. ".log"
local f = io.open(path, "w")
if f then f:setvbuf("full", 1 << 20) end
local function out(s) if f then f:write(s, "\n") end end

local function hex(t, n)
	local p = {}
	for i = 1, n do p[i] = string.format("%02X", t[i] or 0) end
	return table.concat(p)
end

local recording, frames, lastFlush = false, 0, 0

local function dumpFrame()
	out(string.format("F %d cb2 %08X", emu.framecount(), memory.read_u32_le(GMAIN_CB2, BUS)))
	local objId = memory.read_u8(GPLAYERAVATAR + 5, BUS)
	if objId < 16 then
		out("P " .. hex(memory.read_bytes_as_array(GOBJECTEVENTS + objId * 0x24, 0x24, BUS), 0x24))
	end
	local all = memory.read_bytes_as_array(GSPRITES, 64 * 0x44, BUS)
	for s = 0, 63 do
		local base, nz = s * 0x44, false
		for k = 1, 0x44 do
			if all[base + k] ~= 0 then nz = true break end
		end
		if nz then
			local b = {}
			for k = 1, 0x44 do b[k] = all[base + k] end
			out(string.format("S%02d %s", s, hex(b, 0x44)))
		end
	end
	local spr = memory.read_u8(GPLAYERAVATAR + 4, BUS)
	if spr < 64 then
		local attr2 = all[spr * 0x44 + 5] + all[spr * 0x44 + 6] * 256
		local tile = attr2 & 0x3ff
		local ok, v = pcall(memory.read_bytes_as_array, 0x10000 + tile * 32, 256, "VRAM")
		if ok and v then
			local sum = 0
			for k = 1, #v do sum = (sum * 31 + v[k]) % 4294967296 end
			out(string.format("V tile %03X sum %08X", tile, sum))
		end
	end
end

out("borrowed_values_probe loaded frame " .. emu.framecount())
pcall(function() console.log("borrowed_values_probe: " .. path) end)

MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	local want = _G.MESHGHOST_BV_REC and true or false
	if want ~= recording then
		recording = want
		out(string.format("REC %s frame %d %s", want and "on" or "off", emu.framecount(),
			tostring(_G.MESHGHOST_BV_LABEL or "")))
	end
	if recording then dumpFrame() end
	if frames - lastFlush >= 60 and f then
		lastFlush = frames
		pcall(function() f:flush() end)
	end
end

MESHGHOST_DEV_UNLOAD = function()
	if f then
		out("unloaded frame " .. emu.framecount())
		pcall(function() f:close() end)
		f = nil
	end
end
