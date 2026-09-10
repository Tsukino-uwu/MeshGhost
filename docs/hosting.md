# Hosting a server

One person in your group runs the server; everyone else just plays. If that is you, do
[getting-started.md](getting-started.md) first — a host is a player too — then come back here.

**One server hosts every game at once.** A single `meshghost-server.exe` carries Emerald, Crystal,
TEVI and Pseudoregalia sessions at the same time on one port. Games never collide, and players
only ever see others in the same game *and* the same room name. There is nothing to configure for
that.

---

# The short version

1. **Double-click `meshghost-server.exe`.** Leave the window open while people play. It prints
   what it is serving and exactly what to forward.
2. **Make your machine reachable** — pick whichever of the three below fits you. This is the only
   part that ever gives anyone trouble.
3. **Tell your friends your address**, e.g. `203.0.113.40:7777`. They put it in `connect_to`. Tell
   them the `room` word too.
4. **To stop:** close the window, or Ctrl+C. It says goodbye to everyone first so their games
   notice immediately rather than sitting on a frozen room for ~15 seconds.

## Step 2, three ways — pick one

**A. Everyone is on the same network already** (same house, or you all use the same VPN)

Nothing to do. Give them the local address your server prints and you are done.

**B. Port forwarding** — the standard way, and the fastest once it is set up

On your router, forward port **7777** to this machine, on **both TCP and UDP**. Those are two
separate rules on most routers even though it is one number — the session makes first contact over
TCP and then moves to QUIC, which rides on UDP. Your server prints the exact line to follow when
it starts; look for **`to accept players from outside this machine, forward:`**.

Then give friends your public IP (search "what is my ip"), plus `:7777`.

**C. A VPN, if you cannot or would rather not forward ports**

Plenty of people cannot — a landlord's router, a university network, or carrier-grade NAT where
your connection has no public address to forward *to*. Tools like **Radmin VPN**, **Hamachi**,
**ZeroTier** or **Tailscale** put everyone on one virtual local network, and then you are in
case A: no router changes, and you give friends the address the VPN assigns you rather than your
public one.

This is a completely normal way to run MeshGhost, not a workaround. The trade-off is that everyone
has to install the same tool and join the same network, and traffic may take a longer route, so
expect a little more ping than a direct connection.

**D. Rent a small VPS** — worth it only if you want a server that is up when you are not. Any
cheap Linux box works; native Linux and macOS server builds are on the Releases page, and a server
never touches a game so it needs nothing else installed.

That is genuinely all of it. **Everything below is optional** — the shipped defaults were measured
and are what almost every group should stay on.

---

# The longer version

Everything here lives in the `"server"` section of the `config.json` next to
`meshghost-server.exe`. [config.md](config.md) is the terse reference for every key; this page is
the reasoning.

## Locking the server down

**`room_code`** — leave it `""` and anyone who has your address can join. Set it to a word or
phrase and every player must put that same word in their own `config.json` before they get in.
Tell them the same way you tell them the address.

This is a gate, not encryption on its own: someone already watching your network traffic could
read the code in transit. (With the shipped `tls: auto` on both ends, that first contact *is*
encrypted, so in practice on current versions it is protected — see [security.md](security.md) for
what is actually promised.) It stops a stranger who only has your address; it is not a password
system.

**Everyone must be on a current build for this to work.** An old `meshghost.exe` or
`meshghost-server.exe` silently ignores `room_code` and stays wide open with no warning. If in
doubt, have everyone re-download.

**`only_game`** — leave it `""` and your server hosts whatever games people show up with, several
at once if they use different room names. Set it to one game's id to run a dedicated single-game
server, and anyone playing anything else is turned away at connect with a message saying so.

The valid ids, exactly, all lowercase:

| id | game |
|---|---|
| `emerald` | Pokémon Emerald |
| `crystal` | Pokémon Crystal |
| `tevi` | TEVI |
| `pseudoregalia` | Pseudoregalia |

A typo turns **everyone** away, including you. If that happens, `meshghost-server.log` prints the
value it actually read at startup. Players change nothing on their end either way — their game
announces its own id.

## How many players can I host?

**Your upload speed decides this, not the software.** There is no hard limit built in.
`max_clients` ships at **8** because that is a size almost any home connection carries comfortably,
not because 9 would break anything. Raise it as far as your uplink and your game are happy with.

Because the host relays everyone's position to everyone else, host upload grows with the **square**
of the room — doubling the players roughly quadruples your upload. That is why 8 → 16 costs so much
more than 2 → 4.

