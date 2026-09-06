# Code signing policy

This page exists because the [SignPath Foundation](https://signpath.org) requires one from every
project it signs for, and because a user deciding whether to trust a signed download deserves to
know exactly what the signature does and does not vouch for.

**Status:** the application to SignPath Foundation is in progress. Until it is approved and the
signing step is live in the release workflow, no MeshGhost release is signed, and
[antivirus.md](antivirus.md) describes what a user can check instead. This paragraph is updated
when that changes; the date of the change goes in [security.md](security.md)'s changelog.

## What gets signed

The two Windows executables in the full release zip on the
[Releases page](https://github.com/Tsukino-uwu/MeshGhost/releases):

- `meshghost.exe`, the client a game adapter starts or the player runs beside the game.
- `meshghost-server.exe`, the relay a host runs.

Both are built by GitHub Actions from the tagged source in this repository
(`.github/workflows/release.yml`), never on a developer's machine, and the build is reproducible:
[reviewing.md](reviewing.md) gives the recipe for producing a byte-identical copy from the tag.
Signing is applied by SignPath's service to those exact CI-built files, with a certificate issued in
SignPath Foundation's name. No signing key exists in this repository or on any maintainer's machine.

Free code signing provided by [SignPath.io](https://signpath.io), certificate by
[SignPath Foundation](https://signpath.org).

## What does not get signed

- **The Linux and macOS binaries.** Authenticode is a Windows format; those platforms have no
  equivalent gate for a downloaded binary, and the SHA-256 beside each asset is the integrity check.
  macOS Gatekeeper wants an Apple Developer ID signature, which is a separate paid programme this
  project does not take part in.
- **The two game-side DLLs** (`MeshGhostTevi.dll` for TEVI, `main.dll` for Pseudoregalia). They are
  committed prebuilt because CI cannot build them: each compiles against files that may not be
  redistributed (`packaging/README.md`). A signature from a verifiable CI build is therefore not
  available for them. They load inside the game process rather than being launched by the user, and
  the release workflow verifies each one matches the committed source it was built from.
- **Anything built locally**, including development builds a tester may have been handed. Only a
  file whose SHA-256 matches a Releases-page asset is a release build.

## Roles

SignPath's terms distinguish three roles. As of 2026-09-06 one person, the project's maintainer
(GitHub `Tsukino-uwu`), holds all three:

| Role | Who | What it means |
|---|---|---|
| Committer | Tsukino-uwu | May push to `master`. |
| Reviewer | Tsukino-uwu | Approves changes before they are merged. |
| Approver | Tsukino-uwu | Authorises a signing request on SignPath. |

Everyone holding a role uses two-factor authentication on GitHub and on SignPath.

The code itself is written by an AI agent under the maintainer's direction ([reviewing.md](reviewing.md)
says so up front). The agent holds no role and has no credentials of its own. It commits locally;
a push happens only when the maintainer explicitly asks for that push, through the maintainer's
own account, and the maintainer reviews what goes. It never approves a signing request. The
maintainer is accountable for everything that reaches GitHub.

**Outside contributions are welcome and carry no obligations for their author.** A pull request's
author holds no role; the change reaches a signed build only after a reviewer has read and merged
it. When a second person gains commit rights, this table gains a row, and merging to `master` starts
requiring a review from someone other than the author.

## Privacy

The software collects no user data and sends nothing to the project. A relay sees what its players
send it, which is a display name, a colour, and in-game positions, and keeps none of it after the
session; [security.md](security.md) is the full account. There is no telemetry, no crash reporting
and no update check.
