# "My antivirus flagged it"

MeshGhost's client and server are unsigned Go binaries, and two different things flag them. They
are separate causes with separate answers, so they are worth telling apart rather than lumping
together as "it's a false positive, trust me."

**1. Scanners that don't recognise Go binaries.** This one isn't about MeshGhost at all — it
happens to Go programs generally, and Go's own FAQ says so
([go.dev/doc/faq](https://go.dev/doc/faq#virus_scanning_software)):

> This is a common occurrence, especially on Windows machines, and is almost always a false
> positive. Commercial virus scanning programs are often confused by the structure of Go binaries,
> which they don't see as often as those compiled from other languages.

**2. A Microsoft Defender detection whose name ends in `!ml`.** That suffix means the verdict came
from a machine-learning model rather than a signature match — Defender is not saying "this is a
known bad file", it's saying "this *looks* like one". And the profile it matches on is, honestly,
accurate about MeshGhost: the binaries are unsigned, they're downloaded by very few people so they
have no reputation, they open network connections, and for Pseudoregalia the game's mod starts one
*for* you rather than you double-clicking it. That combination is also what a dropper looks like.
The heuristic isn't being stupid; it just can't tell the difference yet.

**What you can actually check, rather than taking our word for it:**

- The whole source is in this repo, and the release binaries are built from it by GitHub Actions —
  the build is a public workflow log, not something produced on a developer's machine.
- Every release asset shows a SHA-256 on the [Releases page](https://github.com/Tsukino-uwu/MeshGhost/releases). If the file you have
  matches, it's the file CI produced.
- If it's specifically the Pseudoregalia mod starting `meshghost.exe` that your scanner objects to,
  set the environment variable `MESHGHOST_NO_AUTOSTART` to anything and start the client yourself —
  that path is unchanged and fully supported.

**What we intend to do about it:** get the binaries code-signed, via SignPath's free offering for
open-source projects. That work hasn't started. It should help with both causes, but it's worth
being straight that signing is a lever rather than a switch — an ML verdict weighs reputation as
well as signing, and reputation is something a new certificate earns over time rather than arrives
with. If your scanner flags a MeshGhost binary, reporting it to that vendor as a false positive
genuinely helps, which is the same thing Go's FAQ asks for.