At the default 15 Hz, for the heaviest supported game (Pseudoregalia), in the units your internet
plan is sold in:

| Players | Your upload needed |
|---|---|
| 4 | ~0.9 Mbps |
| 8 *(the default)* | ~4.1 Mbps |
| 12 | ~9.5 Mbps |
| 16 | ~17.2 Mbps |
| 24 | ~39.5 Mbps |
| 32 | ~71.1 Mbps |

To use this: run any speed test, look at the **upload** number (not download — they are usually
very different, and upload is the smaller one), and do not plan to spend more than about half of
it here. The rest is for your own game, voice chat and headroom. A link run at 100% does not
just get slower, it gets erratic, and then ghosts stutter for everyone at once.

Two things worth knowing before raising it:

- **Raising `send_hz` multiplies every number above by up to 6.7.** Raising both together is what
  actually gets people into trouble. Change one at a time.
- **These are network numbers only.** Your game also has to *draw* every ghost, and a 3D game
  drawing 15 extra characters costs real frames on everyone's machine. If people report the game
  getting choppy while the network looks fine, that is this, and the fix is a smaller room.

To find your own real ceiling rather than trusting the table, the repo has a load-test rig that
fills a room with synthetic players — see `dev-scripts/README.md`.

## Why `send_hz` is 15, and why to leave it there

`send_hz` is how many times a second every player in your room sends their position. Three ways of
saying the same number, since different people know different ones:

- **Hz** — times per second. 15 Hz is 15 updates every second.
- **ms** — the gap between updates, flipped around. `1000 / Hz = ms`, so 15 Hz ≈ one update every
  67 ms. Higher Hz means a *smaller* gap; they move in opposite directions, which is the usual
  source of confusion.
- **Tickrate** — what game servers usually call it. A "64 tick" server is 64 Hz. `send_hz` is that
  same setting, so a 15 Hz room is a "15 tick" room.

**15 is not a compromise, it is where the visible improvement stops.** In a blind test where the
rate was hidden from the person watching, 15 and 20 were indistinguishable, and stutter a watcher
can actually see only starts appearing below about 10. Your client already smooths motion between
updates (`interp`), so 15/second already looks smooth.

The cost of raising it, on the other hand, is immediate and real. Going from 15 to the maximum 100
multiplies **everyone's** bandwidth by nearly 7 — in both directions, and your machine pays worst.
Shown per hour, because per second the same number looks tiny and adds up fast:

**Each player's own upload** (the same no matter how big the room):

| | |
|---|---|
| 15 Hz *(default)* | ~8.8 KB/s = ~31 MB/hour |
| 100 Hz *(max)* | ~58.3 KB/s = ~205 MB/hour |

**Each player's download**, at 15 Hz: ~31 MB/hour in a 2-player room, ~92 in a 4-player,
~215 in an 8-player, ~461 in a 16-player.

**Your upload as the host** — everyone's position relayed to everyone else — at 15 Hz:

| Room | Host upload |
|---|---|
| 2 players | ~17.5 KB/s = ~61 MB/hour |
| 4 players | ~104.9 KB/s = ~369 MB/hour |
| 8 players | ~489.8 KB/s = ~1.7 GB/hour |
| 12 players | ~1.1 MB/s = ~4.0 GB/hour |
| 16 players | ~2.0 MB/s = ~7.2 GB/hour |
| 24 players | ~4.7 MB/s = ~16.6 GB/hour |
| 32 players | ~8.5 MB/s = ~29.8 GB/hour |

At 100 Hz, multiply all of these by 6.7.

These are real measurements rather than guesswork, but treat them as the right ballpark rather
than exact to the byte. They were measured for **Pseudoregalia** deliberately, because it sends
the most detailed update of the four (597 bytes, against 249 for TEVI and 206 for Emerald;
Crystal sends less than Emerald). Hosting any of the other three costs roughly a third of this or
less. Pseudoregalia's own update has grown a little since that measurement, so if you host that
one specifically, treat the table as a floor and leave headroom.

Valid range is 10–100. A player may still choose to send *slower* than the room if their
connection needs it; nobody can send faster than what you set.

## Transports — tcp, udp, quic

`transport` is what your server actually offers. Players find whatever you turn on by themselves,
so **you never have to tell them which to use** — and a player asking for something you do not
serve lands on a working TCP connection rather than failing.

Whatever anyone picks, every client makes first contact over TCP, asks what you serve, and only
then switches. That is why nobody needs to know port numbers.

