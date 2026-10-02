-- json_fuzz.lua -- hostile input against the shipped bridge JSON decoders, offline.
--
-- It reaches the decoder only: each adapter's dispatch sits past where the file starts calling BizHawk. It runs under
-- desktop Lua 5.4, so it bounds the algorithm and says nothing about BizHawk's own Lua.
-- An adapter calls BizHawk at load and cannot be require'd, so the harness loads its prefix up to the end of
-- jsonDecode, which needs only the host globals stubEnv fakes, with `return jsonDecode` appended.
--
-- Run: lua5.4 adapters/emulator/tests/json_fuzz.lua

local ADAPTERS = {
    { name = "emerald", path = "adapters/emulator/pokemon/emerald/meshghost_emerald.lua" },
    { name = "crystal", path = "adapters/emulator/pokemon/crystal/meshghost_crystal.lua" },
}

-- Each decode runs in a coroutine under an instruction-count hook, so a runaway loop is a reported failure rather
-- than a hung job: pcall catches errors, and a hang raises nothing.
local STEP_CAP = 4e6

-- Crystal's cap, far above anything a game sends: a decoder must refuse deep nesting itself, not recurse until the
-- stack gives out.
local MAX_DEPTH = 64

local failures, checks = {}, 0

local function fail(fmt, ...)
    failures[#failures + 1] = string.format(fmt, ...)
end

local function readFile(path)
    local f, err = io.open(path, "rb")
    if not f then
        return nil, err
    end
    local s = f:read("a")
    f:close()
    return s
end

-- stubEnv is the real standard library plus the few host globals the prefix touches at load. Any other BizHawk API is
-- absent on purpose, so a call moved above the decoder fails loudly instead of being stubbed out.
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
    -- The Emerald adapter wraps console.log at load to tee into its log file, so the original must exist.
    env.console = { log = function() end, clear = function() end }

    -- Faked to 64-bit Windows on every platform: both adapters call loadSocketCore at file scope, before the decoder,
    -- and it refuses anything else. Unconditional, so a Windows pass means what a Linux runner's pass means.
    env.package = setmetatable({
        config = "\\\n;\n?\n!\n-\n", -- Windows separators, the shape loadSocketCore tests
        loadlib = function()
            -- Never called: the socket is used by the bridge loop, past the decoder.
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

    -- Writes go to a sink, or the log files both adapters open at load land in the working directory. Reads pass
    -- through: the prefix looks for a config.json and handles finding none.
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

-- decoderPrefix returns the source up to the first column-0 `end` after jsonDecode opens: found by structure, never
-- by line number, so an edit to the decoder cannot point this at the wrong text.
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

-- call returns "ok", "error" or "runaway" and the value or message. A runaway took more than STEP_CAP instructions on
-- one line: a parse that never ends, which in BizHawk is a frozen emulator.
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

local function mustTerminate(name, label, decode, line)
    local status, res = call(decode, line)
    if status == "runaway" then
        fail("%s: %s DID NOT TERMINATE (%s) on %q", name, label, res, line:sub(1, 80))
        return nil, false
    end
    if status == "error" then
        fail("%s: %s raised past jsonDecode's own pcall: %s (input %q)", name, label, tostring(res), line:sub(1, 80))
        return nil, false
    end
    return res, true
end

-- The control: without it, "everything returned nil" reads as a clean run instead of a decoder that stopped decoding.
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
    -- A malformed \u escape must cost one character, not the message: the field after it must still decode.
    ['{"a":"x\\uZZ","b":7}'] = function(v)
        return type(v) == "table" and v.b == 7
    end,
    ['{"a":"x\\u00","b":7}'] = function(v)
        return type(v) == "table" and v.b == 7
    end,
    ['{"a":"x\\u","b":7}'] = function(v)
        return type(v) == "table" and v.b == 7
    end,
    -- A well-formed one still decodes, or the three above would pass on a decoder that ignores \u.
    ['{"a":"R\\u0026B","b":7}'] = function(v)
        return type(v) == "table" and v.a == "R&B" and v.b == 7
    end,
}

local MUST_REFUSE = {
    "", " ", "\n", "{", "[", "{\"", '{"a', '{"a"', '{"a":', '{"a":1', '{"a":1,', '{"a":1,}',
    "[1", "[1,", "[,]", "[[[", '{"a":[1,2', '{"a":{"b":', "tru", "fals", "nul", "-",
    "--1", "1e", '{"a":"\\', '{"a":"unterminated', "}", "]", ",", ":", '{"a" 1}', '{"a":1 "b":2}',
    '{:1}', '{"a":,}', string.rep("{", 200), string.rep("[", 200),
}

-- Accepted by these decoders, refused by a strict parser: reported, never failed, since the core never emits them.
local LENIENT = {
    "0x10",             -- Lua's tonumber takes hex; JSON does not
    '{"a":01}',         -- leading zeros
    '{"a":+1}',
    '{"a":.5}',
    "nan",
    '{"a":"\0"}',       -- an unescaped control character inside a string
    '{"a":"\\uZZZZ"}',  -- a malformed \u escape
}


-- Corpus category 1, the wrong type for every field: each must decode to what the JSON said, since rejecting it is
-- the dispatch's job, and a decoder that coerces leaves the dispatch guarding a type that never arrives.
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

-- Corpus category 2, extreme numerics: reported, not failed. 1e999 is valid JSON, so a peer reaches infinity without
-- writing inf, and bounding it is each adapter's job, not the decoder's.
local EXTREMES = {
    "0", "-0", "1", "-1", "255", "256", "-1e-3",
    "2147483647", "2147483648", "-2147483649", "9007199254740993",
    "3.4028235e38", "1e300", "1e308", "1e309", "1e999", "-1e999", "1e-999",
}
local function nest(depth, open, close)
    return string.rep(open, depth) .. string.rep(close, depth)
end

local report = {}

for _, a in ipairs(ADAPTERS) do
    local decode, err, endLine = loadDecoder(a)
    if not decode then
        fail("%s: %s", a.name, err)
        goto continue
    end
    report[#report + 1] = string.format("%s: decoder loaded (prefix ends line %d)", a.name, endLine)

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

    for _, line in ipairs(MUST_REFUSE) do
        local v, ok = mustTerminate(a.name, "malformed input", decode, line)
        if ok and v ~= nil and line ~= "" then
            fail("%s: malformed input ACCEPTED: %q -> %s", a.name, line:sub(1, 60), type(v))
        end
    end

    local lenient = 0
    for _, line in ipairs(LENIENT) do
        local v, ok = mustTerminate(a.name, "lenient input", decode, line)
        if ok and v ~= nil then
            lenient = lenient + 1
        end
    end
    report[#report + 1] = string.format("%s: accepts %d/%d non-strict input(s) -- leniency, not a fault", a.name, lenient, #LENIENT)


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
    for line in pairs(VALID) do
        for cut = 1, #line - 1 do
            mustTerminate(a.name, "truncation", decode, line:sub(1, cut))
        end
    end

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
