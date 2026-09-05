# Architecture

System shape and the rationale behind decisions that aren't obvious from the code or the
brief alone. The standing prohibitions (no addresses from memory, human-gated verified.md,
etc.) live in `CLAUDE.md`, not here — this file is reference, not rules.

**A cap works on this file because what grows here is bounded**: the system shape is stable, and
each new decision costs exactly one index line. The ADRs themselves are uncapped by design — they
are a record, and a record is capped by splitting it, not by refusing entries
([claude-md-cap.md](claude-md-cap.md), "cap the thing that actually grows").

## System shape

```text
        Relay (relay, cmd/meshghost-relay)
             |  relay protocol: NDJSON over tcp|udp|quic (via netx). 17 types:
             |  hello/welcome/reject/join/leave/state/prefs/ping/pong/transports,
             |  plus the opt-in planes event/lease/lease_state/escrow/escrow_state/
             |  world/world_state (protocol/protocol.go is the list)
        Core (core, cmd/meshghost)
             |  adapter bridge: NDJSON/TCP, localhost-only. 15 types:
             |  hello/bridge_ready/reject/session_policy/local_state/render_remote/
             |  despawn_remote/remote_name, plus the same opt-in planes (bridge/bridge.go)
     [ Adapter contract ]
        /    |    \
   Emerald  Crystal  TEVI  Pseudoregalia   (per-game, rewritten each time)
```

Full field-level detail — packet schema, message types, tick model, transport framing,
limits — lives in `agent_docs/contract.md`. This file covers the shape and the *why*.

## Why the core is out-of-process

Go was chosen for the core and relay (ADR below) so the shipped desktop app is a single
dependency-free binary per OS. That means the core cannot be linked directly into a BizHawk
Lua script or, later, a C# Unity mod — it runs as its own process, and adapters reach it over
a localhost socket (the "bridge" in `contract.md`). This is a deliberate consequence of the
packaging goal, not an accident, and it's why the bridge exists as a named layer instead of
being folded into "the transport."

## Why the tick is adapter-driven

BizHawk's Lua environment owns the frame loop (`emu.frameadvance()`); a hypothetical future
in-process host would want to drive its own loop. Making the *adapter* always the one that
calls into the core — never the reverse — means there's one calling convention for every
adapter, checked for real at Phase 5 rather than discovered as a mismatch then. See
`agent_docs/contract.md`'s tick model section for the reasoning that produced this.

## Package boundaries

Enforced dependency graph for the Go module, added as a compiling type skeleton (zero logic,
`go build ./...` and `go vet ./...` both pass clean) on 2026-08-11. The six library packages
moved out of `internal/` to the repo root on 2026-08-17 and are now a public API surface —
same graph, same rules, see that ADR below. Module path:
`github.com/Tsukino-uwu/MeshGhost`.

```text
PUBLIC — importable by anyone, and therefore a contract:
protocol   — message types + JSON shapes. No deps on our own packages. Lowest layer.
transport  — generic NDJSON framing over any net.Conn. Defines its own Transport
                       interface; no deps on our own packages (byte-level only, doesn't
                       know message shapes).
bridge     — adapter<->core message shapes (LocalState/RenderRemote/DespawnRemote).
                       Imports protocol only.
core       — snapshot buffer, interpolation, remote-player tracking. Imports
                       protocol, transport, bridge, netx, internal/textfmt.
relay      — room membership, forwarding, limits. Imports protocol, transport,
                       internal/textfmt. Never imports core or bridge — the relay stays
                       ignorant of adapter-side concerns, same as it's ignorant of games.
netx       — transport selection (tcp|udp|quic) as net.Listener/net.Conn. Added
                       2026-08-16. No deps on our own packages, same leaf discipline as
                       transport; subpackages netx/udpconn and netx/quicconn hold the
                       datagram implementations, and netx/tlsx holds TLS over tcp — the
                       self-signed certificate, the first-byte sniffing listener and the
                       optional fingerprint pin (added 2026-08-19). Deliberately NOT a second Transport
                       implementation — see the transport ADR for why the seam sits at
                       net.Conn.

NOT PUBLIC — internal/ still means what it always did:
internal/cfg        — production, added 2026-08-25. The config-file plumbing shared by the
                       two mains (BOM stripping, bad-value handling), extracted because
                       both carried a copy that had already begun to diverge.
internal/textfmt    — production, added 2026-08-28. Number formatting for the one-line
                       status summaries; extracted because core/stats.go and
                       relay/introspect.go carried byte-identical copies.
internal/e2e        — test-only. Launches the real binaries and drives a real adapter over
                       the bridge; imports bridge, netx, protocol, transport. Ships no
                       production code, so nothing imports it.
internal/gameblind  — test-only, added 2026-08-20. Five tests over the source tree that make
                       the game-blindness rules mechanical instead of manual: game names in
                       library code, generic imports, frozen wire fields, the
                       server/client/adapter split, and adapters never speaking the relay
                       protocol (testing.md). Imports nothing of ours at build time.
                       Keeping internal/ non-empty is deliberate: it is what makes the six
                       above a chosen set rather than the residue of deleting a directory.

cmd/* are package main and were never importable:
cmd/meshghost       — desktop app entry point. Imports core, netx, protocol and internal/cfg
                       (the Phase 3 note here once predicted transport/bridge imports; they
                       never arrived).
cmd/meshghost-relay — standalone relay entry point. Imports relay, netx, protocol, internal/cfg.
cmd/meshghost-fakeadapter — the test rig's ghost-that-walks-in-a-circle. Imports core, netx
                       and protocol.
cmd/meshghost-netsim — fault-injecting proxy for real sessions. Imports NONE of our own
                       packages, deliberately: it must be able to mangle the wire without
                       inheriting any of the code whose behaviour it is testing.
```

