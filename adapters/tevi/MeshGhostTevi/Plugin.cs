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
        // a position no peer has confirmed? It was written while the marker was update-driven --
        // UpdateRemoteMapMarker ran only from UpsertRemoteGhost, which runs only when a
        // render_remote arrives, so a peer that stopped sending left it frozen. The refresh is
        // frame-driven as of 2026-08-28 and a stale marker now HIDES after MarkerStaleSeconds,
        // which is what this measures now: an age that climbs past that bound while the marker is
        // still visible means the fix is not working. Ages are of the DATA, not of the redraw.
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

        // DIAG_SPAWN_DIFF answers "what does this move actually SPAWN?" -- the question behind the
        // charged-attack gap, where a peer ghost plays the animation and no effect appears. It is
        // the WORLD DIFF instrument from agent_docs/effect-investigation.md: snapshot what exists
        // near a character, do the move on purpose, snapshot again, and read what appeared. Run it
        // on BOTH instances at once and the two lists are the answer directly -- what appears near
        // the local player on one, what appears near that same peer's ghost on the other, and the
        // difference between them is the missing effect.
        //
        // IDENTITY, NOT COUNTS, deliberately (effect-investigation.md rule 4). Effects are usually
        // pooled, and pooling defeats counting at both ends: re-use makes a new effect look old, and
        // retirement makes an old one look new. Instance IDs cannot be fooled either way, and they
        // separate "spawned two" from "counted one twice" -- which need opposite fixes.
        //
        // UNFILTERED BY NAME, also deliberately. A name filter is a guess about the answer, and a
        // wrong guess still returns a complete-looking list. Everything inside the radius is logged;
        // filtering happens afterwards, when reading.
        //
        // THE COST IS THE RISK HERE, so this probe measures itself: a scene enumeration is O(all
        // objects), and a probe too expensive to run does not report being too expensive -- it
        // reports nothing, which reads exactly like "the game spawned nothing". SpawnDiffCoverage
        // prints scan time and object counts so a silent result can be told apart from an absent
        // one. If the scan time is bad, raise SpawnDiffSampleInterval; do not trust a quiet log.
        private const bool DIAG_SPAWN_DIFF = false;
        // 20Hz. Fast enough that a one-frame effect is unlikely to appear and vanish between two
        // samples, slow enough that the enumeration is not per-frame.
        private const float SpawnDiffSampleInterval = 0.05f;
        // World units. The loopback ghost offset is 160f (VERIFIED.md), so 400 comfortably contains
        // a character and its effects while excluding most of the room.
        private const float SpawnDiffRadius = 400f;
        // Per-question budgets, never one shared pool: a shared budget is spent by whatever happens
        // most often, which is never the rare thing being hunted (effect-investigation.md rule 7).
        private const int SpawnDiffAppearBudget = 500;
        private const int SpawnDiffDisappearBudget = 250;
        private const float SpawnDiffCoverageInterval = 5f;
        private float lastSpawnDiffSampleTime;
        private float lastSpawnDiffCoverageTime;
        private int spawnDiffAppearLines;
        private int spawnDiffDisappearLines;
        private int spawnDiffScans;
        private int spawnDiffLastInRadius;
        private int spawnDiffLastTotal;
        private double spawnDiffScanMsTotal;
        private double spawnDiffScanMsWorst;
        private readonly Dictionary<int, string> spawnDiffSeen = new Dictionary<int, string>();

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

            // Highest one-shot VFX counter already played for this peer. Per-ghost, and it
            // starts at 0 so a peer that has already fired effects before we first saw it does
            // not replay its whole history the moment its ghost appears.
            public int LastVfxSeq;

            // Last phase received for this peer, for drift correction.
            public float LastAnimTime;

            // Playback speed multiplier currently correcting this ghost's clip phase, 1 when it
            // is in step. See the phase correction in UpsertRemoteGhost for why a speed and not
            // a seek.
            public float PhaseCatchup = 1f;

            // Time since this ghost last emitted an afterimage. Per-ghost, because two peers
            // trailing at once must not share a cadence.
            public float TrailTimer;

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

            // Names this peer sent that no local controller has, so each is complained about once
            // instead of every frame. Lazily created (a well-behaved peer never allocates one) and
            // capped -- see MaxRejectedAnimNamesPerPeer.
            public HashSet<string> RejectedAnims;
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

            // When the state this marker is DRAWING arrived -- not when the marker was last
            // redrawn, which since the refresh went frame-driven is every frame regardless.
            // Read only under DIAG_MARKER_STALENESS. The marker's AGE is the whole question the
            // staleness defect turns on, and it is not recoverable after the fact from anything
            // on screen.
            public float LastUpdateTime;
        }

        private readonly Dictionary<string, RemoteMapMarker> remoteMapMarkers = new Dictionary<string, RemoteMapMarker>();

        // The last state each peer sent, with WHEN it arrived. Kept because the marker is
        // refreshed every frame from here rather than only when a message lands: the old path
        // ran UpdateRemoteMapMarker from inside UpsertRemoteGhost, so a peer that stopped
        // sending left its marker frozen wherever it was until the core's own drop detection
        // finally despawned it (quic ~17s, udp up to 60s), and a peer whose ghost could not be
        // built yet -- no local player to clone from, a state carrying no position -- got no
        // marker at all, because both of those return before the marker call at the bottom.
        // Recorded at the TOP of UpsertRemoteGhost, above every one of those returns.
        private sealed class RemoteMarkerState
        {
            public BridgeClient.RemoteState State;
            public float ArrivedAt;
        }

        private readonly Dictionary<string, RemoteMarkerState> remoteMarkerStates = new Dictionary<string, RemoteMarkerState>();

        // How long a marker may keep claiming a position after the last state that backed it.
        // The core re-sends every remote it still tracks on EVERY adapter frame -- a peer
        // standing perfectly still still produces render_remote -- so silence here means the
        // states stopped arriving, never that the peer stopped moving. One second is many frames
        // of ordinary jitter and far below the core's own drop detection, which is exactly the
        // window the marker used to spend lying.
        private const float MarkerStaleSeconds = 1f;

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

        // Set once per Update, before bridge.DrainInto and RefreshRemoteMapMarkers run, so
        // UpdateRemoteMapMarker has the local player's current area to gate against without
        // needing to parse it back out of the AreaId string on every remote.
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

        // Every peer's marker, once per frame, from the last state each one sent. Frame-driven
        // rather than arrival-driven: that is the whole fix for a marker that used to sit frozen
        // at a position its peer had long left. Called immediately after DrainInto so a state
        // that landed this frame is drawn this frame -- moving the refresh costs no latency.
        private void RefreshRemoteMapMarkers()
        {
            if (remoteMarkerStates.Count == 0)
            {
                return;
            }
            float now = Time.time;
            foreach (KeyValuePair<string, RemoteMarkerState> kv in remoteMarkerStates)
            {
                if (now - kv.Value.ArrivedAt > MarkerStaleSeconds)
                {
                    // Hidden, not destroyed: the peer may simply be mid-hitch, and the entry
                    // still has to come back the moment states resume. Destroying is
                    // DespawnRemoteMapMarker's job, driven by the core's despawn.
                    if (remoteMapMarkers.TryGetValue(kv.Key, out RemoteMapMarker stale) && stale.Go != null)
                    {
                        stale.Go.SetActive(false);
                    }
                    continue;
                }
                UpdateRemoteMapMarker(kv.Key, kv.Value.State, kv.Value.ArrivedAt);
            }
        }

        private void UpdateRemoteMapMarker(string playerId, BridgeClient.RemoteState state, float stateArrivedAt)
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
            marker.LastUpdateTime = stateArrivedAt;
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
            // Dropped with the marker, or RefreshRemoteMapMarkers would keep rebuilding a marker
            // for a peer the core has already despawned -- and the entry would outlive every
            // session the peer was ever in.
            remoteMarkerStates.Remove(playerId);
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

        // A peer's clip name, checked against the GHOST'S OWN Animator controller rather than
        // against a list written here. That is deliberate: the names are the game's vocabulary and
        // this project does not invent one (contract.md -- `anim` is opaque outside the adapter
        // that produced it), so the only honest allowlist is "a state this controller actually
        // has". `HasState` performs the same name -> state lookup `Play` does, which is what makes
        // this exact rather than an approximation of it: anything rejected here is something Play
        // could not have found either. Every layer is asked, because Play with no layer argument
        // searches all of them and checking only layer 0 would refuse a state that legitimately
        // lives higher up.
        //
        // The length bound sits in front of the hash purely so an adversarially long name costs
        // nothing to reject; the wire cap (protocol.MaxAnimLen, 256) is the outer bound, and a real
        // TEVI clip name is far shorter than this.
        private const int MaxAnimNameLength = 96;

        // A rejection is logged ONCE per name per peer, and only for the first few: the whole
        // defect being fixed is a per-frame log line driven by remote input, so an unthrottled
        // "rejected an unknown animation" would reproduce it in our own logger. The set is capped
        // for the same reason a peer-keyed map would be -- a peer sending endless distinct names
        // must not grow anything without bound.
        private const int MaxRejectedAnimNamesPerPeer = 4;

        private bool IsPlayableAnimName(RemoteGhostVisual visual, string anim)
        {
            if (visual == null || visual.Pc == null || visual.Pc.anim == null)
            {
                return false;
            }
            if (string.IsNullOrEmpty(anim) || anim.Length > MaxAnimNameLength)
            {
                return false;
            }
            int hash = Animator.StringToHash(anim);
            Animator animator = visual.Pc.anim;
            for (int layer = 0; layer < animator.layerCount; layer++)
            {
                if (animator.HasState(layer, hash))
                {
                    return true;
                }
            }
            if (visual.RejectedAnims == null)
            {
                visual.RejectedAnims = new HashSet<string>();
            }
            if (visual.RejectedAnims.Count < MaxRejectedAnimNamesPerPeer && visual.RejectedAnims.Add(anim))
            {
                Logger.LogWarning($"MeshGhost: ignored an animation name no local controller has "
                    + $"(peer-controlled input, see the ACE audit): length={anim.Length}");
            }
            return false;
        }

        // Deliberately empty. Out of play there is nothing to render a peer ONTO, and the state
        // plane is latest-wins, so dropping these costs nothing: the next state after the player
        // exists rebuilds everything. They exist so DrainInto can run out of play for the control
        // plane's sake without the remote callbacks being reachable from there.
        private void DiscardRemoteWhileOutOfPlay(string playerId, BridgeClient.RemoteState state)
        {
        }

        private void DiscardDespawnWhileOutOfPlay(string playerId)
        {
        }

        private void UpsertRemoteGhost(string playerId, BridgeClient.RemoteState state)
        {
            // FIRST, above every early return below. The map marker is a separate feature from
            // the world ghost and must not inherit its preconditions: a peer with no position, or
            // one arriving before there is a local player to clone a ghost from, still belongs on
            // the map. RefreshRemoteMapMarkers draws from here.
            if (remoteMarkerStates.TryGetValue(playerId, out RemoteMarkerState markerState))
            {
                markerState.State = state;
                markerState.ArrivedAt = Time.time;
            }
            else
            {
                remoteMarkerStates[playerId] = new RemoteMarkerState { State = state, ArrivedAt = Time.time };
            }

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

            // The clip name is PEER-CONTROLLED (../_template/PROTOCOL.md), and until this check it
            // went straight into Unity's animator bounded only by the wire protocol's 256-byte cap.
            // Not ACE -- managed and memory-safe, an unknown state is a no-op with a warning -- but
            // a peer alternating two nonexistent names defeats the LastAnim dedupe below and
            // produces that warning EVERY FRAME, which is disk and CPU on the RECIPIENT'S machine
            // driven entirely by remote input. That is the one thing the 2026-08-27 audit found
            // crossing the user's stated line (`../../agent_docs/ideas.md`, "The ACE audit", gap 2).
            bool animPlayable = IsPlayableAnimName(visual, state.Anim);

            // Only call Play() on an actual change -- calling it every frame would restart the
            // clip from time 0 every frame and the animation would never visibly progress.
            if (animPlayable && state.Anim != visual.LastAnim)
            {
                visual.Pc.anim.Play(state.Anim);
                visual.LastAnim = state.Anim;
                visual.LastAnimTime = state.AnimTime ?? 0f;
            }
            else if (animPlayable && state.AnimTime.HasValue)
            {
                // PHASE CORRECTION, deliberately not every frame. Re-seeking an Animator that is
                // already close enough is what makes a remote character stutter, so this acts only
                // once the two have drifted past a tolerance the eye can see.
                //
                // It is also what replays a REPEATED identical clip: attacking twice in a row never
                // changes the name, so the branch above never fires and the ghost would hold the
                // finished pose. The peer's phase jumping backwards IS that event, and it exceeds
                // the tolerance by construction.
                float peerT = state.AnimTime.Value;
                float ghostT = visual.Pc.anim.GetCurrentAnimatorStateInfo(0).normalizedTime;
                ghostT -= Mathf.Floor(ghostT);
                // SIGNED, and wrapped the short way round: a clip near its end and one near its
                // start are adjacent, not a whole clip apart. The sign is what makes a smooth
                // correction possible at all -- it says whether the ghost is behind or ahead.
                float drift = peerT - ghostT;
                if (drift > 0.5f)
                {
                    drift -= 1f;
                }
                else if (drift < -0.5f)
                {
                    drift += 1f;
                }

                if (Mathf.Abs(drift) > AnimReseekThreshold)
                {
                    // A genuinely different point in the clip: the peer restarted it. Attacking
                    // twice in a row never changes the clip NAME, so this jump backwards is the
                    // only evidence the second attack happened, and seeking is correct here --
                    // the peer really did snap.
                    visual.Pc.anim.Play(state.Anim, 0, peerT);
                    visual.PhaseCatchup = 1f;
                }
                else
                {
                    // EVERYTHING ELSE IS REPAID CONTINUOUSLY, NOT SNAPPED. Seeking on every small
                    // drift is what made an idle ghost's ears "snap a bit every now and then"
                    // (user, 2026-08-28, watching over a jittery link): the arrival times wobble,
                    // the measured drift crosses the tolerance constantly, and each correction is
                    // a visible jump in the animation.
                    //
                    // This is the same rule adapters/CLAUDE.md already states for POSITION -- do
                    // not save up a correction and pay it in one go, repay it continuously and
                    // finely -- applied to time instead of space. A small speed change converges
                    // the ghost's clip onto the peer's phase over a few frames and is invisible,
                    // where the jump it replaces was not.
                    //
                    // Clamped hard: the ghost's animation must never look like a different speed
                    // of the same move, which is a thing no player can do.
                    visual.PhaseCatchup = Mathf.Clamp(1f + drift * PhaseCatchupGain,
                        1f - PhaseCatchupRange, 1f + PhaseCatchupRange);
                }
                visual.LastAnimTime = peerT;
            }

            // Unlike the animation above, this is NOT gated on having changed. SetTrail arms a
            // countdown, so re-arming while the peer is still trailing is the point; skipping it
            // on "same as last frame" would let the trail lapse in the middle of a slide.
            // A peer that predates the field sends nothing, which reads as 0 and renders no trail.
            ApplyTrail(visual, state.TrailMode ?? 0, cloneTemplate);

            // HITSTOP, mirrored onto the GHOST'S ANIMATOR ONLY. The peer's game is holding a
            // temp pause, which freezes their character mid-swing; a watcher of a real second
            // player would see exactly that. Freezing our own game instead would be a peer's
            // attack stuttering someone else's play, which is why the game's own
            // `SetTempPause` call is deliberately not mirrored (BANDAGES).
            //
            // Speed rather than a stored clip time: the ghost is already playing the right clip,
            // and holding it is the whole effect. Restored to 1 the moment the peer's pause ends,
            // and set unconditionally so a peer that vanishes mid-pause cannot strand a ghost
            // frozen forever.
            if (visual.Pc != null && visual.Pc.anim != null)
            {
                // Hitstop wins outright; otherwise the animator runs at the phase catch-up speed,
                // which is 1 whenever the ghost is already in step. Written every frame so a peer
                // that vanishes mid-pause cannot strand a ghost frozen forever.
                visual.Pc.anim.speed = (state.TempPause ?? 0f) > 0f ? 0f : visual.PhaseCatchup;
            }

            // One-shot pooled VFX. Only ever plays on a RISE, and a first sighting adopts the
            // peer's current counter without playing anything -- otherwise a ghost created
            // mid-session would replay every effect its peer had fired.
            int vfxSeq = state.VfxSeq ?? 0;
            if (vfxSeq > 0 && visual.LastVfxSeq == 0)
            {
                visual.LastVfxSeq = vfxSeq;
            }
            else if (vfxSeq > visual.LastVfxSeq)
            {
                visual.LastVfxSeq = vfxSeq;
                PlayGhostVfx(visual, state.VfxEffect ?? -1, state.VfxFacingLeft ?? false);
            }
        }

        // Every peer ghost at once, for leaving play rather than for a peer leaving. Iterates a
        // copy of the key list because DespawnRemoteGhost mutates remoteVisuals as it goes.
        // Set to whatever session was live when this frame's ghosts were built. Compared every
        // frame; a change means they belong to a connection that no longer exists.
        private int lastBridgeSessionEpoch;

        // The last session actually SWEPT, which is only ever a session that reached ready --
        // see the sweep's call site for why those are different numbers.
        private int lastSweptSessionEpoch;

        // ORPHANS: ghost objects in the scene that no live plugin instance is tracking. Despawning
        // through the dictionary can only ever reach what THIS instance created, and two things
        // routinely leave objects it never knew about:
        //
        //   * a HOT RELOAD -- the outgoing instance's OnDestroy is the only thing that cleans up
        //     after it, and anything it missed (or anything created between its teardown and the
        //     new instance's first frame) is now parented to the scene with nobody holding it;
        //   * a plugin instance that DIED rather than unloaded.
        //
        // Naming is the whole mechanism: every object this adapter parents into the scene is
        // called MeshGhostRemote_<id> or MeshGhostMapMarker_<id>, so "ours but untracked" is
        // answerable from the scene alone -- which is what makes a sweep possible at all.
        //
        // Deliberately NOT run per frame: it enumerates the scene. It runs when the bridge session
        // changes and once at load, which are the two moments an orphan can appear.
        //
        // Found live 2026-08-28: the user saw several static ghosts standing around after cores
        // were restarted under running games, and they survived the despawn-everything fix
        // shipped earlier that same day -- because that fix walks a dictionary and these were not in it.
        private void SweepOrphanGhosts(string reason)
        {
            int destroyed = 0;
            foreach (GameObject go in FindObjectsOfType<GameObject>())
            {
                if (go == null)
                {
                    continue;
                }
                string name = go.name;
                string id;
                if (name.StartsWith("MeshGhostRemote_", System.StringComparison.Ordinal))
                {
                    id = name.Substring("MeshGhostRemote_".Length);
                    if (remoteVisuals.TryGetValue(id, out RemoteGhostVisual tracked) && tracked.Go == go)
                    {
                        continue; // ours, and we know about it
                    }
                }
                else if (name.StartsWith("MeshGhostMapMarker_", System.StringComparison.Ordinal))
                {
                    id = name.Substring("MeshGhostMapMarker_".Length);
                    if (remoteMapMarkers.TryGetValue(id, out RemoteMapMarker marker) && marker.Go == go)
                    {
                        continue;
                    }
                }
                else
                {
                    continue;
                }
                Destroy(go);
                destroyed++;
            }
            if (destroyed > 0)
            {
                Logger.LogInfo($"MeshGhost: swept {destroyed} orphaned ghost object(s) nobody was tracking ({reason}).");
            }
        }

        private void DespawnAllRemoteGhosts(string reason = "leaving play")
        {
            // Cleared even when there are no visuals to despawn: a peer can have a recorded
            // marker state and no ghost (it arrived before there was a local player to clone
            // from), and the early return below would otherwise leave that entry behind for
            // RefreshRemoteMapMarkers to keep drawing after we left play.
            remoteMarkerStates.Clear();
            if (remoteVisuals.Count == 0)
            {
                return;
            }
            Logger.LogInfo($"MeshGhost: {reason} -- despawning all {remoteVisuals.Count} remote ghost(s).");
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

        // THE AFTERIMAGE TRAIL. TEVI spawns a trailing afterimage for several moves -- the blue one
        // on a quickdrop is the one the user named (2026-08-28) -- and a peer ghost showed none.
        //
        // MIRROR THE DECISION, NOT THE MOVE. `SpriteAnimation` recomputes a small mode every frame
        // from three values and spawns its own pooled GhostEffect from that. So this reads the same
        // three values rather than enumerating moves: enumerating would need a new case for every
        // move that ever uses the system, and would silently miss the ones nobody thought to test.
        // This is `effect-investigation.md`'s central lesson -- mirroring the rule the game already
        // owns beats reconstructing it, and Pseudoregalia's slide trail cost several sessions
        // learning that.
        //
        // WHY THE GHOST GETS NOTHING BY DEFAULT: the game's own two move branches are gated on
        // `isPlayer()`, and a clone is not the player. Its third branch, a plain `trail > 0f`
        // countdown, is NOT gated -- which is the documented way in, and why `SetTrail` on a clone
        // works at all.
        //
        // Everything past the decision stays the game's: pooling, spawn rate, decay, which sprite,
        // the flip, the scale and the position all come from TEVI's own component. We set a mode
        // and a colour and nothing else.

        // Read off the LOCAL player, from the same public values TEVI's own SpriteAnimation reads.
        // Returns 0/1/2 -- opaque to the core, meaningful only between two TEVI clients.
        private static int ReadTrailMode(CharacterBase player)
        {
            if (player == null)
            {
                return 0;
            }
            // Order matters and is the GAME's order, not ours: it evaluates the speed-bonus branch
            // first and the dodge branch second, so dodge wins when both are true. Reproducing the
            // order rather than picking one keeps a simultaneous case looking like the game's.
            int mode = 0;
            if (player.cphy_perfer != null
                && (player.cphy_perfer.moveSpeedBonusSlide > 0f || player.cphy_perfer.moveSpeedBonusQuickDrop > 0f))
            {
                mode = 1;
            }
            if (player.playerc_perfer != null && player.playerc_perfer.HaveDodge() >= 1)
            {
                mode = 2;
            }
            // The generic timed trail: anything in the game may call SetTrail directly, and that
            // path is invisible to the two checks above. Reading it too is what makes this cover
            // trails we have not seen rather than only the ones we went looking for.
            if (mode == 0 && player.spranim_prefer != null && player.spranim_prefer.GetTrail() > 0f)
            {
                mode = 1;
            }
            return mode;
        }

        // WHY THIS SPAWNS THE EFFECT ITSELF instead of calling the game's `SetTrail`. `SetTrail`
        // lives on `SpriteAnimation`, and **a ghost has no SpriteAnimation**: the clone is
        // `spranim_prefer.pixel.gameObject`, the pixel CHILD, so the component that would drive a
        // trail sits on a parent we never cloned (documentation.md: the drawn position hangs off
        // that child, which is why we clone it and not the whole character).
        //
        // So we drive the same loop the component would: on the same cadence, spawn the same
        // pooled `GhostEffect`, hand it the ghost's own current sprite, and let it decay itself.
        // Everything that makes an afterimage LOOK right stays the game's -- the pool, the effect
        // object, the fade, the sprite. What we reproduce is only the *cadence*, and that number
        // is the game's own `trailRate`, cited rather than tuned.
        //
        // The `CharacterBase` argument is the LOCAL player deliberately. `SetSprite` dereferences
        // it only inside `if (cb.isPlayer())`, where it copies the effect-sprite transform; we
        // pass no effect sprite, so that branch sets a transform on a renderer with nothing in it.
        // Passing null instead would throw there.
        // How far out of phase a ghost's clip may drift before it is re-seeked. Small enough that
        // a hitstop lands on the right frame, large enough that ordinary jitter does not cause a
        // visible re-seek every frame.
        private const float AnimPhaseTolerance = 0.06f;

        // Past this much drift the ghost is not lagging, it is somewhere else in the clip -- the
        // peer restarted it. A seek is right there and a gentle catch-up would be wrong, because
        // the peer's own animation snapped and 1:1 means ours does too. Below it, nothing is ever
        // seeked; see PhaseCatchupGain.
        private const float AnimReseekThreshold = 0.25f;

        // How hard a small phase error pulls on playback speed, and the ceiling on that pull.
        // 0.06 of a clip corrected at gain 2 is a 12% speed change, gone within a few frames --
        // below what the eye reads as "moving at a different speed", which is the thing this must
        // never look like (adapters/CLAUDE.md: never in units the game does not use).
        private const float PhaseCatchupGain = 2f;
        private const float PhaseCatchupRange = 0.25f;

        private const float TrailSpawnRate = 0.07f;      // SpriteAnimation.trailRate
        private const float TrailDecaySpeed = 1.5f;      // SpriteAnimation.trailDecay
        private const int TrailSortingOrder = 99;        // SpriteAnimation.trailOrder

        // Where the local player is inside its current clip, 0..1. Looping clips run
        // normalizedTime past 1 forever, so it is wrapped -- a ghost needs the phase, not how many
        // times the peer has looped.
        private static float ReadAnimTime(CharacterBase player)
        {
            if (player == null || player.spranim_prefer == null || player.spranim_prefer.pixel == null
                || player.spranim_prefer.pixel.anim == null)
            {
                return 0f;
            }
            float t = player.spranim_prefer.pixel.anim.GetCurrentAnimatorStateInfo(0).normalizedTime;
            return t - Mathf.Floor(t);
        }

        private void ApplyTrail(RemoteGhostVisual visual, int mode, CharacterBase localPlayer)
        {
            if (mode <= 0)
            {
                // Let the cadence lapse rather than zeroing it: the next trail starts a fresh
                // interval anyway, and a half-elapsed timer is not state worth clearing.
                visual.TrailTimer = 0f;
                return;
            }
            if (visual.Pc == null || visual.Pc.basesprite == null || localPlayer == null)
            {
                return;
            }
            // A ghost with nothing drawn must not leave a trail of nothing -- the game guards the
            // same way before spawning (`pixel.basesprite.enabled`), and without this a ghost that
            // is hidden for a zone load would still emit afterimages.
            if (!visual.Pc.basesprite.enabled || visual.Pc.basesprite.sprite == null)
            {
                return;
            }

            visual.TrailTimer += Time.deltaTime;
            if (visual.TrailTimer < TrailSpawnRate)
            {
                return;
            }
            // Subtract rather than zero, so a long frame does not silently drop a spawn and
            // shorten the trail relative to the player's.
            visual.TrailTimer -= TrailSpawnRate;

            // Mode 2's colour is the literal from the game's own dodge branch; mode 1 is
            // SpriteAnimation's default `trailcolor`, which is the blue seen on a quickdrop.
            Color c = mode == 2
                ? (Color)new Color32(255, 225, 0, 170)
                : (Color)new Color32(0, 223, 255, 128);

            GhostEffect effect = GemaPoolManager.Instance.CreateGhostEffect();
            if (effect == null)
            {
                return;
            }
            effect.SetSprite(localPlayer, visual.Pc.basesprite.flipX, visual.Pc.basesprite.sprite,
                null, c, c, TrailSortingOrder, TrailSortingOrder - 1);
            effect.SetDecaySpeed(TrailDecaySpeed);
            effect.transform.localScale = visual.Pc.transform.localScale;
            effect.transform.position = visual.Pc.transform.position;
        }

        // WARP DEVICES WAKE UP FOR A GHOST -- the visual half only, and the split is the whole
        // point of this code.
        //
        // A WarpDevice animates when the player stands in it. It does that from `OnTriggerStay2D`
        // and `OnTriggerEnter2D`, which also do all of this:
        //
        //     SaveManager.Instance.AutoSave();                    <- WRITES A SAVE
        //     ...playerc_perfer.RegenHealth(3f, ...);             <- heals the LOCAL player
        //     EnterTips.Instance.EnableMe(2, null, 0);            <- interaction prompt
        //     FullMap.Instance.SetMiniMapIcon(..., Icon.WARP);    <- marks the local minimap
        //
        // So the obvious implementation -- give the ghost its collider back and let the game's own
        // trigger fire -- is FORBIDDEN, not merely untidy. `CLAUDE.md`: nothing that ships writes a
        // save, ever, not even as a feature. Note also that RegenHealth is called on
        // `EventManager.Instance.mainCharacter` rather than on whatever entered the trigger, so a
        // peer standing in a portal would heal YOU. That is a gameplay effect caused by a cosmetic
        // layer, which is the exact thing the cosmetic-first design exists to prevent.
        // (`BANDAGES.md` entry 4 is why a ghost has no colliders in the first place.)
        //
        // THE SEAM: `WarpDevice.Update()` produces the entire visual -- the "assembling" animation,
        // the particle scale, the light intensity -- from the private `readyopen`/`readyclose`
        // flags and `lastAnim`. None of the side effects above is in Update. So setting one flag
        // gives the wake-up and nothing else, and the game still owns every frame of the animation.
        //
        // Membership is tested with the device's OWN trigger collider (`OverlapPoint`), never a
        // radius of our own: the shape is the game's, so a ghost wakes a portal at exactly the
        // distance a player does, and there is no constant here to get wrong.
        private const float WarpScanInterval = 0.5f;
        private float lastWarpScanTime;
        private WarpDevice[] warpDevices = new WarpDevice[0];
        // Which devices currently have a ghost inside, so the flags are set on the TRANSITION --
        // matching OnTriggerEnter/Exit semantics rather than re-asserting every frame, which would
        // fight Update's own clearing of them.
        private readonly HashSet<int> warpsWithGhostInside = new HashSet<int>();

        private static readonly FieldInfo WarpReadyOpenField =
            typeof(WarpDevice).GetField("readyopen", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo WarpReadyCloseField =
            typeof(WarpDevice).GetField("readyclose", BindingFlags.NonPublic | BindingFlags.Instance);
        // Zeroed every frame a ghost is inside, mirroring what OnTriggerStay2D does for the player.
        // Optional: if this one field is ever renamed the portal still stays open (readyclose is
        // held false), it just loses the belt-and-braces half, so it is null-checked rather than
        // treated as required.
        private static readonly FieldInfo WarpReadyCloseTimerField =
            typeof(WarpDevice).GetField("readyclosetimer", BindingFlags.NonPublic | BindingFlags.Instance);

        // Trigger colliders per device, resolved at SCAN time rather than per frame.
        // GetComponentsInChildren allocates an array on every call, and this now runs every frame
        // for every device -- which is the per-frame allocation adapters/CLAUDE.md's cost rule
        // exists to prevent. The set only changes when the devices do, so it is cached with them.
        private Collider2D[][] warpTriggers = new Collider2D[0][];

        private void UpdateWarpDevicesForGhosts()
        {
            // Reflection resolved once; if a future build renames either field this does nothing
            // at all rather than throwing every frame, and the ghost simply stops waking portals.
            if (WarpReadyOpenField == null || WarpReadyCloseField == null)
            {
                return;
            }
            // Re-scan on a timer rather than every frame: FindObjectsOfType is O(scene), and the
            // set of warp devices only changes on a room change.
            if (Time.time - lastWarpScanTime >= WarpScanInterval)
            {
                lastWarpScanTime = Time.time;
                warpDevices = FindObjectsOfType<WarpDevice>();
                warpTriggers = new Collider2D[warpDevices.Length][];
                for (int i = 0; i < warpDevices.Length; i++)
                {
                    var triggers = new List<Collider2D>();
                    foreach (Collider2D col in warpDevices[i].GetComponentsInChildren<Collider2D>())
                    {
                        if (col != null && col.isTrigger)
                        {
                            triggers.Add(col);
                        }
                    }
                    warpTriggers[i] = triggers.ToArray();
                }
            }
            if (warpDevices.Length == 0)
            {
                return;
            }

            for (int i = 0; i < warpDevices.Length; i++)
            {
                WarpDevice device = warpDevices[i];
                // OnBecameInvisible disables the component off-camera, and a disabled Update will
                // not act on the flag anyway -- so skip rather than set something nothing reads.
                if (device == null || !device.isActiveAndEnabled)
                {
                    continue;
                }
                int id = device.GetInstanceID();
                bool ghostInside = false;
                foreach (KeyValuePair<string, RemoteGhostVisual> kv in remoteVisuals)
                {
                    if (kv.Value.Go == null || !kv.Value.Go.activeInHierarchy)
                    {
                        continue;
                    }
                    Vector3 p = kv.Value.Go.transform.position;
                    foreach (Collider2D col in warpTriggers[i])
                    {
                        if (col != null && col.OverlapPoint(p))
                        {
                            ghostInside = true;
                            break;
                        }
                    }
                    if (ghostInside)
                    {
                        break;
                    }
                }

                bool wasInside = warpsWithGhostInside.Contains(id);
                if (ghostInside)
                {
                    warpsWithGhostInside.Add(id);
                    // EVERY FRAME, not just on the way in. This mirrors `OnTriggerStay2D`, which is
                    // what the game itself does: it resets `readyclosetimer` on every frame the
                    // player is inside rather than acting once on entry.
                    //
                    // Doing it on the transition only was a real bug, found by the user
                    // 2026-08-28: with a ghost standing in a portal, the LOCAL player walking out
                    // fires the game's own `OnTriggerExit2D`, which sets `readyclose`. Nothing then
                    // re-asserted the ghost that had never left, so the portal shut with someone
                    // still on it. **A transition cannot answer "is anyone still here" -- only a
                    // per-frame test can**, and the game's own code says so by being written that
                    // way.
                    //
                    // Re-asserting is safe rather than a fight with `Update`: `readyopen` is a
                    // one-shot REQUEST that Update clears once it has opened the gate, and its
                    // branch only fires when the animation is `deactivated`/`inert`. Setting it
                    // continuously means "stay wanting to be open" and does nothing while open.
                    WarpReadyCloseField.SetValue(device, false);
                    if (WarpReadyCloseTimerField != null)
                    {
                        WarpReadyCloseTimerField.SetValue(device, 0f);
                    }
                    WarpReadyOpenField.SetValue(device, true);
                }
                else if (wasInside)
                {
                    warpsWithGhostInside.Remove(id);
                    // The last ghost left. Ask it to close -- and this stays a transition, because
                    // asserting it every frame would override the game closing or opening it for
                    // its own reasons. If the LOCAL player is still inside, the game's own
                    // `OnTriggerStay2D` zeroes `readyclosetimer` every frame and the close branch
                    // never reaches its 0.5s threshold, so this cannot shut a portal out from
                    // under the player.
                    WarpReadyCloseField.SetValue(device, true);
                    WarpReadyOpenField.SetValue(device, false);
                }
            }
        }

        // POOLED VFX MIRRORING -- the shipped half of what DIAG_POOL_WATCH found.
        //
        // The charged attack's burst does NOT parent to the character: measured 2026-08-28, 4,926
        // hierarchy scans with the player's subtree constant at 53 objects and the probe's budget
        // barely touched, so it was a true negative rather than a truncated log. Widening to the
        // POOL found it immediately, by name: `Normal4H Blast`, pool index 56 of
        // `GemaPoolManager.Instance.CommonEffectsPooler`, six activations for six attacks, at
        // dPlayer=123 against dGhost=275.
        //
        // MIRROR THE DECISION, NOT THE RULE. The game spawns it from inside its 4th-hit attack at
        // `animTime >= 21f/32f` gated on an internal counter. Re-deriving that timing on the ghost
        // would mean reproducing a rule the game owns -- and one that also consults the local
        // player's BADGES, which a peer's differ from. Instead the local side notices that the game
        // ITSELF activated the effect and reports that it happened; the ghost then plays it. What
        // travels is "this occurred", never "here is when it should occur".
        //
        // WHY A COUNTER and not a boolean: this is an impulse on a latest-wins state plane, so a
        // flag can be missed entirely between two frames. A monotonic counter survives a dropped
        // frame -- the receiver spawns the difference -- and cannot double-fire on a repeated one.
        //
        // Deliberately an ALLOWLIST of indices rather than "mirror every pooled effect": a pool
        // activation near the player may belong to the world, an enemy, or another system, and
        // firing all of them on a ghost would be inventing visuals rather than mirroring them.
        // One row per pooled effect we mirror. EVERY number is copied from that effect's own spawn
        // site in the game, never eyeballed, and the placement genuinely differs per effect -- so a
        // table rather than one shared offset.
        //
        // NegateOnLeft is the trap this table exists for. The blast negates its offset when facing
        // LEFT; CutinStar negates when facing RIGHT, so the two sit on OPPOSITE sides of the
        // character. Copying one effect's placement to another puts it on the wrong flank, and it
        // looks close enough to be believed.
        //
        // NOT MIRRORED, deliberately: the same attack calls `GameSystem.Instance.SetTempPause` for
        // its hitstop. That is global, so replaying it for a peer would freeze the WATCHER's game
        // -- a peer's attack stuttering your own play. Same class as the warp's autosave: the
        // visual is mirrored, the side effect never is.
        private struct MirroredEffect
        {
            public int Index;
            public float OffsetX;
            public float OffsetY;
            public float ScaleX;         // 0 = leave the prefab's own scale alone
            public float ScaleY;
            public bool NegateOnLeft;    // false = negate the OFFSET when facing RIGHT instead
            public bool FlipScaleByFacing; // does the game mirror this effect's scale at all?
        }

        private static readonly MirroredEffect[] MirroredCommonEffectTable =
        {
            // "Normal4H Blast": offset 105/-64, uniform scale 55, offset AND scale mirrored by
            // facing (the game writes `(LEFT ? -1 : 1) * 55f`).
            new MirroredEffect { Index = 56, OffsetX = 105f, OffsetY = -64f, ScaleX = 55f, ScaleY = 55f,
                                 NegateOnLeft = true, FlipScaleByFacing = true },
            // "CutinStar": offset 109/-18, prefab scale untouched, offset negated when facing RIGHT.
            new MirroredEffect { Index = 0, OffsetX = 109f, OffsetY = -18f, ScaleX = 0f, ScaleY = 0f,
                                 NegateOnLeft = false, FlipScaleByFacing = false },
            // Index 37, the PERFECT-TIMING extra -- the game spawns it only when its
            // BADGE_GroundNormalCombo4AltTiming state reads 4 or 5, the same condition that swaps
            // the swing sound. That is why it appears only on some attacks, and why a ghost that
            // did not mirror it always looked like the plain version.
            //
            // Its X is taken from the BLAST's X in the game's own code, not computed independently,
            // so it carries the blast's offset and the blast's negate rule. Its Y is -107 from the
            // character, and its scale is NON-UNIFORM and never mirrored -- which is why the table
            // grew ScaleX/ScaleY and FlipScaleByFacing rather than being forced into one number.
            new MirroredEffect { Index = 37, OffsetX = 105f, OffsetY = -107f, ScaleX = 225f, ScaleY = 260f,
                                 NegateOnLeft = true, FlipScaleByFacing = false },
        };
        // An effect this far from the local player is not the local player's. Generous, because the
        // measured figure was 123 units for the player against 275 for a ghost standing well away.
        private const float MirroredEffectOwnershipRange = 200f;
        // EVERY FRAME, and the interval that used to be here was a real defect. It was 0.05f,
        // copied from the probe's sample rate without thinking -- and for a PROBE that is right
        // (a diagnostic must not cost frames), while for a MECHANISM the interval simply becomes
        // latency. Polling at 20Hz meant a mirrored effect was detected 0-50ms after the game
        // actually spawned it, averaging ~25ms, and biased ENTIRELY one way: always late, never
        // early. The user saw it as the star landing "a tiny bit late".
        //
        // Affordable because this walks only the allowlisted pools -- a few dozen objects -- not
        // the 375 the DIAG_POOL_WATCH probe enumerates. The probe's cost is not this one's cost,
        // and the two should never have shared a number.
        private readonly Dictionary<int, int> mirroredEffectActive = new Dictionary<int, int>();
        private int localVfxSeq;
        private int localVfxEffect;
        // Which way the character was facing AT THE MOMENT the effect fired. Sent with the event
        // rather than read on arrival: the attack can be performed while turning, and by the time
        // a peer renders it the reported facing may already be the other one -- which put the star
        // and blast on the wrong side when moving left/right mid-move.
        private bool localVfxFacingLeft;

        // Instance ids of pooled objects THIS adapter activated for a ghost. They must not be
        // counted as local activity, and that is not a nicety -- it is a FEEDBACK LOOP otherwise.
        // Both instances run this same code: A attacks, B plays it on A's ghost by activating an
        // object in B's own pool, B's watcher sees its pool rise and reports it as B's own effect,
        // A plays it on B's ghost, and it echoes indefinitely. The user saw it as the ending VFX
        // being spammed. The distance guard cannot fix this: it is exactly wrong when the two
        // characters are near each other, which is when they are being watched.
        //
        // Identity rather than a count, per pitfalls' "when a count is suspect, log IDENTITY" --
        // counts cannot separate "the game spawned one" from "we spawned one".
        private readonly HashSet<int> ghostSpawnedEffects = new HashSet<int>();

        // Runs on the LOCAL side: did the game just activate one of the effects we mirror, close
        // enough to the player to be the player's? If so, bump the counter the peer reads.
        private void WatchLocalVfx(CharacterBase player)
        {
            if (GemaPoolManager.Instance == null || player == null || player.t == null)
            {
                return;
            }
            ObjectPooler op = GemaPoolManager.Instance.CommonEffectsPooler;
            if (op == null || op.pooledObjectsList == null)
            {
                return;
            }
            foreach (MirroredEffect eff in MirroredCommonEffectTable)
            {
                int index = eff.Index;
                if (index < 0 || index >= op.pooledObjectsList.Count)
                {
                    continue;
                }
                List<GameObject> pool = op.pooledObjectsList[index];
                if (pool == null)
                {
                    continue;
                }
                int active = 0;
                bool nearPlayer = false;
                foreach (GameObject go in pool)
                {
                    if (go == null || !go.activeInHierarchy)
                    {
                        continue;
                    }
                    // Ours, played for a ghost. Not local activity, and counting it is the echo.
                    if (ghostSpawnedEffects.Contains(go.GetInstanceID()))
                    {
                        continue;
                    }
                    active++;
                    if (Vector3.Distance(go.transform.position, player.t.position) <= MirroredEffectOwnershipRange)
                    {
                        nearPlayer = true;
                    }
                }
                int prev;
                bool known = mirroredEffectActive.TryGetValue(index, out prev);
                mirroredEffectActive[index] = active;
                // A rise, near the player, and only after a baseline exists -- the first sample
                // must not report the resting state as an event.
                if (known && active > prev && nearPlayer)
                {
                    localVfxSeq++;
                    localVfxEffect = index;
                    localVfxFacingLeft = player.direction == Character.Direction.LEFT;
                }
            }
        }

        // Runs on the WATCHER: play the peer's effect on their ghost, with the game's own offsets
        // and the ghost's own facing. The pooled object and everything it does are the game's.
        private void PlayGhostVfx(RemoteGhostVisual visual, int effect, bool left)
        {
            if (visual.Go == null || GemaPoolManager.Instance == null)
            {
                return;
            }
            ObjectPooler op = GemaPoolManager.Instance.CommonEffectsPooler;
            if (op == null)
            {
                return;
            }
            MirroredEffect eff = default(MirroredEffect);
            bool found = false;
            foreach (MirroredEffect candidate in MirroredCommonEffectTable)
            {
                if (candidate.Index == effect)
                {
                    eff = candidate;
                    found = true;
                    break;
                }
            }
            // An id we do not have placement data for is dropped rather than guessed at. A peer on
            // a newer adapter can name an effect this build has never heard of, and putting it at
            // an invented offset would be worse than not showing it.
            if (!found)
            {
                return;
            }
            GameObject go = op.GetPooledObject(effect);
            if (go == null)
            {
                return;
            }
            bool negate = eff.NegateOnLeft ? left : !left;
            float offX = negate ? -eff.OffsetX : eff.OffsetX;
            // THE LOGICAL POSITION, not the drawn one. The game places these relative to
            // `cb_perfer.t.position` -- the character's transform -- while our ghost IS the pixel
            // child, which hangs 56 units below it (`documentation.md`: the two positions do not
            // coincide, and AnchorOffset is that gap, measured at clone time). Placing an effect at
            // the ghost's own position therefore puts it a whole anchor-offset too LOW, which the
            // user saw first on the star: *"happening way too low down"*. Subtracting the offset
            // recovers the logical position the game's own numbers are written against.
            //
            // This applies to EVERY mirrored effect, not just the one it was noticed on -- the
            // blast was equally wrong and merely less obvious, which is exactly why a single
            // reported symptom should be checked against the whole class.
            Vector3 logicalPos = visual.Go.transform.position - visual.AnchorOffset;
            go.transform.position = logicalPos + new Vector3(offX, eff.OffsetY, 0f);
            if (eff.ScaleX > 0f)
            {
                float sx = eff.FlipScaleByFacing ? (left ? -1f : 1f) * eff.ScaleX : eff.ScaleX;
                go.transform.localScale = new Vector3(sx, eff.ScaleY, eff.ScaleY);
            }
            // Remembered so our own watcher does not mistake it for the local player's effect and
            // echo it straight back. The set is bounded by the pools themselves -- a pooled object
            // is reused, so the same handful of ids recur rather than growing without limit.
            ghostSpawnedEffects.Add(go.GetInstanceID());
            go.SetActive(true);
        }

        // DIAG_POOL_WATCH -- the deliberate WIDENING after the hierarchy probe came back empty.
        //
        // `DIAG_SPAWN_DIFF` watches a character's own subtree, which is where `ChargeShot` parents
        // its effect. If a hunted effect never appears there, that is a finding: it does not parent
        // to the character. The documented response is to widen the SUBSYSTEM rather than sample
        // harder (`agent_docs/pitfalls.md`), and the honest place to widen to is the POOL, because
        // every effect in this game comes from one:
        // `GemaPoolManager.Instance.CommonEffectsPooler` / `.AreaPooler`, both `ObjectPooler`s
        // holding `pooledObjectsList` (a list of pools) and `itemsToPool` (the prefab per pool).
        //
        // WHY THIS IS THE RIGHT INSTRUMENT and not just a bigger net: it reports the PREFAB NAME.
        // Every dead end tonight -- `isAfterImage`, `shadowMat`, `Charge` under `Jetpack Meter` --
        // came from guessing which name meant the effect. A pool activation names the thing the
        // game itself chose to spawn, with no interpretation in between.
        //
        // Cost is the open question, so this reports its own like the other probe does. It walks
        // every pooled object once per sample; if that is too slow the log says so, and the answer
        // is a slower sample rate, never a quieter log.
        private const bool DIAG_POOL_WATCH = false;
        private const float PoolWatchInterval = 0.05f;
        private const int PoolWatchBudget = 400;
        private float lastPoolWatchTime;
        private float lastPoolWatchCoverageTime;
        private int poolWatchLines;
        private int poolWatchScans;
        private int poolWatchObjects;
        private double poolWatchMsTotal;
        private double poolWatchMsWorst;
        // Active count per pool, keyed "poolerName#index". A RISE means the game just spawned one.
        private readonly Dictionary<string, int> poolActiveCounts = new Dictionary<string, int>();

        private void DiagPoolWatch(CharacterBase player)
        {
            if (Time.time - lastPoolWatchTime < PoolWatchInterval)
            {
                return;
            }
            lastPoolWatchTime = Time.time;
            if (GemaPoolManager.Instance == null)
            {
                return;
            }
            var watch = System.Diagnostics.Stopwatch.StartNew();
            int objects = 0;
            var poolers = new List<KeyValuePair<string, ObjectPooler>> {
                new KeyValuePair<string, ObjectPooler>("common", GemaPoolManager.Instance.CommonEffectsPooler),
                // AreaPooler hangs off AreaResource, not GemaPoolManager -- cited from the game's
                // own call site, `AreaResource.Instance.AreaPooler.GetPooledObject(...)`.
                new KeyValuePair<string, ObjectPooler>("area",
                    AreaResource.Instance != null ? AreaResource.Instance.AreaPooler : null),
            };

            foreach (KeyValuePair<string, ObjectPooler> pooler in poolers)
            {
                ObjectPooler op = pooler.Value;
                if (op == null || op.pooledObjectsList == null || op.itemsToPool == null)
                {
                    continue;
                }
                for (int i = 0; i < op.pooledObjectsList.Count; i++)
                {
                    List<GameObject> pool = op.pooledObjectsList[i];
                    if (pool == null)
                    {
                        continue;
                    }
                    int active = 0;
                    GameObject sample = null;
                    for (int j = 0; j < pool.Count; j++)
                    {
                        objects++;
                        if (pool[j] != null && pool[j].activeInHierarchy)
                        {
                            active++;
                            if (sample == null)
                            {
                                sample = pool[j];
                            }
                        }
                    }
                    string key = pooler.Key + "#" + i;
                    int prev;
                    bool known = poolActiveCounts.TryGetValue(key, out prev);
                    poolActiveCounts[key] = active;
                    // First sample establishes a baseline; reporting it would dump the whole
                    // resting state and spend the budget before anything happened.
                    if (!known || active <= prev || poolWatchLines >= PoolWatchBudget)
                    {
                        continue;
                    }
                    string prefab = (i < op.itemsToPool.Count && op.itemsToPool[i] != null
                        && op.itemsToPool[i].objectToPool != null)
                        ? op.itemsToPool[i].objectToPool.name
                        : "<unnamed>";
                    // Distance to the player AND to the nearest ghost, because the whole question
                    // is which of the two an effect belongs to.
                    string where = "";
                    if (sample != null && player != null && player.t != null)
                    {
                        float dPlayer = Vector3.Distance(sample.transform.position, player.t.position);
                        float dGhost = float.MaxValue;
                        foreach (KeyValuePair<string, RemoteGhostVisual> kv in remoteVisuals)
                        {
                            if (kv.Value.Go != null)
                            {
                                float d = Vector3.Distance(sample.transform.position, kv.Value.Go.transform.position);
                                if (d < dGhost) { dGhost = d; }
                            }
                        }
                        where = $" dPlayer={dPlayer:0} dGhost={(dGhost == float.MaxValue ? -1f : dGhost):0}";
                    }
                    poolWatchLines++;
                    Logger.LogInfo($"MeshGhost/probe pool: +{active - prev} '{prefab}' "
                        + $"[{key}] active={active}{where}");
                }
            }

            watch.Stop();
            poolWatchScans++;
            poolWatchObjects = objects;
            poolWatchMsTotal += watch.Elapsed.TotalMilliseconds;
            if (watch.Elapsed.TotalMilliseconds > poolWatchMsWorst)
            {
                poolWatchMsWorst = watch.Elapsed.TotalMilliseconds;
            }
            if (Time.time - lastPoolWatchCoverageTime >= 5f)
            {
                lastPoolWatchCoverageTime = Time.time;
                Logger.LogInfo($"MeshGhost/probe pool coverage: scans={poolWatchScans} "
                    + $"pooledObjects={poolWatchObjects} pools={poolActiveCounts.Count} "
                    + $"avgMs={(poolWatchScans == 0 ? 0 : poolWatchMsTotal / poolWatchScans):0.00} "
                    + $"worstMs={poolWatchMsWorst:0.00} budget={poolWatchLines}/{PoolWatchBudget}");
            }
        }

        // PROBE, off unless DIAG_SPAWN_DIFF. See the flag's own comment for the question and the
        // method. Reports APPEARED/DISAPPEARED GameObjects near a character, by instance id.
        private void DiagSpawnDiff(CharacterBase player)
        {
            if (Time.time - lastSpawnDiffSampleTime < SpawnDiffSampleInterval)
            {
                return;
            }
            lastSpawnDiffSampleTime = Time.time;

            var watch = System.Diagnostics.Stopwatch.StartNew();

            // Anchors: the local player, and every peer ghost. Both are logged in one pass so a
            // single instance's log carries "what appeared near me" and "what appeared near the
            // ghost" side by side -- which is the comparison, and doing it in one pass means the
            // two lists come from the same frames rather than from two runs that have to be
            // trusted to match.
            var anchorRoots = new List<KeyValuePair<string, Transform>> {
                new KeyValuePair<string, Transform>("player", player.t)
            };
            foreach (KeyValuePair<string, RemoteGhostVisual> kv in remoteVisuals)
            {
                if (kv.Value.Go != null)
                {
                    anchorRoots.Add(new KeyValuePair<string, Transform>("ghost:" + kv.Key, kv.Value.Go.transform));
                }
            }

            // HIERARCHY, not the whole scene. The first version enumerated every Transform and
            // MEASURED ITSELF AT avgMs=19.19 / worstMs=27.13 against a 16.7ms frame, in a scene
            // holding 36,854 transforms -- unusable, and it said so, which is the only reason it
            // was not simply believed. The clue that made this cheap is in the game's own code:
            // spawned effects are PARENTED to the character (`ChargeShot` does
            // `SetParent(_owner.t)`), so a character's own subtree is where they appear. Tens of
            // objects instead of tens of thousands.
            //
            // If a hunted effect never shows up here, it does not parent to the character -- that
            // is a FINDING, and the response is to widen the subsystem deliberately rather than to
            // sample harder (`agent_docs/pitfalls.md`).
            var current = new Dictionary<int, string>();
            int scanned = 0;
            foreach (KeyValuePair<string, Transform> a in anchorRoots)
            {
                if (a.Value == null)
                {
                    continue;
                }
                foreach (Transform t in a.Value.GetComponentsInChildren<Transform>(true))
                {
                    if (t == null)
                    {
                        continue;
                    }
                    scanned++;
                    Vector3 p = t.position;
                    string nearest = a.Key;
                    float best = (p - a.Value.position).sqrMagnitude;
                // NOT filtered by name. A name filter is a guess about the answer, and a wrong
                // guess still returns a complete-looking list (effect-investigation.md).
                    current[t.gameObject.GetInstanceID()] =
                        $"{t.name} parent={(t.parent == null ? "-" : t.parent.name)} "
                        + $"near={nearest} d={Mathf.Sqrt(best):0} active={t.gameObject.activeInHierarchy} "
                        + $"comps=[{DescribeComponents(t.gameObject)}]";
                }
            }
            watch.Stop();

            spawnDiffScans++;
            spawnDiffLastTotal = scanned;
            spawnDiffLastInRadius = current.Count;
            spawnDiffScanMsTotal += watch.Elapsed.TotalMilliseconds;
            if (watch.Elapsed.TotalMilliseconds > spawnDiffScanMsWorst)
            {
                spawnDiffScanMsWorst = watch.Elapsed.TotalMilliseconds;
            }

            // The first sample has nothing to diff against and would otherwise report the entire
            // room as "appeared", spending the whole budget before anything happened.
            if (spawnDiffScans > 1)
            {
                foreach (KeyValuePair<int, string> kv in current)
                {
                    if (!spawnDiffSeen.ContainsKey(kv.Key) && spawnDiffAppearLines < SpawnDiffAppearBudget)
                    {
                        spawnDiffAppearLines++;
                        Logger.LogInfo($"MeshGhost/probe spawn-diff: + id={kv.Key} {kv.Value}");
                    }
                }
                foreach (KeyValuePair<int, string> kv in spawnDiffSeen)
                {
                    if (!current.ContainsKey(kv.Key) && spawnDiffDisappearLines < SpawnDiffDisappearBudget)
                    {
                        spawnDiffDisappearLines++;
                        Logger.LogInfo($"MeshGhost/probe spawn-diff: - id={kv.Key} {kv.Value}");
                    }
                }
            }

            spawnDiffSeen.Clear();
            foreach (KeyValuePair<int, string> kv in current)
            {
                spawnDiffSeen[kv.Key] = kv.Value;
            }

            // An instrument reports its own coverage, not just its findings: a quiet log has to be
            // distinguishable from a scan that was too slow to catch anything or a budget that ran
            // out. If the worst scan time is bad, RAISE SpawnDiffSampleInterval -- do not read the
            // quiet log as "the game spawned nothing".
            if (Time.time - lastSpawnDiffCoverageTime >= SpawnDiffCoverageInterval)
            {
                lastSpawnDiffCoverageTime = Time.time;
                Logger.LogInfo($"MeshGhost/probe spawn-diff coverage: scans={spawnDiffScans} "
                    + $"transformsInScene={spawnDiffLastTotal} inRadius={spawnDiffLastInRadius} "
                    + $"anchors={anchorRoots.Count} avgMs={(spawnDiffScans == 0 ? 0 : spawnDiffScanMsTotal / spawnDiffScans):0.00} "
                    + $"worstMs={spawnDiffScanMsWorst:0.00} "
                    + $"appearBudget={spawnDiffAppearLines}/{SpawnDiffAppearBudget} "
                    + $"disappearBudget={spawnDiffDisappearLines}/{SpawnDiffDisappearBudget}");
            }
        }

        // Component TYPE names only -- never their values. This is a "what is this thing" probe,
        // and a value dump here would be both enormous and a different question.
        private static string DescribeComponents(GameObject go)
        {
            Component[] comps = go.GetComponents<Component>();
            var sb = new System.Text.StringBuilder();
            for (int i = 0; i < comps.Length; i++)
            {
                if (i > 0)
                {
                    sb.Append(' ');
                }
                // A missing script leaves a null entry, and saying so is more useful than a gap.
                sb.Append(comps[i] == null ? "<null>" : comps[i].GetType().Name);
            }
            return sb.ToString();
        }

        private void Awake()
        {
            // What a tester reads when they are wondering whether the mod loaded at all, so it
            // says what this build actually is. It said "(Phase 6 step 6.1 hello-world)" until
            // 2026-08-27, which the adapter has been well past since Phase 6.6.
            Logger.LogInfo($"{PluginName} v{PluginVersion} loaded.");
            // Anything of ours already in the scene at load belongs to an instance that is gone --
            // a previous hot reload, or a crashed one. See SweepOrphanGhosts.
            SweepOrphanGhosts("plugin load");
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
            // Set before bridge.DrainInto and RefreshRemoteMapMarkers below, which need the
            // local player's current area to gate remote markers against.
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

            // A NEW BRIDGE SESSION INVALIDATES EVERY GHOST. Peer ghosts are built from what one
            // core told us, and `despawn_remote` travels over that same connection -- so if it
            // drops, every despawn it would ever have sent is gone with it, and the ghosts stand
            // there forever. The next core is a different session with different player ids, so it
            // will never despawn them either: it has never heard of them.
            //
            // Found live 2026-08-28, restarting cores under running games -- the user saw several
            // static ghosts accumulate in both instances. Harmless-looking and permanent.
            if (bridge.SessionEpoch != lastBridgeSessionEpoch)
            {
                lastBridgeSessionEpoch = bridge.SessionEpoch;
                // ORDER MATTERS. Drop the dead session's unread messages BEFORE despawning, or
                // this frame's drain recreates a ghost for a player id that no longer exists --
                // and it is then tracked, so the orphan sweep leaves it alone and it stands there
                // forever. That is exactly what a static ghost turned out to be, twice.
                bridge.DiscardQueuedMessages();
                // Cheap: walks the ghost dictionary, nothing else.
                DespawnAllRemoteGhosts("the bridge session changed");
            }

            // THE SWEEP IS NOT CHEAP and is deliberately not hung on the line above. It
            // enumerates every GameObject in the scene, while SessionEpoch changes on every DIAL
            // ATTEMPT -- including the failed ones, every two seconds, for as long as no core is
            // up. Hung there it is a full scene walk on repeat, and the first version of this cost
            // the user a frozen game inside ten minutes of shipping (2026-08-28).
            //
            // Tied to a session that actually came UP instead: at most one sweep per working
            // connection, which is exactly when an orphan can have appeared.
            if (bridge.IsReady && bridge.SessionEpoch != lastSweptSessionEpoch)
            {
                lastSweptSessionEpoch = bridge.SessionEpoch;
                SweepOrphanGhosts("a new bridge session");
            }

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
                // DRAINED HERE TOO, and this is not a nicety. `bridge_ready` and `reject` are
                // parsed inside DrainInto, so while this branch returned early -- the main menu,
                // the title, every loading screen -- nothing consumed the core's answer to our
                // hello, and the hello-answer deadline expired against a core that had already
                // accepted us. The adapter then walked the whole port range spawning a core per
                // port on every launch. Found live 2026-08-28 with two instances; the cores' own
                // logs showed each hello accepted at the moment the adapter called it unanswered.
                //
                // Remote state is DISCARDED rather than rendered, which keeps the invariant this
                // gate exists for: no ghost may be built while there is no local player. Only the
                // control plane gets through, which is exactly what was being starved.
                bridge.DrainInto(DiscardRemoteWhileOutOfPlay, DiscardDespawnWhileOutOfPlay);

                // PROTOCOL.md: send local_state every frame even when there's nothing to send.
                bridge.SendLocalState(null);
                return;
            }

            // The in-play drain: the same call as the one above the gate, differing only in that
            // remote state is RENDERED here rather than discarded. Above the gate a remote's state
            // could create a ghost while the local player did not exist -- the very thing the gate
            // is for -- and it would be destroyed again on the same frame by that branch.
            bridge.DrainInto(UpsertRemoteGhost, DespawnRemoteGhost);

            // Marker refresh, every frame, from what DrainInto just recorded. Not inside
            // UpsertRemoteGhost: a marker that only moves when a message arrives cannot hide
            // itself when the messages stop.
            RefreshRemoteMapMarkers();

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
                TrailMode = ReadTrailMode(player),
                VfxSeq = localVfxSeq,
                VfxEffect = localVfxEffect,
                VfxFacingLeft = localVfxFacingLeft,
                TempPause = GameSystem.Instance != null ? GameSystem.Instance.GetTempPause() : 0f,
                AnimTime = ReadAnimTime(player),
            });

            // Watcher-side and purely cosmetic: wakes a warp device a peer ghost is standing in,
            // without going near the trigger that would save, heal and mark the local minimap.
            if (remoteVisuals.Count > 0)
            {
                UpdateWarpDevicesForGhosts();
            }

            WatchLocalVfx(player);

            if (DIAG_SPAWN_DIFF)
            {
                DiagSpawnDiff(player);
            }

            if (DIAG_POOL_WATCH)
            {
                DiagPoolWatch(player);
            }

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
