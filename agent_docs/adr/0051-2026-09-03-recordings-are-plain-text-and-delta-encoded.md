# 2026-09-03 — Recordings are plain text, and small because they de-duplicate

<!-- ADR 0051. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** a recording is a plain `.ndjson` file whose sample lines carry only the `extras`
  that CHANGED since the line before (`replay.delta`, on). Compression is an opt-in
  (`replay.gzip`, off). The header — the line anyone actually edits — is untouched by either.
- **Supersedes** the same day's decision to ship gzipped recordings, which stood for a few hours.
- **Status:** built and tested 2026-09-03; the format change is exercised by a round-trip test and
  by every existing replay test. Not yet watched in a game.
- **What went wrong with gzip, and it is not about ratios:** a recording ends when the game
  closes, which is the normal end of a session, and the client exits through `watchParentPID`'s
  `os.Exit(0)` — no deferred cleanup, so the gzip footer was never written. **Every byte of data
  survived** (the recorder syncs a gzip flush point every second, and 3,394 lines decompressed
  fine), but `gzip -t` says `unexpected end of file` and Explorer and 7-Zip refuse the file whole:
  *"Error 0x8000FFFF: Catastrophic failure"*, which is what the user hit on their first real
  recording. **A plain file cut short at the same instant loses nothing visible.** The exit path is
  fixed too — that was a bug regardless of format — but the lesson is the ordering one: a format
  whose failure mode is "all or nothing" is the wrong default for an artefact produced by a process
  that is routinely killed.
- **Measured on a real 3-minute Pseudoregalia clip** (15,500,011 bytes, 15,762 samples):

  | | bytes | MB/hour | vs. raw |
  |---|---|---|---|
  | as recorded | 15,500,011 | 310 | — |
  | rounded, full lines | 14,422,802 | 288 | 1.1x |
  | **rounded + delta (ships)** | **3,476,990** | **70** | **4.5x** |
  | rounded + delta + gzip (opt-in) | 398,928 | 8 | 38.9x |

- **Why per KEY and not per line**, which is the intuitive design and is nearly worthless here:
  only **274 of 15,761** lines carry an `extras` block identical to the one before it, because
  `h_speed`, `v_speed` and `slide_t` jitter every frame — while every other one of the 40 keys
  changes on **117 lines or fewer**. Per-line dedup is 2%; per-key is 4.5x.
- **The encoding rule that keeps it honest:** an absent key means *unchanged*, so a key that
  actually GOES AWAY is written as an explicit `null`. Without that distinction an adapter that
  stopped reporting a field would have its last value carried forward for the rest of the clip.
- **Reconstruction happens at LOAD, before validation** (`parseReplay`), so `ValidateState`, the
  fuzz target, every render and every seek see exactly the samples a full file would have produced.
  Nothing downstream can tell a delta clip from a full one, which is what makes this a storage
  change rather than a contract change. A hand-edited file also stays consistent: deleting a line
  loses that line's changes and nothing else, because the carry-forward is a running value rather
  than a reference to a particular line.
- **Compatibility:** files without the header's `delta` key — every clip recorded before today —
  are read literally, as they always were. Both readers already accepted `.ndjson` and
  `.ndjson.gz`, and still do.
- **The user's framing, which is the whole decision:** they wanted to edit clips, and assumed
  de-duplication was already what made them small. It was not — the size had come from compression,
  which is exactly the thing that makes a file unopenable. Doing the de-duplication properly gets
  both.
