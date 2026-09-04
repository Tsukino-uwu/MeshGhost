# 2026-09-04 — The core tells the adapter when it is recording

<!-- ADR 0052. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** a new bridge message, `recording_state`, core → adapter, pushed **on change** and
  again **on adapter attach**. Payload: `recording` (bool) and `started_unix_ms` (the wall-clock
  start, 0 when not recording). The adapter draws whatever indicator it likes, or nothing.
- **Status:** built 2026-09-04 — Go side tested (`core/recordingstate_test.go`, both edges plus the
  de-dupe), adapter side built and deployed, **not yet watched on screen**.

## Why a message exists at all

The record hotkey is system-wide and lives in the core process (ADR 0048), and **the core never
touches the game** (the standing rule). So the only feedback a recording toggle could give was a
console line — and the console is hidden by default, which is how the user runs:

> *"I have the console hidden, and was unsure if f9 was doing something or not when using it. i
> usually did f9 2-3 times then f11"*

The same day, with the log open and a `RECORDING STARTED`/`STOPPED` line that had been fixed hours
earlier specifically to be unambiguous, the agent read it, concluded a recording was running,
pressed the toggle to stop it — and started one instead, leaving a 54-sample clip that briefly
became the newest file and therefore what `replay_last` would play. **If the log is not enough for
the process that writes it, it is not enough.**

## Why STATE, not an event

An event ("a recording just started") is lost on anyone who was not attached to hear it. The
question an indicator answers is *am I recording right now*, continuously, so the message is the
answer to that question and is pushed on attach as well as on change. An adapter that comes up
mid-recording — a game relaunched during one — shows the truth rather than nothing. Same shape and
same reasoning as `session_policy`, which is the only other core → adapter state message.

## Why the START TIME rather than an elapsed duration

The user asked for the duration too: *"so you know how long you have recorded as right now there is
no feedback at all for that either"*. Sending elapsed time would mean a message per second forever;
sending the start instant means the adapter counts locally and the message stays push-on-change. It
also makes the mid-recording attach correct rather than starting from zero.

**Wall clock is legitimate here and would not be in general:** the bridge is loopback-only by
construction (an adapter never learns a relay address), so both processes are on one machine and
share a clock. Nothing about this generalises to a relay-side message.

## What the adapter does with it, and what that is NOT

The Pseudoregalia adapter draws a red `●` with the elapsed time beside it, fixed in the top-right of
the screen. **No new rendering mechanism was needed**, which is the reason this was cheap: the
nametag's coloured "box" is not geometry — it is a second `TextRenderComponent` drawing behind black
text with a tinted material. A circle is therefore a *character*, and the corner is a fixed offset
in the camera's own frame, recomputed per tick. UMG would be the "proper" screen-space route and
needs a widget class this project has no way to author.

**This is not a shared setting yet.** `adapters/CLAUDE.md`'s rule is that a player-facing preference
is defined once in the shared config and every adapter honours it or logs that it cannot. The
indicator is exactly that shape, and the toggle is still open work — see `agent_docs/ideas.md` for
the decisions already made (top right; a dot; default off for the automatic `record_on_launch` path)
and the ones still open.

## The alternative that was rejected

Making the adapter poll the core for recording state, or read the same config the core reads. Both
fail the same way: recording is started by a keypress the adapter never sees, at a moment the
adapter has no reason to look, and polling for a thing that changes twice an hour is worse than
being told.
