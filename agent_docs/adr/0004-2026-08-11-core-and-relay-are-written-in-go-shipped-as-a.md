# 2026-08-11 — Core and relay are written in Go, shipped as a single static binary per OS

<!-- ADR 0004. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-11
- **Decision:** Core and relay are written in Go, shipped as a single static binary per OS.
- **Status:** accepted
- **Context:** `README.md` commits to a packaged desktop app with no runtime install
  (Python, .NET, JVM, etc.) across Windows/Linux/macOS. No language had been chosen; this
  had to be resolved before any Phase 3 network code could be written.
- **Options considered:** C#/.NET 8 (in-process option for a future Unity adapter, but
  larger binaries and no benefit to BizHawk/UE4SS), Rust (best runtime characteristics, but
  slowest to write for an I/O-bound JSON-plumbing project), Python + PyInstaller (fastest to
  prototype, but works directly against the no-dependency packaging goal).
- **Resolution:** Go. Single static binary, trivial cross-compilation, no runtime for the
  end user, sufficient stdlib for TCP/JSON.
- **Consequences:** The core is out-of-process for every adapter, including a future
  in-process-capable host like Unity/C#. See "Why the core is out-of-process" above. One
  uniform bridge/relay split for all games, at the cost of losing the option of linking the
  core directly into a C# host later without keeping the bridge as a compatibility path.
