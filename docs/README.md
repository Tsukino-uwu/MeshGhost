# MeshGhost docs

These are for people using MeshGhost. The internal working record of how it got built is
[agent_docs/](../agent_docs/README.md).

- [getting-started.md](getting-started.md) — **start here.** Everything a player does, from unzipping to seeing a friend appear.
- [hosting.md](hosting.md) — running the server for your group: the short version, then every knob and what it costs.
- [troubleshooting.md](troubleshooting.md) — it did not work, or something looks wrong.
- [config.md](config.md) — every `config.json` key: its shipped value, what it does, which program reads it.
- [integrating.md](integrating.md) — putting MeshGhost in your own game, in any language.
- [security.md](security.md) — the security and privacy posture: what is already
  checked-safe, the gaps that remain, and a dated changelog of every hardening pass.
- [reviewing.md](reviewing.md) — auditing it yourself: which code a host runs, where the
  bytes go, and how to run the fuzzers and race detector on your own machine.
- [networking.md](networking.md) — how the relay and client actually work, traced through
  the real code.
- [antivirus.md](antivirus.md) — why the binaries get flagged, and what you can check.
- [code-signing.md](code-signing.md) — what a signature on a release vouches for, and who holds the keys (nobody).

`getting-started.md`, `hosting.md` and `troubleshooting.md` ship in the release zip too, under
`docs\`.
