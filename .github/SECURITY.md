# Security policy

<!-- line-cap: none -- written for people, not for an agent's instruction budget. Why: agent_docs/claude-md-cap.md. -->

**Reporting.** Open a GitHub issue. If you would rather not disclose the details publicly first,
open the issue with just "security, details on request" and the maintainer will reach out. There is
no bug bounty and no embargo process; this is a hobby project with one maintainer.

**What to include.** The input that triggers it, if you have one — a confirmed finding gets a fix
with a regression test that fails without it, and a dated line in the security changelog.

**What is covered.** The relay (`meshghost-server`), the client core (`meshghost`), and each game
adapter as shipped in a release. The threat model, what each transport does and does not protect,
every limit and the known gaps that are deliberately not defended are in
[docs/security.md](../docs/security.md). How to audit it yourself — which code a host runs, where
the bytes go, and the fuzz and race commands — is [docs/reviewing.md](../docs/reviewing.md).

**Supported versions.** The latest release only. The project assumes everyone is on it.
