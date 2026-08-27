using System.Collections.Generic;
using System.Reflection;
using BepInEx;
using UnityEngine;

namespace MeshGhostTevi
{
    // Phase 6, step 6.1: the smallest thing that proves the toolchain end to end -- a plugin
    // that loads and logs, nothing else.
    // Step 6.2: read the real local player's state once per second and log it, TEVI's analogue
    // of Emerald's Phase 1 read-only motion-tracking print. Class/field names below are cited
    // facts from decompiling this machine's own Assembly-CSharp.dll (2026-07-09) with ilspycmd
    // -- see agent_docs/verified.md's Phase 6.2 entry once confirmed, and
    // agent_docs/licensing.md for the "facts, never code" posture this follows.
    // Step 6.3: proved screen/world ghost placement with a placeholder box before tackling a
    // real character-visual clone (TEVI's characters are plain SpriteRenderer + Animator, not
    // Spine -- confirmed by decompiling PixelCharacter.cs, zero Spine references, unlike the
    // ~14 boss/environment files that do use it). Superseded by the real remote-ghost visual
    // (see UpsertRemoteGhost) and removed once 6.6 confirmed it live.
    // Step 6.4/6.5: a real bridge connection (see BridgeClient.cs) to the local core process,
    // sending local_state every frame and rendering whatever render_remote/despawn_remote comes
    // back.
    // Step 6.6: two real players, confirmed live 2026-08-13 -- a second TEVI copy running from
    // a standalone build folder (see agent_docs/phases/phase6.md's dual-instance notes) pointed
    // at its own local core process via BridgePort's config override below, both connected
    // through one real (non-loopback) relay.
    [BepInPlugin(PluginGuid, PluginName, PluginVersion)]
    public class Plugin : BaseUnityPlugin
    {
        public const string PluginGuid = "dev.meshghost.tevi";
        public const string PluginName = "MeshGhost";
        // Also sent as this adapter's bridge Hello game_version (internal/bridge.Hello,
        // added for relay-safety hardening — see the ADR in agent_docs/architecture.md).
        // This is this *plugin's* own version, not TEVI's game build — no cited API exists
        // to read that, and CLAUDE.md's "no addresses/APIs from memory" rule means one
        // isn't guessed at here. Opaque to the core/relay, compared only by equality: it
        // catches two peers running different revisions of this adapter, the most likely
        // real source of a silent protocol mismatch.
        // Bumped 0.1.0 -> 0.2.0 (2026-08-15): real fixes have landed since 0.1.0 (the
        // zone-transition invisible-ghost fix, cross-area filtering, pause-map marker work --
        // see adapters/tevi/README.md's "How this adapter was built") without the version
        // string ever moving, which meant two peers on genuinely different revisions were
        // both reporting the same version -- exactly the failure this field exists to catch.
        // Deliberate breaking change: an older TEVI client's version string will no longer
        // match a newer one's, and game_version mismatches are a hard reject at the relay.
        public const string PluginVersion = "0.2.0";

        // Gates the per-remote redraw trace in UpsertRemoteGhost (see LastDiagLogTime below):
        // it was added to chase the 2026-08-14 zone-transition ghost-invisibility bug, which is
        // now root-caused and fixed (see the basesprite.enabled reset in CreateRealGhostVisual).
        // Left off by default since it fires every 2s per remote, forever -- flip to true only
        // when actively chasing a similar live repro. Matches the flag convention already used
        // by the other two adapters (Emerald's DIAG_STEP_CURVE/DIAG_SCREENPOS_PARTS,
        // Pseudoregalia's ANIM_PULSE_TRACE).
        private const bool DIAG_REDRAW_TRACE = false;

        // TEVI's FIRST TWO PROBES, 2026-08-27, and they are compile-time flags rather than
        // scripts because of the host: BepInEx has no equivalent of BizHawk's Lua console, so
        // there is nothing to attach a standalone probe to. A probe here is a block compiled out
        // when its flag is false, exactly like DIAG_REDRAW_TRACE above. PROBES.md is the index.
        //
        // NEITHER HAS BEEN RUN. Both were written blind, from the code, and a probe that has never
        // run proves nothing -- see adapters/tevi/UNVERIFIED.md.

        // DIAG_MARKER_STALENESS answers ONE question: how long has the FullMap marker been showing
        // a position no peer has confirmed? The marker is update-driven -- UpdateRemoteMapMarker
        // runs only from UpsertRemoteGhost, which runs only when a render_remote arrives -- so a
        // peer that stops sending leaves it frozen. That is a shipped defect, and the thing worth
        // measuring is the AGE of what is on screen, which no amount of reading the code gives you.
        //
        // Fires only while the map is actually open AND at most once a second, because a per-frame
        // log line is a per-frame stall on any host (adapters/emulator/CLAUDE.md measured 63-83ms
        // for one line plus a flush; BepInEx's logger is cheaper but the principle is the same).
        private const bool DIAG_MARKER_STALENESS = false;
        private const float MarkerStalenessLogInterval = 1f;
        private float lastMarkerStalenessLogTime;

