-- Phase 3: loopback. Sends the local player's real state through the actual Go networking
-- layer (bridge -> core -> relay -> core -> bridge) and draws whatever comes back as a
-- trailing ghost. With a real second player absent (that's Phase 4), the relay's dev-only
-- `-loopback` flag (internal/relay/relay.go, agent_docs/phases/phase3.md) echoes this
-- client's own state back under a synthetic "<id>-ghost" player_id, so this script exercises
-- the full round trip -- and real core-side interpolation -- with only one BizHawk instance.
-- Never writes memory.
--
-- This is the first script in the project that opens a socket at all. Per
-- agent_docs/contract.md's "two protocols" section, this socket is to the *local core
-- process only* (127.0.0.1, the bridge port) -- it never learns a relay address and never
-- speaks the relay protocol directly. The core is the only thing that talks to the relay.
--
-- State reading: same addresses as adapters/pokemon/emerald/phase1_probe.lua (gSaveBlock1Ptr,
-- gPlayerAvatar, gObjectEvents), same pokeemerald citations, not re-derived here.
-- Screen-position anchor: same formula as adapters/pokemon/emerald/phase2_ghost.lua (gSprites,
-- gSpriteCoordOffsetX/Y), reused rather than reimplemented -- see that script's header for
-- the exact addresses and source citations.
--
-- Ghost placement for a REMOTE player (new in this phase, since Phase 2 only ever drew an
-- offset from the LOCAL player's own screen position): the remote's map-tile position differs
-- from the local player's, so screen placement can't reuse Phase 2's formula unmodified. This
-- deliberately does not re-derive camera-scroll math independently (the actual risk Phase 2's
-- edge-of-map test was designed to retire, for the LOCAL player only) -- instead it anchors on
-- the already-verified local player screen position and adds the tile-space delta between the
-- remote and the local player, scaled by TILE:
--   ghostScreenX = playerScreenX + (ghostMapX - playerMapX) * TILE
--   ghostScreenY = playerScreenY + (ghostMapY - playerMapY) * TILE
-- TILE = 16 (GBA tile size) is ASSUMED, NOT YET CONFIRMED ON SCREEN -- the on-screen test is
-- "one tile of player movement moves the loopback ghost by the same screen distance", per
-- agent_docs/phases/phase3.md. If it's off, this is the constant to fix.
--
-- LuaSocket: vendored binary, not BizHawk's own comm.* (see agent_docs/licensing.md and the
-- Phase 3 ADR in agent_docs/architecture.md for why: comm.* uses a length-prefixed framing
-- that would leak into every future adapter's bridge protocol; LuaSocket keeps the bridge as
-- plain NDJSON like every other adapter will speak). Loaded directly from its compiled core
-- (luaopen_socket_core) -- confirmed by reading connector_bizhawk_generic.lua
-- (C:\dev\Archipelago\data\lua\connector_bizhawk_generic.lua, MIT, see licensing.md) that
-- socket.tcp()/:connect()/:send()/:receive()/:settimeout()/:close() all come from that raw
-- core, so no LuaSocket wrapper module needs vendoring, only the .dll.

local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
local GSPRITECOORDOFFSETX_ADDR = 0x02021bbc
local GSPRITECOORDOFFSETY_ADDR = 0x02021bbe

local TILE = 16 -- ASSUMED, see header. Confirm on screen before trusting.
local GHOST_IMAGE_SIZE = 16

local BRIDGE_HOST = "127.0.0.1"
local BRIDGE_PORT = 7778

local FACING = { [1] = "south", [2] = "north", [3] = "west", [4] = "east" }

----------------------------------------------------------------------------
-- Paths, resolved relative to this script's own location. NOT via
-- debug.getinfo(1, "S").source, despite that being the more obviously
-- "correct" API for this -- confirmed live (2026-08-11) that it doesn't
-- work here: BizHawk reads the script file's *text* in C# and loads it as
-- an in-memory Lua chunk named literally "main" (`LuaLibraries.cs`:
-- `_lua.LoadString(File.ReadAllText(file), "main")`), not via a file-path
-- load -- so debug.getinfo's source is just the bare string "main", no `@`
-- prefix, which is also exactly why an unhandled error shows as
-- `[string "main"]:N:` rather than a real file path (Lua's own standard
-- formatting for a chunk name without an `@`/`=` prefix). Using this
-- (wrong) approach silently resolved every path in this section to "./"
-- and caused the first live failure, which looked like a missing DLL
-- dependency but was actually just a wrong path.
--
-- Fixed the same way agent_docs/licensing.md's cited reference script
-- (Archipelago's socket.lua) already does, for the identical reason its
-- own comment states ("for some reason ./ isn't working, so use a horrible
-- hack to get the pwd") -- confirmed BizHawk does set the real Win32
-- process working directory to the script's own directory before running
-- it (`LuaSandbox.cs`'s `Sandbox()` calls `CoolSetCurrentDirectory`, which
-- for Windows calls `CWDHacks.Set`, a direct P/Invoke of the real
-- `SetCurrentDirectoryW` -- confirmed by reading `CWDHacks.cs`, not
-- assumed), so asking the OS for its own current directory via a spawned
-- shell command is a reliable source of truth here, unlike deriving it
-- from Lua-level chunk metadata that BizHawk's loading path doesn't
-- populate the way a `dofile`/`loadfile`-based host would.
----------------------------------------------------------------------------

local function scriptDir()
    local pwd = io.popen and io.popen("cd"):read("*l")
    if not pwd or pwd == "" then
        error("MeshGhost Phase 3: could not determine the script's own directory (io.popen \"cd\" unavailable or returned nothing).")
    end
    return pwd .. "\\"
end

local SCRIPT_DIR = scriptDir()
local GHOST_IMAGE_PATH = SCRIPT_DIR .. "assets/ghost_placeholder.bmp"

----------------------------------------------------------------------------
-- LuaSocket: load the compiled core directly. Windows/x64/Lua 5.4 only for
-- now -- matches the confirmed environment in agent_docs/environment.md;
-- fails loudly rather than guessing at an unverified combination.
----------------------------------------------------------------------------

-- socket-windows-5-4.dll imports lua54.dll by name (confirmed by inspecting
-- its PE import table, 2026-08-11). Windows' plain LoadLibrary (which is
-- what package.loadlib calls -- confirmed against Lua's own loadlib.c,
-- lsys_load, LUA_LLE_FLAGS defaults to 0) resolves a loaded DLL's own
-- dependencies via the OS's standard search order, which does NOT include
-- the directory the DLL being loaded lives in -- confirmed empirically
-- (not guessed): loading the vendored .dll alone from a directory that
-- also contains a copy of lua54.dll still failed with the exact same
-- "specified module could not be found" error this script hit live. What
-- DOES fix it, confirmed the same way: explicitly pre-loading lua54.dll by
-- its own full path *before* loading the socket module -- Windows' loader
-- reuses an already-loaded module of the same name for a later module's
-- dependency resolution, regardless of which directory either came from.
-- The vendored copy here is byte-identical to the one already running
-- inside BizHawk (copied directly from the user's own install, not
-- independently built) specifically so this pre-load binds to a
-- compatible instance -- see agent_docs/licensing.md and the Phase 3 ADR
-- in agent_docs/architecture.md.
local function preloadLua54()
    -- Symbol lookup is expected to fail (we don't know or need a real
    -- exported name) -- that's fine and deliberate: Lua's own loadlib.c
    -- keeps the library loaded (registered in its C-library cache) even
    -- when the requested symbol isn't found; only the LoadLibrary side
    -- effect is wanted here. Wrapped in pcall since a failed symbol lookup
    -- surfaces as a Lua error, not just a nil return.
    pcall(function()
        package.loadlib(SCRIPT_DIR .. "lib/x64/lua54.dll", "meshghost_force_preload")
    end)
end

local function loadSocketCore()
    if package.config:sub(1, 1) ~= "\\" then
        error("MeshGhost Phase 3: only Windows is supported by the vendored LuaSocket binary so far.")
    end
    local luaMajor, luaMinor = _VERSION:match("Lua (%d+)%.(%d+)")
    if luaMajor ~= "5" or luaMinor ~= "4" then
        error("MeshGhost Phase 3: only Lua 5.4 is supported by the vendored LuaSocket binary so far (got " .. _VERSION .. ").")
    end
    local arch = os.getenv("PROCESSOR_ARCHITECTURE") or ""
    if not arch:find("64") then
        error("MeshGhost Phase 3: only x64 is supported by the vendored LuaSocket binary so far.")
    end
    preloadLua54()
    local dllPath = SCRIPT_DIR .. "lib/x64/socket-windows-5-4.dll"
    return assert(package.loadlib(dllPath, "luaopen_socket_core"))()
end

local socketCore = loadSocketCore()

----------------------------------------------------------------------------
-- Minimal JSON, written for this project (agent_docs/licensing.md). Not a
-- general-purpose library: the encoder only ever produces the shapes the
-- bridge protocol needs (internal/bridge.LocalState); the decoder only
-- ever needs to parse what our own Go core sends back
-- (RenderRemote/DespawnRemote), which is always canonical, unindented
-- output from encoding/json -- not untrusted network input (that boundary
-- is the relay's job, enforced server-side per contract.md's Limits
-- section, not the adapter's).
----------------------------------------------------------------------------

local function jsonString(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
    return '"' .. s .. '"'
end

-- encodeLocalState builds the bridge.Envelope{Type: "local_state", ...} wire
-- form directly (internal/bridge/bridge.go). player_id/seq/timestamp are
-- left out: the core stamps those itself on every forward
-- (internal/core/core.go's onAdapterFrame), so the adapter never needs to
-- track them.
local function encodeLocalState(areaId, x, y, orientation, anim)
    return string.format(
        '{"type":"local_state","payload":{"state":{"area_id":%s,"position":[%s,%s],"orientation":%s,"anim":%s}}}',
        jsonString(areaId), tostring(x), tostring(y), jsonString(orientation), jsonString(anim))
end

local ENCODED_NO_SEND = '{"type":"local_state","payload":{"state":null}}'

local decodeValue -- forward declaration

local function skipWs(s, i)
    local _, j = s:find("^[ \t\r\n]*", i)
    return j + 1
end

local function decodeString(s, i)
    local j = i + 1
    local out = {}
    while true do
        local c = s:sub(j, j)
        if c == "" then
            error("json: unterminated string")
        elseif c == '"' then
            return table.concat(out), j + 1
        elseif c == "\\" then
            local e = s:sub(j + 1, j + 1)
            if e == "n" then table.insert(out, "\n")
            elseif e == "t" then table.insert(out, "\t")
            elseif e == "r" then table.insert(out, "\r")
            elseif e == "u" then
                local hex = s:sub(j + 2, j + 5)
                table.insert(out, string.char(tonumber(hex, 16) % 256))
                j = j + 4
            else
                table.insert(out, e) -- covers \" \\ \/ and anything unexpected verbatim
            end
            j = j + 2
        else
            table.insert(out, c)
            j = j + 1
        end
    end
end

local function decodeNumber(s, i)
    local _, j, num = s:find("^(-?%d+%.?%d*[eE]?[%+%-]?%d*)", i)
    if not num then error("json: expected number") end
    return tonumber(num), j + 1
end

local function decodeObject(s, i)
    local obj = {}
    i = skipWs(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
        local key
        key, i = decodeString(s, i)
        i = skipWs(s, i)
        if s:sub(i, i) ~= ":" then error("json: expected ':'") end
        i = skipWs(s, i + 1)
        local val
        val, i = decodeValue(s, i)
        obj[key] = val
        i = skipWs(s, i)
        local c = s:sub(i, i)
        if c == "," then
            i = skipWs(s, i + 1)
        elseif c == "}" then
            return obj, i + 1
        else
            error("json: expected ',' or '}'")
        end
    end
end

local function decodeArray(s, i)
    local arr = {}
    i = skipWs(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
        local val
        val, i = decodeValue(s, i)
        table.insert(arr, val)
        i = skipWs(s, i)
        local c = s:sub(i, i)
        if c == "," then
            i = skipWs(s, i + 1)
        elseif c == "]" then
            return arr, i + 1
        else
            error("json: expected ',' or ']'")
        end
    end
end

decodeValue = function(s, i)
    i = skipWs(s, i)
    local c = s:sub(i, i)
    if c == "{" then return decodeObject(s, i)
    elseif c == "[" then return decodeArray(s, i)
    elseif c == '"' then return decodeString(s, i)
    elseif c == "t" then
        if s:sub(i, i + 3) ~= "true" then error("json: bad literal") end
        return true, i + 4
    elseif c == "f" then
        if s:sub(i, i + 4) ~= "false" then error("json: bad literal") end
        return false, i + 5
    elseif c == "n" then
        if s:sub(i, i + 3) ~= "null" then error("json: bad literal") end
        return nil, i + 4
    else
        return decodeNumber(s, i)
    end
end

-- jsonDecode returns nil on any parse failure -- a malformed line is
-- dropped, same forward-compatibility posture the relay and core already
-- apply to unknown fields/types (agent_docs/contract.md).
local function jsonDecode(line)
    local ok, val = pcall(function()
        local v = decodeValue(line, 1)
        return v
    end)
    if not ok then return nil end
    return val
end

----------------------------------------------------------------------------
-- Bridge connection: non-blocking TCP to the local core, NDJSON framing.
-- LuaSocket buffers partial lines internally across receive() calls -- a
-- non-blocking receive() returns nil, "timeout" until a full line has
-- arrived, so no manual partial-buffer bookkeeping is needed here (checked
-- against connector_bizhawk_generic.lua's send_receive, which relies on
-- the same behavior).
----------------------------------------------------------------------------

local sock = nil
local connected = false

-- Non-blocking connect: the first call starts the OS-level connect; while
-- it's still in progress, repeated connect() calls return nil, "timeout"
-- (retry), and once it completes in the background a repeated call returns
-- nil, "already connected" (LuaSocket's PIE_ISCONN, from a real EISCONN --
-- confirmed against src/pierror.h and src/usocket.c at
-- github.com/lunarmodules/luasocket, 2026-08-11, not assumed from memory).
local function connectBridge()
    if not sock then
        sock = socketCore.tcp()
        sock:settimeout(0)
    end
    local ok, err = sock:connect(BRIDGE_HOST, BRIDGE_PORT)
    if ok == 1 or err == "already connected" then
        connected = true
    end
    -- Any other result (typically nil, "timeout") just means: try again
    -- next frame.
end

local function resetBridge()
    if connected then
        console.log("MeshGhost Phase 3: bridge connection lost, will retry connecting.")
    end
    if sock then pcall(function() sock:close() end) end
    sock = nil
    connected = false
end

local function sendLine(line)
    local ok, err = sock:send(line .. "\n")
    if not ok and err ~= "timeout" then
        resetBridge()
    end
end

----------------------------------------------------------------------------
-- Local state reading. Same addresses/citations as phase1_probe.lua.
----------------------------------------------------------------------------

local lastMapGroup, lastMapNum = nil, nil

-- mapJustChanged debounces the one-frame gSaveBlock1Ptr-relocation
-- transient the contract's closed open question calls out
-- (agent_docs/contract.md): the frame a map transition is first observed,
-- the read is untrusted, not the frame after.
local function mapJustChanged(mapGroup, mapNum)
    local changed = lastMapGroup ~= nil and (mapGroup ~= lastMapGroup or mapNum ~= lastMapNum)
    lastMapGroup, lastMapNum = mapGroup, mapNum
    return changed
end

-- getLocalState returns a table {areaId, x, y, orientation, anim} or nil
-- (meaning "don't send this frame" -- no save loaded, or the map-transition
-- debounce frame).
local function getLocalState()
    local base = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
    if base == 0 then return nil end

    local x = memory.read_s16_le(base + 0x00)
    local y = memory.read_s16_le(base + 0x02)
    local mapGroup = memory.read_s8(base + 0x04)
    local mapNum = memory.read_s8(base + 0x05)

    if mapJustChanged(mapGroup, mapNum) then return nil end

    local flags = memory.read_u8(GPLAYERAVATAR_ADDR + 0x00)
    local runningState = memory.read_u8(GPLAYERAVATAR_ADDR + 0x02)
    local objectEventId = memory.read_u8(GPLAYERAVATAR_ADDR + 0x05)
    local dashing = (flags & 0x80) ~= 0

    local objEventAddr = GOBJECTEVENTS_ADDR + (objectEventId * OBJECTEVENT_SIZE)
    local facingRaw = memory.read_u16_le(objEventAddr + 0x18) & 0xF
    local orientation = FACING[facingRaw] or "south"

    local anim
    if runningState == 2 and dashing then
        anim = "running"
    elseif runningState == 2 then
        anim = "walking"
    else
        anim = "idle" -- covers runningState 0 (idle) and 1 (turning, no position change)
    end

    return {
        areaId = mapGroup .. ":" .. mapNum,
        x = x,
        y = y,
        orientation = orientation,
        anim = anim,
    }
end

-- Player's own on-screen sprite position, same formula as phase2_ghost.lua
-- -- the already-verified anchor a remote ghost's screen position is
-- computed relative to.
local function playerScreenPos()
    local spriteId = memory.read_u8(GPLAYERAVATAR_ADDR + 0x04)
    local spriteAddr = GSPRITES_ADDR + (spriteId * SPRITE_SIZE)

    local sx = memory.read_s16_le(spriteAddr + 0x20)
    local sy = memory.read_s16_le(spriteAddr + 0x22)
    local sx2 = memory.read_s16_le(spriteAddr + 0x24)
    local sy2 = memory.read_s16_le(spriteAddr + 0x26)
    local cx = memory.read_s8(spriteAddr + 0x28)
    local cy = memory.read_s8(spriteAddr + 0x29)

    local coordOffsetX = memory.read_s16_le(GSPRITECOORDOFFSETX_ADDR)
    local coordOffsetY = memory.read_s16_le(GSPRITECOORDOFFSETY_ADDR)

    return sx + sx2 + cx + coordOffsetX, sy + sy2 + cy + coordOffsetY
end

----------------------------------------------------------------------------
-- Remote ghost set. Per the tick model (agent_docs/contract.md): this is an
-- adapter-owned map the core upserts into via render_remote and removes
-- from via despawn_remote; it is redrawn from this table every frame
-- regardless of when new network data last arrived, never drawn once per
-- receipt.
----------------------------------------------------------------------------

local remotes = {}

local function handleBridgeLine(line)
    local env = jsonDecode(line)
    if not env or type(env) ~= "table" then return end

    if env.type == "render_remote" then
        local payload = env.payload
        if type(payload) == "table" and type(payload.state) == "table" and payload.player_id then
            local st = payload.state
            local pos = st.position
            if type(pos) == "table" and pos[1] and pos[2] then
                remotes[payload.player_id] = {
                    areaId = st.area_id,
                    x = pos[1],
                    y = pos[2],
                    orientation = st.orientation,
                    anim = st.anim,
                }
            end
        end
    elseif env.type == "despawn_remote" then
        local payload = env.payload
        if type(payload) == "table" and payload.player_id then
            remotes[payload.player_id] = nil
        end
    end
    -- Unknown types ignored -- same forward-compatibility posture as the
    -- relay and core apply to unknown fields/types.
end

local function drainBridge()
    while true do
        local line, err = sock:receive()
        if line then
            handleBridgeLine(line)
        elseif err == "timeout" then
            return -- nothing more buffered right now
        else
            -- Any outcome other than "timeout" means the connection is no
            -- longer usable -- treat it as fatal rather than assuming the
            -- specific string "closed" is the only failure mode. Found
            -- live (2026-08-11): the original code special-cased
            -- err == "closed" and treated everything else as a harmless
            -- timeout, so whatever LuaSocket actually reports when the
            -- core process is closed (a forcibly-terminated peer, not
            -- necessarily a graceful close) fell through unnoticed,
            -- leaving connected == true and a stale ghost drawn forever.
            resetBridge()
            remotes = {} -- don't leave a stale ghost frozen on screen forever
            return
        end
    end
end

----------------------------------------------------------------------------
-- Drawing. See the header for the tile-delta placement formula and the
-- TILE assumption that needs on-screen confirmation.
----------------------------------------------------------------------------

local function drawRemotes(localAreaId, playerMapX, playerMapY)
    local playerScreenX, playerScreenY = playerScreenPos()
    for _, remote in pairs(remotes) do
        if remote.areaId == localAreaId then
            local screenX = playerScreenX + (remote.x - playerMapX) * TILE
            local screenY = playerScreenY + (remote.y - playerMapY) * TILE
            gui.drawImage(GHOST_IMAGE_PATH, screenX, screenY, GHOST_IMAGE_SIZE, GHOST_IMAGE_SIZE)
        end
        -- A remote in a different area is deliberately not drawn at all --
        -- area_id is opaque and compared by equality only
        -- (agent_docs/contract.md); this is not the same as despawning it.
    end
end

----------------------------------------------------------------------------
-- Main loop. The adapter always drives (agent_docs/contract.md's tick
-- model): once per emu frame, try to connect if needed, send local state,
-- drain and apply whatever the core pushed back, then redraw every known
-- remote unconditionally.
----------------------------------------------------------------------------

if not memory.usememorydomain("System Bus") then
    console.log("ERROR: 'System Bus' memory domain not found on this core.")
    console.log("Domains available: " .. memory.getmemorydomainlist())
    return
end

console.log("MeshGhost Phase 3 loopback adapter running.")
console.log("Connecting to bridge at " .. BRIDGE_HOST .. ":" .. BRIDGE_PORT .. " ...")

while true do
    -- Confirmed live (2026-08-11), against BizHawk's own gui.d.lua doc
    -- ("gui.clearGraphics -- clears all lua drawn graphics from the
    -- screen") and real precedent in BizHawk's own bundled scripts
    -- (Gargoyles.lua, Earthworm Jim 2.lua, Super Mario World.lua all call
    -- it for the same reason): drawn images do NOT auto-clear between
    -- frames the way this project's own contract.md assumed when it was
    -- written (that assumption was never actually tested against "stop
    -- drawing entirely," only against "draw every frame vs. draw at
    -- network rate," and turned out to be wrong for the former case). A
    -- ghost that stops being drawn just freezes in its last position
    -- forever instead of disappearing. Clearing unconditionally, every
    -- frame, before the connect/send/draw logic below (not only when
    -- connected) is what makes "nothing to draw" actually mean nothing is
    -- shown, matching the tick model's actual intent.
    gui.clearGraphics()

    if not connected then
        connectBridge()
        if connected then
            console.log("MeshGhost Phase 3: connected to bridge.")
        end
    end

    if connected then
        local state = getLocalState()
        if state then
            sendLine(encodeLocalState(state.areaId, state.x, state.y, state.orientation, state.anim))
        else
            sendLine(ENCODED_NO_SEND)
        end

        if connected then -- sendLine may have reset the connection on error
            drainBridge()
        end

        if connected then
            local base = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
            if base ~= 0 then
                local playerMapX = memory.read_s16_le(base + 0x00)
                local playerMapY = memory.read_s16_le(base + 0x02)
                local mapGroup = memory.read_s8(base + 0x04)
                local mapNum = memory.read_s8(base + 0x05)
                drawRemotes(mapGroup .. ":" .. mapNum, playerMapX, playerMapY)
            end
        end
    end

    emu.frameadvance()
end
