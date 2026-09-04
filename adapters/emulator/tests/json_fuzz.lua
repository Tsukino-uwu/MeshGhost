-- json_fuzz.lua -- hostile input against the SHIPPED bridge JSON decoders, offline.
--
-- WHY THIS EXISTS. On 2026-08-25 a malformed bridge line froze BizHawk outright: Crystal's
-- jsonDecode looped forever on truncated input, and the pcall around it could not help, because
-- pcall turns an ERROR into a return value and an infinite loop raises nothing. That was found by
-- transliterating the function into another language and running it against truncated inputs with
-- a step cap. This is that technique promoted from a throwaway to something CI runs, against the
-- real functions rather than a transliteration.
--
-- WHAT IT COVERS, AND WHAT IT DOES NOT. The decoder only. Each adapter's message DISPATCH (what it
-- does with a decoded table) sits thousands of lines further down, past the point where the file
-- starts calling BizHawk's drawing and memory APIs, so nothing here reaches it. A peer string
-- becoming a lookup it should not be is a dispatch question and is not answered here.
--
-- IT IS ALSO NOT BIZHAWK'S LUA. This runs under a desktop Lua 5.4, so it bounds the ALGORITHM and
-- says nothing about the host. The one question that genuinely needs the emulator -- whether a Lua
-- stack overflow inside pcall drops the message or takes BizHawk down -- has been open since
-- 2026-08-25 and needs a probe, not this.
--
-- HOW IT LOADS A SHIPPED DECODER WITHOUT EDITING IT. Each adapter is one long script that calls
-- BizHawk at load, so it cannot be require'd. But the decoder sits near the top, before any of
-- that: the PREFIX up to the end of jsonDecode is pure declarations. So the harness takes that
-- prefix, appends `return jsonDecode`, and loads it with a stub _ENV. The cut point is found
-- structurally (the first column-0 `end` after the function opens), never as a line number, so an
-- edit to the decoder cannot silently point this at the wrong text.
--
-- Run: lua5.4 adapters/emulator/tests/json_fuzz.lua

local ADAPTERS = {
    { name = "emerald", path = "adapters/emulator/pokemon/emerald/meshghost_emerald.lua" },
    { name = "crystal", path = "adapters/emulator/pokemon/crystal/meshghost_crystal.lua" },
}

-- A decode is run inside a coroutine with an instruction-count hook, so a runaway loop is a
-- REPORTED FAILURE rather than a hung CI job. This is the whole point: the 2026-08-25 bug was a
-- hang, and a harness that can only catch errors would have missed it exactly as pcall did.
local STEP_CAP = 4e6

-- The recursion depth a decoder may accept before refusing. 64 is Crystal's, chosen by its
-- 2026-08-25 fix and comfortably above anything a game sends -- every shipped adapter puts a FLAT
-- scalar map in extras (protocol/limits.go says so and refuses to recurse for that reason). The
-- cap matters because `extras` is bounded by SIZE (1024 bytes) and never by SHAPE: nested arrays
-- cost about a byte a level, so a peer fits several hundred levels into a message the relay
-- forwards without complaint.
local MAX_DEPTH = 64

local failures, checks = {}, 0