        // DIAG_MENU_GATE prints what the adapter can actually SEE at each play-session transition:
        // whether the player object is null, whether the FullMap says it is open, and which branch
        // was taken. It exists to settle documentation.md's claim that the pause-vs-main-menu
        // distinction is PlayerControl.instance, when this adapter reads
        // EventManager.Instance.mainCharacter and PlayerControl appears nowhere in it. Asked, the
        // user was unsure and said only that the behaviour works today -- so this is the
        // measurement, and nothing was changed on a guess. The 2026-08-18 false regression came
        // from reasoning about this exact question from code.
        //
        // Edge-triggered on the transition, so it costs one line per menu open or close.
        private const bool DIAG_MENU_GATE = false;

        // Diagnostic-only throttling. First attempt (position-change-triggered with a 0.5-unit
        // epsilon) still produced 7324 lines in one session: real per-frame movement deltas in
        // TEVI are themselves ~0.5-0.7 units (confirmed from that run's own log), so the epsilon
        // sat right at the noise floor and fired almost every frame -- the exact "guessed
        // constant instead of measured" mistake already flagged once in Emerald's history.
        // Fix: cap logging to a fixed cadence while state is continuously changing (position
        // drifts constantly while moving; that's expected, not interesting per-frame), but still
        // log immediately on a discrete change (direction flip, anim change, area change) since
        // those are genuinely rare events worth seeing right away.
        private const float MaxSilenceSeconds = 5f;
        private const float MinLogIntervalSeconds = 0.5f;
        private const float PositionChangeEpsilon = 0.5f;
        private float timeSinceLastLog = MaxSilenceSeconds;
        private bool hadPlayerLastFrame;
        private CoreLauncher launcher;
        private Vector3 lastLoggedPos;
        private Character.Direction lastLoggedDir;
        private Character.PlayerAniState lastLoggedAnim;
        private byte lastLoggedArea;

        private BridgeClient bridge;
        private const string BridgeHost = "127.0.0.1";

        // The BASE of the port walk, not the only port tried. Since 2026-08-27 the adapter walks
        // BridgeClient.BridgePortCount ports up from here, matching the other three adapters, so
        // two local TEVI instances each find their own core with nothing configured. It stays
        // configurable to move the whole range; before the walk it had to be set by hand on the
        // second instance, and forgetting to was a real failure mode (agent_docs/phases/phase6.md,
        // and the .gitignore entry for dev-scripts/*.local.bat records the same trap in Emerald).
        private const int DefaultBridgePort = 7778;

        // Sent as this adapter's bridge Hello (internal/bridge.Hello) so the core can connect
        // to the relay without the user typing "game" into config.json themselves -- see
        // agent_docs/architecture.md's ADR. Opaque to the core; matches the folder name under
        // games/tevi/ in the shipped release, per packaging/README.md's convention.
        private const string GameId = "tevi";

        // Step 6.6-prep (real ghost visuals, done solo via loopback -- see phase6.md): a remote
        // ghost is a real clone of the local player's own visual object
        // (CharacterBase.spranim_prefer.pixel.gameObject), not a flat placeholder square.
        // PixelCharacter has no Update/Awake/Start of its own (confirmed by decompiling
        // PixelCharacter.cs) -- it is a pure data holder (Animator + SpriteRenderers), so it is
        // safe to detach and clone standalone without dragging along CharacterBase's gameplay
        // logic, which lives on a different object entirely.
        private sealed class RemoteGhostVisual
        {
            public GameObject Go;
            public PixelCharacter Pc;
            public string LastAnim;

            // The real, measured offset between the source player's t.position and its own
            // spranim_prefer.pixel.transform.position at clone time -- read directly rather than
            // guessed, the same real-offset-not-a-constant fix Emerald needed a hardcoded
            // GHOST_Y_CORRECTION for (see verified.md's Phase 5.5 entry). Confirmed necessary
            // live 2026-08-12: without it, the clone rendered near the player's head instead of
            // their body, because pixel.gameObject sits above the root at its own local offset,
            // which Instantiate()-ing it standalone and setting world position directly throws
            // away.
            public Vector3 AnchorOffset;

            // Throttled diagnostic redraw logging (see UpsertRemoteGhost) -- added while
            // chasing the 2026-08-14 zone-transition ghost-invisibility bug so a next repro
            // shows whether a ghost's actual position/active-state drifts wrong sometime after
            // creation, not just what it looked like at the moment it was made.
            public float LastDiagLogTime = float.NegativeInfinity;
        }

        private readonly Dictionary<string, RemoteGhostVisual> remoteVisuals = new Dictionary<string, RemoteGhostVisual>();

        // Step 6.7 (agent_docs/phases/phase6.md): a remote's marker on TEVI's map screen
        // (FullMap, the pause-menu map -- room-grid based, not continuous-position-based).
        // Separate from RemoteGhostVisual: the world-space ghost only helps when a peer is
        // on-screen with you; this helps anywhere in the shared zone, gated on the map
        // actually being open and the room already being discovered by the local player (see
        // UpdateRemoteMapMarker).
        private sealed class RemoteMapMarker
        {
            public GameObject Go;

