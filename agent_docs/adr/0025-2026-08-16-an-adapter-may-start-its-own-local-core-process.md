# 2026-08-16 — An adapter may start its own local core process (autostart)

<!-- ADR 0025. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** A game adapter may spawn `meshghost.exe` itself, hidden, when a bridge connect
  attempt finds nothing listening — and passes it no relay settings, only a working directory.
- **Status:** Implemented for Pseudoregalia the same day (`CoreLauncher.cpp`, plus
  `-exit-with-pid`/`show_console` on the client). **Since watched running on both Windows and
  Proton** — cold start, reuse of an existing core, and cleanup on game exit are all user-confirmed
  (`verified.md`, 2026-08-16). TEVI and Emerald are still not converted (`status.md`).
- **Context:** A Pseudoregalia speedrunner tried MeshGhost and reported that having to launch a
  second program defeats the point: the interactions worth having were the unplanned ones, both
  people just having it on while practising, and nobody starts a separate client for an encounter
  they haven't planned yet. Every doc said "double-click meshghost.exe, leave the window open,
  then start the game" — a per-session step that converts ambient presence into a deliberate act.
- **Options considered:** (1) a tray app / run-at-login service — best "always on", but a resident
  process is a bigger ask and needs a tray UI and startup registration that don't exist;
  (2) the mod spawns the client; (3) leave it, and treat the friction as inherent.
- **Resolution:** Option 2, chosen by the user, with the window hidden (`CREATE_NO_WINDOW`) so it
  reads as *server + game* rather than *server + client + game*. Reuse-before-spawn falls out of
  hanging it off the connect-failure path: a core that is already running — started by hand, by
  another game, or natively on the Linux side of a Proton prefix — is found and used, never
  duplicated, and never killed by a mod that didn't start it.
- **Resolution (why a working directory and not `-relay`):** The contract says an adapter has no
  say in *how* the core reaches the relay. Passing the address on the command line would have been
  the obvious implementation and would have broken exactly that, in the same shape as the rejected
  `preferred_transport` bridge field. Setting the child's cwd instead means the core reads its own
  `config.json` as if a human had launched it there, and the adapter passes only what was already
  its business: its bridge port, and a pid to exit with. Contract amended in `contract.md`.
- **Resolution (the exe ships beside the mod, and only where it must):** Pseudoregalia and TEVI
  install *into the game's* directory tree, so after a drag-and-drop install nothing points back
  at the unzipped release folder — the exe and a client-only `config.json` have to ride along in
  the mod folder. Emerald does not: its script is loaded from the release folder itself, so it
  reaches the root exe and config with no second copy. The duplication is forced by the install
  model, not chosen, and should not be copied to adapters that don't need it.
- **Resolution (one owner per setting):** `local_game_bridge` is deliberately absent from the
  mod-folder config — the mod passes `-bridge` when spawning. TEVI already had this split (its
  port lives in a BepInEx cfg while the core reads `local_game_bridge`), and a config sitting
  *directly beside* the mod that the mod partly ignores would have been a worse version of it.
- **Consequences:** The client's log stops being a backup and becomes the only channel a remote
  tester can send back, so it now appends rather than truncating (a respawned client used to erase
  the evidence of why the last one died), carries a per-run banner, and says which `config.json`
  it actually loaded — a missing one used to be silent, which with no console is indistinguishable
  from "my settings did nothing". A spawn that fails outright produces no client log at all, so
  the mod logs that outcome to UE4SS's own log. **The real cost is antivirus**: a game mod
  silently starting an unsigned, already-false-positive-flagged exe is the literal shape of a
  dropper, and this raises the priority of the unstarted SignPath code-signing work
  (`risks.md`). `MESHGHOST_NO_AUTOSTART` is the escape hatch, and the manual path is unchanged.
