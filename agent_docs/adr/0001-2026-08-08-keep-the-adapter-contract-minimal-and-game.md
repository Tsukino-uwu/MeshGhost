# 2026-08-08 — Keep the adapter contract minimal and game-specific

<!-- ADR 0001. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-08
- **Decision:** Keep the adapter contract minimal and game-specific.
- **Status:** accepted
- **Context:** The project must support multiple game engines without leaking game-specific
  logic into the core.
- **Options considered:** a larger shared world model, a universal animation vocabulary,
  engine-specific core branches.
- **Resolution:** Use a thin adapter contract and keep all game-specific normalization
  inside adapters.
- **Consequences:** The first game adapter carries most of the work; the core stays reusable
  and easier to validate.
