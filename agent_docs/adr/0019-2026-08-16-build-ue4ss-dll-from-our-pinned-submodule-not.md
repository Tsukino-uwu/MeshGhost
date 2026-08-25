# 2026-08-16 — Build `UE4SS.dll` from our pinned submodule, not upstream's release zip

<!-- ADR 0019. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-16
- **Decision:** Keep building `UE4SS.dll` from our own pinned RE-UE4SS submodule rather than
  shipping upstream's published release zip; ship third-party notices alongside it.
- **Status:** accepted
- **Context:** A full-repo licence audit found `licensing.md` covered RE-UE4SS's own MIT code but
  not what RE-UE4SS *statically links into* the `UE4SS.dll` this repo builds and redistributes —
  about a dozen MIT/BSD-2/zlib libraries whose terms each require their notice to travel with a
  binary. The audit also established what the Epic-account-gated `UEPseudo` submodule actually
  is: ~200 headers carrying `// Copyright Epic Games, Inc. All Rights Reserved.`, which is why
  that repo is private and carries no licence. We compile against those headers; we do not
  redistribute them.
- **Options considered:** (1) status quo, unexamined; (2) keep building our own but close the
  notice gap; (3) ship upstream's published `UE4SS_v3.0.1.zip` so the Epic-headers compilation is
  upstream's arrangement rather than ours; (4) stop shipping UE4SS and make users install it.
- **Resolution:** Option 2. Option 3 was investigated with real measurements and rejected: no
  published upstream artifact matches our pinned commit (`733e5969` is **938 commits ahead** of
  the `v3.0.1` tag, 300 files changed, built 2024-02-14), our own `main.dll` is *linked against*
  UE4SS so the mismatch would be ABI-level rather than cosmetic, that zip predates the `ue4ss/`
  folder layout, and it contains no LICENSE file — meaning our staged tree is already more
  complete than upstream's own. Crucially the licence benefit is also narrower than it first
  looked: we remain the redistributor either way, so the notice obligation does not move. Option
  4 was never seriously on the table — it breaks the adapter for no gain. The measured detail
  lives in `agent_docs/licensing.md`; it is not duplicated here.
- **Consequences:** `packaging/release/.../Binaries/Win64/ue4ss/THIRD-PARTY-NOTICES.txt` now ships
  and is hand-maintained — `stage-ue4ss-runtime.bat` does not generate it and carries a comment
  saying so, since nothing there deletes the folder. It must be re-checked whenever the RE-UE4SS
  pin moves, because the dependency set can move with it. The `UEPseudo` question stays open and
  is recorded rather than resolved: what is fact (we ship only a compiled binary; upstream
  publicly ships the equivalent) is separated from what is a legal question this project will not
  assert either way. Revisit only on a concrete concern, not on general tidiness. One dependency,
  `patternsleuth`, has no licence text anywhere upstream — only a `Cargo.toml` declaration — so
  that declaration is quoted verbatim rather than expanded into boilerplate with an invented
  copyright line.