**`tcp,quic` is the default and is what you want.** It gives your players an encrypted session
without anyone doing anything, and both sit on the same port *number*, so hosting stays one number
to forward.

| | |
|---|---|
| **tcp** — always served whether you list it or not | Works everywhere, and the only one that can be inspected when something goes wrong, so it is easiest to get help with. Its weakness: one lost packet holds up the positions queued behind it, so a bad connection looks "stuttery, then catches up". Not encrypted unless `tls` is on — which it is, by default, on both ends. |
| **quic** — the other half of the default | Same loss handling as udp, so the same benefit on a bad connection, and encrypted always with nothing to switch on. Rides on UDP but keeps tcp's port number. Harder to troubleshoot. |
| **udp** — never chosen for anyone; you must ask for it by name | Best on a genuinely bad connection and the lightest of the three. But **it can never be encrypted** — room codes travel in the clear — and it is the hardest to troubleshoot. Prefer quic unless you have a specific reason. |

> **"But isn't udp the fast one?"** Not quite, and this is the most common misunderstanding. On a
> connection that is not dropping packets, all three arrive at exactly the same speed — same route,
> same physics. What udp and quic avoid is one lost packet holding up the ones behind it. The win
> is **smoothness on a bad connection**, not lower ping on a good one.

Short version:

| | |
|---|---|
| Just want it to work? | `tcp,quic` — the default, leave it |
| Keep it simplest? | `tcp` |
| Hosting for a group on flaky connections? | `tcp,udp` — but this drops the encrypted default, so room codes go back to travelling in the clear |

**What to forward, per transport:**

| Transport | Rule |
|---|---|
| tcp | forward **TCP** 7777 |
| quic | forward **UDP** 7777 — the same number as tcp, on purpose |
| udp | forward **UDP** 7777, and see below |

Adding plain `udp` is the one case that needs more, because udp wants the same UDP port quic is
already using. quic **keeps** the shared number (it is served by default, plain udp is opt-in), so
udp moves aside to `listen_udp`, which defaults to **7780** — forward UDP there as well. The
server refuses to start and tells you if you forget.

A player set to a transport you have not forwarded just sees a timeout with nothing explaining it.
If one person cannot connect and everyone else can, check this first.

## Encryption and proving it is really you

**`tls`** ships at `auto`, which encrypts TCP connections for every player whose client asks —
which is all current ones — while still accepting those that do not. This matters even though
quic is already encrypted, because **every** player makes first contact over TCP and that is where
their `room_code` is sent. `required` refuses unencrypted players outright; `off` is plaintext.

With TLS on, your server prints a **`tls certificate fingerprint:`** line at startup. That string
is how a player can verify they reached *your* server and not someone impersonating it: send it to
them some other way — chat, not through the server — and they put it in `tls_fingerprint`. It
changes every restart, so it is a per-session thing, and nobody has to do it. Without it the
traffic is still encrypted, just not *proven* to be yours.

## Seeing what your server is actually doing

Start it from a command prompt with:

```text
meshghost-server.exe -introspect=30s
```

and every 30 seconds it logs what it currently believes: which rooms exist, who is in each and
over which transport, and how much position data it is really relaying — including how much is
going to players in a different area of the game who will discard it. That last part is the
measured answer to the bandwidth tables above rather than the predicted one.

It prints nothing secret: no room codes, no game data. Everything the server prints also goes to
`meshghost-server.log` next to the exe, so a window that closed too fast is not lost.

## Ghost collision

`ghost_collision` ships `disabled`, which asks every game to make sure no ghost ever blocks anyone
— no crowd wedged in a doorway. `enabled` leaves each game to its own behaviour. Players can also
turn it off just for themselves, and the **strictest side wins**: you can take collision away from
everyone, a player can take it away from themselves, and nobody can force it back on.

Two honest caveats: it is a *request*, since the server has no idea what these games are or what
collision means in them; and **no shipped mod acts on it yet** (as of 2026-09-08) — the setting
travels the whole way and every shipped mod currently ignores it. See
[troubleshooting.md](troubleshooting.md#ghost-collision) for what each game actually does today.

## Where to go next

- **[config.md](config.md)** — every key including the ones not covered here, with its shipped value.
- **[security.md](security.md)** — what is checked-safe, what is encrypted, and the gaps that remain.
- **[reviewing.md](reviewing.md)** — auditing the code you are about to run on your own machine.
- **[networking.md](networking.md)** — how the relay actually works, traced through the real code.