            // When a render_remote last moved this marker. Written unconditionally -- one float
            // assignment on a path that is already touching the object -- and read only under
            // DIAG_MARKER_STALENESS. The marker's AGE is the whole question the staleness defect
            // turns on, and it is not recoverable after the fact from anything on screen.
            public float LastUpdateTime;
        }

        private readonly Dictionary<string, RemoteMapMarker> remoteMapMarkers = new Dictionary<string, RemoteMapMarker>();

        // FullMap.playerPos (the local player's own map marker, a SpriteRenderer) and
        // FullMap.maxroom (the per-area stride into FullMap.roomtilelist) are both private
        // fields -- confirmed by decompiling Assembly-CSharp.dll with ilspycmd, same
        // reflection approach already used below for EventManager.mainCharacter's shape
        // differing across builds. roomtilelist itself and isFullMap are public, read
        // directly with no reflection needed.
        private static readonly FieldInfo FullMapPlayerPosField =
            typeof(FullMap).GetField("playerPos", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo FullMapMaxRoomField =
            typeof(FullMap).GetField("maxroom", BindingFlags.NonPublic | BindingFlags.Instance);

        // Tinted distinctly from the local player's own (default-colored) FullMap.playerPos
        // marker -- same cyan already established for the remote character ghost (step
        // 6.4/6.5), one consistent "this is a MeshGhost marker" visual language.
        private static readonly Color RemoteMapMarkerColor = new Color(0f, 1f, 1f, 1f);

        // Set once per Update, before bridge.DrainInto runs, so UpdateRemoteMapMarker (called
        // from inside UpsertRemoteGhost, itself invoked by DrainInto) has the local player's
        // current area to gate against without needing to parse it back out of the AreaId
        // string on every remote.
        private byte currentLocalArea = 255;

        // Finds the FullMapTile for (area, x, y) the same way FullMap.MoveMapToCurrentRoom
        // does for the local player's current room -- confirmed live by reading that method
        // directly, not guessed: roomtilelist is a flat array indexed area*maxroom+slot, found
        // by a linear scan of that area's slice comparing GetX()/GetY(). Generalized here to
        // any (area, x, y), not just "current."
        private static FullMapTile FindRoomTile(byte area, int x, int y)
        {
            FullMap map = FullMap.Instance;
            if (map == null || map.roomtilelist == null || FullMapMaxRoomField == null)
            {
                return null;
            }
            int maxroom = (int)FullMapMaxRoomField.GetValue(map);
            int start = area * maxroom;
            int end = start + maxroom;
            for (int i = start; i < end && i < map.roomtilelist.Length; i++)
            {
                FullMapTile tile = map.roomtilelist[i];
                if (tile != null && tile.GetX() == x && tile.GetY() == y)
                {
                    return tile;
                }
            }
            return null;
        }

        // room_x/room_y arrive over the wire from a peer (adapters/_template/PROTOCOL.md:
        // inbound render_remote data is peer-controlled, bound before feeding your engine).
        // Not a measured game constant -- TEVI's real room grid is far smaller than this -- just
        // a generous sanity bound so a bogus/adversarial value can't reach GetRoomWalkedBool
        // (unknown internals, currently only caught by DrainInto's per-line try/catch, which
        // means a bad value spams that catch's log line every frame instead of just being
        // filtered out here).
        private const int MaxRoomCoordinate = 100000;

        private void UpdateRemoteMapMarker(string playerId, BridgeClient.RemoteState state)
        {
            FullMap map = FullMap.Instance;
            bool roomInRange = state.RoomX.HasValue && state.RoomY.HasValue
                && Mathf.Abs(state.RoomX.Value) <= MaxRoomCoordinate
                && Mathf.Abs(state.RoomY.Value) <= MaxRoomCoordinate;
            bool wantVisible = map != null && map.isFullMap
                && roomInRange
                && state.AreaId == currentLocalArea.ToString()
                // Fog-of-war: never let a peer's marker reveal a room the local player hasn't
                // personally discovered yet (SaveManager.GetRoomWalkedBool is the game's own
                // discovery-state query, confirmed live by reading FullMapTile.SetVisible's
                // use of it).
                && SaveManager.Instance != null
                && SaveManager.Instance.GetRoomWalkedBool(currentLocalArea, state.RoomX.Value, state.RoomY.Value, 0, 0);

            if (!remoteMapMarkers.TryGetValue(playerId, out RemoteMapMarker marker) || marker.Go == null)
            {
                if (!wantVisible)
                {
                    return; // nothing to create yet, and nothing to show
                }
                if (map == null || FullMapPlayerPosField == null)
                {
                    return;
                }
                SpriteRenderer template = (SpriteRenderer)FullMapPlayerPosField.GetValue(map);
                if (template == null)
                {
                    return;
                }
                // Same parent as the original so it inherits FullMap's own zoom rescaling
                // (see GemaFixedSizeMapIcon.Update, which explicitly rescales map icons
                // against FullMap.Instance.transform.localScale every frame) instead of
                // staying a fixed size while the map zooms.
                GameObject go = Instantiate(template.gameObject, template.transform.parent);
                go.name = $"MeshGhostMapMarker_{playerId}";
                SpriteRenderer sr = go.GetComponent<SpriteRenderer>();
                if (sr != null)
                {
                    sr.color = RemoteMapMarkerColor;
                }
                marker = new RemoteMapMarker { Go = go };
                remoteMapMarkers[playerId] = marker;
            }

            if (!wantVisible)
            {
                marker.Go.SetActive(false);
                return;
            }

            FullMapTile tile = FindRoomTile(currentLocalArea, state.RoomX.Value, state.RoomY.Value);
            if (tile == null)
            {
                marker.Go.SetActive(false);
                return;
            }
            marker.Go.SetActive(true);
            marker.Go.transform.position = tile.transform.position;
            marker.LastUpdateTime = Time.time;
        }

        // PROBE, off unless DIAG_MARKER_STALENESS. Reports how old each visible marker's position
        // is while the map is actually open. A marker whose age keeps climbing is the shipped
        // update-driven defect happening in front of you; one that stays near zero is a peer still
        // sending. Gated on the map being open and throttled to once a second, because a per-frame
        // log line is a per-frame cost on every host this project has measured.
        private void DiagMarkerStaleness()
        {
            FullMap map = FullMap.Instance;
            if (map == null || !map.isFullMap || remoteMapMarkers.Count == 0)
            {
                return;
            }
            if (Time.time - lastMarkerStalenessLogTime < MarkerStalenessLogInterval)
            {
                return;
            }
            lastMarkerStalenessLogTime = Time.time;
            foreach (KeyValuePair<string, RemoteMapMarker> kv in remoteMapMarkers)
            {
                if (kv.Value == null || kv.Value.Go == null)
                {
                    continue;
                }
                Logger.LogInfo($"MeshGhost/probe marker-staleness: peer={kv.Key} "
                    + $"visible={kv.Value.Go.activeInHierarchy} "
                    + $"ageSinceLastUpdate={Time.time - kv.Value.LastUpdateTime:0.00}s");
            }
        }

        private void DespawnRemoteMapMarker(string playerId)
        {
            if (remoteMapMarkers.TryGetValue(playerId, out RemoteMapMarker marker))
            {
                // SetActive(false) alone left the GameObject (and its dictionary entry) alive
                // forever -- every despawn/respawn of the same peer (a reconnect, an area
                // transition) instantiated a fresh marker without ever freeing the old one, a
                // monotonic per-reconnect leak. Destroy it and drop the entry so the next
                // UpdateRemoteMapMarker for this playerId creates a clean new one.
                if (marker.Go != null)
                {
                    Destroy(marker.Go);
                }
                remoteMapMarkers.Remove(playerId);
            }
        }

        // Set once per Update from EventManager.Instance.mainCharacter, before bridge.DrainInto
        // runs, so UpsertRemoteGhost has a live template to clone from the first time a remote
        // shows up. Cloning the *local* player's own visual is exactly correct for the loopback
        // test (the remote genuinely is you); for a real different remote character later this
        // would need its own per-character template, deferred until 6.6 has a real second peer.
        private CharacterBase cloneTemplate;

        private GameObject CreateRealGhostVisual(CharacterBase templatePlayer, string name, out PixelCharacter pc, out Vector3 anchorOffset, out string inheritedSpriteState)
        {
            // Measure the real offset before instantiating a detached copy loses the parent
            // relationship that produced it.
            anchorOffset = templatePlayer.spranim_prefer.pixel.transform.position - templatePlayer.t.position;

            // Diagnostic only, captured before the reset below overwrites it -- added while
            // chasing the 2026-08-14 zone-transition ghost-invisibility bug, to confirm what
            // render state Instantiate() actually inherited from the live template.
            SpriteRenderer templateBase = templatePlayer.spranim_prefer.pixel.basesprite;
            inheritedSpriteState = templateBase != null
                ? $"enabled={templateBase.enabled} color={templateBase.color}"
                : "basesprite=null";

            GameObject clone = Instantiate(templatePlayer.spranim_prefer.pixel.gameObject);
            clone.name = name;

            // Defensive: strip anything that could carry a gameplay side effect onto a detached
            // clone. Not confirmed to exist on this object (PixelCharacter.cs itself declares
            // none), but a hitbox collider living on a child sprite object would be a real,
            // silent bug (e.g. accidentally colliding with something) if one turned out to be
            // there and this weren't here.
            foreach (var collider in clone.GetComponentsInChildren<Collider2D>(true))
            {
                Destroy(collider);
            }
            foreach (var rb in clone.GetComponentsInChildren<Rigidbody2D>(true))
            {
                Destroy(rb);
            }

            // Found live 2026-08-14: Instantiate() deep-copies every component's *current*
            // field values, not just static geometry -- including whatever transient render
            // state (a screen fade-in right after the zone load that triggered this clone in
            // the first place, a hit-flash, etc.) the source sprite happens to be in at this
            // exact instant. The clone has no gameplay logic of its own driving it afterward
            // (deliberate, see the class comment above), so a bad state captured mid-fade never
            // self-corrects -- the ghost stays alive, active, correctly positioned, and
            // invisible forever. Confirmed via inheritedSpriteState logging (below) on a real
            // repro: basesprite.enabled was false at clone time, color was already a correct
            // opaque (1,1,1,1) -- so only the renderer's enabled flag needs resetting, NOT its
            // color. An earlier version of this fix also forced color = Color.white, which
            // "fixed" the invisibility but introduced a real regression: outlinesprite is not
            // meant to be white (it renders the character's outline effect in its own distinct
            // tint), and overwriting its color turned that outline into a solid white glow --
            // found live immediately after deploying that version. Rather than guessing a delay
            // to dodge the race window instead (see agent_docs/pitfalls.md's already-burned
            // guessed-constant history for why that was rejected too), only touch what's
            // actually confirmed broken.
            foreach (var sr in clone.GetComponentsInChildren<SpriteRenderer>(true))
            {
                sr.enabled = true;
            }

            pc = clone.GetComponent<PixelCharacter>();
            return clone;
        }

        private void UpsertRemoteGhost(string playerId, BridgeClient.RemoteState state)
        {
            if (state.Position == null || state.Position.Length < 2)
            {
                return;
            }
            if (!remoteVisuals.TryGetValue(playerId, out RemoteGhostVisual visual) || visual.Go == null)
            {
                if (cloneTemplate == null || cloneTemplate.spranim_prefer == null
                    || cloneTemplate.spranim_prefer.pixel == null)
                {
                    return; // no local player to clone from yet -- retry next frame
                }
                GameObject go = CreateRealGhostVisual(cloneTemplate, $"MeshGhostRemote_{playerId}", out PixelCharacter pc, out Vector3 anchorOffset, out string inheritedSpriteState);
                visual = new RemoteGhostVisual { Go = go, Pc = pc, LastAnim = null, AnchorOffset = anchorOffset };
                remoteVisuals[playerId] = visual;
                // Diagnostic fields added while chasing a real bug found live 2026-08-14: after
                // a zone/scene transition, the traveling player sometimes stopped seeing a
                // peer's ghost that reappeared in the log as freshly "created" (this line fires)
                // but was never actually visible again, with no further despawn/recreate logged
                // after it -- ruling out the object being destroyed again (that would trigger
                // another one of these lines on the very next frame, via the visual.Go == null
                // check below) and, separately, ruling out a bad position (computedGhostPos
                // consistently matched the real remote's real, unmoving coordinates exactly).
                // Root cause, confirmed via isolate-by-subtraction (temporarily disabling
                // internal/core's cross-area filter made the bug disappear, isolating it to this
                // create path specifically): CreateRealGhostVisual's Instantiate() deep-copies
                // whatever transient render state (a screen fade-in right after the zone load
                // that triggered this very recreate) the source sprite was in at that instant --
                // now reset to a known-good visible state there, see its comment. Logged here
                // (inheritedSpriteState) purely to confirm what state was actually inherited
                // before the reset overwrote it.
                Vector3 initialGhostPos = new Vector3(state.Position[0], state.Position[1], 0f) + anchorOffset;
                Logger.LogInfo($"MeshGhost: real remote ghost visual created for {playerId} (step 6.4/6.5+). "
                    + $"anchorOffset={anchorOffset} templatePos={cloneTemplate.t.position} "
                    + $"templateScene={cloneTemplate.spranim_prefer.pixel.gameObject.scene.name} cloneScene={go.scene.name} "
                    + $"remoteStatePos=({state.Position[0]:F2},{state.Position[1]:F2}) computedGhostPos={initialGhostPos} "
                    + $"inheritedSpriteState=[{inheritedSpriteState}]");
            }

            visual.Go.SetActive(true);
            // Loopback ghost offset, 2026-08-14 -- user-requested, generalized from the same fix
            // in adapters/emulator/pokemon/emerald/meshghost_emerald.lua's drawRemotes() (and
            // adapters/pseudoregalia's UpsertRemoteGhost-equivalent). A loopback-echoed ghost
            // (internal/relay's dev-only -loopback flag, id = "<id>-ghost") otherwise renders
            // exactly on top of the real player -- it's an echo of your own position by
            // definition -- which made it hard to visually judge ghost rendering quality against
            // the real character side by side. Nudge it sideways purely for local rendering;
            // never changes what's actually sent/received over the network (state.Position here
            // is only ever a local render input). Magnitude fixed 2026-08-15: the original 2.0f
            // guess was live-tested and confirmed too small -- the ghost rendered basically
            // inside the player, not visibly to the side. First replaced with 80f (X axis only,
            // same as the original 6.3-era magenta-placeholder-box offset removed in 6.6, see
            // agent_docs/phases/phase6.md's `RemoteVisualTestOffset` entry), confirmed live via
            // screenshot -- still fairly close. Doubled to 160f same day, per explicit user
            // direction that this next step didn't need a fresh live check: a linear doubling
            // of an already-watched, correctly-oriented offset on the same render path, not a
            // new guess. See agent_docs/verified.md.
            float loopbackOffsetX = playerId.EndsWith("-ghost", System.StringComparison.Ordinal) ? 160f : 0f;
            visual.Go.transform.position = new Vector3(state.Position[0] + loopbackOffsetX, state.Position[1], 0f)
                + visual.AnchorOffset;

            // Throttled (once every 2s per remote, not every frame) so a real repro of the
            // 2026-08-14 zone-transition bug shows the ghost's actual ongoing position/
            // active-state/scene over time, in case it silently drifts wrong or gets
            // deactivated sometime after the creation log line rather than at creation itself.
            if (DIAG_REDRAW_TRACE && Time.time - visual.LastDiagLogTime >= 2f)
            {
                visual.LastDiagLogTime = Time.time;
                Logger.LogInfo($"MeshGhost: remote {playerId} redraw: pos={visual.Go.transform.position} "
                    + $"activeInHierarchy={visual.Go.activeInHierarchy} scene={visual.Go.scene.name} "
                    + $"localArea={currentLocalArea} remoteAreaId={state.AreaId}");
            }

            // Facing: confirmed live 2026-08-12 that flipX=true means "facing LEFT" is the
            // wrong way around -- inverted from the first guess. All five sprite layers are
            // flipped together, not just basesprite: normally SpriteAnimation (the logic
            // component this clone deliberately doesn't carry, see the class comment above)
            // keeps outline/effect/flash/support in sync with the base sprite's flip every
            // frame. Without that, only flipping basesprite left the outline sprite stuck at
            // its original orientation -- confirmed live as the cause of a visible outline seam
            // sticking out whenever facing didn't match the outline's stale flip state.
            if (visual.Pc != null)
            {
                bool flip = state.Orientation == "RIGHT";
                if (visual.Pc.basesprite != null) visual.Pc.basesprite.flipX = flip;
                if (visual.Pc.outlinesprite != null) visual.Pc.outlinesprite.flipX = flip;
                if (visual.Pc.effectsprite != null) visual.Pc.effectsprite.flipX = flip;
                if (visual.Pc.flashsprite != null) visual.Pc.flashsprite.flipX = flip;
                if (visual.Pc.supportsprite != null) visual.Pc.supportsprite.flipX = flip;
            }

            // Only call Play() on an actual change -- calling it every frame would restart the
            // clip from time 0 every frame and the animation would never visibly progress.
            if (visual.Pc != null && visual.Pc.anim != null
                && !string.IsNullOrEmpty(state.Anim) && state.Anim != visual.LastAnim)
            {
                visual.Pc.anim.Play(state.Anim);
                visual.LastAnim = state.Anim;
            }

            UpdateRemoteMapMarker(playerId, state);
        }

        // Every peer ghost at once, for leaving play rather than for a peer leaving. Iterates a
        // copy of the key list because DespawnRemoteGhost mutates remoteVisuals as it goes.
        private void DespawnAllRemoteGhosts()
        {
            if (remoteVisuals.Count == 0)
            {
                return;
            }
            Logger.LogInfo($"MeshGhost: leaving play -- despawning all {remoteVisuals.Count} remote ghost(s).");
            foreach (string playerId in new List<string>(remoteVisuals.Keys))
            {
                DespawnRemoteGhost(playerId);
            }
        }

        private void DespawnRemoteGhost(string playerId)
        {
            // Called only from bridge.DrainInto's despawn_remote callback -- a real peer leave.
            // Previously only SetActive(false)'d the GameObject and left it and its dictionary
            // entry alive forever, so every reconnect of the same peer instantiated a brand new
            // clone without ever freeing the last one -- a monotonic leak. Destroy it and drop
            // the entry; UpsertRemoteGhost already handles a missing entry by creating a fresh
            // clone next time this playerId reappears.
            if (remoteVisuals.TryGetValue(playerId, out RemoteGhostVisual visual))
            {
                // Logged (missing before 2026-08-14) so a real despawn_remote can be told apart
                // from a ghost silently going invisible without one -- see UpsertRemoteGhost's
                // creation-time diagnostic comment for the bug this was added to chase.
                Logger.LogInfo($"MeshGhost: despawned remote ghost for {playerId} (localArea={currentLocalArea}).");
                if (visual.Go != null)
                {
                    Destroy(visual.Go);
                }
                remoteVisuals.Remove(playerId);
            }
            DespawnRemoteMapMarker(playerId);
        }

        private void Awake()
        {
            // What a tester reads when they are wondering whether the mod loaded at all, so it
            // says what this build actually is. It said "(Phase 6 step 6.1 hello-world)" until
            // 2026-08-27, which the adapter has been well past since Phase 6.6.
            Logger.LogInfo($"{PluginName} v{PluginVersion} loaded.");
            int bridgePort = Config.Bind(
                "Network",
                "BridgePort",
                DefaultBridgePort,
                "First local core process bridge port to try. The adapter WALKS " +
                "BridgePortCount ports upward from here, so a second TEVI instance on the same " +
                "machine finds its own core without this being set at all -- since 2026-08-27. " +
                "Change it only to move the whole range.").Value;
            bridge = new BridgeClient(BridgeHost, bridgePort);
            launcher = new CoreLauncher(msg => Logger.LogInfo(msg));
        }

        // Neither BepInEx nor Unity closes the bridge socket for us on shutdown -- without this,
        // quitting the game leaves the local core process's bridge connection open until it
        // eventually times out on its own, delaying this player's despawn for any peer still
        // connected.
        //
        // DespawnAllRemoteGhosts() is here for RELOADING, not for quitting: on a real quit the
        // scene is torn down anyway, but ScriptEngine (BepInEx.Debug) reloads this plugin in a
        // live game by destroying the old instance and constructing a new one. A peer ghost is a
        // cloned GameObject parented in the scene, not a child of this component, so it outlives
        // the instance that made it -- and the fresh instance, whose remoteVisuals is empty,
        // clones a second one on the next render_remote. Every reload would leave one more
        // orphan on screen that nothing tracks or despawns. Cheap on quit, load-bearing on F6.
        private void OnDestroy()
        {
            DespawnAllRemoteGhosts();
            bridge?.Disconnect();
            launcher?.Stop();
        }

        private void OnApplicationQuit()
        {
            bridge?.Disconnect();
            launcher?.Stop();
        }

        // EventManager.mainCharacter is a property on the current game build (backed by a
        // private _mainCharacter field, confirmed by decompiling this machine's current
        // Assembly-CSharp.dll with ilspycmd) but a plain public field on at least one older
        // build (SteamDB build 14778703, 2024-06-20 -- same tool, same class, different shape).
        // A direct `.mainCharacter` read compiles to a get_mainCharacter() call, which doesn't
        // exist on the older field-shaped build and throws MissingMethodException every frame.
        // Reflection resolves whichever shape is actually present at runtime instead of
        // hard-linking one of them; the lookup itself only runs once per game build (JIT caches
        // per closed generic/reflection call site is not relied on here -- these fields are the
        // cache).
        private static readonly PropertyInfo MainCharacterProperty = typeof(EventManager).GetProperty("mainCharacter");
        private static readonly FieldInfo MainCharacterField = typeof(EventManager).GetField("mainCharacter");

        private static CharacterBase GetMainCharacter(EventManager eventManager)
        {
            if (MainCharacterProperty != null)
            {
                return (CharacterBase)MainCharacterProperty.GetValue(eventManager);
            }
            if (MainCharacterField != null)
            {
                return (CharacterBase)MainCharacterField.GetValue(eventManager);
            }
            return null;
        }

        private void Update()
        {
            timeSinceLastLog += Time.deltaTime;

            // EventManager.Instance / mainCharacter / WorldManager.Instance can all be null
            // outside a real play session (main menu, loading) -- a null read must not crash
            // the plugin, per CLAUDE.md's "a wrong read returns a plausible number instead of
            // crashing" standard applied to a missing reference instead of a bad address.
            CharacterBase player = EventManager.Instance != null ? GetMainCharacter(EventManager.Instance) : null;
            cloneTemplate = (player != null && player.t != null) ? player : cloneTemplate;
            // Set before bridge.DrainInto below, which invokes UpsertRemoteGhost ->
            // UpdateRemoteMapMarker synchronously and needs the local player's current area
            // to gate remote markers against.
            currentLocalArea = WorldManager.Instance != null ? WorldManager.Instance.Area : (byte)255;

            bridge.DrainLogsInto(msg => Logger.LogInfo(msg));
            bridge.TryConnect();
            // Autostart sits here rather than in Awake: "is a core running?" is only answerable by
            // trying, and TryConnect above is the thing that tries. If one is already up -- started
            // by hand, or left by another instance -- this never spawns anything.
            if (bridge.IsConnected)
            {
                launcher.TickConnected();
            }
            else
            {
                // The port the WALK is currently on, not the configured base -- otherwise a second
                // instance, having been refused on the base port and walked to the next, would spawn
                // its core back onto the first instance's port and fail there instead. Changed with
                // the walk on 2026-08-27.
                launcher.TickDisconnected(bridge.CurrentPort);
            }
            bridge.SendHelloIfNeeded(GameId, PluginVersion);

            if (DIAG_MARKER_STALENESS && remoteMapMarkers.Count > 0)
            {
                DiagMarkerStaleness();
            }

            if (player == null || player.t == null)
            {
                if (hadPlayerLastFrame)
                {
                    Logger.LogInfo("MeshGhost: left the play session (main menu / title, NOT the pause overlay) -- disconnecting bridge so this player's ghost despawns for any peer, and despawning theirs.");
                    hadPlayerLastFrame = false;
                    if (DIAG_MENU_GATE && !hadPlayerLastFrame)
                    {
                        // The question: is `player == null` really the main-menu/pause
                        // discriminator, or is something else doing the work? This prints what the
                        // adapter can see at the moment it decides, so the answer comes from a run
                        // rather than from reading code -- which is how the 2026-08-18 false
                        // regression happened. Open the pause overlay and this line must NOT
                        // appear; quit to the title and it must.
                        FullMap gateMap = FullMap.Instance;
                        Logger.LogInfo("MeshGhost/probe menu-gate: took the LEFT-PLAY branch. "
                            + $"player==null={player == null} "
                            + $"playerTransform==null={(player == null ? "n/a" : (player.t == null).ToString())} "
                            + $"eventManager==null={EventManager.Instance == null} "
                            + $"fullMapOpen={(gateMap == null ? "no-instance" : gateMap.isFullMap.ToString())}");
                    }
                    timeSinceLastLog = 0f;
                    // Reconnects automatically next frame via TryConnect() once back in a real
                    // play session -- see BridgeClient.Disconnect's comment for why this exists.
                    bridge.Disconnect();
                    // Symmetry, and the exit direction of the template's "never let a ghost
                    // exist before the player is in the game": we tell peers our ghost is gone,
                    // so theirs must go too. Without this, peer ghosts stayed standing between
                    // sessions, frozen at their last position, because nothing else destroys
                    // them -- despawn_remote only ever arrives for a real leave.
                    //
                    // *** THIS IS THE MAIN MENU, NOT THE PAUSE MENU. *** Peer ghosts MUST stay
                    // visible during the pause overlay -- that is wanted behaviour, confirmed by
                    // the user 2026-08-18. It is safe here because this whole branch is gated on
                    // `player == null`, and phases/phase6.md records (confirmed live 2026-08-13)
                    // that the Characters/pause overlay does NOT null the player, so that check
                    // "safely distinguishes a real menu return from a pause overlay". If a future
                    // TEVI build ever nulls the player on pause, this call despawns every peer
                    // ghost mid-session and must be removed -- it is the first thing to suspect.
                    DespawnAllRemoteGhosts();
                }
                // PROTOCOL.md: send local_state every frame even when there's nothing to send.
                bridge.SendLocalState(null);
                return;
            }

            // Drained only now, below the gate. Above it, a remote's state could create a ghost
            // while the local player did not exist -- the very thing the gate is for -- and it
            // would then be destroyed again on the same frame by the branch above.
            bridge.DrainInto(UpsertRemoteGhost, DespawnRemoteGhost);

            Vector3 pos = player.t.position;
            byte area = currentLocalArea;

            // Room-grid coordinates for the map marker (step 6.7) -- TEVI's map is room-based,
            // not continuous-position-based, see UpdateRemoteMapMarker/FindRoomTile above.
            // Only meaningful together with WorldManager.Instance itself being present.
            int? roomX = WorldManager.Instance != null ? (int?)WorldManager.Instance.CurrentRoomX : null;
            int? roomY = WorldManager.Instance != null ? (int?)WorldManager.Instance.CurrentRoomY : null;

            // Anim sent over the wire is the *real* currently-playing Animator clip name
            // (SpriteAnimation.GetAnimationTrueName(), reads pixel.anim's own
            // GetCurrentAnimatorClipInfo directly), not our PlayerAniState enum -- this is what
            // lets a remote ghost literally Animator.Play() the right thing with zero invented
            // name-mapping table, the same "read the real vocabulary, don't invent one" posture
            // as area_id/anim being opaque per contract.md. Falls back to the enum name only if
            // the animator reference chain isn't available yet (e.g. a very early frame).
            string clipName = player.spranim_prefer != null && player.spranim_prefer.pixel != null
                && player.spranim_prefer.pixel.anim != null
                ? player.spranim_prefer.GetAnimationTrueName()
                : player.aniStatus.ToString();

            bridge.SendLocalState(new BridgeClient.RemoteState
            {
                AreaId = area.ToString(),
                Position = new[] { pos.x, pos.y },
                Orientation = player.direction.ToString(),
                Anim = clipName,
                RoomX = roomX,
                RoomY = roomY,
            });

            if (DIAG_MENU_GATE && !hadPlayerLastFrame)
            {
                // The other edge: the frame the player comes BACK. Pairs with the left-play line
                // above, so one run of open-pause / close-pause / quit-to-title produces exactly
                // the transitions the gate claims, and the pause overlay produces none of them.
                FullMap gateMap = FullMap.Instance;
                Logger.LogInfo("MeshGhost/probe menu-gate: taking the ENTER-PLAY branch. "
                    + $"eventManager==null={EventManager.Instance == null} "
                    + $"fullMapOpen={(gateMap == null ? "no-instance" : gateMap.isFullMap.ToString())} "
                    + $"area={area}");
            }

            bool discreteChange = !hadPlayerLastFrame
                || player.direction != lastLoggedDir
                || player.aniStatus != lastLoggedAnim
                || area != lastLoggedArea;
            bool positionChanged = Vector3.Distance(pos, lastLoggedPos) > PositionChangeEpsilon;

            bool shouldLog = discreteChange
                ? true
                : positionChanged
                    ? timeSinceLastLog >= MinLogIntervalSeconds
                    : timeSinceLastLog >= MaxSilenceSeconds;

            if (!shouldLog)
            {
                return;
            }

            Logger.LogInfo(
                $"MeshGhost local state: area={area} pos=({pos.x:F2},{pos.y:F2}) "
                + $"dir={player.direction} anim={player.aniStatus} clip={clipName}");

            hadPlayerLastFrame = true;
            lastLoggedPos = pos;
            lastLoggedDir = player.direction;
            lastLoggedAnim = player.aniStatus;
            lastLoggedArea = area;
            timeSinceLastLog = 0f;
        }
    }
}
