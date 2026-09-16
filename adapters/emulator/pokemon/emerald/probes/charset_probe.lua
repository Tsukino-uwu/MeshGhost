-- MeshGhost — Pokémon Emerald: make the game draw every glyph byte (DEV TOOL, WRITES, never shipped)
-- -- 2026-09-16
--
-- WHY THIS EXISTS. autoplay decodes Emerald's text, and the encoding is to be learned from the game:
-- text drawn on screen against the bytes behind it (`agent_docs/phases/phase13.md`). Ordinary dialogue
-- covers the common letters; this makes the game's own text printer draw bytes 00-F7 in a real text
-- box, so each can be paired with the glyph a screenshot shows. The situation is made (the bytes); the
-- mechanism under test (the printer drawing them) runs untouched.
--
-- HOW. Armed at load. On the first entry to the routine named AddTextPrinter whose template names
-- window 0 and points at the buffer named gStringVar4 -- an ordinary message box starting to print --
-- it overwrites that buffer with a test page, before the printer has drawn anything:
--   per line: EF, then ten test bytes each followed by EF (EF is the cursor glyph, measured
--   2026-09-16 by text_probe.lua, used as a separator so a blank glyph still shows as "EF EF")
--   FE after line 1 of a box, FB after line 2 (both measured the same day in the nurse's dialogue:
--   FE starts line 2, FB waits with the arrow and clears), FF at the end.
-- The log (charset_probe_<time>.log, gitignored) lists box -> line -> byte range, and the page READ
-- BACK from memory after the write. Only once; reload to arm again.
--
-- ADDRESSES: the same hash-matched build as text_probe.lua (SHA-1 compared 2026-09-16), vanilla only.
-- The buffer is scratch space every message overwrites; nothing here touches a save.

local BUS = "System Bus"
local ADDTEXTPRINTER = 0x0800467c
local GSTRINGVAR4, GSTRINGVAR4_SIZE = 0x02021fc4, 0x3e8
local FIRST, LAST, PER_LINE = 0x00, 0xF7, 10
local SEP, NEWLINE, CLEAR, EOS = 0xEF, 0xFE, 0xFB, 0xFF

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local logf = io.open(dir .. "/charset_probe_" .. os.date("%Y%m%d_%H%M%S") .. ".log", "w")
local function log(s)
	if logf then
		logf:write(string.format("f%d %s\n", emu.framecount(), s))
		logf:flush() -- a few lines, once
	end
end

local page, layout = {}, {}
do
	local b, line = FIRST, 0
	while b <= LAST do
		page[#page + 1] = SEP
		local from = b
		for _ = 1, PER_LINE do
			if b > LAST then break end
			page[#page + 1] = b
			page[#page + 1] = SEP
			b = b + 1
		end
		layout[#layout + 1] = string.format("box %d line %d: %02X-%02X", line // 2 + 1, line % 2 + 1, from, b - 1)
		if b <= LAST then page[#page + 1] = (line % 2 == 0) and NEWLINE or CLEAR end
		line = line + 1
	end
	page[#page + 1] = EOS
end
assert(#page <= GSTRINGVAR4_SIZE, "page does not fit the buffer")

local armed = true
local HOOK = "meshghost_charset_probe"
pcall(event.unregisterbyname, HOOK)
local ok, err = pcall(event.onmemoryexecute, function()
	if not armed then return end
	local r0 = emu.getregister("R0")
	local t = memory.read_bytes_as_array(r0, 8, BUS)
	local ptr = t[1] | (t[2] << 8) | (t[3] << 16) | (t[4] << 24)
	if t[5] ~= 0 or ptr ~= GSTRINGVAR4 then return end
	armed = false
	memory.write_bytes_as_array(GSTRINGVAR4, page, BUS)
	local back = memory.read_bytes_as_array(GSTRINGVAR4, #page, BUS)
	local hex, same = {}, true
	for i = 1, #page do
		hex[#hex + 1] = string.format("%02X", back[i])
		if back[i] ~= page[i] then same = false end
	end
	log(string.format("wrote the page (%d bytes) at a window-0 print; read back %s", #page, same and "MATCHES" or "DIFFERS"))
	for _, l in ipairs(layout) do log(l) end
	log("read back: " .. table.concat(hex))
end, ADDTEXTPRINTER, HOOK)
log(ok and "armed: waiting for a window-0 message" or ("hook REFUSED: " .. tostring(err)))

MESHGHOST_DEV_TICK = function() end
MESHGHOST_DEV_UNLOAD = function()
	pcall(event.unregisterbyname, HOOK)
	log("unloaded")
	if logf then logf:close() end
	logf = nil
end
