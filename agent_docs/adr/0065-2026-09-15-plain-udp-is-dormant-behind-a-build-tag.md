# 2026-09-15 — Plain `udp` is dormant: refused by releases, kept behind a build tag

<!-- ADR 0065. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** shipped relays and clients serve and dial `tcp` and `quic` only. `udp` — the
  reliability layer this project wrote over plain datagrams (`netx/udpconn`, ADR 0021/0024) — is
  compiled only under the `meshghost_devudp` build tag. Untagged, `netx.ParseKind("udp")` and
  `ParseKinds` return `udp is not a supported transport; use quic or tcp`, `netx.AutoPreference`
  is `{QUIC, TCP}`, and a relay config carrying a non-empty `listen_udp` refuses to start (an
  empty one, which every config shipped before this date carries, is ignored). An old `config.json`
  saying `"transport": "udp"` is an error, not a fallback. The tagged build keeps everything, and
  `dev-scripts/run-gotests-udp.bat` runs its tests by hand; CI compiles it (`go vet -tags
  meshghost_devudp ./...`) so a refactor cannot rot it silently, and runs none of its tests or its
  fuzz target.
- **Status:** Implemented 2026-09-15 (user decision 2026-09-14, recorded in the plan that led here;
  landed with the fourth adversarial review's fixes, whose findings D1–D3 it closes by not
  shipping).
- **Why.** udp never rescued a player quic could not: quic runs over udp, so whatever blocks one
  blocks both (Wine, udp-blocked networks), and tcp is already the fallback. It cannot be encrypted
  (Go has no DTLS), so it was the one transport on which the room code crossed readable whatever
  `tls` said. And it was attack surface for no player benefit: our own reliability layer, a fuzz
  target, the spoofing surface the pass-4 findings D1–D3 describe (a limiter-refused joiner told
  "ready" first; a spoofable handshake phase; undeadlined writes in the read loop). Adapters are
  unaffected either way — they speak only the bridge and never see the transport.
- **Why keep it at all.** As an A/B control against quic-go: the same unreliable, datagram-shaped
  path without QUIC's congestion control, which is how the quic glide in `agent_docs/ideas.md`
  ("quic datagrams are congestion-controlled") was isolated; Wireshark-readable packets; a
  no-quic-go baseline if a quic-go upgrade breaks something. Testing udp does not test quic — but
  udp had been "the unreliable transport" in several suites, so those moved to quic rather than
  letting quic coverage shrink silently: `netx/conformance_test.go`'s `transportsUnderTest`,
  `internal/e2e`'s per-transport round trip, `relay`'s mixed-transport room test (three-way under
  the tag).
- **What a host sees.** Nothing, unless they had opted into udp: `-transport tcp,quic` is the
  shipped default and unchanged. `docs/config.md` drops the `listen_udp` row and the `udp` option;
  `docs/integrating.md` says no shipped relay serves it and keeps the wire format for anyone
  reading the tagged code.
- **Supersedes** the udp parts of ADR 0021 (selectable transport), 0023 (the handshake is always
  tcp — still true, the list of what follows it is shorter) and 0027; ADR 0024 (the udp token)
  describes code that still exists, untagged nowhere.
- **Follow-on.** Forced TLS (the parked `tls-planning`) assumes no shipped udp; this is its
  prerequisite and it now holds.