**Hard rule:** `core` and `relay` may never import anything under
`adapters/`. There's no Go code under `adapters/` today (BizHawk is Lua), but the rule holds
regardless — it's the Go-level enforcement of "the core never touches the game," parallel to
the existing "no `if game == \"emerald\"`" rule. Checked manually until 2026-08-20, when
`internal/gameblind` made it mechanical: five tests over the source tree covering game names in
library code, generic imports, frozen wire fields, the server/client/adapter split, and adapters
never speaking the relay protocol (`testing.md`).

The one Go interface in the skeleton, `core.Adapter`, is deliberately scoped in its doc
comment to the Phase 5 in-process fake/test adapter only — real adapters (BizHawk Lua, any
future host) speak the `bridge` wire protocol and never implement it. Conflating the
two would wrongly suggest Lua adapters need Go bindings.

## Decision log (ADRs)

**Each ADR is its own file under [adr/](adr/), and this is the index.** Split out 2026-08-25:
the log had grown to 2,332 of this file's 2,501 lines, so reading the system shape above meant
loading 38 decisions with it, and citing one meant citing a line number. Nothing was reworded in
the move — each file is its heading plus its own body, verbatim.

**The index lives here, not in `adr/README.md`, on purpose.** Every existing citation in this repo
says "the `<date>` ADR in `architecture.md`", and there are many; keeping the index at the cited
address means all of them still land somewhere useful in one hop. It is also the only index, so
there is nothing to drift. A filename carries its own date, so a citation by date resolves without
opening anything.

**Every ADR carries a `# YYYY-MM-DD — decision` heading, then the fields:** Date / Decision /
Status / Context / Options considered / Resolution / Consequences.

**The first 20 had no heading at all until 2026-08-25** — they were bullet blocks separated by
`---`, so they could not be linked to, indexed, or found by heading search, while the 18 written
after 2026-08-16 could. Headings were added from each block's own Date and Decision fields; no
ADR text was changed.

**Adding one:** write `adr/<NNNN>-<date>-<slug>.md`, taking the next number, and add its line to
the index below. `dev-scripts/preflight.ps1` fails if a file in `adr/` is missing from this index,
or if a number is duplicated — an unindexed ADR is one nobody will find.

