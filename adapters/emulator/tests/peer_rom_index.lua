-- peer_rom_index.lua -- can a peer's number reach a ROM offset, or a permanent table key, without being an integer?
--
-- Run: lua5.4 adapters/emulator/tests/peer_rom_index.lua   (from the repo root)
--
-- Crystal uses peer numbers both as ROM arithmetic and as keys into a memo that is never cleared, and a range check
-- alone lets 83.0001, 83.0002 ... through: one permanent entry per state for the whole session.
-- Both functions are lifted from the adapter by text, so this tests what ships.

local path = "adapters/emulator/pokemon/crystal/meshghost_crystal.lua"
local src = assert(io.open(path, "rb")):read("a")
-- The markers anchor on line starts, and a Windows checkout may hold this unpinned file as CRLF.
src = src:gsub("\r\n", "\n")

local function lift(marker, what)
	local startAt = src:find(marker, 1, true)
	assert(startAt, what .. " not found -- it was renamed, and this test is testing nothing")
	local endAt = src:find("\nend\n", startAt, true)
	assert(endAt, "could not find the end of " .. what)
	return src:sub(startAt, endAt + 4)
end

local failures = 0
local function check(desc, got, want)
	if got ~= want then
		failures = failures + 1
		io.write(string.format("FAIL  %s: got %s, want %s\n", desc, tostring(got), tostring(want)))
	end
end

-- The growth check goes through the shipped spriteSig, not the gate, so it fails on a tree without peerRomIndex
-- instead of erroring. Lifted by text, the adapter's ENGINE upvalue resolves against this stub, where the gate is
-- simply nil on such a tree. memory.read_u8 records each address it is asked for, so a fractional one shows itself.
local asked = {}
local env = {
	ENGINE = { spriteSigs = {} },
	OVERWORLD_SPRITES_ROM = 0x10000,
	SPRITEDATA_STRIDE = 6,
	ROM_DOMAIN = "ROM",
	memory = {
		read_u8 = function(addr)
			asked[#asked + 1] = addr
			return 0x5A
		end,
	},
	math = math,
	type = type,
}
local peerRomIndexSrc = src:find("function ENGINE.peerRomIndex", 1, true)
	and lift("function ENGINE.peerRomIndex", "ENGINE.peerRomIndex")
if peerRomIndexSrc then
	assert(load(peerRomIndexSrc, "peerRomIndex", "t", env))()
end
assert(load(lift("function ENGINE.spriteSig", "ENGINE.spriteSig"), "spriteSig", "t", env))()

for i = 1, 1000 do
	env.ENGINE.spriteSig(83 + i / 10000)
end
if next(env.ENGINE.spriteSigs) ~= nil then
	local n = 0
	for _ in pairs(env.ENGINE.spriteSigs) do
		n = n + 1
	end
	failures = failures + 1
	io.write(string.format(
		"FAIL  1000 fractional sprite ids left %d entries in ENGINE.spriteSigs, which is never " ..
		"cleared -- one permanent entry per state, at the room's send rate, for the session\n", n))
end
for _, addr in ipairs(asked) do
	if addr ~= math.floor(addr) then
		failures = failures + 1
		io.write(string.format(
			"FAIL  a fractional ROM address (%s) was handed to memory.read_u8\n", tostring(addr)))
		break
	end
end

-- A real id must still work, or the ghost loses its bike, its surf blob and its running pose.
local sig = env.ENGINE.spriteSig(83)
if type(sig) ~= "number" then
    failures = failures + 1
    io.write(string.format("FAIL  an ordinary sprite id 83 produced %s, not a signature\n", tostring(sig)))
end
if env.ENGINE.spriteSig(83) ~= sig then
	failures = failures + 1
	io.write("FAIL  the memo did not return the same signature the second time\n")
end
check("out of range is still refused", env.ENGINE.spriteSig(256), nil)
check("zero is still refused", env.ENGINE.spriteSig(0), nil)

-- The gate itself, skipped when absent so the growth check above is the verdict on an unfixed tree.
local peerRomIndex = env.ENGINE.peerRomIndex
if not peerRomIndex then
	io.write("peerRomIndex is not in this adapter -- the growth check above is the verdict\n")
else
	check("an ordinary sprite id", peerRomIndex(83, 1, 255), 83)
	check("an integer-valued float", peerRomIndex(83.0, 1, 255), 83)
	check("the answer is an integer", math.type(peerRomIndex(83.0, 1, 255)), "integer")
	check("the low bound", peerRomIndex(1, 1, 255), 1)
	check("the high bound", peerRomIndex(255, 1, 255), 255)
	check("emote's low bound is zero", peerRomIndex(0, 0, 11), 0)

	check("a fractional sprite", peerRomIndex(83.5, 1, 255), nil)
	check("a barely-fractional sprite", peerRomIndex(83.0001, 1, 255), nil)
	check("a fractional emote", peerRomIndex(6.25, 0, 11), nil)
	check("a fractional species", peerRomIndex(155.75, 1, 251), nil)

	check("below the range", peerRomIndex(0, 1, 255), nil)
	check("above the range", peerRomIndex(256, 1, 255), nil)
	check("above the emote range", peerRomIndex(12, 0, 11), nil)
	check("negative", peerRomIndex(-1, 0, 11), nil)

	check("nan", peerRomIndex(0 / 0, 1, 255), nil)
	check("+inf", peerRomIndex(math.huge, 1, 255), nil)
	check("-inf", peerRomIndex(-math.huge, 1, 255), nil)

	check("nil", peerRomIndex(nil, 1, 255), nil)
	check("a string", peerRomIndex("83", 1, 255), nil)
	check("a table", peerRomIndex({}, 1, 255), nil)
	check("a boolean", peerRomIndex(true, 1, 255), nil)
end

if failures > 0 then
	io.write(string.format("\n%d check(s) failed\n", failures))
	os.exit(1)
end
io.write("peer_rom_index: all checks passed\n")
