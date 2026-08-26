
## CONFIRMED ON SCREEN 2026-08-26 — Crystal: no ghost painted over the party menu

**The user, after reproducing the failed-Surf case against the fix:** *"the 'can't use surf' thing
got fixed at least."* The fault was `wMenuBorder*` being one scratch slot — the "can't use that
here" text box REPLACES the party menu's full-screen rectangle, so a single remembered rectangle
protected six rows of a screen that was entirely menu. `lastMenuBox` is now a list; a peer inside
ANY live rectangle is hidden. `pitfalls/by-lesson.md` has the general form.

**What it does NOT cover:** one reproduction, one menu stack (party menu + failed field move), on
the compare rig in loopback. Other stacks — nested bag pockets, the PokéGear, a menu over a text
box already open — were not exercised. The START-menu and plain-text-box clipping confirmed
2026-08-19 were not re-watched after the list change.

## CONFIRMED ON SCREEN 2026-08-26 — Crystal: the ghost returns after a same-town Fly

**The user, same session, third fix attempt:** *"only the drawn ghost is actually following
during/after fly is used. the spawned ghost just 'teleport' after fly has been used"* — i.e. both
copies are back on screen after the landing, which is exactly what the two previous attempts
failed at. The fault chain and the two failed fixes are in `UNVERIFIED.md` 2026-08-26 and
`pitfalls/by-lesson.md`; the fix that held is refusing the exact `wMenuBorder*` value a
warp-teardown (or adapter load) leaves behind until the slot changes.

**What it does NOT cover:** the ghost's behaviour DURING the fly (the game hides every character
through its cutscene — that part is correct by construction, see `documentation.md`), the Fly
landing animation on a ghost (does not exist on the wire; measured), and any non-Fly warp leaving
a stale rectangle (doors and Dig were not re-tested).