- [2026-08-08 — Keep the adapter contract minimal and game-specific](adr/0001-2026-08-08-keep-the-adapter-contract-minimal-and-game.md)
- [2026-08-08 — Use JSON as the default wire format for Phase 0 and Phase 1](adr/0002-2026-08-08-use-json-as-the-default-wire-format-for-phase-0.md)
- [2026-08-08 — Treat `area_id` and `anim` as opaque values in the core](adr/0003-2026-08-08-treat-area-id-and-anim-as-opaque-values-in-the.md)
- [2026-08-11 — Core and relay are written in Go, shipped as a single static binary per OS](adr/0004-2026-08-11-core-and-relay-are-written-in-go-shipped-as-a.md)
- [2026-08-11 — Second target game is TEVI, not Ori: Will of the Wisps](adr/0005-2026-08-11-second-target-game-is-tevi-not-ori-will-of-the.md)
- [2026-08-11 — Relay runs unauthenticated through Phases 3-4; room code is the recorded end goal](adr/0006-2026-08-11-relay-runs-unauthenticated-through-phases-3-4.md)
- [2026-08-11 — Reserve an opaque event plane and a `features` list, and implement neither now](adr/0007-2026-08-11-reserve-an-opaque-event-plane-and-a-features.md)
- [2026-08-11 — Emerald uses a vendored LuaSocket, not BizHawk's own `comm.*`](adr/0008-2026-08-11-emerald-uses-a-vendored-luasocket-not-bizhawk-s.md)
- [2026-08-12 — Cap `core.Core`'s actual send rate to the relay](adr/0009-2026-08-12-cap-core-core-s-actual-send-rate-to-the-relay.md)
- [2026-08-12 — The adapter declares `game_id` over the bridge, not the user in `config.json`](adr/0010-2026-08-12-the-adapter-declares-game-id-over-the-bridge-not.md)
- [2026-08-13 — A bridge disconnect closes the relay connection, and a relay drop clears identity](adr/0011-2026-08-13-a-bridge-disconnect-closes-the-relay-connection.md)
- [2026-08-13 — `Core.remoteStatesAt` filters remotes by `area_id`, unless our own area is unknown](adr/0012-2026-08-13-core-remotestatesat-filters-remotes-by-area-id.md)
- [2026-08-14 — Add room-code auth and a peer game-version check to `hello`](adr/0013-2026-08-14-add-room-code-auth-and-a-peer-game-version-check.md)
- [2026-08-14 — Relay lifecycle logging, and permanent vs transient rejects](adr/0014-2026-08-14-relay-lifecycle-logging-and-permanent-vs.md)
- [2026-08-14 — Two review passes across the Go layer and all three adapters](adr/0015-2026-08-14-two-review-passes-across-the-go-layer-and-all.md)
- [2026-08-14 — `Core` auto-retries a dropped relay connection](adr/0016-2026-08-14-core-auto-retries-a-dropped-relay-connection.md)
- [2026-08-15 — Make the room's state send rate operator-configurable at the relay](adr/0017-2026-08-15-make-the-room-s-state-send-rate-operator.md)
- [2026-08-15 — A relay may be restricted to a single game (`server.only_game`), off by default](adr/0018-2026-08-15-a-relay-may-be-restricted-to-a-single-game.md)
- [2026-08-16 — Build `UE4SS.dll` from our pinned submodule, not upstream's release zip](adr/0019-2026-08-16-build-ue4ss-dll-from-our-pinned-submodule-not.md)
- [2026-08-16 — `transport.NDJSONConn` loses no message before `OnReceive` is registered](adr/0020-2026-08-16-transport-ndjsonconn-loses-no-message-before.md)
- [2026-08-16 — Selectable transport: `tcp` | `udp` | `quic`](adr/0021-2026-08-16-selectable-transport-tcp-udp-quic.md)
- [2026-08-16 — Transport discovery: `transport: "auto"`](adr/0022-2026-08-16-transport-discovery-transport-auto.md)
- [2026-08-16 — Revision: the handshake is always tcp; `transport` is the upgrade target](adr/0023-2026-08-16-revision-the-handshake-is-always-tcp-transport.md)
- [2026-08-16 — UDP per-connection token (the second half of the CelesteNet measure)](adr/0024-2026-08-16-udp-per-connection-token-the-second-half-of-the.md)
- [2026-08-16 — An adapter may start its own local core process (autostart)](adr/0025-2026-08-16-an-adapter-may-start-its-own-local-core-process.md)
- [2026-08-16 — Amendment to the autostart ADR: the Wine console valve is removed](adr/0026-2026-08-16-amendment-to-the-autostart-adr-the-wine-console.md)
- [2026-08-16 — One adapter per core, answered explicitly (groundwork for the port walk)](adr/0027-2026-08-16-one-adapter-per-core-answered-explicitly.md)
- [2026-08-17 — The planes past cosmetic: event routing, sequencer, leases, escrow, resumption, clock sync](adr/0028-2026-08-17-the-planes-past-cosmetic-event-routing-sequencer.md)
- [2026-08-17 — Capability scope: room-scoped vs client-scoped, and session takeover](adr/0029-2026-08-17-capability-scope-room-scoped-vs-client-scoped.md)
- [2026-08-17 — Rooms are keyed by game_id AND name, so a server hosts many games out of the box](adr/0030-2026-08-17-rooms-are-keyed-by-game-id-and-name-so-a-server.md)
- [2026-08-17 — World custody: the relay holds the world, and four ways of doing it that fail silently](adr/0031-2026-08-17-world-custody-the-relay-holds-the-world-and-four.md)
- [2026-08-17 — The Go packages leave `internal/` and the module takes its real path](adr/0032-2026-08-17-the-go-packages-leave-internal-and-the-module.md)
- [2026-08-17 — Crystal spawns a real object event, and MeshGhost writes game memory for the first time](adr/0033-2026-08-17-crystal-spawns-a-real-object-event-and-meshghost.md)
- [2026-08-18 — Emerald spawns too: the Crystal spawn ADR extends to Emerald, and call-vs-imitate is answered](adr/0034-2026-08-18-emerald-spawns-too-the-crystal-spawn-adr-extends.md)
- [2026-08-19 — Ghost collision becomes a room policy the host sets, with a client override one way only](adr/0035-2026-08-19-ghost-collision-becomes-a-room-policy-the-host.md)
- [2026-08-20 — An adapter may take area visibility away from the core: `render_all_areas`](adr/0036-2026-08-20-an-adapter-may-take-area-visibility-away-from.md)
- [2026-08-21 — Emulator adapters are Lua-only: no ROM patch, ever](adr/0037-2026-08-21-emulator-adapters-are-lua-only-no-rom-patch-ever.md)
- [2026-08-21 — Extra hardware sprites come from OAM injection above `gOamLimit`, not HBlank multiplexing](adr/0038-2026-08-21-extra-hardware-sprites-come-from-oam-injection.md)
- [2026-08-28 — A client stops restating an unchanged state, and brackets its resume so nothing creeps](adr/0039-2026-08-28-a-client-stops-restating-an-unchanged-state.md)
- [2026-08-28 — The render model becomes three knobs, chosen per game rather than one size fits all](adr/0040-2026-08-28-the-render-model-becomes-three-knobs-chosen-per-game.md)
- [2026-08-28 — The relay filters cross-area state, for clients that ask for it](adr/0041-2026-08-28-the-relay-filters-cross-area-state-for-clients-that-ask.md)
- [2026-08-28 — Every client gets its own outbound queue and writer](adr/0042-2026-08-28-every-client-gets-its-own-outbound-queue-and-writer.md)
- [2026-08-30 — The core hands the adapter its orientation bracket, and rotation gets interpolated for the first time](adr/0043-2026-08-30-the-core-hands-the-adapter-its-orientation-bracket.md)
- [2026-09-02 — The first adversarial review, and what it changed](adr/0044-2026-09-02-the-first-adversarial-review-and-what-it-changed.md)
- [2026-09-02 — Every state carries the sample before it (loss cover for the state plane)](adr/0045-2026-09-02-every-state-carries-the-sample-before-it.md)
- [2026-09-02 — 450ms interp ships for every game, judged on the worst-case link](adr/0046-2026-09-02-450ms-ships-everywhere-judged-on-the-worst-case-link.md)
- [2026-09-03 — A replay is a local fake peer: recording, playback, the chaser and split times](adr/0047-2026-09-03-a-replay-is-a-local-fake-peer.md)
- [2026-09-03 — System-wide hotkeys live in the core process, not in the adapters](adr/0048-2026-09-03-system-wide-hotkeys-live-in-the-core-process.md)
- [2026-09-03 — A local ghost renders on its own delay, not the network's](adr/0049-2026-09-03-a-local-ghost-renders-on-its-own-delay.md)
- [2026-09-03 — A relay that is merely down no longer refuses the game](adr/0050-2026-09-03-a-downed-relay-no-longer-refuses-the-game.md)
- [2026-09-03 — Recordings are plain text, and small because they de-duplicate](adr/0051-2026-09-03-recordings-are-plain-text-and-delta-encoded.md)
- [2026-09-04 — The core tells the adapter when it is recording](adr/0052-2026-09-04-the-core-tells-the-adapter-when-it-is-recording.md)
- [2026-09-05 — The chaser runs on gameplay time, which stops while the player is frozen](adr/0053-2026-09-05-the-chaser-runs-on-gameplay-time.md)

## Prior art

- [How CelesteNet handles this (researched 2026-08-13)](adr/prior-art-celestenet.md) — research
  history behind the room-code auth, game-version check and udp per-connection token ADRs. Moved
  out of this file 2026-08-25 with the log itself.
