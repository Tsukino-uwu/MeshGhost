MeshGhost relay -- hosting instructions
========================================

Only ONE person in your group needs this -- whoever is hosting the session.
Everyone else needs the "player" package instead, not this one.

Setup:
1. (Optional) Open config.json in a text editor if you want a different port
   than the default 7777 -- change the number after the colon in "addr".
   Only edit the text between the quotes, keep the rest of the punctuation
   as-is or the file won't parse.
2. Run run-relay.bat.
3. If your friends are NOT on the same local network/VPN as you, forward
   your port (TCP) on your router to this machine, or run this on a small
   public server/VPS instead.
4. Give your friends this machine's IP address (and port, if you changed it)
   -- they'll need it for their own setup. Treat this like a shared secret:
   there is no password system yet, so anyone with the address can join.

To stop hosting: just close the window (or Ctrl+C).
