Play is over. Now write down what this session learned, so the next session reaches the same goal with fewer calls.
You have at most {{.Budget}} model calls for this. Edit only files in `autoplay/games/{{.Game}}/`.

**Measured or observed only.** Write a fact only when this session saw it through the tools: an answer, an `observe`,
a picture, a `goal` check. What you know about this game from anywhere else does not go in, not even as a hint. Every
new stretch names this session's run log, `{{.RunLog}}`, and the date, {{.Date}}: a label saying when it was walked,
not a reference, because the log is gitignored and will not be there for the next session, so write out what was seen.
Never name a snapshot, a file path outside the repo, or a person.

What to write:
- **`route.md`**: the stretch you walked, in the form of the stretches already there — the maps as `observe` named
  them, the warps and doors taken, where each building was (a Center, a Mart, a gym, by map id), the trainers and scenes
  met, what beat a gym leader or a rival and what did not, and where a trip stopped and what got it going again. A trip
  worth repeating is written as its `run_skill trip` target. Replace a stretch you walked better; never add a second copy.
- **`game.md`**: only a lesson about playing with these tools that holds beyond one place. Update the line it belongs
  to in place.
- **`goals.json`**: a goal for each place on the way that you stood on and that a later session would plan by, placed in
  story order before the goal it leads to, checked by `location.map` (with a badge check so it is not met by coming back
  later), `hints` naming its heading in route.md. Do not change a goal's `done_when` unless the game showed it wrong.
- **Skills**: none new. A skill is kept only once it has succeeded twice; describe a sequence that worked in route.md.

Keep each file under 8 KB: consolidate rather than grow. When you are done, end your turn with one line: `DISTILLED`.
