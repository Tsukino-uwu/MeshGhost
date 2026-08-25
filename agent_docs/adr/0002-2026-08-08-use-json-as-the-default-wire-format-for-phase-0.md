# 2026-08-08 — Use JSON as the default wire format for Phase 0 and Phase 1

<!-- ADR 0002. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-08
- **Decision:** Use JSON as the default wire format for Phase 0 and Phase 1.
- **Status:** accepted
- **Context:** Early work must prioritize correctness, observability, and easy debugging.
- **Options considered:** JSON text, custom binary encoding, CBOR-like binary formats.
- **Resolution:** Start with JSON and defer binary encodings until the contract is stable
  and bandwidth is demonstrably limiting.
- **Consequences:** Easier early debugging and review; wire format may need a later
  performance pass.
