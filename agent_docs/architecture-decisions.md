# Architecture decisions

This file captures rationale for key architectural choices and contract decisions.

## Purpose

Use this file to record the why behind architecture and contract decisions. When a design choice must be revisited later, this file should make the rationale easy to understand.

## Decision record format

- `Date:`
- `Decision:` short description
- `Status:` proposed / accepted / superseded
- `Context:` why the decision was needed
- `Options considered:` brief list of alternatives
- `Resolution:` what was chosen and why
- `Consequences:` what this implies for future work

## Example decision

- `Date:` 2026-08-08
- `Decision:` Keep the adapter contract minimal and game-specific.
- `Status:` accepted
- `Context:` The project must support multiple game engines without leaking game-specific logic into the core.
- `Options considered:` a larger shared world model, a universal animation vocabulary, engine-specific core branches.
- `Resolution:` Use a thin adapter contract and keep all game-specific normalization inside adapters.
- `Consequences:` The first game adapter will carry most of the work; the core remains reusable and easier to validate.

## Additional decisions

- `Date:` 2026-08-08
- `Decision:` Use JSON as the default wire format for Phase 0 and Phase 1.
- `Status:` accepted
- `Context:` Early work must prioritize correctness, observability, and easy debugging.
- `Options considered:` JSON text, custom binary encoding, CBOR-like binary formats.
- `Resolution:` Start with JSON and defer binary encodings until the contract is stable and bandwidth is demonstrably limiting.
- `Consequences:` Early debugging and review are easier, but the wire format may need a later performance evaluation.

- `Date:` 2026-08-08
- `Decision:` Treat `area_id` and `anim` as opaque values in the core.
- `Status:` accepted
- `Context:` The core should avoid game-specific assumptions and keep the contract reusable.
- `Options considered:` normalized area identifiers, shared animation vocabulary, game-specific core branches.
- `Resolution:` Keep `area_id` and `anim` opaque and compare them only by equality in the core.
- `Consequences:` Adapters carry game-specific interpretation, and the core remains simpler and more portable.
