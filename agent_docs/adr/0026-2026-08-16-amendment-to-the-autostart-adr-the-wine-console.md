# 2026-08-16 — Amendment to the autostart ADR: the Wine console valve is removed

<!-- ADR 0026. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** Delete the default that turned the client's console window on under Wine. Keep
  `show_console` for real Windows, and keep Wine detection only to say a console cannot appear.
- **Status:** Done same day, after the Linux tester ran v0.7.0 under Proton.
- **Context:** The original ADR shipped a safety valve: under Wine, show a console by default, so
  an autostarted client that outlived its game could at least be seen and closed. Its own code
  comment set the condition for removing it — *"if the client reliably dies with the game there,
  this becomes noise rather than a valve."*
- **What the test showed:** both halves were wrong. The window never appears (Wine emulates a
  console only through wineconsole/conhost, and a Proton-launched game has no backend for it —
  `AllocConsole` can return success and produce nothing), and `-exit-with-pid` reaps the client
  across the Wine boundary anyway, six sessions out of six. The valve guarded a door that was
  already shut, with a lock that did not work.
- **Consequences:** One less platform special case, and one fewer promise the client makes that it
  cannot keep. The honest replacement is a single log line when `show_console` is set under Wine.
  **The general lesson is the one worth keeping**: a mitigation written for an unmeasured risk
  should carry its own removal condition, because the measurement usually arrives later and
  quietly — this one did, in a tester's log, and would otherwise have stayed forever.
