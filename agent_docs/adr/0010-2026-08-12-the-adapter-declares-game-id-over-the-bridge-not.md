# 2026-08-12 — The adapter declares `game_id` over the bridge, not the user in `config.json`

<!-- ADR 0010. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-12
- **Decision:** The adapter declares `game_id` to the core over the bridge (a new `hello`
  message, sent first on every connection), instead of the user supplying `"game"` in
  `config.json`. `-game`/the config field remain as an explicit override for callers that
  don't have a real adapter to ask (dev/testing scripts, `cmd/meshghost-fakeadapter`).
- **Status:** accepted
- **Context:** Raised by the user while reviewing the reworked release `config.json`
  (`plans.md`'s "Release packaging" entry): the adapter already knows which game it's running
  in — it's literally the Lua script or mod the user loaded — so asking them to also type
  `"emerald"`/`"tevi"` into a text file is a second statement of a fact already established
  elsewhere, and a second place for it to go stale or be mistyped.
- **Options considered:** (1) leave `game_id` user-supplied, just documented better — doesn't
  remove the actual redundancy, only explains it; (2) infer the game from which port an
  adapter connects to — would need one bridge port per game, more moving parts than the
  problem justifies; (3) the adapter states `game_id` itself, over the bridge, as connection
  setup.
- **Resolution:** Option 3. `bridge.Hello` (`{"type":"hello","payload":{"game_id":
  "..."}}`) is a fourth bridge message, sent by the adapter as the first message on a fresh
  connection. `core.Core` no longer requires a `game_id` before `ServeBridge` starts;
  `Core.ConnectRelayOnAdapterHello` connects to the relay lazily, the first time a `hello`
  arrives, using new `RelayAddr`/`Room`/`DisplayName`/`DialTimeout` fields set by the caller
  up front. `game_id` stays opaque to the core throughout — forwarded verbatim into the relay
  `Hello`, never inspected, same as `area_id`/`anim` (`CLAUDE.md`). `cmd/meshghost`'s `-game`
  flag (and the config file's `"game"` field) still work exactly as before when set — this is
  additive, not a removal, since dev/testing tooling with no real adapter attached
  (`dev-scripts/run-core-*.bat`, `cmd/meshghost-fakeadapter`) has no `hello` to wait for. A
  single `Core` still serves exactly one game per process: a `hello` for a different `game_id`
  than the one already connected is refused, not treated as a game switch.
- **Consequences:** `packaging/release/config.json` drops `"game"` entirely — the shipped
  package now has nothing for the user to get wrong about which game they're playing, and
  switching games is "load the other one, restart the launcher," not "load the other one, also
  edit a text file to match." The cost is a small ordering contract every future adapter must
  follow (hello before any `local_state`) that a purely-flag-driven adapter never had to think
  about — documented in `contract.md` and `adapters/_template/PROTOCOL.md`, and demonstrated in
  both shipped adapters (`adapters/emulator/pokemon/emerald/meshghost_emerald.lua`,
  `adapters/tevi/MeshGhostTevi/BridgeClient.cs`).
