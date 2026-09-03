# Phase 11 — Replays: recording, playback ghosts, the chaser, hotkeys, split times

**A dated record, not current fact.** Each entry says what was true while it was written; paths
and numbers are left as they were. Current state lives in `status.md`; the decisions in ADR 0047
(the replay model) and ADR 0048 (hotkeys in the core process); the roadmap entry in `plans.md`.

**What this phase is.** The wire format is already a replay format: every `protocol.State` carries
its own timestamp, area, position, orientation, anim and extras. A recording is that stream written
to a file instead of a socket; playback is a fake peer fed into the existing interpolation buffer,
so every renderer, adapter and knob works unchanged. On top of that: a "chaser" pack (the player's
own ghosts following N seconds behind), system-wide hotkeys owned by the core, and split times on
the replay ghost's nametag. Game-blind throughout — the adapters need no change for any of it, and
the one adapter-facing hook (the chaser's contact damage) is a per-game follow-on with its own ADR.

**Numbering note.** `phases/README.md` and `phase10.md` said "Phase 11 onward is reserved for the
fifth game and beyond"; this is Go-side feature work large enough to want its own log rather than
another entry in phase 10's component timeline, so it took the number and the fifth game takes the next.

## 2026-09-03 — planned, and Stage 0 written

The user's request, in one conversation: a ghost that trails and can hurt you ("similar to how
Badeline chases Madeline in Celeste"), recordings ("we are already sending/handling everything data
wise that we would need"), start/stop on a hotkey, looping a trick, playback speed, sharing files,
several replays at once, split times, and then the rules that shape it all:

- *"default to just having things in the config, and then per-adapter hotkeys need to be done if
  they are needed"* — and a core-owned key "makes sure it works for any/all adapters".
- *"everything goes into /replay when you record, anything you put into /replay/active would be
  the list of active recordings"* — no config key ever names a file.
- *"collision should always be off for recordings & the trailing ghost that can hurt you. no matter
  what setting you have in the client config. these are meant to be purely cosmetic no matter what"*.
- *"make it possible to pick X number of chasers, each one would have some delay in between so they
  don't just stack on top of each other"* — 4-5 chasers make doubling back a decision.
- *"just want to avoid someone ever being able to share a malicious replay file"* — answered by the
  one-entry-point rule in ADR 0047: a file can do what a stranger in a room can do, and no more.
- On what a recording is: *"1:1 to their gameplay"* — from the moment the player is in the world,
  a watched cutscene replays as a standstill, a skipped one moves earlier, a pause is a pause, the
  main menu is never in it; zone changes ride on `area_id` so a full run is one file.
- Prior art the user asked about (Trackmania, Celeste, Mario Kart — general knowledge, unverified)
  gave the `anchor` header key: restart at the start line, or per area.

**Stage 0 (this entry):** ADR 0047, ADR 0048, this file, the roadmap entry, the status line, the
`ideas.md` pointer, the `security-design.md` entry. Nothing built yet. Stages 1-9 follow, one commit
each: the local fake peer seam; the recorder; playback; seeks and `replay_control`; anchors;
hotkeys; save-last; the chaser pack; split times; the config/packaging/docs sweep.
