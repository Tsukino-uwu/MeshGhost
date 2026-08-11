# Adapter protocol stub

Language-agnostic. Every real adapter (BizHawk Lua today, whatever TEVI needs later) implements
this same shape by dialing the local core's bridge port and speaking NDJSON — see
`agent_docs/contract.md`'s "Adapter bridge" and "Adapter interface" sections for the full,
authoritative spec. This file is a condensed, copy-from starting point, not a replacement for
reading that file first.

## The three functions

```text
get_local_state()          -> snapshot | nil     # sampled once per adapter frame tick
render_remote(id, state)   -> void                # upsert into the adapter's remote-ghost set
despawn_remote(id)         -> void                # remove from that set
```

`nil` from `get_local_state()` means "don't send this frame" — e.g. the local player is in a
menu, loading screen, or otherwise has no meaningful position right now (see
`agent_docs/contract.md`'s closed open question on this for what Emerald decided).

## Wire form (over the bridge, one JSON object per line)

Adapter → core, once per frame:

```json
{"type":"local_state","payload":{"state":{"area_id":"...","position":[0,0],"orientation":"...","anim":"..."}}}
```

or, when `get_local_state()` returned nil:

```json
{"type":"local_state","payload":{"state":null}}
```

`player_id`, `seq`, and `timestamp` are stamped by the core, not the adapter — leave them out.

Core → adapter, zero or more times per frame, one per currently-known remote:

```json
{"type":"render_remote","payload":{"player_id":"p2","state":{"area_id":"...","position":[0,0],"orientation":"...","anim":"..."}}}
{"type":"despawn_remote","payload":{"player_id":"p2"}}
```

## The tick loop (the part every real adapter gets wrong the first time)

```text
loop, once per real game frame:
    clear whatever was drawn last frame (if the render target doesn't auto-clear — confirm
        this for your engine; BizHawk's gui.* does NOT, see the correction in
        agent_docs/contract.md's tick model)

    if not connected to bridge:
        try to connect (non-blocking, retry next frame on failure)

    if connected:
        state = get_local_state()
        send local_state(state)               # state may be nil — send it anyway
        drain all buffered render_remote / despawn_remote messages, updating the
            adapter-owned remote-ghost map (upsert / delete)

    redraw every entry currently in the remote-ghost map, unconditionally — not only the
        ones that changed this frame. render_remote is an upsert into a set the adapter
        redraws every frame on its own clock, not a one-shot draw call; network updates
        arrive far slower than the render loop.
```

The "redraw every frame regardless of new data" rule is the one that produces flicker if
skipped — see `agent_docs/contract.md`'s tick model section for the full reasoning, and
`adapters/pokemon/emerald/phase3_loopback.lua`'s header for the specific bug this project hit live
before that rule was written down.

## Reference implementations

- `adapters/pokemon/emerald/phase4_multiplayer.lua` — a complete, real adapter speaking exactly this
  protocol (BizHawk Lua, NDJSON over LuaSocket). Its connection/tick-loop shape transfers to a
  new game; its `getLocalState`/`playerScreenPos` game-memory reads do not.
- `cmd/meshghost-fakeadapter/main.go` — not a template for a real adapter (it uses the
  in-process `core.Adapter` Go interface, not this wire protocol, since it has no separate
  process to bridge to). Useful only as a minimal example of the same three-function contract
  and tick model from the *core's* side, and as the Phase 5 proof that the core has no
  game-specific leaks — see `agent_docs/verified.md`.
