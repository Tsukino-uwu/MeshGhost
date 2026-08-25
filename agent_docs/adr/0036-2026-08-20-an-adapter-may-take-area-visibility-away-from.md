# 2026-08-20 — An adapter may take area visibility away from the core: `render_all_areas`

<!-- ADR 0036. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-20
- **Decision:** The bridge `hello` gains an optional, adapter-local `render_all_areas` flag. Set,
  the core delivers every remote's state regardless of `area_id` and issues no area-based
  despawns; area visibility becomes entirely the adapter's job. Absent means false — the core's
  own cross-area equality filter (the 2026-08-13 ADR) applies exactly as before.
- **Status:** accepted, shipped (bridge, core, Emerald adapter, `TestRenderAllAreasDeliversCrossArea`).
- **Context:** Emerald's cross-map ghosts translate a CONNECTED neighboring map's coordinates into
  the local frame — a peer across a route seam renders correctly. But the core's cross-area filter
  despawned every follower at every seam crossing: an echoed `area_id` lags a real crossing by one
  delivery, the equality test cannot know two maps are connected, and the resulting
  despawn/respawn was a visible pop the adapter could not prevent from its side. Diagnostically
  expensive too: every adapter-side instrument measured innocent because the killer was upstream.
- **Options considered:** (1) A grace period in the core's filter — rejected: a timing patch on a
  judgment the core should not be making, wrong for genuinely cross-area peers an adapter can now
  render. (2) A room `features` entry — rejected: feature sets are matched room-wide, and this is
  a statement about one adapter's rendering, not about the room; using features would fragment
  room compatibility for a purely local concern. (3) An adapter-local hello flag — chosen.
- **Resolution:** One bool through `bridge.Hello`, read under the core's lock at attach, reset on
  adapter detach, checked in `remoteStatesAt`. The filter that remains is still equality-only;
  the core learns nothing about any game. The user's standing rule, restated during this change:
  *"I want the server/client to stay dumb & never know anything about the games"* — the flag
  complies by REMOVING an area judgment from the core rather than teaching it one.
- **Consequences:** An adapter that sets the flag owns ALL area hiding, including for maps it
  cannot translate (Emerald's untranslated peers keep their foreign `area_id` and stay hidden by
  the adapter's own gates). The relay is untouched; rooms mix flagged and unflagged clients
  freely. The old behaviour is byte-identical for every adapter that does not set the flag.