local function fail(fmt, ...)
    failures[#failures + 1] = string.format(fmt, ...)
end

----------------------------------------------------------------------------
-- Loading a shipped decoder
----------------------------------------------------------------------------

local function readFile(path)
    local f, err = io.open(path, "rb")
    if not f then
        return nil, err
    end
    local s = f:read("a")
    f:close()
    return s
end

-- stubEnv is the real standard library plus the few host globals the PREFIX touches at load time.
-- Everything else is absent on purpose: if a future edit moves a BizHawk call above the decoder,
-- this harness should fail loudly rather than quietly stub it out.
local function stubEnv()
    local env = {}
    for _, k in ipairs({
        "assert", "error", "ipairs", "next", "pairs", "pcall", "xpcall", "select", "setmetatable",
        "getmetatable", "rawget", "rawset", "rawequal", "rawlen", "tonumber", "tostring", "type",
        "unpack", "print", "string", "table", "math", "io", "os", "coroutine", "debug", "utf8",
        "load", "loadstring", "require", "package", "_VERSION",
    }) do
        env[k] = _G[k]
    end
    env._G = env
    -- console.log is reassigned at load by the Emerald adapter (it wraps the original to tee into
    -- a logfile), so the original has to exist and be callable.
    env.console = { log = function() end, clear = function() end }

    -- THE PLATFORM IS FAKED TO WINDOWS, and this is not optional. Both adapters call
    -- loadSocketCore() at file scope, well before the decoder, and it refuses outright unless
    -- package.config says Windows, _VERSION says Lua 5.4, and PROCESSOR_ARCHITECTURE contains 64 --
    -- then loads a vendored .dll. None of that is reachable on a Linux CI runner, and none of it
    -- has anything to do with parsing a line of JSON.
    --
    -- Found by CI, not locally: this harness passed on Windows, where the real package.config
    -- already starts with a backslash, and failed on the first push with "only Windows is supported
    -- by the vendored LuaSocket binary so far". A harness that only runs on its author's platform is
    -- a harness that stops running the moment it moves.
    --
    -- Faked UNCONDITIONALLY rather than only on Linux, so the harness exercises the same path
    -- everywhere and a Windows pass means what a Linux pass means.
    env.package = setmetatable({
        config = "\\\n;\n?\n!\n-\n", -- Windows separators, the shape loadSocketCore tests
        loadlib = function()
            -- A loader whose result is the socket module. Nothing here calls it: the socket is used
            -- by the bridge loop, thousands of lines past the decoder.
            return function()
                return {}
            end
        end,
    }, { __index = package })

    env.os = setmetatable({
        getenv = function(name)
            if name == "PROCESSOR_ARCHITECTURE" then
                return "AMD64"
            end
            return os.getenv(name)
        end,
    }, { __index = os })

    -- io.open is proxied so a WRITE never touches the disk. Both adapters open a log file at load,
    -- and running this from the repo root made them scatter nine meshghost_crystal_*.log files into
    -- it -- committed once, on 2026-09-03, before this was noticed. A harness that litters the tree
    -- it is checking is a harness that will be run less often. Reads pass through untouched: the
    -- prefix probes for a config.json, and finding none is a legitimate outcome it handles.
    local sink = {
        write = function(self) return self end,
        close = function() return true end,
        flush = function() return true end,
        setvbuf = function() return true end,
        lines = function() return function() return nil end end,
        read = function() return nil end,
        seek = function() return 0 end,
    }
    env.io = setmetatable({
        open = function(path, mode)
            if mode and mode:find("[wa+]") then
                return sink
            end
            return io.open(path, mode)
        end,
    }, { __index = io })
    return env
end

-- decoderPrefix returns the source text up to and including the end of jsonDecode.
local function decoderPrefix(src, path)
    local lines = {}
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    local start
    for i, line in ipairs(lines) do
        if line:match("^local function jsonDecode%s*%(") or line:match("^local jsonDecode%s*=%s*function") then
            start = i
            break
        end
    end
    if not start then
        return nil, path .. ": no top-level `local function jsonDecode(` -- the decoder was renamed or moved"
    end
    for i = start + 1, #lines do
        if lines[i]:match("^end%s*$") then
            return table.concat(lines, "\n", 1, i), nil, i
        end
    end
    return nil, path .. ": jsonDecode opens at line " .. start .. " and never closes at column 0"
end

local function loadDecoder(a)
    local src, err = readFile(a.path)
    if not src then
        return nil, a.path .. ": " .. tostring(err)
    end
    local prefix, perr, endLine = decoderPrefix(src, a.path)
    if not prefix then
        return nil, perr
    end
    local chunk = prefix .. "\nreturn jsonDecode\n"
    local fn, lerr = load(chunk, "@" .. a.path, "t", stubEnv())
    if not fn then
        return nil, a.path .. ": the prefix does not compile: " .. tostring(lerr)
    end
    local ok, decode = pcall(fn)
    if not ok then
        return nil, a.path .. ": the prefix does not RUN: " .. tostring(decode)
    end
    if type(decode) ~= "function" then
        return nil, a.path .. ": jsonDecode is a " .. type(decode) .. ", not a function"
    end
    return decode, nil, endLine
end

----------------------------------------------------------------------------
-- Running one decode under a step cap
----------------------------------------------------------------------------

-- call returns: status ("ok" | "error" | "runaway"), value-or-message.
-- "runaway" means the decoder used more than STEP_CAP VM instructions on one line, which is what a
-- non-terminating parse looks like from outside. In BizHawk that is a frozen emulator.
local function call(decode, line)
    checks = checks + 1
    local co = coroutine.create(decode)
    debug.sethook(co, function()
        error("step cap: " .. STEP_CAP .. " instructions", 2)
    end, "", STEP_CAP)
    local ok, res = coroutine.resume(co, line)
    debug.sethook(co)
    if ok then
        return "ok", res
    end
    if tostring(res):find("step cap", 1, true) then
        return "runaway", res
    end
    return "error", res
end

-- A decoder must always come back. Anything that neither returns nor raises is the 2026-08-25 bug.
local function mustTerminate(name, label, decode, line)
    local status, res = call(decode, line)
    if status == "runaway" then
        fail("%s: %s DID NOT TERMINATE (%s) on %q", name, label, res, line:sub(1, 80))
        return nil, false
    end
    if status == "error" then
        -- jsonDecode's own pcall should have absorbed this. An error escaping means the wrapper is
        -- not covering the whole parse.
        fail("%s: %s raised past jsonDecode's own pcall: %s (input %q)", name, label, tostring(res), line:sub(1, 80))
        return nil, false
    end
    return res, true
end

----------------------------------------------------------------------------
-- The corpus
----------------------------------------------------------------------------

-- Valid lines, run as a CONTROL in the same pass. Without them "everything returned nil" reads as
-- a clean run instead of a decoder that stopped decoding -- the 2026-08-25 note makes this point
-- explicitly, and it is the same failure this repo hit with a fuzz generator on 2026-09-03.
local VALID = {
    ['{"type":"bridge_ready"}'] = function(v) return type(v) == "table" and v.type == "bridge_ready" end,
    ['{"type":"despawn_remote","payload":{"player_id":"p1"}}'] = function(v)
        return type(v) == "table" and v.payload and v.payload.player_id == "p1"
    end,
    ['{"type":"render_remote","payload":{"player_id":"p1","position":[1.5,-2.25],"area_id":"a","anim":"run"}}'] = function(v)
        local p = type(v) == "table" and v.payload
        return p and p.position and p.position[1] == 1.5 and p.position[2] == -2.25 and p.anim == "run"
    end,
    ['{"a":"\\u0041\\n\\t\\"x\\\\"}'] = function(v) return type(v) == "table" and v.a == 'A\n\t"x\\' end,
    ['{"n":-1.5e3,"t":true,"f":false,"z":null,"arr":[1,null,3]}'] = function(v)
        return type(v) == "table" and v.n == -1500 and v.t == true and v.f == false and v.arr[1] == 1
    end,
    ['{"extras":{"a":1,"b":{"c":2}}}'] = function(v)
        return type(v) == "table" and v.extras and v.extras.b and v.extras.b.c == 2
    end,
    ['{}'] = function(v) return type(v) == "table" end,
    ['{"e":[]}'] = function(v) return type(v) == "table" and type(v.e) == "table" end,
}

-- Lines that must be REFUSED -- nil, not a value, and never a hang. These are the shapes that
-- either truncate mid-structure or are not JSON at all. The truncations are the class that froze
-- BizHawk on 2026-08-25.
local MUST_REFUSE = {
    "", " ", "\n", "{", "[", "{\"", '{"a', '{"a"', '{"a":', '{"a":1', '{"a":1,', '{"a":1,}',
    "[1", "[1,", "[,]", "[[[", '{"a":[1,2', '{"a":{"b":', "tru", "fals", "nul", "-",
    "--1", "1e", '{"a":"\\', '{"a":"unterminated', "}", "]", ",", ":", '{"a" 1}', '{"a":1 "b":2}',
    '{:1}', '{"a":,}', string.rep("{", 200), string.rep("[", 200),
}

-- Lines a STRICT JSON parser would refuse but these decoders accept. REPORTED, never failed.
-- Every one is leniency toward input our own core would never emit, none of them hangs, and a
-- harness that fails on harmless leniency is a harness somebody switches off. They are listed so
-- the leniency is a recorded fact rather than an unexamined one.
local LENIENT = {
    "0x10",             -- Lua's tonumber takes hex; JSON does not
    '{"a":01}',         -- leading zeros
    '{"a":+1}',
    '{"a":.5}',
    "nan",
    '{"a":"\0"}',       -- an unescaped control character inside a string
    '{"a":"\\uZZZZ"}',  -- a malformed \u escape
}


-- CATEGORY 1 of the shared adversarial corpus (adapters/_template/README.md, "every field in a
-- render_remote came from a stranger"): WRONG TYPE FOR EVERY FIELD. A field that should be a
-- number arrives as a string, a bool, null, an array or an object, and vice versa.
--
-- These must DECODE, and decode to what the JSON actually said. That is the honest boundary of a
-- decoder test: the decoder's job is to report the type faithfully, and REJECTING it is the
-- dispatch's job. The value here is that it pins the shape the dispatch has to survive -- and this
-- is exactly the class Emerald's gender bug lived in, where a table arrived where a string was
-- expected and every peer sorted after it stopped drawing.
local WRONG_TYPES = {
    ['{"payload":{"player_id":123}}'] = function(v) return type(v.payload.player_id) == "number" end,
    ['{"payload":{"player_id":null}}'] = function(v) return v.payload.player_id == nil end,
    ['{"payload":{"player_id":[1,2]}}'] = function(v) return type(v.payload.player_id) == "table" end,
    ['{"payload":{"player_id":{"a":1}}}'] = function(v) return type(v.payload.player_id) == "table" end,
    ['{"payload":{"player_id":true}}'] = function(v) return v.payload.player_id == true end,
    ['{"extras":{"gender":{"a":1}}}'] = function(v) return type(v.extras.gender) == "table" end,
    ['{"extras":{"gender":42}}'] = function(v) return type(v.extras.gender) == "number" end,
    ['{"extras":{"act":"seven"}}'] = function(v) return v.extras.act == "seven" end,
    ['{"extras":{"sprite":true}}'] = function(v) return v.extras.sprite == true end,
    ['{"extras":"not a table"}'] = function(v) return v.extras == "not a table" end,
    ['{"extras":[1,2,3]}'] = function(v) return type(v.extras) == "table" end,
    ['{"position":"nope"}'] = function(v) return v.position == "nope" end,
    ['{"position":[]}'] = function(v) return type(v.position) == "table" and v.position[1] == nil end,
    ['{"position":[1]}'] = function(v) return v.position[1] == 1 and v.position[2] == nil end,
    ['{"position":["a","b"]}'] = function(v) return v.position[1] == "a" end,
    ['{"anim":123}'] = function(v) return v.anim == 123 end,
    ['{"area_id":[]}'] = function(v) return type(v.area_id) == "table" end,
}

-- CATEGORY 2: EXTREME NUMERICS, high and low. Each type's boundaries and the values just past
-- them, plus the ones a peer reaches legally: 1e999 is VALID JSON and the relay forwards it, so
-- inf arrives without anyone writing "inf". Reported rather than failed, because what the decoder
-- returns is the truth about the wire -- the question this raises is what each adapter DOES with
-- a non-finite extras value, and neither of them clamps most of them yet.
local EXTREMES = {
    "0", "-0", "1", "-1", "255", "256", "-1e-3",
    "2147483647", "2147483648", "-2147483649", "9007199254740993",
    "3.4028235e38", "1e300", "1e308", "1e309", "1e999", "-1e999", "1e-999",
}
-- A nested value of the given depth, which is what a peer can actually send: extras is bounded by
-- SIZE (1024 bytes) and never by SHAPE, and a nested array costs about one byte per level, so
-- several hundred levels fit inside a message the relay forwards without complaint.
local function nest(depth, open, close)
    return string.rep(open, depth) .. string.rep(close, depth)
end

----------------------------------------------------------------------------
-- The run
----------------------------------------------------------------------------

local report = {}

for _, a in ipairs(ADAPTERS) do
    local decode, err, endLine = loadDecoder(a)
    if not decode then
        fail("%s: %s", a.name, err)
        goto continue
    end
    report[#report + 1] = string.format("%s: decoder loaded (prefix ends line %d)", a.name, endLine)

    -- 1. The control. Valid input must still parse to the right values.
    for line, want in pairs(VALID) do
        local v, ok = mustTerminate(a.name, "valid input", decode, line)
        if ok then
            if v == nil then
                fail("%s: VALID input was refused: %s", a.name, line)
            elseif not want(v) then
                fail("%s: VALID input decoded to the wrong value: %s", a.name, line)
            end
        end
    end

    -- 2. Malformed lines: refused, never accepted, never hung.
    for _, line in ipairs(MUST_REFUSE) do
        local v, ok = mustTerminate(a.name, "malformed input", decode, line)
        if ok and v ~= nil and line ~= "" then
            fail("%s: malformed input ACCEPTED: %q -> %s", a.name, line:sub(1, 60), type(v))
        end
    end

    -- 2b. Leniency: recorded, not failed.
    local lenient = 0
    for _, line in ipairs(LENIENT) do
        local v, ok = mustTerminate(a.name, "lenient input", decode, line)
        if ok and v ~= nil then
            lenient = lenient + 1
        end
    end
    report[#report + 1] = string.format("%s: accepts %d/%d non-strict input(s) -- leniency, not a fault", a.name, lenient, #LENIENT)


    -- 2c. WRONG TYPE FOR EVERY FIELD (corpus category 1). These must DECODE, and decode to what
    -- the JSON said. A decoder that quietly coerces is worse than one that refuses, because the
    -- dispatch then guards a type that never arrives.
    for line, want in pairs(WRONG_TYPES) do
        local v, ok = mustTerminate(a.name, "wrong type", decode, line)
        if ok then
            if v == nil then
                fail("%s: a wrong-typed but VALID line was refused: %s", a.name, line)
            elseif not want(v) then
                fail("%s: wrong-typed line decoded to something else: %s", a.name, line)
            end
        end
    end

    -- 2d. EXTREME NUMERICS (corpus category 2). Reported, not failed: what comes back is the truth
    -- about the wire. 1e999 is valid JSON, so a peer reaches infinity without writing "inf" --
    -- which is why the adapters, not the decoder, are where this has to be bounded.
    local nonfinite = {}
    for _, raw in ipairs(EXTREMES) do
        local line = string.format('{"extras":{"v":%s}}', raw)
        local v, ok = mustTerminate(a.name, "extreme number", decode, line)
        if ok and type(v) == "table" and type(v.extras) == "table" then
            local n = v.extras.v
            if type(n) == "number" and (n ~= n or n == math.huge or n == -math.huge) then
                nonfinite[#nonfinite + 1] = raw
            end
        end
    end
    if #nonfinite > 0 then
        report[#report + 1] = string.format(
            "%s: %d/%d extreme number(s) decode NON-FINITE (%s) -- valid JSON, so an adapter must bound them",
            a.name, #nonfinite, #EXTREMES, table.concat(nonfinite, ", "))
    end
    -- 3. Every truncation of every valid line. This is what found the original bug.
    for line in pairs(VALID) do
        for cut = 1, #line - 1 do
            mustTerminate(a.name, "truncation", decode, line:sub(1, cut))
        end
    end

    -- 4. DEPTH. The measured exposure: extras is size-bounded, never shape-bounded, so a peer can
    -- send several hundred levels of nesting inside 1KB. A decoder must refuse it, not recurse
    -- until the stack gives out.
    local depths = { 8, 16, 32, 64, 65, 100, 200, 490, 1000, 5000 }
    local deepest = 0
    for _, d in ipairs(depths) do
        for _, pair in ipairs({ { "[", "]" }, { '{"a":', "}" } }) do
            local line = nest(d, pair[1], pair[2])
            if pair[1] ~= "[" then
                line = string.rep('{"a":', d) .. "1" .. string.rep("}", d)
            end
            local status, res = call(decode, line)
            if status == "runaway" then
                fail("%s: depth %d DID NOT TERMINATE -- in BizHawk that is a frozen emulator", a.name, d)
            elseif status == "error" then
                fail("%s: depth %d raised past jsonDecode's own pcall: %s", a.name, d, tostring(res))
            elseif res ~= nil then
                deepest = math.max(deepest, d)
            end
        end
    end
    report[#report + 1] = string.format("%s: deepest nesting ACCEPTED = %d (cap %d)", a.name, deepest, MAX_DEPTH)
    if deepest > MAX_DEPTH then
        fail("%s: accepts nesting %d deep, cap is %d -- extras is bounded by SIZE and never by SHAPE, "
            .. "so a peer fits several hundred levels inside the 1KB the relay forwards without complaint",
            a.name, deepest, MAX_DEPTH)
    end

    ::continue::
end

----------------------------------------------------------------------------

for _, line in ipairs(report) do
    print("  " .. line)
end
print(string.format("  %d decode(s) run across %d adapter(s)", checks, #ADAPTERS))

if #failures > 0 then
    print(string.format("\nFAIL: %d problem(s)", #failures))
    for _, f in ipairs(failures) do
        print("  - " .. f)
    end
    os.exit(1)
end
print("\nOK: every decoder terminated, valid input still parses, hostile input is refused.")
