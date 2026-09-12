-- peer_rom_index.lua -- can a peer's number reach a ROM offset, or a permanent table key,
-- without being an integer?
--
-- Run: lua5.4 adapters/emulator/tests/peer_rom_index.lua   (from the repo root)
--
-- Crystal takes three numbers straight off the wire -- `extras.sprite`, `extras.emote` and
-- `extras.fly` -- and each is used twice over: as arithmetic into a ROM address, and as a key into
-- a table that is never cleared. All three were RANGE-checked (`id < 1 or id > 255` and friends)
-- and nothing else, so `83.5` passed every gate they had.
--
-- The half that needs no emulator to judge, and the reason this test exists on the desktop side:
-- **there are as many floats between 1 and 255 as there are anywhere else.** A peer sending
-- 83.0001, 83.0002, 83.0003 ... adds one permanent entry to `ENGINE.spriteSigs` per state, at the
-- room's send rate, for the length of the session. The range check does not slow that down by one
-- entry. The ADDRESS half needs a running emulator and is the user's to see; the GROWTH half is
-- arithmetic, and arithmetic can be checked here.
--
-- Found by the Lua-adapters cell of the third adversarial review (P2c-3, P2c-4, P2c-5).
--
-- **The growth check is the one that can fail against the unfixed adapter, and that is why it is
-- here rather than only the unit check below it.** A test written in the fix's own vocabulary --
-- "does peerRomIndex refuse 83.5" -- cannot go red against a tree where `peerRomIndex` does not
-- exist; it errors instead, which is a compile check wearing a regression test's clothes
-- (`agent_docs/pitfalls/method.md`, 2026-09-12). Lifting `ENGINE.spriteSig` and counting its memo
-- table asks the question in the OLD code's vocabulary, so it goes red properly.
--
-- Both functions are lifted out of the adapter BY TEXT rather than copied, the same way
-- json_fuzz.lua and spans_reuse.lua lift theirs, so this tests the real ones and cannot drift from
-- what ships.

local path = "adapters/emulator/pokemon/crystal/meshghost_crystal.lua"
local src = assert(io.open(path, "rb")):read("a")
-- Read as bytes and normalized, because the markers below anchor on line starts. This adapter's
-- .lua is not among the eol=lf pins in .gitattributes (those cover the sources a release gate
-- HASHES), so a Windows working copy can hold CRLF while CI's Linux checkout holds LF, and a
-- harness that only worked on one of them would be a green tick on the runner and an error here.
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

-- ---------------------------------------------------------------------------
-- The growth check, through the SHIPPED spriteSig
-- ---------------------------------------------------------------------------
--
-- The stub environment is everything spriteSig reaches for. `memory.read_u8` returns a
-- deterministic byte rather than a real ROM read -- the hash it feeds is not what is under test,
-- the size of the table it fills is. It also records the addresses it was ASKED for, so a
-- fractional one shows up as itself rather than being quietly rounded by the arithmetic.
--
-- `ENGINE` is stubbed here with only what these two functions touch, which is also where the gate
-- lands: the adapter declares it as `ENGINE.peerRomIndex` rather than a file-scope local because
-- that chunk is at Lua's 200-local ceiling, and a 201st raises at LOAD time -- the whole adapter
-- failing to start. Lifting by text turns the adapter's own `ENGINE` upvalue into a global lookup,
-- which resolves against this stub, and which is exactly what lets the same harness run against a
-- tree that has no such gate at all (the field is simply nil there).
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
	-- Loaded into the same stub env, where ENGINE already exists, so the lifted chunk assigns the
	-- field exactly as the adapter does and every later lift finds it by the same name.
	assert(load(peerRomIndexSrc, "peerRomIndex", "t", env))()
end
assert(load(lift("function ENGINE.spriteSig", "ENGINE.spriteSig"), "spriteSig", "t", env))()

-- A thousand fractional ids, every one of them inside the range the adapter already checked.
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

-- And a real id still works, or the guard is a regression of its own: the ghost would lose its
-- bike, its surf blob and its running pose.
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

-- ---------------------------------------------------------------------------
-- The gate itself
-- ---------------------------------------------------------------------------
--
-- Skipped rather than failed when the function is absent, so the growth check above is what
-- reports on an unfixed tree instead of this erroring out first.
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

	-- Every one of these is inside the range each caller checked.
	check("a fractional sprite", peerRomIndex(83.5, 1, 255), nil)
	check("a barely-fractional sprite", peerRomIndex(83.0001, 1, 255), nil)
	check("a fractional emote", peerRomIndex(6.25, 0, 11), nil)
	check("a fractional species", peerRomIndex(155.75, 1, 251), nil)

	check("below the range", peerRomIndex(0, 1, 255), nil)
	check("above the range", peerRomIndex(256, 1, 255), nil)
	check("above the emote range", peerRomIndex(12, 0, 11), nil)
	check("negative", peerRomIndex(-1, 0, 11), nil)

	-- Non-finite. Every caller's range check already excludes these; they are refused explicitly
	-- anyway so a reader need not prove the ordering -- the shape `pal` and `clo` use two sites
	-- away.
	check("nan", peerRomIndex(0 / 0, 1, 255), nil)
	check("+inf", peerRomIndex(math.huge, 1, 255), nil)
	check("-inf", peerRomIndex(-math.huge, 1, 255), nil)

	-- Not a number at all. A decoder can hand back a string or a table, and this gate is what
	-- every caller now leans on.
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
