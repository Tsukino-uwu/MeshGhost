using System.Collections.Generic;
using System.Reflection;
using BepInEx;
using FXV;
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

            // The peer's weapon-strobe colour and when one was last seen, so the strobe's white
            // frames do not read as the strobe having stopped. Receiver-side state: the sender
            // reports only the truth of each frame (see ReadWeaponStrobe).
            public int StrobeRgb = 0xFFFFFF;
            public float StrobeSeenAt = float.NegativeInfinity;

            // HITSTOP BY PHASE, not by arrival. The peer's game freezes their clip at a specific
            // phase; the state that says "paused" also says WHERE (AnimTime holds still while the
            // peer's animator is frozen). Freezing this ghost the moment the message arrives
            // freezes it at ITS phase, which under network jitter lags the peer's -- seen live
            // 2026-08-28 on the netsim rig as the charged attack "freezing the pose a bit early"
            // while the same code looked right under clean conditions. PendingFreezePhase is
            // where the peer froze (-1 none armed, -2 freeze immediately, no phase known);
            // Frozen is whether this ghost has actually stopped.
            public float PendingFreezePhase = -1f;
            public float FreezeArmedAt;
            public bool Frozen;


            // Time since this ghost last emitted an afterimage. Per-ghost, because two peers
            // trailing at once must not share a cadence.
            public float TrailTimer;
            // The trail the peer is CURRENTLY running, latched from the last message and spawned
            // from TickTrails every frame -- see that method for why not per message.
            public int TrailMode;
            public float TrailRate = TrailSpawnRate;
            public float TrailDecay = TrailDecaySpeed;
            public Color TrailColor = new Color32(0, 223, 255, 128);
            public int TrailOrder = TrailSortingOrder;
            public bool TrailHaveEffect;

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

            // The peer's two orbitars, cloned lazily from the game's own orb prefab the first
            // time the peer reports one visible. See ReadOrbs / ApplyGhostOrbs.
            public GhostOrb[] Orbs = new GhostOrb[2];

            // The peer's core expansions (summoned Celia/Sable), keyed by character type. Each is
            // a second sprite-rig clone driven exactly like the ghost itself. See ReadSummons.
            public Dictionary<string, SummonGhost> Summons = new Dictionary<string, SummonGhost>();

            // Highest orb-to-human flash counter already played for this peer (see OrbFxSeq).
            public int LastOrbFxSeq;

            // The peer's live projectiles, by birth seq (see ReadBullets / ApplyGhostBullets).
            public Dictionary<int, GhostBullet> Bullets = new Dictionary<int, GhostBullet>();
            public int LastBulletSeq;
            public bool BulletSeqAdopted;
            public int LastFlashSeq;
            public bool FlashSeqAdopted;

            // The peer's boost shield and platforms (see ReadShield / ApplyGhostShield).
            public GhostShield Shield;
            public GhostPlatform[] Platforms = new GhostPlatform[2];
        }

        // A dormant bullet: the game's bullet prefab with its script never ticked by BulletManager
        // (it is not in the pool, so it never hits, never checks walls, never spends anything).
        // We fly it; the game's own pooled effect follows it.
        private sealed class GhostBullet
        {
            public GameObject Go;
            public bulletScript B;
            public float BornAt;
            public float DiedAt = float.NegativeInfinity;
            public float Cos, Sin, Speed;   // birth values, the fallback if the game's own are unreadable
            public bool EffectAttached;
            public bool BehaveFailed;       // its own behaviour threw once; it flies straight now
            public string Cause;            // DIAG_GHOST_BULLETS: which of our rules ended it
            public string EffectObjectName; // DIAG_GHOST_BULLETS: the pooled object handed to it
        }

        private sealed class GhostShield
        {
            public GameObject Go;
            public FXVShield Fx;
            public bool Up;
            public bool LoggedActive;
        }

        private sealed class GhostPlatform
        {
            public GameObject Go;
            public SpriteRenderer Sr;
        }

        private sealed class SummonGhost
        {
            public GameObject Go;
            public PixelCharacter Pc;
            public string LastAnim;
            public string Controller;
            public bool Visible;
            // A clone of the game's orb-to-humanoid trail (TrailRenderer + its own mover), flown
            // from the ghost orb to this summon when it appears and back when it goes. Its mover
            // never stops itself; TrailOffAt is when we park it, timed like the game does.
            public GemaOrbToHumanoidTrail Trail;
            public float TrailOffAt = float.NegativeInfinity;
            public bool WasPresent;
        }

        // EventManager keeps two GemaOrbToHumanoidTrail objects in a private array; the first one
        // is the template a ghost's trail is cloned from. Name from the assembly, read once.
        private static readonly FieldInfo O2HTrailsField = typeof(EventManager).GetField("O2Htrails", BindingFlags.NonPublic | BindingFlags.Instance);

        // A logic-stripped orb: the prefab's renderers with the OrbBall behaviour removed, so
        // nothing on it can shoot, aim, register a light or read the local save. Every field here
        // is written from the peer's reported values and nothing else drives it.
        private sealed class GhostOrb
        {
            public GameObject Go;
            public SpriteRenderer Render;
            public SpriteRenderer Glow;
            public SpriteRenderer Crystal;
            public SpriteRenderer Charge;
            public Transform ChargeTransform;
            // The prefab's own afterimage pool (GemaOrbTrail children). The real orb lights one
            // per physics step while its crystal ring is on; the ghost orb does the same from
            // FixedUpdate below. A trail DETACHES itself on first use, so these are tracked here
            // and destroyed with the orb rather than found through the hierarchy.
            public GemaOrbTrail[] Trails;
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
        // "map_markers" in config.json (CoreLauncher.ConfigSaysNoMapMarkers). Polled once a second
        // by the file's timestamp, never re-read per frame; the shipped default is on.
        private bool mapMarkersEnabled = true;
        private float nextMapMarkerConfigPoll;
        private System.DateTime lastMapMarkerConfigStamp = System.DateTime.MinValue;

        private void PollMapMarkerConfig()
        {
            if (Time.unscaledTime < nextMapMarkerConfigPoll)
            {
                return;
            }
            nextMapMarkerConfigPoll = Time.unscaledTime + 1f;
            bool off = CoreLauncher.ConfigSaysNoMapMarkers(out System.DateTime stamp);
            if (stamp == lastMapMarkerConfigStamp && stamp != System.DateTime.MinValue)
            {
                return;
            }
            lastMapMarkerConfigStamp = stamp;
            if (mapMarkersEnabled == off)
            {
                mapMarkersEnabled = !off;
                Logger.LogInfo($"MeshGhost: map markers {(mapMarkersEnabled ? "ON" : "OFF")} (config.json \"map_markers\").");
            }
        }

        private void RefreshRemoteMapMarkers()
        {
            PollMapMarkerConfig();
            if (!mapMarkersEnabled)
            {
                // Hidden, not destroyed, so flipping the setting back shows them again at once.
                foreach (KeyValuePair<string, RemoteMapMarker> kv in remoteMapMarkers)
                {
                    if (kv.Value.Go != null && kv.Value.Go.activeSelf)
                    {
                        kv.Value.Go.SetActive(false);
                    }
                }
                return;
            }
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

            // The orbitars ride the peer's ROOT position (their offsets were measured from it), so
            // the anchor offset the sprite clone needs is deliberately not added here.
            // Each cosmetic sub-feature is walled off: an exception in one must never abort the
            // ghost's own pose, facing, trail and hitstop below it (the shield did exactly that on
            // 2026-09-10). Logged once per message text, not per frame.
            Vector3 worldNudge = new Vector3(loopbackOffsetX, 0f, 0f);
            try { ApplyGhostOrbs(playerId, visual, state.Orbs, new Vector3(state.Position[0] + loopbackOffsetX, state.Position[1], 0f)); }
            catch (System.Exception e) { LogSubfeatureFailure("orbitars", e); }
            // World-fixed things (the summon, its shield, its platforms) travel as ABSOLUTE positions
            // and get only the loopback nudge, never the ghost's interpolated root.
            try { ApplyGhostSummons(playerId, visual, state.Summons, worldNudge); }
            catch (System.Exception e) { LogSubfeatureFailure("core expansion", e); }
            try { ApplyOrbFx(visual, state); }
            catch (System.Exception e) { LogSubfeatureFailure("orb flash", e); }
            try { ApplyGhostShield(playerId, visual, state, worldNudge); }
            catch (System.Exception e) { LogSubfeatureFailure("boost shield", e); }
            try { ApplyGhostBullets(playerId, visual, state, worldNudge); }
            catch (System.Exception e) { LogSubfeatureFailure("projectiles", e); }
            try { ApplyGhostFlashes(visual, state, worldNudge); }
            catch (System.Exception e) { LogSubfeatureFailure("muzzle flash", e); }

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
                // Started AT THE PEER'S REPORTED PHASE, not at 0. Starting at 0 left every new
                // clip ~0.1 behind from its first frame -- the delivered state is already that far
                // in -- and the catch-up then ground the gap down for the rest of the clip. The
                // hitstop probe measured it directly (2026-08-28): at freeze time the ghost still
                // lagged the target by 0.11, so it spent 100-140ms of a 250ms hitstop catching up
                // and the hold read as barely-there.
                visual.Pc.anim.Play(state.Anim, 0, state.AnimTime ?? 0f);
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
            LatchTrail(visual, state);

            // THE WEAPON STROBE, reproduced locally -- see ReadWeaponStrobe for why the decision
            // travels and the frames do not. The cadence is MEASURED, not guessed: the probe's
            // frame numbers show 2 frames of color, 3 of white, a 5-frame period -- the first
            // build used the enemy code's 2:2 and the user read it as "a bit better? unsure if
            // 1:1". And during a hitstop the game's strobe HOLDS its current color (measured: 18
            // frames of blue straight through a freeze), so a frozen ghost's layer is not touched.
            // With no strobe reported the layer rests white, which is also what un-freezes a clone
            // that inherited a strobe frame at Instantiate time.
            if (visual.Pc != null && visual.Pc.effectsprite != null)
            {
                int packed = state.WeaponRgba ?? 0;
                // FROZEN MEANS HELD ON THE COLOUR, not held on whatever frame we stopped at. The
                // probe measured the player's strobe running 18 unbroken frames of colour through
                // a hitstop, and the peer keeps REPORTING that colour while paused -- so a ghost
                // that merely stopped updating showed white for the 3-in-5 of freezes that caught
                // it mid-white, at the one moment the weapon is largest on screen. That is what
                // the user saw as "the ghost still has a white wrench sometimes while the player
                // has a blue one".
                // ALPHA IS NEVER OURS TO WRITE. This layer's VISIBILITY is driven by the clone's
                // own animation; its sprite is not (a clone carries no SpriteAnimation, which is
                // what would clear the layer between attacks). Driving alpha from the peer
                // therefore lights up a STALE attack frame that nothing will ever take down --
                // seen live 2026-08-28 as an attack effect welded to the ghost's model, surviving
                // every later action. Only the COLOUR travels; the alpha stays whatever the
                // ghost's own animation is doing, which was already correct before any of this.
                float a = visual.Pc.effectsprite.color.a;
                if (packed == 0)
                {
                    visual.Pc.effectsprite.color = new Color(1f, 1f, 1f, a);
                }
                else
                {
                    int rgb = packed & 0xFFFFFF;
                    if (rgb != 0xFFFFFF)
                    {
                        // A coloured frame arrived: remember it, so the strobe's white frames in
                        // between do not read as "the strobe stopped".
                        visual.StrobeRgb = rgb;
                        visual.StrobeSeenAt = Time.time;
                    }
                    if (visual.Frozen)
                    {
                        // HELD POSE: exactly what the peer's layer held, no strobe logic. The peer
                        // is paused, so its reported colour is constant and correct, and this is
                        // the one moment the weapon is big enough on screen to read precisely.
                        visual.Pc.effectsprite.color = new Color(
                            ((rgb >> 16) & 255) / 255f, ((rgb >> 8) & 255) / 255f, (rgb & 255) / 255f, a);
                    }
                    else
                    {
                        // Moving: reproduce the strobe LOCALLY at the measured 2-of-5 cadence,
                        // because sampling a ~12Hz alternation through the state stream would
                        // alias into a slow flicker.
                        bool strobing = Time.time - visual.StrobeSeenAt < WeaponStrobeHold;
                        bool coloured = strobing && Time.frameCount % 5 < 2;
                        visual.Pc.effectsprite.color = coloured
                            ? new Color(((visual.StrobeRgb >> 16) & 255) / 255f,
                                        ((visual.StrobeRgb >> 8) & 255) / 255f,
                                        (visual.StrobeRgb & 255) / 255f, a)
                            : new Color(1f, 1f, 1f, a);
                    }
                }
            }

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
                // Hitstop, mirrored AT THE PEER'S PHASE rather than on arrival -- see
                // PendingFreezePhase's comment for the live evidence. While armed and not yet
                // reached, the clip keeps running (at the catch-up speed, which is actively
                // converging on the freeze phase, since the peer's reported AnimTime holds still
                // during their pause); it stops the frame its own phase gets there. Written every
                // frame so a peer that vanishes mid-pause cannot strand a ghost frozen forever.
                if ((state.TempPause ?? 0f) > 0f)
                {
                    if (visual.PendingFreezePhase == -1f)
                    {
                        // SEEK TO THE HELD POSE AND STOP, immediately. The first version waited
                        // for the ghost's own clip to reach the peer's phase, and the probe
                        // measured why that was wrong: steady-state drift under jitter is ~0.09
                        // of a clip, so the ghost spent 100-140ms of a ~250ms hitstop still
                        // swinging -- frames the peer's screen never showed -- and held for only
                        // the remainder. A hitstop IS the peer's timeline snapping to one pose;
                        // matching that pose for the full window is the 1:1 rendering, and the
                        // seek is legitimate by the same rule as the repeated-attack restart:
                        // the peer's own animation snapped, so ours does too. Cost: the ~3
                        // skipped in-between frames, which were wrong to show anyway.
                        visual.PendingFreezePhase = state.AnimTime ?? -2f;
                        visual.FreezeArmedAt = Time.time;
                        if (DIAG_HITSTOP_PHASE)
                        {
                            float g0 = visual.Pc.anim.GetCurrentAnimatorStateInfo(0).normalizedTime;
                            Logger.LogInfo($"MeshGhost/probe hitstop: ARM target={visual.PendingFreezePhase:0.000} "
                                + $"ghostRaw={g0:0.000} pause={state.TempPause:0.000} anim={state.Anim} last={visual.LastAnim}");
                        }
                        if (visual.PendingFreezePhase >= 0f && animPlayable)
                        {
                            visual.Pc.anim.Play(state.Anim, 0, visual.PendingFreezePhase);
                            visual.LastAnim = state.Anim;
                            visual.LastAnimTime = visual.PendingFreezePhase;
                        }
                        visual.Frozen = true;
                    }
                    visual.Pc.anim.speed = 0f;
                }
                else
                {
                    if (DIAG_HITSTOP_PHASE && visual.PendingFreezePhase != -1f)
                    {
                        float g1 = visual.Pc.anim.GetCurrentAnimatorStateInfo(0).normalizedTime;
                        Logger.LogInfo($"MeshGhost/probe hitstop: UNPAUSE frozen={visual.Frozen} "
                            + $"ghostRaw={g1:0.000} target={visual.PendingFreezePhase:0.000}");
                    }
                    visual.PendingFreezePhase = -1f;
                    visual.Frozen = false;
                    visual.Pc.anim.speed = visual.PhaseCatchup;
                }
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
                if (DIAG_HITSTOP_PHASE)
                {
                    Logger.LogInfo($"MeshGhost/probe vfx: RECV seq {visual.LastVfxSeq}->{vfxSeq} "
                        + $"idx={state.VfxEffect ?? -1} (a jump of more than 1 lost an effect)");
                }
                visual.LastVfxSeq = vfxSeq;
                // ON ARRIVAL, deliberately -- phase-gating was tried here (2026-08-28) alongside
                // the hitstop's phase work and REVERTED the same hour: waiting for the ghost's
                // lagging clip to reach the fire phase pushed the star past the freeze-snap, so
                // it appeared AFTER the held pose began -- the peer shows star THEN freeze, and
                // the gate reversed them. Arrival order preserves the game's own ordering because
                // the impulse and the pause ride the same delivered timeline, and the star's
                // arrival timing was never the faulted half; only the freeze needed phase work,
                // and it gets it by SNAPPING (see the hitstop block).
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
                    // A ghost's orbitar is named <ghost name>_orb<i>; tracked through the same
                    // visual, so it is not an orphan while that visual holds it.
                    // A projectile is <ghost>_bullet<seq>.
                    int bulAt = id.LastIndexOf("_bullet", System.StringComparison.Ordinal);
                    if (bulAt > 0 && bulAt + 7 < id.Length && int.TryParse(id.Substring(bulAt + 7), out int bulSeq)
                        && remoteVisuals.TryGetValue(id.Substring(0, bulAt), out RemoteGhostVisual bulOwner)
                        && bulOwner.Bullets.TryGetValue(bulSeq, out GhostBullet gb) && gb.Go == go)
                    {
                        continue;
                    }
                    // The boost shield is <ghost>_shield, its platforms <ghost>_plat<i>.
                    if (id.EndsWith("_shield", System.StringComparison.Ordinal)
                        && remoteVisuals.TryGetValue(id.Substring(0, id.Length - 7), out RemoteGhostVisual shOwner)
                        && shOwner.Shield != null && shOwner.Shield.Go == go)
                    {
                        continue;
                    }
                    int platAt = id.LastIndexOf("_plat", System.StringComparison.Ordinal);
                    if (platAt > 0 && platAt + 5 < id.Length && int.TryParse(id.Substring(platAt + 5), out int platIndex)
                        && remoteVisuals.TryGetValue(id.Substring(0, platAt), out RemoteGhostVisual plOwner)
                        && platIndex >= 0 && platIndex < plOwner.Platforms.Length
                        && plOwner.Platforms[platIndex] != null && plOwner.Platforms[platIndex].Go == go)
                    {
                        continue;
                    }
                    // A core expansion is <ghost>_summon<Type>, tracked through the same visual.
                    int sumAt = id.LastIndexOf("_summon", System.StringComparison.Ordinal);
                    if (sumAt > 0 && sumAt + 7 < id.Length
                        && remoteVisuals.TryGetValue(id.Substring(0, sumAt), out RemoteGhostVisual sumOwner))
                    {
                        string sumKey = id.Substring(sumAt + 7);
                        bool isTrail = sumKey.EndsWith("_trail", System.StringComparison.Ordinal);
                        if (isTrail) sumKey = sumKey.Substring(0, sumKey.Length - 6);
                        if (sumOwner.Summons.TryGetValue(sumKey, out SummonGhost sg)
                            && ((!isTrail && sg.Go == go) || (isTrail && sg.Trail != null && sg.Trail.gameObject == go)))
                        {
                            continue;
                        }
                    }
                    // ...and a detached afterimage <ghost>_orb<i>_trail<k>. Both are tracked
                    // through the same visual, so neither is an orphan while it holds them.
                    int orbAt = id.LastIndexOf("_orb", System.StringComparison.Ordinal);
                    if (orbAt > 0 && orbAt + 4 < id.Length)
                    {
                        string tail = id.Substring(orbAt + 4);
                        int trailAt = tail.IndexOf("_trail", System.StringComparison.Ordinal);
                        string orbDigits = trailAt < 0 ? tail : tail.Substring(0, trailAt);
                        if (int.TryParse(orbDigits, out int orbIndex)
                            && remoteVisuals.TryGetValue(id.Substring(0, orbAt), out RemoteGhostVisual orbOwner)
                            && orbIndex >= 0 && orbIndex < orbOwner.Orbs.Length
                            && orbOwner.Orbs[orbIndex] != null)
                        {
                            GhostOrb owned = orbOwner.Orbs[orbIndex];
                            if (trailAt < 0 && owned.Go == go)
                            {
                                continue;
                            }
                            if (trailAt >= 0 && owned.Trails != null)
                            {
                                bool trailTracked = false;
                                foreach (GemaOrbTrail t in owned.Trails)
                                {
                                    if (t != null && t.gameObject == go) { trailTracked = true; break; }
                                }
                                if (trailTracked)
                                {
                                    continue;
                                }
                            }
                        }
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
            // Pooled effects we lit for a ghost go back off. Done before the early return, since
            // an effect can be mid-flight with no ghost left to own it.
            foreach (GameObject fx in ghostEffectObjects)
            {
                if (fx != null && fx.activeSelf)
                {
                    fx.SetActive(false);
                }
            }
            ghostEffectObjects.Clear();
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
                DestroyGhostOrbs(visual);
                DestroyGhostSummons(visual);
                DestroyGhostShield(visual);
                DestroyGhostBullets(visual);
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
            // The generic timed trail: anything in the game may call SetTrail directly (hover does,
            // with 999), and that path is invisible to the two checks above. IT WINS, and it wins
            // LAST: the game's own order is speed-bonus -> 1, dodge-ready -> 2, then `trail > 0`
            // -> 1 unconditionally. The first version only consulted it when nothing else was set,
            // so a player hovering with a charged dodge trailed BLUE while their ghost trailed
            // yellow (user, 2026-09-10: "is it due to having the yellow trail things on me
            // currently, i don't think blue trails are appearing properly").
            if (player.spranim_prefer != null && player.spranim_prefer.GetTrail() > 0f)
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

        // How long a phase-gated freeze or effect may wait for the ghost's clip to reach the
        // peer's reported phase before firing anyway. A missed crossing (a clip change mid-wait,
        // a frozen animator) must degrade to today's fire-on-arrival, never to nothing.
        private const float FreezePhaseTimeout = 0.25f;

        // TEMPORARY probe for the freeze-phase gating, logging one line per hitstop TRANSITION
        // (arm / freeze / unpause) -- a handful per attack, never per frame. On while the gating
        // is being timed against a live game; remove with the answer (PROBES.md).
        // DIAG_HITSTOP_PHASE answered three questions in one session (2026-08-28) and is kept for
        // the next timing question rather than deleted: it logs one line per hitstop TRANSITION
        // (arm / freeze / unpause), one per effect impulse SENT and RECEIVED, the player's sprite
        // layers whenever their colour changes, and all five layers once per freeze. Events, never
        // per-frame -- a few lines per attack.
        //
        // What it found, in order: the freeze was landing 100-140ms early because the ghost's clip
        // started at 0 instead of the peer's phase; the effect impulses were arriving fine, so the
        // white/blue difference was NOT a lost effect; and the held pose's colour lives on the
        // effect sprite layer, which the RGB-only version of this probe could not have shown.
        private const bool DIAG_HITSTOP_PHASE = false;
        private bool loggedThisFreeze;

        private static void AppendLayer(System.Text.StringBuilder sb, string label, SpriteRenderer sr)
        {
            if (sr == null)
            {
                sb.Append($" | {label}=none");
                return;
            }
            Color c = sr.color;
            sb.Append($" | {label} on={sr.enabled} rgba=({c.r:0.00},{c.g:0.00},{c.b:0.00},{c.a:0.00})"
                + $" spr={(sr.sprite != null ? sr.sprite.name : "null")}"
                + $" mat={(sr.sharedMaterial != null ? sr.sharedMaterial.name : "null")}");
        }

        private Vector3 lastEffectRgb = new Vector3(-1f, -1f, -1f);
        private Vector3 lastFlashRgb = new Vector3(-1f, -1f, -1f);

        private const float TrailSpawnRate = 0.07f;      // SpriteAnimation.trailRate
        private const float TrailDecaySpeed = 1.5f;      // SpriteAnimation.trailDecay
        private const float DodgeTrailDecaySpeed = 6.67f; // SpriteAnimation's dodge branch literal
        private const int TrailSortingOrder = 99;        // SpriteAnimation.trailOrder

        // Where the local player is inside its current clip, 0..1 -- or NULL when the receiver can
        // work it out for itself, which is most of the time a player is standing around.
        //
        // WHY IT IS EVER OMITTED. This is the only field TEVI sends that changes every single
        // frame by construction: an idle is a looping clip (the breathing/ear wiggle), so its
        // phase advances forever even when nothing is happening. That single field is what stops
        // the core's change suppression from ever firing for this adapter -- a standing TEVI
        // player uploads ~20 states a second that differ in nothing else, where a standing Pokemon
        // player sends 4. Measured ranking of the alternatives: `agent_docs/ideas.md`, "Ranked by
        // measurement".
        //
        // WHAT STILL GETS IT, so nothing that depends on phase can regress:
        //   * NON-LOOPING clips -- every attack and one-shot. This is what makes a ghost start a
        //     clip at the peer's phase, and what the hitstop's held pose is measured against.
        //   * Any frame the peer is in HITSTOP, so the freeze lands on the right pose even if it
        //     somehow happens during a looping clip.
        //   * MOVEMENT needs no special case: a moving player's position differs anyway, so those
        //     states are never identical and never suppressed.
        //
        // WHAT IT COSTS: a ghost's idle loop can slide out of phase with its peer's while BOTH are
        // motionless, re-anchoring the moment either does anything (any clip change sends phase
        // again). Bounded by how long someone stands perfectly still, not by session length.
        //
        // `loop` is the Animator's own flag for the current state, so this is exact rather than a
        // guess about which clips are idles.
        private static float? ReadAnimTime(CharacterBase player)
        {
            if (player == null || player.spranim_prefer == null || player.spranim_prefer.pixel == null
                || player.spranim_prefer.pixel.anim == null)
            {
                return null;
            }
            AnimatorStateInfo info = player.spranim_prefer.pixel.anim.GetCurrentAnimatorStateInfo(0);
            bool paused = GameSystem.Instance != null && GameSystem.Instance.GetTempPause() > 0f;
            if (info.loop && !paused)
            {
                return null;
            }
            // Looping clips run normalizedTime past 1 forever, so it is wrapped -- a ghost needs
            // the phase, not how many times the peer has looped.
            float t = info.normalizedTime;
            return t - Mathf.Floor(t);
        }

        // The trail's parameters are private on SpriteAnimation; names from the assembly, read by
        // reflection, defaults if a build renames them.
        private static readonly FieldInfo TrailRateField = typeof(SpriteAnimation).GetField("trailRate", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo TrailDecayField = typeof(SpriteAnimation).GetField("trailDecay", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo TrailColorField = typeof(SpriteAnimation).GetField("trailcolor", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo TrailOrderField = typeof(SpriteAnimation).GetField("trailOrder", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo TrailHaveEffectField = typeof(SpriteAnimation).GetField("haveEffect", BindingFlags.NonPublic | BindingFlags.Instance);

        private static void ReadTrailParams(CharacterBase player, out float rate, out float decay, out int rgba, out int order, out bool haveEffect)
        {
            rate = TrailSpawnRate; decay = TrailDecaySpeed; rgba = unchecked((int)0x00DFFF80); order = TrailSortingOrder; haveEffect = false;
            SpriteAnimation sa = player != null ? player.spranim_prefer : null;
            if (sa == null)
            {
                return;
            }
            if (TrailRateField != null && TrailRateField.GetValue(sa) is float r && r > 0f) rate = r;
            if (TrailDecayField != null && TrailDecayField.GetValue(sa) is float d && d > 0f) decay = d;
            if (TrailColorField != null && TrailColorField.GetValue(sa) is Color32 c)
            {
                rgba = (c.r << 24) | (c.g << 16) | (c.b << 8) | c.a;
            }
            if (TrailOrderField != null && TrailOrderField.GetValue(sa) is int o) order = o;
            if (TrailHaveEffectField != null && TrailHaveEffectField.GetValue(sa) is bool h) haveEffect = h;
        }

        // Latch what the peer's trail IS this frame. Spawning happens in TickTrails.
        private static void LatchTrail(RemoteGhostVisual visual, BridgeClient.RemoteState state)
        {
            int mode = state.TrailMode ?? 0;
            if (mode <= 0)
            {
                // Let the cadence lapse rather than zeroing it: the next trail starts a fresh
                // interval anyway, and a half-elapsed timer is not state worth clearing.
                visual.TrailTimer = 0f;
                visual.TrailMode = 0;
                return;
            }
            visual.TrailMode = mode;
            if (mode == 2)
            {
                // The game's dodge branch: its own yellow literal, its own faster decay
                // (SetDecaySpeed(6.67f) beside the colour), never the effect layer.
                visual.TrailRate = TrailSpawnRate;
                visual.TrailDecay = DodgeTrailDecaySpeed;
                visual.TrailColor = new Color32(255, 225, 0, 170);
                visual.TrailOrder = TrailSortingOrder;
                visual.TrailHaveEffect = false;
                return;
            }
            visual.TrailRate = state.TrailRate.HasValue && state.TrailRate.Value > 0f ? state.TrailRate.Value : TrailSpawnRate;
            visual.TrailDecay = state.TrailDecay.HasValue && state.TrailDecay.Value > 0f ? state.TrailDecay.Value : TrailDecaySpeed;
            if (state.TrailRgba.HasValue)
            {
                int c = state.TrailRgba.Value;
                visual.TrailColor = new Color32((byte)((c >> 24) & 255), (byte)((c >> 16) & 255), (byte)((c >> 8) & 255), (byte)(c & 255));
            }
            else
            {
                visual.TrailColor = new Color32(0, 223, 255, 128);
            }
            visual.TrailOrder = state.TrailOrder ?? TrailSortingOrder;
            visual.TrailHaveEffect = state.TrailHaveEffect ?? false;
        }

        // SPAWN ON FRAMES, NOT ON MESSAGES. The first version ran the spawn timer inside the
        // per-message upsert and added Time.deltaTime per CALL; the core delivers render_remote on
        // its own tick, not once per rendered frame, so at 144fps the timer saw a fraction of real
        // time and the ghost spawned a fraction of the afterimages -- user, 2026-09-10: "its not
        // doing enough of them when im hovering on the ghost ... might apply to all the blue
        // trails". The game itself advances its trail timer once per frame in SpriteAnimation's
        // update, on GemaTimeManager's delta, which is what this does now.
        private void TickTrails(CharacterBase localPlayer)
        {
            if (remoteVisuals.Count == 0 || localPlayer == null || GemaPoolManager.Instance == null)
            {
                return;
            }
            float dt = GemaTimeManager.Instance != null ? GemaTimeManager.Instance.deltaTime : Time.deltaTime;
            foreach (KeyValuePair<string, RemoteGhostVisual> kv in remoteVisuals)
            {
                RemoteGhostVisual visual = kv.Value;
                if (visual.TrailMode <= 0 || visual.Pc == null || visual.Pc.basesprite == null)
                {
                    continue;
                }
                // A ghost with nothing drawn must not leave a trail of nothing -- the game guards the
                // same way before spawning (`pixel.basesprite.enabled`), and without this a ghost that
                // is hidden for a zone load would still emit afterimages.
                if (!visual.Pc.basesprite.enabled || visual.Pc.basesprite.sprite == null)
                {
                    continue;
                }
                visual.TrailTimer += dt;
                if (visual.TrailTimer < visual.TrailRate)
                {
                    continue;
                }
                // Subtract rather than zero, so a long frame does not silently drop a spawn and
                // shorten the trail relative to the player's.
                visual.TrailTimer -= visual.TrailRate;

                GhostEffect effect = GemaPoolManager.Instance.CreateGhostEffect();
                if (effect == null)
                {
                    continue;
                }
                Sprite fxSprite = visual.TrailHaveEffect && visual.Pc.effectsprite != null ? visual.Pc.effectsprite.sprite : null;
                effect.SetSprite(localPlayer, visual.Pc.basesprite.flipX, visual.Pc.basesprite.sprite,
                    fxSprite, visual.TrailColor, visual.TrailColor, visual.TrailOrder, visual.TrailOrder - 1);
                effect.SetDecaySpeed(visual.TrailDecay);
                effect.transform.localScale = visual.Pc.transform.localScale;
                effect.transform.position = visual.Pc.transform.position;
            }
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
        // Scratch for pruning warpsWithGhostInside; a set cannot be modified while enumerated.
        private readonly List<int> staleWarpIds = new List<int>();

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
                // No devices in this scene: nothing can be inside one, and an entry left over
                // from the previous scene would otherwise keep the scan alive forever.
                warpsWithGhostInside.Clear();
                return;
            }

            // Forget devices that no longer exist. Entries are keyed by instance id, devices are
            // re-scanned every WarpScanInterval, and a scene change hands out new ids -- so an
            // entry that matches no current device is a leak, and with the caller now running
            // this scan while the set is non-empty, a leak would mean a per-frame scan for the
            // rest of the session.
            if (warpsWithGhostInside.Count > 0)
            {
                staleWarpIds.Clear();
                foreach (int id in warpsWithGhostInside)
                {
                    bool present = false;
                    for (int i = 0; i < warpDevices.Length; i++)
                    {
                        if (warpDevices[i] != null && warpDevices[i].GetInstanceID() == id)
                        {
                            present = true;
                            break;
                        }
                    }
                    if (!present)
                    {
                        staleWarpIds.Add(id);
                    }
                }
                foreach (int id in staleWarpIds)
                {
                    warpsWithGhostInside.Remove(id);
                }
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

        // The pooled objects behind those ids, so teardown can switch off anything still lit --
        // see PlayGhostVfx for why an id alone is not enough.
        private readonly List<GameObject> ghostEffectObjects = new List<GameObject>(16);

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
                    if (DIAG_HITSTOP_PHASE)
                    {
                        Logger.LogInfo($"MeshGhost/probe vfx: SEND rise idx={index} seq={localVfxSeq}");
                        // One dump per rise (rare): the color-bearing components of the object the
                        // GAME just spawned, so a white attack and a blue one can be diffed to
                        // find which field carries the variant. Temporary, removed with the answer.
                        GameObject risen = null;
                        foreach (GameObject go2 in pool)
                        {
                            if (go2 != null && go2.activeInHierarchy
                                && !ghostSpawnedEffects.Contains(go2.GetInstanceID()))
                            {
                                risen = go2;
                            }
                        }
                        if (risen != null)
                        {
                            Logger.LogInfo($"MeshGhost/probe vfx: PLAYER idx={index} " + DumpEffectObject(risen));
                        }
                    }
                }
            }
        }

        // Runs on the WATCHER: play the peer's effect on their ghost, with the game's own offsets
        // and the ghost's own facing. The pooled object and everything it does are the game's.
        // TEMPORARY, with DIAG_HITSTOP_PHASE: everything colour-bearing on one effect object, so
        // the player's pooled instance and the ghost's can be DIFFED. The first dump read only
        // startColor.color, which is meaningless when the mode is gradient/two-colours -- this one
        // reads the mode, both bounds, the trail module and the renderer's material.
        private string DumpEffectObject(GameObject go)
        {
            var sb = new System.Text.StringBuilder();
            sb.Append(go.name);
            foreach (ParticleSystem ps in go.GetComponentsInChildren<ParticleSystem>(true))
            {
                var sc = ps.main.startColor;
                sb.Append($" | PS:{ps.gameObject.name} mode={sc.mode} c={sc.color} cMin={sc.colorMin} cMax={sc.colorMax}");
                if (ps.trails.enabled)
                {
                    sb.Append($" trail={ps.trails.colorOverLifetime.color}");
                }
                var psr = ps.GetComponent<ParticleSystemRenderer>();
                if (psr != null && psr.sharedMaterial != null)
                {
                    sb.Append($" mat={psr.sharedMaterial.name}");
                    if (psr.sharedMaterial.HasProperty("_TintColor"))
                    {
                        sb.Append($" tint={psr.sharedMaterial.GetColor("_TintColor")}");
                    }
                    if (psr.sharedMaterial.HasProperty("_Color"))
                    {
                        sb.Append($" col={psr.sharedMaterial.GetColor("_Color")}");
                    }
                }
            }
            foreach (SpriteRenderer sr in go.GetComponentsInChildren<SpriteRenderer>(true))
            {
                sb.Append($" | SR:{sr.gameObject.name}={sr.color} mat={(sr.sharedMaterial != null ? sr.sharedMaterial.name : "none")}");
            }
            return sb.ToString();
        }

        // THE WEAPON STROBE. During some combos TEVI tints the character's effectsprite -- the
        // slash/weapon frames -- by alternating its color between white and a color (measured:
        // (0, 0.82, 1), the cyan family) EVERY FRAME. Which look a combo gets is the game's
        // decision; what a watcher must not do is sample it: a 60Hz strobe through a 20Hz state
        // stream aliases into slow flicker. So the sender detects "a strobe is running with color
        // C" -- a non-white weapon RGB seen within the last WeaponStrobeHold -- and sends C once
        // per state; the ghost reproduces the alternation locally at frame rate.
        //
        // Alpha rides along (0xAARRGGBB) because the attack also runs the layer at partial alpha
        // (measured 0.59), which the clone would otherwise freeze or overstate.
        // Just above the strobe's own white gap, which the probe measured at 3 frames (~50ms) --
        // long enough to bridge it, short enough not to leave a blue TAIL after the combo that
        // owned it has ended. The first value was 0.15s, nine frames, which reported "still
        // strobing" for ~100ms after the last real colour frame.
        private const float WeaponStrobeHold = 0.07f;
        private int lastWeaponRgb = 0xFFFFFF;
        private float lastWeaponSeenAt = float.NegativeInfinity;

        private int? ReadWeaponStrobe(CharacterBase player)
        {
            if (player.spranim_prefer == null || player.spranim_prefer.pixel == null
                || player.spranim_prefer.pixel.effectsprite == null)
            {
                return null;
            }
            Color c = player.spranim_prefer.pixel.effectsprite.color;

            // ALPHA DECIDES WHETHER THE LAYER EXISTS AT ALL, and reading only RGB was the bug
            // behind "the ghost kept using blue when the player used white" (2026-08-28). The game
            // does not reset this layer's COLOUR when an attack ends -- it drops the ALPHA and
            // leaves the colour sitting there (`effectsprite.color = (1,1,1,0)` on some paths,
            // SyncEffectAlpha copying alpha on others). So a leftover blue at alpha 0 is invisible
            // on the player and read as "still strobing" by anything that ignores alpha: the ghost
            // strobed blue forever, through white combos and idling alike.
            if (c.a <= 0.02f)
            {
                lastWeaponSeenAt = float.NegativeInfinity;
                return 0;
            }

            // THE INSTANTANEOUS COLOUR, with no substitution. An earlier version reported the
            // remembered strobe colour during the strobe's white frames, to stop the "is it
            // strobing" decision flickering -- and that is precisely what broke the HELD POSE: a
            // hitstop freezes the layer on whichever half it caught, the peer can freeze on white,
            // and a sender substituting blue made every ghost's held wrench blue. The freeze needs
            // the truth of this frame; the strobe's continuity is the RECEIVER's problem, where it
            // can be solved without lying about the current frame (see the render side).
            return ((int)(c.a * 255f) << 24)
                | ((int)(c.r * 255f) << 16) | ((int)(c.g * 255f) << 8) | (int)(c.b * 255f);
        }

        // Whether ghostPhase is at or past target, on a looping 0..1 clip where the short way
        // round is the truth (the same wrap rule the phase correction uses).
        private static bool PhaseReached(float ghostPhase, float target)
        {
            float lead = target - ghostPhase;
            if (lead > 0.5f)
            {
                lead -= 1f;
            }
            else if (lead < -0.5f)
            {
                lead += 1f;
            }
            return lead <= 0f;
        }

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
            // Tracked as an OBJECT too, not just an id, so teardown can put it back. A pooled
            // effect is the GAME's object that we switched on; if this plugin instance goes away
            // mid-effect -- a hot reload, a crash -- nothing of ours is left to switch it off and
            // it stays on screen forever. Seen live 2026-08-28: a reload during a combo stranded a
            // slash effect on the ground. The list is small and oldest-out, because only recently
            // activated objects can still be lit.
            ghostEffectObjects.Add(go);
            if (ghostEffectObjects.Count > 16)
            {
                ghostEffectObjects.RemoveAt(0);
            }
            go.SetActive(true);
            if (DIAG_HITSTOP_PHASE)
            {
                Logger.LogInfo($"MeshGhost/probe vfx: GHOST idx={effect} " + DumpEffectObject(go));
            }
        }

        // THE ORBITARS -- the two orbs that fly around the player. Not synced at all before
        // 2026-09-10 (ideas.md, "the orbitars are not synced at all").
        //
        // MIRROR THE DECISION, NOT THE RULE, the same posture as the afterimage trail above. The
        // game's OrbBall computes each orb's target from a dozen inputs (orbit mode, a running
        // phase, facing, a lock-on target, event positions, auto-shot state, the badge set...) and
        // then eases toward it; re-deriving that on the watcher would copy the game's expression
        // and drift the moment any input was missing. What the peer's screen SHOWS is a short list
        // of renderer facts -- where the orb is, which of the game's own orb sprites it wears, its
        // glow and its charge halo -- so that is what travels, and the watcher paints exactly it.
        //
        // WHY THE PEER'S LOOK AND NOT THE WATCHER'S: the two saves differ. One player's orbs are
        // the plain starting pair, another's are the powered black/white pair with the crystal
        // rings (user, 2026-09-10, on the two-instance rig). Reading the sprite off the peer's
        // renderer and resolving it against the game's own sprite table on arrival is what makes a
        // basic-orb player see a powered-orb peer correctly, and vice versa.
        //
        // THE CLONE IS THE GAME'S OWN PREFAB WITH ITS BRAIN REMOVED. BulletManager.Instance.orb is
        // the prefab playerController instantiates for the real orbs; cloning it gives the exact
        // renderer stack, materials and child layout. The OrbBall component is then destroyed
        // IMMEDIATELY, before its Start can run: Start registers the orb's Light into
        // LightManager.OrbLight (it would hijack the local player's light slot) and Update shoots,
        // aims and spends the LOCAL save's MP. Nothing that ships may cause a gameplay effect on
        // the watcher (CLAUDE.md). The prefab's Light is disabled rather than mirrored for now --
        // an open item, not a decision that it does not matter.
        //
        // The renderers are private on OrbBall (_glowrender, _cerender, _chargerender, _ct) --
        // names from the assembly, resolved once by reflection, null if a build renames them, in
        // which case that layer is simply not mirrored rather than anything throwing.
        private static readonly FieldInfo OrbGlowField = typeof(OrbBall).GetField("_glowrender", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo OrbCrystalField = typeof(OrbBall).GetField("_cerender", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo OrbChargeField = typeof(OrbBall).GetField("_chargerender", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo OrbChargeTransformField = typeof(OrbBall).GetField("_ct", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo OrbTrailsField = typeof(OrbBall).GetField("GemaOrbTrails", BindingFlags.NonPublic | BindingFlags.Instance);

        // The game's orb sprite tables are short (4 body sprites, 3 glow sprites as of this build).
        private const int OrbSpriteTableProbe = 8;

        // Which entry of the game's own table this sprite IS, by reference. -2 means "a sprite that
        // is not in the table" -- still visible, so the receiver keeps whatever it has rather than
        // hiding the orb.
        private static int OrbSpriteIndex(Sprite sprite, bool glow)
        {
            if (sprite == null || CommonResource.Instance == null)
            {
                return -2;
            }
            for (int k = 0; k < OrbSpriteTableProbe; k++)
            {
                Sprite candidate = glow ? CommonResource.Instance.GetGlowOrb(k) : CommonResource.Instance.GetOrb(k);
                if (candidate == null)
                {
                    break;
                }
                if (candidate == sprite)
                {
                    return k;
                }
            }
            return -2;
        }

        private static int PackRgb(Color c)
        {
            return (Mathf.RoundToInt(Mathf.Clamp01(c.r) * 255f) << 16)
                 | (Mathf.RoundToInt(Mathf.Clamp01(c.g) * 255f) << 8)
                 | Mathf.RoundToInt(Mathf.Clamp01(c.b) * 255f);
        }

        // Read off the LOCAL player's real orbs, every frame. Hidden orbs (the game's HideOrb /
        // ShowAllOrb(false) / the orb-turned-summon Invisible path) are omitted, so "absent" and
        // "not shown" agree. Rows are the layout RemoteState.Orbs documents.
        private float[][] ReadOrbs(CharacterBase player)
        {
            if (player == null || player.t == null || player.playerc_perfer == null || player.playerc_perfer.orb == null)
            {
                return null;
            }
            OrbBall[] orbs = player.playerc_perfer.orb;
            List<float[]> rows = null;
            for (int i = 0; i < orbs.Length && i < 2; i++)
            {
                OrbBall ob = orbs[i];
                if (ob == null || ob._render == null || !ob.gameObject.activeInHierarchy || !ob._render.enabled)
                {
                    continue;
                }
                Vector3 d = ob.transform.position - player.t.position;
                SpriteRenderer glow = OrbGlowField != null ? OrbGlowField.GetValue(ob) as SpriteRenderer : null;
                SpriteRenderer crystal = OrbCrystalField != null ? OrbCrystalField.GetValue(ob) as SpriteRenderer : null;
                SpriteRenderer charge = OrbChargeField != null ? OrbChargeField.GetValue(ob) as SpriteRenderer : null;
                Transform ct = OrbChargeTransformField != null ? OrbChargeTransformField.GetValue(ob) as Transform : null;

                int glowSprite = glow != null && glow.enabled ? OrbSpriteIndex(glow.sprite, glow: true) : -1;
                int glowAlpha = glow != null ? Mathf.RoundToInt(glow.color.a * 100f) : 0;
                int crystalRgb = crystal != null && crystal.enabled ? PackRgb(crystal.color) : -1;
                int crystalAlpha = crystal != null ? Mathf.RoundToInt(crystal.color.a * 100f) : 0;
                int crystalRot = crystal != null ? Mathf.RoundToInt(crystal.transform.eulerAngles.z) : 0;
                int chargeScale = charge != null && charge.enabled && ct != null ? Mathf.RoundToInt(ct.localScale.x * 100f) : 0;

                rows = rows ?? new List<float[]>(2);
                rows.Add(new float[]
                {
                    i,
                    Mathf.Round(d.x * 10f) / 10f,
                    Mathf.Round(d.y * 10f) / 10f,
                    OrbSpriteIndex(ob._render.sprite, glow: false),
                    ob._render.sortingOrder,
                    glowSprite,
                    glowAlpha,
                    crystalRgb,
                    crystalAlpha,
                    crystalRot,
                    chargeScale,
                });
            }
            return rows == null ? null : rows.ToArray();
        }

        private GhostOrb CreateGhostOrb(string playerId, int index)
        {
            if (BulletManager.Instance == null || BulletManager.Instance.orb == null)
            {
                return null;
            }
            OrbBall prefab = BulletManager.Instance.orb;
            GameObject go = Instantiate(prefab.gameObject);
            go.name = $"MeshGhostRemote_{playerId}_orb{index}";
            OrbBall ob = go.GetComponent<OrbBall>();
            var orb = new GhostOrb { Go = go };
            if (ob != null)
            {
                orb.Render = ob._render;
                orb.Glow = OrbGlowField != null ? OrbGlowField.GetValue(ob) as SpriteRenderer : null;
                orb.Crystal = OrbCrystalField != null ? OrbCrystalField.GetValue(ob) as SpriteRenderer : null;
                orb.Charge = OrbChargeField != null ? OrbChargeField.GetValue(ob) as SpriteRenderer : null;
                orb.ChargeTransform = OrbChargeTransformField != null ? OrbChargeTransformField.GetValue(ob) as Transform : null;
                orb.Trails = OrbTrailsField != null ? OrbTrailsField.GetValue(ob) as GemaOrbTrail[] : null;
                // Before Start, see the block comment. DestroyImmediate, because a deferred
                // Destroy still lets Start run at the top of the next frame.
                DestroyImmediate(ob);
            }
            // THE AFTERIMAGE TRAIL (user, 2026-09-10: orbs synced, "not the orbitar after image/trail").
            // The trail objects are the prefab's own children and their GemaOrbTrail behaviour is
            // self-contained -- StartMe places and colours one, its FixedUpdate fades and parks it.
            // They stay, named so the orphan sweep can tell they are ours, and the ghost orb lights
            // them from this plugin's FixedUpdate exactly as the real orb does from its own.
            if (orb.Trails == null || orb.Trails.Length == 0)
            {
                orb.Trails = go.GetComponentsInChildren<GemaOrbTrail>(true);
            }
            for (int k = 0; k < orb.Trails.Length; k++)
            {
                if (orb.Trails[k] != null)
                {
                    orb.Trails[k].gameObject.name = go.name + "_trail" + k;
                    orb.Trails[k].gameObject.SetActive(false);
                }
            }
            foreach (Light light in go.GetComponentsInChildren<Light>(true))
            {
                light.enabled = false;
            }
            foreach (Collider2D collider in go.GetComponentsInChildren<Collider2D>(true))
            {
                Destroy(collider);
            }
            foreach (Rigidbody2D rb in go.GetComponentsInChildren<Rigidbody2D>(true))
            {
                Destroy(rb);
            }
            // Same parent the game gives the real orbs, so layering and scene membership match.
            if (GameSystem.Instance != null && GameSystem.Instance.maint != null)
            {
                go.transform.SetParent(GameSystem.Instance.maint, worldPositionStays: true);
            }
            if (orb.Render == null)
            {
                orb.Render = go.GetComponent<SpriteRenderer>();
            }
            Logger.LogInfo($"MeshGhost: orbitar {index} cloned for {playerId} "
                + $"(render={(orb.Render != null)} glow={(orb.Glow != null)} crystal={(orb.Crystal != null)} "
                + $"charge={(orb.Charge != null)} ct={(orb.ChargeTransform != null)}).");
            return orb;
        }

        private void ApplyGhostOrbs(string playerId, RemoteGhostVisual visual, float[][] rows, Vector3 peerRoot)
        {
            bool seen0 = false, seen1 = false;
            if (rows != null)
            {
                foreach (float[] row in rows)
                {
                    if (row == null || row.Length < 11)
                    {
                        continue;
                    }
                    bool finite = true;
                    for (int k = 0; k < row.Length; k++)
                    {
                        if (float.IsNaN(row[k]) || float.IsInfinity(row[k])) { finite = false; break; }
                    }
                    int index = finite ? (int)row[0] : -1;
                    if (index < 0 || index >= visual.Orbs.Length)
                    {
                        continue;
                    }
                    GhostOrb orb = visual.Orbs[index];
                    if (orb == null || orb.Go == null)
                    {
                        orb = CreateGhostOrb(playerId, index);
                        visual.Orbs[index] = orb;
                        if (orb == null)
                        {
                            continue;
                        }
                    }
                    if (index == 0) seen0 = true; else seen1 = true;
                    orb.Go.SetActive(true);
                    orb.Go.transform.position = peerRoot + new Vector3(row[1], row[2], 0f);

                    int sprite = (int)row[3];
                    if (orb.Render != null)
                    {
                        orb.Render.enabled = sprite != -1;
                        if (sprite >= 0 && CommonResource.Instance != null)
                        {
                            Sprite s = CommonResource.Instance.GetOrb(sprite);
                            if (s != null) orb.Render.sprite = s;
                        }
                        orb.Render.sortingOrder = (int)row[4];
                    }
                    int glowSprite = (int)row[5];
                    if (orb.Glow != null)
                    {
                        orb.Glow.enabled = glowSprite != -1;
                        if (glowSprite >= 0 && CommonResource.Instance != null)
                        {
                            Sprite s = CommonResource.Instance.GetGlowOrb(glowSprite);
                            if (s != null) orb.Glow.sprite = s;
                        }
                        Color c = orb.Glow.color;
                        c.a = Mathf.Clamp01(row[6] / 100f);
                        orb.Glow.color = c;
                    }
                    int crystalRgb = (int)row[7];
                    if (orb.Crystal != null)
                    {
                        orb.Crystal.enabled = crystalRgb >= 0;
                        if (crystalRgb >= 0)
                        {
                            orb.Crystal.color = new Color(((crystalRgb >> 16) & 255) / 255f, ((crystalRgb >> 8) & 255) / 255f,
                                (crystalRgb & 255) / 255f, Mathf.Clamp01(row[8] / 100f));
                            orb.Crystal.transform.eulerAngles = new Vector3(0f, 0f, row[9]);
                        }
                    }
                    int chargeScale = (int)row[10];
                    if (orb.Charge != null)
                    {
                        orb.Charge.enabled = chargeScale > 0;
                        // The game keeps the halo's sprite equal to the glow's (HidePoweredOrb /
                        // Start), so the clone does too.
                        if (chargeScale > 0)
                        {
                            if (orb.Glow != null && orb.Glow.sprite != null) orb.Charge.sprite = orb.Glow.sprite;
                            if (orb.ChargeTransform != null)
                            {
                                float sc = chargeScale / 100f;
                                orb.ChargeTransform.localScale = new Vector3(sc, sc, 1f);
                            }
                        }
                    }
                }
            }
            if (!seen0 && visual.Orbs[0] != null && visual.Orbs[0].Go != null && visual.Orbs[0].Go.activeSelf)
            {
                visual.Orbs[0].Go.SetActive(false);
            }
            if (!seen1 && visual.Orbs[1] != null && visual.Orbs[1].Go != null && visual.Orbs[1].Go.activeSelf)
            {
                visual.Orbs[1].Go.SetActive(false);
            }
        }

        // Mirrors OrbBall.FixedUpdate's one rule: while the crystal ring renders, one pooled
        // afterimage per physics step at the orb's position in the ring's colour. The colour's
        // alpha is overridden inside StartMe by the game itself, so only the RGB matters here.
        private void FixedUpdate()
        {
            if (remoteVisuals.Count == 0)
            {
                return;
            }
            // Bullets step here, on the same physics tick BulletManager gives the real ones.
            TickGhostBullets();
            foreach (KeyValuePair<string, RemoteGhostVisual> kv in remoteVisuals)
            {
                GhostOrb[] orbs = kv.Value.Orbs;
                for (int i = 0; i < orbs.Length; i++)
                {
                    GhostOrb orb = orbs[i];
                    if (orb == null || orb.Go == null || !orb.Go.activeInHierarchy
                        || orb.Crystal == null || !orb.Crystal.enabled || orb.Trails == null)
                    {
                        continue;
                    }
                    for (int k = 0; k < orb.Trails.Length; k++)
                    {
                        GemaOrbTrail trail = orb.Trails[k];
                        if (trail != null && !trail.isActiveAndEnabled)
                        {
                            trail.StartMe(orb.Crystal.color, orb.Go.transform.position);
                            break;
                        }
                    }
                }
            }
        }

        // CORE EXPANSIONS -- the B-button orbitar skills (user's name for them, 2026-09-10).
        //
        // THE FIRST BUILD LOOKED AT THE WRONG MECHANISM and mirrored nothing (user: "the core
        // expansions are not working"; the probe never saw a SUMMON-typed character). OrbBall's
        // SkillUsing path (SkillName.*_TEMP, BossType.SUMMON, SetSubOwner) is a legacy route nothing
        // in this build triggers. The real one is CharacterPhy.UseBoost -> BoostSystem ->
        // EventManager.OrbsToHumanoid: the orb is HIDDEN, a trail (GemaOrbToHumanoidTrail) flies from
        // the orb to a REAL character created as CreateEnemy(Celia|Sable, NOAI) and made Invisible();
        // ~0.33s later it plays "to_character", turns visible, becomes BossType.NPC, runs the boost
        // logic (SUMMON_BOOST_N/U/D), plays "to_ball", a trail flies back to the orb, the character
        // despawns and the orb is shown again. The humanoid is found by the game itself as
        // GetCharacterWithID(Celia|Sable, 0): a non-player Celia or Sable IS the player's core
        // expansion, which is the identity this reader uses.
        //
        // None of that may exist on the watcher's machine as a character. What the
        // peer's screen shows is a character sprite rig -- the same PixelCharacter the player has,
        // with a different Animator controller -- so the ghost of a summon is built the way the
        // ghost itself is: clone the local player's rig, swap the controller to the one the peer's
        // summon is wearing (looked up through the game's own GetNPC by controller name), and
        // drive it by clip name and phase, including the game's own "to_character"
        // and "to_ball" clips. The trail is a clone of the game's own trail object, flown at the
        // ghost orb's position toward the summon ghost (and back when the row disappears).
        //
        // Echo-loop safety: a PEER's summon ghost on this machine is a bare sprite clone, never a
        // CharacterBase, so it can never be picked up by this reader (before-mirroring-state.md).
        // PROBE, temporary: what the summon filter sees, one line per second while any SUMMON-typed
        // character is alive. Armed 2026-09-10 because a B press produced no summon rows at all.
        private const bool DIAG_SUMMON_TRACE = false;
        private float lastSummonDiagTime = float.NegativeInfinity;

        private object[][] ReadSummons(CharacterBase player)
        {
            if (player == null || player.t == null || CharacterManager.Instance == null
                || CharacterManager.Instance.characters == null)
            {
                return null;
            }
            List<object[]> rows = null;
            List<CharacterBase> all = CharacterManager.Instance.characters;
            bool diagDue = DIAG_SUMMON_TRACE && Time.time - lastSummonDiagTime >= 1f;
            for (int i = 0; i < all.Count; i++)
            {
                CharacterBase cb = all[i];
                if (diagDue && cb != null && !cb.isPlayer()
                    && (cb.type == Character.Type.Celia || cb.type == Character.Type.Sable))
                {
                    lastSummonDiagTime = Time.time;
                    PixelCharacter px = cb.spranim_prefer != null ? cb.spranim_prefer.pixel : null;
                    Logger.LogInfo($"MeshGhost/probe summon: type={cb.type} isBoss={cb.isBoss} id={cb.ID} "
                        + $"subowner={(cb.subowner == null ? "null" : cb.subowner.name)} active={cb.gameObject.activeInHierarchy} "
                        + $"pixel={(px != null)} anim={(px != null && px.anim != null)} "
                        + $"base={(px != null && px.basesprite != null ? px.basesprite.enabled.ToString() : "n/a")} "
                        + $"ctrl={(px != null && px.anim != null && px.anim.runtimeAnimatorController != null ? px.anim.runtimeAnimatorController.name : "null")}");
                }
                if (cb == null || cb.isPlayer()
                    || (cb.type != Character.Type.Celia && cb.type != Character.Type.Sable)
                    || !cb.gameObject.activeInHierarchy || cb.spranim_prefer == null
                    || cb.spranim_prefer.pixel == null || cb.spranim_prefer.pixel.anim == null)
                {
                    continue;
                }
                PixelCharacter pixel = cb.spranim_prefer.pixel;
                if (pixel.basesprite == null)
                {
                    continue;
                }
                bool visible = pixel.basesprite.enabled;
                RuntimeAnimatorController controller = pixel.anim.runtimeAnimatorController;
                if (controller == null)
                {
                    continue;
                }
                // ABSOLUTE: the humanoid stands still in the world while the peer moves; relative to
                // the peer's root it inherited the ghost's interpolated motion (user, 2026-09-10:
                // "the summon is supposed to stay still, but ... moving slightly depending on where
                // the ghost was").
                Vector3 d = pixel.transform.position;
                if (DIAG_SHIELD_TIMING)
                {
                    string clipNow = cb.spranim_prefer.GetAnimationTrueName() + (visible ? "" : " (invisible)");
                    string key = cb.type.ToString();
                    string last;
                    if (!lastSummonClipLogged.TryGetValue(key, out last) || last != clipNow)
                    {
                        lastSummonClipLogged[key] = clipNow;
                        Logger.LogInfo($"MeshGhost/probe summon-send: {key} clip={clipNow} t={Time.time:0.000}");
                    }
                }
                AnimatorStateInfo info = pixel.anim.GetCurrentAnimatorStateInfo(0);
                float phase = info.normalizedTime;
                phase -= Mathf.Floor(phase);
                rows = rows ?? new List<object[]>(2);
                rows.Add(new object[]
                {
                    cb.type.ToString(),
                    controller.name,
                    Mathf.Round(d.x * 10f) / 10f,
                    Mathf.Round(d.y * 10f) / 10f,
                    cb.direction.ToString(),
                    cb.spranim_prefer.GetAnimationTrueName(),
                    Mathf.Round(phase * 1000f) / 1000f,
                    pixel.transform.localScale.x,
                    pixel.transform.localScale.y,
                    visible,
                    // The peer's animator speed: the humanoid's clips do not all run at 1, and a
                    // ghost playing at 1 with a hard re-seek on drift snapped every fraction of a
                    // second (user, 2026-09-10: "animating a bit weird/looping").
                    pixel.anim.speed,
                });
            }
            if (DIAG_SHIELD_TIMING && (rows == null) != lastSummonRowsNull)
            {
                lastSummonRowsNull = rows == null;
                Logger.LogInfo($"MeshGhost/probe summon-send: rows {(rows == null ? "STOP" : "start")} t={Time.time:0.000}");
                if (rows == null) lastSummonClipLogged.Clear();
            }
            return rows == null ? null : rows.ToArray();
        }

        private readonly Dictionary<string, string> lastSummonClipLogged = new Dictionary<string, string>();
        private bool lastSummonRowsNull = true;

        private static float CellF(object[] row, int i)
        {
            return row[i] is float f ? f : float.NaN;
        }

        private static bool AnimatorHasState(Animator anim, string clip)
        {
            if (anim == null || string.IsNullOrEmpty(clip))
            {
                return false;
            }
            int hash = Animator.StringToHash(clip);
            for (int layer = 0; layer < anim.layerCount; layer++)
            {
                if (anim.HasState(layer, hash))
                {
                    return true;
                }
            }
            return false;
        }

        private void ApplyGhostSummons(string playerId, RemoteGhostVisual visual, object[][] rows, Vector3 worldOffset)
        {
            List<string> seen = null;
            if (rows != null)
            {
                foreach (object[] row in rows)
                {
                    if (row == null || row.Length < 9)
                    {
                        continue;
                    }
                    string type = row[0] as string;
                    string controllerName = row[1] as string;
                    float dx = CellF(row, 2), dy = CellF(row, 3);
                    string dir = row[4] as string;
                    string clip = row[5] as string;
                    float phase = CellF(row, 6);
                    float sx = CellF(row, 7), sy = CellF(row, 8);
                    bool visibleNow = row.Length > 9 && row[9] is bool vb ? vb : true;
                    float peerSpeed = row.Length > 10 && row[10] is float ps && !float.IsNaN(ps) && !float.IsInfinity(ps) ? ps : 1f;
                    if (string.IsNullOrEmpty(type) || string.IsNullOrEmpty(controllerName)
                        || float.IsNaN(dx) || float.IsNaN(dy) || float.IsInfinity(dx) || float.IsInfinity(dy)
                        || float.IsNaN(sx) || float.IsNaN(sy) || float.IsInfinity(sx) || float.IsInfinity(sy))
                    {
                        continue;
                    }
                    SummonGhost sg;
                    if (!visual.Summons.TryGetValue(type, out sg) || sg.Go == null)
                    {
                        if (cloneTemplate == null || cloneTemplate.spranim_prefer == null
                            || cloneTemplate.spranim_prefer.pixel == null || AreaResource.Instance == null)
                        {
                            continue;
                        }
                        RuntimeAnimatorController controller = AreaResource.Instance.GetNPC(controllerName);
                        if (controller == null)
                        {
                            // Logged through the visual's rejected-name set so it is said once.
                            visual.RejectedAnims = visual.RejectedAnims ?? new HashSet<string>();
                            if (visual.RejectedAnims.Add("summon:" + controllerName))
                            {
                                Logger.LogWarning($"MeshGhost: no animator controller named '{controllerName}' for {playerId}'s summon {type}; not rendering it.");
                            }
                            continue;
                        }
                        GameObject go = CreateRealGhostVisual(cloneTemplate, $"MeshGhostRemote_{playerId}_summon{type}",
                            out PixelCharacter pc, out Vector3 _, out string _);
                        if (pc != null && pc.anim != null)
                        {
                            pc.anim.runtimeAnimatorController = controller;
                            pc.anim.speed = 1f;
                        }
                        sg = new SummonGhost { Go = go, Pc = pc, Controller = controllerName };
                        visual.Summons[type] = sg;
                        Logger.LogInfo($"MeshGhost: core expansion '{type}' cloned for {playerId} (controller '{controllerName}').");
                    }
                    seen = seen ?? new List<string>(2);
                    seen.Add(type);
                    sg.Go.SetActive(true);
                    sg.Go.transform.position = worldOffset + new Vector3(dx, dy, 0f);
                    sg.Go.transform.localScale = new Vector3(sx, sy, 1f);
                    // The row APPEARING is the orb-to-humanoid moment: fly the trail from the
                    // ghost orb (black orb for Sable, white for Celia) to this summon, as the game
                    // does. It is parked when the summon turns visible, which is when the game
                    // parks its own.
                    if (!sg.WasPresent)
                    {
                        sg.WasPresent = true;
                        StartSummonTrail(visual, sg, type, toSummon: true);
                    }
                    if (visibleNow && sg.Trail != null && sg.Trail.gameObject.activeSelf)
                    {
                        sg.Trail.gameObject.SetActive(false);
                    }
                    if (visibleNow != sg.Visible && sg.Pc != null)
                    {
                        sg.Visible = visibleNow;
                        foreach (SpriteRenderer sr in sg.Go.GetComponentsInChildren<SpriteRenderer>(true))
                        {
                            sr.enabled = visibleNow;
                        }
                    }
                    if (sg.Pc != null)
                    {
                        // Same convention as the ghost: flipX true is facing RIGHT (confirmed live 2026-08-12).
                        bool flip = dir == "RIGHT";
                        if (sg.Pc.basesprite != null) sg.Pc.basesprite.flipX = flip;
                        if (sg.Pc.outlinesprite != null) sg.Pc.outlinesprite.flipX = flip;
                        if (sg.Pc.effectsprite != null) sg.Pc.effectsprite.flipX = flip;
                        if (sg.Pc.flashsprite != null) sg.Pc.flashsprite.flipX = flip;
                        if (sg.Pc.supportsprite != null) sg.Pc.supportsprite.flipX = flip;

                        if (sg.Pc.anim != null && AnimatorHasState(sg.Pc.anim, clip))
                        {
                            float t = float.IsNaN(phase) ? 0f : Mathf.Clamp01(phase);
                            if (clip != sg.LastAnim)
                            {
                                sg.Pc.anim.Play(clip, 0, t);
                                sg.LastAnim = clip;
                                sg.Pc.anim.speed = peerSpeed;
                                if (DIAG_SHIELD_TIMING) Logger.LogInfo($"MeshGhost/probe summon-recv: {type} play {clip} visible={visibleNow} t={Time.time:0.000}");
                            }
                            else if (!float.IsNaN(phase))
                            {
                                // Same rule as the ghost's own clip: a big jump is the peer restarting
                                // the clip and is seeked; small drift is repaid continuously by a
                                // bounded speed change on top of the PEER'S speed, never snapped.
                                float g = sg.Pc.anim.GetCurrentAnimatorStateInfo(0).normalizedTime;
                                g -= Mathf.Floor(g);
                                float drift = t - g;
                                if (drift > 0.5f) drift -= 1f; else if (drift < -0.5f) drift += 1f;
                                if (Mathf.Abs(drift) > AnimReseekThreshold)
                                {
                                    sg.Pc.anim.Play(clip, 0, t);
                                    sg.Pc.anim.speed = peerSpeed;
                                }
                                else
                                {
                                    sg.Pc.anim.speed = peerSpeed * Mathf.Clamp(1f + drift * PhaseCatchupGain,
                                        1f - PhaseCatchupRange, 1f + PhaseCatchupRange);
                                }
                            }
                        }
                    }
                }
            }
            foreach (KeyValuePair<string, SummonGhost> kv in visual.Summons)
            {
                SummonGhost sg = kv.Value;
                if (sg.Go != null && sg.Go.activeSelf && (seen == null || !seen.Contains(kv.Key)))
                {
                    // The row DISAPPEARING is the humanoid-to-orb moment: the trail flies back
                    // to the ghost orb from where the summon stood, then parks 0.7s later.
                    sg.Go.SetActive(false);
                    sg.WasPresent = false;
                    StartSummonTrail(visual, sg, kv.Key, toSummon: false);
                    if (DIAG_SHIELD_TIMING) Logger.LogInfo($"MeshGhost/probe summon-recv: {kv.Key} HIDDEN (row gone) t={Time.time:0.000}");
                }
                if (sg.Trail != null && sg.Trail.gameObject.activeSelf && Time.time >= sg.TrailOffAt)
                {
                    sg.Trail.gameObject.SetActive(false);
                }
            }
        }

        // Sable rides the BLACK orb (index 0), Celia the WHITE (index 1) -- the game's own pairing
        // in OrbsToHumanoid. The trail object is cloned from the game's first trail on first use.
        private void StartSummonTrail(RemoteGhostVisual visual, SummonGhost sg, string type, bool toSummon)
        {
            int orbIndex = type == "Sable" ? 0 : 1;
            GhostOrb orb = orbIndex < visual.Orbs.Length ? visual.Orbs[orbIndex] : null;
            if (sg.Go == null || orb == null || orb.Go == null)
            {
                return;
            }
            if (sg.Trail == null)
            {
                if (EventManager.Instance == null || O2HTrailsField == null)
                {
                    return;
                }
                var templates = O2HTrailsField.GetValue(EventManager.Instance) as GemaOrbToHumanoidTrail[];
                if (templates == null || templates.Length == 0 || templates[0] == null)
                {
                    return;
                }
                GameObject go = Instantiate(templates[0].gameObject);
                go.name = sg.Go.name + "_trail";
                go.transform.SetParent(sg.Go.transform.parent, worldPositionStays: true);
                sg.Trail = go.GetComponent<GemaOrbToHumanoidTrail>();
                if (sg.Trail == null)
                {
                    Destroy(go);
                    return;
                }
                go.SetActive(false);
            }
            if (toSummon)
            {
                sg.Trail.transform.position = orb.Go.transform.position;
                sg.Trail.RestartMe(sg.Go.transform, new Vector3(0f, -16f, 0f));
                sg.TrailOffAt = Time.time + 0.325f; // the game parks it here if the summon never shows
            }
            else
            {
                sg.Trail.transform.position = sg.Go.transform.position;
                sg.Trail.RestartMe(orb.Go.transform, Vector3.zero);
                sg.TrailOffAt = Time.time + 0.7f;
            }
        }

        private void DestroyGhostSummons(RemoteGhostVisual visual)
        {
            foreach (KeyValuePair<string, SummonGhost> kv in visual.Summons)
            {
                if (kv.Value.Go != null)
                {
                    Destroy(kv.Value.Go);
                }
                if (kv.Value.Trail != null)
                {
                    Destroy(kv.Value.Trail.gameObject);
                }
            }
            visual.Summons.Clear();
        }

        // THE ORB-TO-HUMAN FLASH. OrbBall.Invisible(effect: true) spawns one of two pooled effects
        // at the orb (white orb: CreateOrbToHumanEffect, else CreateOrbToHumanEffect2), tilted 90
        // degrees and scaled 32x1x32, and sets invButNotSummon. That flag's RISE is the event; the
        // watcher plays the same pooled effect at its ghost orb. Not parented to the ghost orb the
        // way the game parents to the real one: our orb can be destroyed while the pooled effect
        // is live, and a destroyed pooled object corrupts the pool.
        private int localOrbFxSeq;
        private int localOrbFxOrb;
        private bool localOrbFxWhite;
        private readonly bool[] lastOrbInvisible = new bool[2];

        private void WatchLocalOrbFx(CharacterBase player)
        {
            if (player == null || player.playerc_perfer == null || player.playerc_perfer.orb == null)
            {
                return;
            }
            OrbBall[] orbs = player.playerc_perfer.orb;
            for (int i = 0; i < orbs.Length && i < 2; i++)
            {
                bool inv = orbs[i] != null && orbs[i].invButNotSummon;
                if (inv && !lastOrbInvisible[i])
                {
                    localOrbFxSeq++;
                    localOrbFxOrb = i;
                    localOrbFxWhite = orbs[i].orbType == Character.OrbType.WHITE;
                }
                lastOrbInvisible[i] = inv;
            }
        }

        private void ApplyOrbFx(RemoteGhostVisual visual, BridgeClient.RemoteState state)
        {
            int seq = state.OrbFxSeq ?? 0;
            if (seq <= 0)
            {
                return;
            }
            if (visual.LastOrbFxSeq == 0)
            {
                visual.LastOrbFxSeq = seq; // first sighting adopts, never replays history
                return;
            }
            if (seq <= visual.LastOrbFxSeq)
            {
                return;
            }
            visual.LastOrbFxSeq = seq;
            if (GemaPoolManager.Instance == null)
            {
                return;
            }
            int orbIndex = state.OrbFxOrb ?? 0;
            Vector3 at = visual.Go != null ? visual.Go.transform.position : Vector3.zero;
            if (orbIndex >= 0 && orbIndex < visual.Orbs.Length && visual.Orbs[orbIndex] != null && visual.Orbs[orbIndex].Go != null)
            {
                at = visual.Orbs[orbIndex].Go.transform.position;
            }
            Transform fx = (state.OrbFxWhite ?? false)
                ? GemaPoolManager.Instance.CreateOrbToHumanEffect()
                : GemaPoolManager.Instance.CreateOrbToHumanEffect2();
            if (fx == null)
            {
                return;
            }
            fx.position = at;
            fx.eulerAngles = new Vector3(90f, 0f, 0f);
            fx.localScale = new Vector3(32f, 1f, 32f);
        }

        // THE BOOST SHIELD -- the barrier a core expansion raises (user, 2026-09-10: "it does the
        // summon thing now, but not the barrier"). playerController.BoostShieldObject is an FXVShield:
        // a shader-driven mesh with an activation animation and a camera post-process, placed on
        // the humanoid by the boost logic (SUMMON.cs), scaled by badges, given a random Y spin, and
        // coloured by type. Two platform sprites (BoostPlatforms) fade in under it.
        //
        // WHAT TRAVELS: where it is, how big, how it is turned, and its three material colours READ
        // OFF THE PEER'S MATERIAL -- not the type, because the colours are the game's decision and
        // reading them is what keeps this right if a badge or a build changes them.
        //
        // THE CLONE IS THE GAME'S OWN SHIELD OBJECT with one private flag cleared: FXVShield's
        // FixedUpdate calls BulletManager.BlockBulletsWithShield while `isBoostShield` is set --
        // a peer's barrier erasing YOUR enemies' bullets would be a gameplay effect on the watcher,
        // so the clone's flag is set false by reflection before it is ever active. Everything else
        // (activation rim, the post-process, the inside mesh) is the component doing its own job.
        //
        // ONE SHARED RESOURCE: FXVShield.DisableMe turns the camera's ShieldPostProcess OFF when any
        // shield finishes deactivating -- the game only ever has one. With a ghost's clone in the
        // scene, ours could switch it off under the local player's live shield, so KeepShieldPostprocess
        // re-enables it every frame while any shield here (the player's or a ghost's) is up.
        private static readonly FieldInfo ShieldIsBoostField = typeof(FXVShield).GetField("isBoostShield", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo ShieldActivationMaterialField = typeof(FXVShield).GetField("activationMaterial", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo ShieldPostActivationMaterialField = typeof(FXVShield).GetField("postprocessActivationMaterial", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly int ShieldTexColorId = Shader.PropertyToID("_TextureColor");
        private static readonly int ShieldPatternColorId = Shader.PropertyToID("_PatternColor");

        private static string Hex(Color c)
        {
            Color32 b = c;
            return b.r.ToString("X2") + b.g.ToString("X2") + b.b.ToString("X2") + b.a.ToString("X2");
        }

        private static bool TryColor(object cell, out Color c)
        {
            c = Color.white;
            string s = cell as string;
            if (s == null || s.Length != 8)
            {
                return false;
            }
            try
            {
                byte r = System.Convert.ToByte(s.Substring(0, 2), 16), g = System.Convert.ToByte(s.Substring(2, 2), 16);
                byte bl = System.Convert.ToByte(s.Substring(4, 2), 16), a = System.Convert.ToByte(s.Substring(6, 2), 16);
                c = new Color32(r, g, bl, a);
                return true;
            }
            catch (System.Exception)
            {
                return false;
            }
        }

        private const bool DIAG_SHIELD_TIMING = false;
        private bool lastShieldUpSent;
        private bool lastShieldRowSent;

        private object[] ReadShield(CharacterBase player)
        {
            if (player == null || player.t == null || player.playerc_perfer == null)
            {
                return null;
            }
            FXVShield sh = player.playerc_perfer.BoostShieldObject;
            bool rowNow = !(sh == null || !sh.gameObject.activeInHierarchy || !(sh.GetIsShieldActive() || sh.GetIsDuringActivationAnim()));
            if (DIAG_SHIELD_TIMING && rowNow != lastShieldRowSent)
            {
                lastShieldRowSent = rowNow;
                Logger.LogInfo($"MeshGhost/probe shield: ROW {(rowNow ? "starts" : "stops")} t={Time.time:0.000}");
            }
            if (!rowNow)
            {
                return null;
            }
            Renderer r = sh.GetComponent<Renderer>();
            Material m = r != null ? r.sharedMaterial : null;
            // PROBE (event-triggered, a line per change): when the peer's shield flips up/fading and
            // when its row stops -- to time the ghost's fade against it (2026-09-10, "the barrier
            // still stays for a bit").
            if (DIAG_SHIELD_TIMING && sh.GetIsShieldActive() != lastShieldUpSent)
            {
                lastShieldUpSent = sh.GetIsShieldActive();
                Logger.LogInfo($"MeshGhost/probe shield: SEND up={lastShieldUpSent} anim={sh.GetIsDuringActivationAnim()} t={Time.time:0.000}");
            }
            // ABSOLUTE world position: the shield sits on the humanoid, a world-fixed thing, and a
            // root-relative offset would make it inherit the ghost's interpolated motion (the user
            // saw the summon "moving slightly depending on where the ghost was", 2026-09-10).
            Vector3 d = sh.transform.position;
            Vector3 e = sh.transform.eulerAngles;
            return new object[]
            {
                Mathf.Round(d.x * 10f) / 10f, Mathf.Round(d.y * 10f) / 10f, Mathf.Round(d.z * 10f) / 10f,
                Mathf.Round(sh.transform.localScale.x * 10f) / 10f,
                Mathf.Round(e.x), Mathf.Round(e.y), Mathf.Round(e.z),
                m != null ? Hex(m.color) : "FFFFFFFF",
                m != null && m.HasProperty(ShieldTexColorId) ? Hex(m.GetColor(ShieldTexColorId)) : "FFFFFFFF",
                m != null && m.HasProperty(ShieldPatternColorId) ? Hex(m.GetColor(ShieldPatternColorId)) : "FFFFFFFF",
                // UP or FADING. The row is sent through the peer's deactivation animation (so the
                // clone can be placed), but the clone must start ITS fade the moment the peer's
                // starts, not after it ends -- the user saw the barrier "stay a bit too long".
                sh.GetIsShieldActive(),
            };
        }

        private object[][] ReadPlatforms(CharacterBase player)
        {
            if (player == null || player.t == null || player.playerc_perfer == null || player.playerc_perfer.BoostPlatforms == null)
            {
                return null;
            }
            SpriteRenderer[] plats = player.playerc_perfer.BoostPlatforms;
            List<object[]> rows = null;
            for (int i = 0; i < plats.Length && i < 2; i++)
            {
                SpriteRenderer sr = plats[i];
                if (sr == null || !sr.enabled || !sr.gameObject.activeInHierarchy)
                {
                    continue;
                }
                Vector3 d = sr.transform.position; // absolute, see ReadShield
                rows = rows ?? new List<object[]>(2);
                rows.Add(new object[] { (float)i, Mathf.Round(d.x * 10f) / 10f, Mathf.Round(d.y * 10f) / 10f, Hex(sr.color) });
            }
            return rows == null ? null : rows.ToArray();
        }

        private void ApplyGhostShield(string playerId, RemoteGhostVisual visual, BridgeClient.RemoteState state, Vector3 worldOffset)
        {
            object[] row = state.Shield;
            if (row != null && row.Length >= 10 && cloneTemplate != null && cloneTemplate.playerc_perfer != null)
            {
                float dx = CellF(row, 0), dy = CellF(row, 1), dz = CellF(row, 2), sc = CellF(row, 3);
                float rx = CellF(row, 4), ry = CellF(row, 5), rz = CellF(row, 6);
                bool finite = !(float.IsNaN(dx) || float.IsNaN(dy) || float.IsNaN(dz) || float.IsNaN(sc)
                    || float.IsNaN(rx) || float.IsNaN(ry) || float.IsNaN(rz)
                    || float.IsInfinity(dx) || float.IsInfinity(dy) || float.IsInfinity(dz) || float.IsInfinity(sc));
                if (finite)
                {
                    GhostShield gs = visual.Shield;
                    if (gs == null || gs.Go == null)
                    {
                        FXVShield template = cloneTemplate.playerc_perfer.BoostShieldObject;
                        if (template != null)
                        {
                            GameObject go = Instantiate(template.gameObject);
                            go.name = $"MeshGhostRemote_{playerId}_shield";
                            go.transform.SetParent(template.transform.parent, worldPositionStays: true);
                            // THE TEMPLATE IS PARKED INACTIVE between boosts (FXVShield.DisableMe), so
                            // its clone is born inactive and Awake -- which builds every material --
                            // has not run. SetMainColor on it threw NullReference per message, and the
                            // exception aborted the whole ghost update: pose and facing froze for the
                            // length of the core expansion (user, 2026-09-10). Activating once runs
                            // Awake synchronously; Awake's own DisableMe parks it again, initialised.
                            go.SetActive(true);
                            FXVShield fx = go.GetComponent<FXVShield>();
                            if (fx != null && ShieldIsBoostField != null)
                            {
                                ShieldIsBoostField.SetValue(fx, false);
                            }
                            foreach (Collider col in go.GetComponentsInChildren<Collider>(true))
                            {
                                Destroy(col);
                            }
                            // THE GLOW IS A CAMERA POST-PROCESS, not the mesh: FXVShieldPostprocess
                            // draws every shield in its list with the shield's activation material,
                            // which is where the start-up bloom and the fade-out live. A shield joins
                            // that list in its Awake via Camera.main -- and the clone's Awake ran with
                            // whatever Camera.main was at that instant, not the camera the game's own
                            // CameraScript holds. Registering with the game's actual post-process is
                            // what makes the clone glow and fade like the peer's (user, 2026-09-10:
                            // "just disappearing, not doing the fading/ending vfx", "missing that at
                            // the start as well").
                            // THE ACTIVATION KEYWORD IS GONE FROM THE CLONE'S MATERIALS. FXVShield.SetMaterial
                            // builds its four materials from the renderer's current material and then
                            // strips ACTIVATION_EFFECT_ON from the base one; the template has already
                            // done that, so its renderer now holds the stripped base material -- and a
                            // clone's Awake builds everything from THAT. Its activation materials never
                            // had the keyword, so the shield popped on and off with no bloom and no fade
                            // (user, 2026-09-10, twice). Re-enable it on the two activation materials.
                            bool keyworded = false;
                            if (fx != null)
                            {
                                Material am = ShieldActivationMaterialField != null ? ShieldActivationMaterialField.GetValue(fx) as Material : null;
                                Material pam = ShieldPostActivationMaterialField != null ? ShieldPostActivationMaterialField.GetValue(fx) as Material : null;
                                if (am != null) { am.EnableKeyword("ACTIVATION_EFFECT_ON"); keyworded = true; }
                                if (pam != null) { pam.EnableKeyword("ACTIVATION_EFFECT_ON"); }
                            }
                            bool registered = false;
                            if (fx != null && CameraScript.Instance != null && CameraScript.Instance.ShieldPostProcess != null)
                            {
                                CameraScript.Instance.ShieldPostProcess.AddShield(fx);
                                registered = true;
                            }
                            gs = new GhostShield { Go = go, Fx = fx };
                            visual.Shield = gs;
                            Logger.LogInfo($"MeshGhost: boost shield cloned for {playerId} (fx={(fx != null)} boostFlagCleared={(fx != null && ShieldIsBoostField != null)} postprocess={registered} activationKeyword={keyworded}).");
                        }
                    }
                    if (gs != null && gs.Go != null)
                    {
                        gs.Go.transform.position = worldOffset + new Vector3(dx, dy, dz);
                        gs.Go.transform.localScale = new Vector3(sc, sc, sc);
                        gs.Go.transform.eulerAngles = new Vector3(rx, ry, rz);
                        if (gs.Fx != null)
                        {
                            Color c;
                            if (TryColor(row[7], out c)) gs.Fx.SetMainColor(c);
                            if (TryColor(row[8], out c)) gs.Fx.SetTextureColor(c);
                            if (TryColor(row[9], out c)) gs.Fx.SetPatternColor(c);
                            bool up = row.Length > 10 && row[10] is bool ub ? ub : true;
                            if (up && !gs.Up)
                            {
                                gs.Up = true;
                                gs.Fx.SetShieldActive(active: true);
                            }
                            else if (!up && gs.Up)
                            {
                                gs.Up = false;
                                gs.Fx.SetShieldActive(active: false);
                                if (DIAG_SHIELD_TIMING) Logger.LogInfo($"MeshGhost/probe shield: RECV fade starts t={Time.time:0.000}");
                            }
                        }
                    }
                }
            }
            else if (visual.Shield != null && visual.Shield.Up)
            {
                // The peer's barrier came down: animate ours down the same way. DisableMe parks the
                // object when the animation ends.
                visual.Shield.Up = false;
                if (visual.Shield.Fx != null)
                {
                    visual.Shield.Fx.SetShieldActive(active: false);
                    if (DIAG_SHIELD_TIMING) Logger.LogInfo($"MeshGhost/probe shield: RECV row gone, fade starts t={Time.time:0.000}");
                }
            }

            // Platforms.
            bool seen0 = false, seen1 = false;
            if (state.Platforms != null && cloneTemplate != null && cloneTemplate.playerc_perfer != null
                && cloneTemplate.playerc_perfer.BoostPlatforms != null)
            {
                foreach (object[] prow in state.Platforms)
                {
                    if (prow == null || prow.Length < 4)
                    {
                        continue;
                    }
                    float fi = CellF(prow, 0), px = CellF(prow, 1), py = CellF(prow, 2);
                    if (float.IsNaN(fi) || float.IsNaN(px) || float.IsNaN(py) || float.IsInfinity(px) || float.IsInfinity(py))
                    {
                        continue;
                    }
                    int i = (int)fi;
                    if (i < 0 || i >= visual.Platforms.Length)
                    {
                        continue;
                    }
                    GhostPlatform gp = visual.Platforms[i];
                    if (gp == null || gp.Go == null)
                    {
                        SpriteRenderer[] templates = cloneTemplate.playerc_perfer.BoostPlatforms;
                        if (i >= templates.Length || templates[i] == null)
                        {
                            continue;
                        }
                        GameObject go = Instantiate(templates[i].gameObject);
                        go.name = $"MeshGhostRemote_{playerId}_plat{i}";
                        go.transform.SetParent(templates[i].transform.parent, worldPositionStays: true);
                        foreach (Collider2D col in go.GetComponentsInChildren<Collider2D>(true)) Destroy(col);
                        foreach (Rigidbody2D rb in go.GetComponentsInChildren<Rigidbody2D>(true)) Destroy(rb);
                        gp = new GhostPlatform { Go = go, Sr = go.GetComponent<SpriteRenderer>() };
                        visual.Platforms[i] = gp;
                    }
                    if (i == 0) seen0 = true; else seen1 = true;
                    gp.Go.SetActive(true);
                    gp.Go.transform.position = worldOffset + new Vector3(px, py, 0f);
                    if (gp.Sr != null)
                    {
                        gp.Sr.enabled = true;
                        Color c;
                        if (TryColor(prow[3], out c)) gp.Sr.color = c;
                    }
                }
            }
            if (!seen0 && visual.Platforms[0] != null && visual.Platforms[0].Go != null && visual.Platforms[0].Go.activeSelf) visual.Platforms[0].Go.SetActive(false);
            if (!seen1 && visual.Platforms[1] != null && visual.Platforms[1].Go != null && visual.Platforms[1].Go.activeSelf) visual.Platforms[1].Go.SetActive(false);
        }

        // See the shield block comment: one camera post-process, several shields.
        private void KeepShieldPostprocess(CharacterBase player)
        {
            if (CameraScript.Instance == null || CameraScript.Instance.ShieldPostProcess == null)
            {
                return;
            }
            bool anyUp = false;
            FXVShield mine = player != null && player.playerc_perfer != null ? player.playerc_perfer.BoostShieldObject : null;
            if (mine != null && mine.gameObject.activeInHierarchy && (mine.GetIsShieldActive() || mine.GetIsDuringActivationAnim()))
            {
                anyUp = true;
            }
            if (!anyUp)
            {
                foreach (KeyValuePair<string, RemoteGhostVisual> kv in remoteVisuals)
                {
                    GhostShield gs = kv.Value.Shield;
                    if (gs != null && gs.Fx != null && gs.Go.activeInHierarchy && (gs.Fx.GetIsShieldActive() || gs.Fx.GetIsDuringActivationAnim()))
                    {
                        anyUp = true;
                        break;
                    }
                }
            }
            if (DIAG_SHIELD_TIMING)
            {
                foreach (KeyValuePair<string, RemoteGhostVisual> kv in remoteVisuals)
                {
                    GhostShield gs = kv.Value.Shield;
                    if (gs == null || gs.Go == null) continue;
                    bool on = gs.Go.activeSelf;
                    if (on != gs.LoggedActive)
                    {
                        gs.LoggedActive = on;
                        Logger.LogInfo($"MeshGhost/probe shield: RECV clone {(on ? "ACTIVE" : "INACTIVE (fade done)")} t={Time.time:0.000}");
                    }
                }
            }
            if (anyUp && !CameraScript.Instance.ShieldPostProcess.enabled)
            {
                CameraScript.Instance.ShieldPostProcess.enabled = true;
            }
        }

        private readonly HashSet<string> subfeatureFailuresLogged = new HashSet<string>();

        private void LogSubfeatureFailure(string what, System.Exception e)
        {
            if (subfeatureFailuresLogged.Add(what + ":" + e.Message))
            {
                Logger.LogWarning($"MeshGhost: {what} mirroring failed and is skipped this frame (the ghost itself is unaffected): {e}");
            }
        }

        private void DestroyGhostShield(RemoteGhostVisual visual)
        {
            if (visual.Shield != null && visual.Shield.Go != null)
            {
                if (visual.Shield.Fx != null && CameraScript.Instance != null && CameraScript.Instance.ShieldPostProcess != null)
                {
                    CameraScript.Instance.ShieldPostProcess.RemoveShield(visual.Shield.Fx);
                }
                Destroy(visual.Shield.Go);
            }
            visual.Shield = null;
            for (int i = 0; i < visual.Platforms.Length; i++)
            {
                if (visual.Platforms[i] != null && visual.Platforms[i].Go != null)
                {
                    Destroy(visual.Platforms[i].Go);
                }
                visual.Platforms[i] = null;
            }
        }

        private void DestroyGhostOrbs(RemoteGhostVisual visual)
        {
            for (int i = 0; i < visual.Orbs.Length; i++)
            {
                if (visual.Orbs[i] != null && visual.Orbs[i].Go != null)
                {
                    Destroy(visual.Orbs[i].Go);
                }
                if (visual.Orbs[i] != null && visual.Orbs[i].Trails != null)
                {
                    foreach (GemaOrbTrail trail in visual.Orbs[i].Trails)
                    {
                        if (trail != null) Destroy(trail.gameObject);
                    }
                }
                visual.Orbs[i] = null;
            }
        }

        // PROJECTILES, SPAWN-AND-FLY -- the plan in agent_docs/ideas.md (the orbitar entry), built
        // 2026-09-10 on the census DIAG_BULLET_WATCH produced the same evening: every orbitar bullet
        // the user fired (basic A/B/C, charged A/B/C, the core expansions' shots; peak 29 alive) flew
        // with ZERO speed or angle drift and lived under a second. So a bullet is a pure function of
        // its birth here, and the watcher can fly it with the game's own step
        // (bulletScript._Update: cachepos += (cos, -sin) * speed * (fixeddeltatime * 60)).
        //
        // WHAT A BULLET LOOKS LIKE is not the bullet: most are SpriteType.USE_PS with no sprite at
        // all, and the visual is a pooled CommonEffects object (OrbShootNormal #8, the charge-shot
        // families #10/11/14/16/17/19/20/43/44/45/47) whose script is handed the bulletScript and
        // FOLLOWS it -- reading only its transform, its active flag, isDespawning() and its type.
        // So the watcher spawns the game's bullet PREFAB as a dormant object (never in
        // BulletManager's pool, so never ticked: no hits, no walls, no damage), flies it, and hands
        // it to the same pooled effect with the same Setup. The effect then ends itself the way it
        // does for a real bullet, hit flash included, when the dormant bullet is marked despawning.
        //
        // THE SENDER learns which effect was attached by scanning the effect pool on the birth frame
        // for an active object whose private bullet field points at the newborn -- identity, never
        // proximity. A death (wall, hit, range) is one seq in a second small ring, so an early end
        // vanishes at the same spot rather than flying on to the default life.
        //
        // Rings are 300ms wide so a lossy sample still carries a birth; the receiver dedupes on seq
        // and adopts the counter on first sight, never replaying history. Bullets are the elastic
        // field: BridgeClient drops them first when a frame nears the core's 1024-byte extras cap.
        // 150ms: a burst of a core expansion (29 alive at peak) at 300ms pushed one frame's extras to
        // 1047 bytes and the guard dropped every bullet in it (2026-09-10). At the shipped 20Hz
        // this is still three samples of loss cover; at the dev 100Hz, fifteen.
        //
        // THE FLIGHT IS THE GAME'S, NOT OURS (2026-09-10, second pass). The census above measured
        // speed and angle drift and found none -- true of the shots it saw, and false as a premise.
        // bulletScript._Update calls the bullet's own BulletBehave(), a switch on BulletType, and
        // the orbitar families move THEMSELVES inside it rather than through speed or angle:
        // the Sable charged B steps its position up and down every physics tick (the zig-zag a
        // straight-line mirror flattens), the Celia charged C turns 180 degrees, homes, then
        // accelerates past 1.6s, the Sable charged C falls on a curve, and the normal orb shot
        // homes when its counter 3 says so. A straight line at a constant speed is not any of
        // those (user, 2026-09-10: the ghost's shots "don't do these", "go a really short distance").
        //
        // So the watcher no longer reconstructs the flight: it hands the dormant bullet to the
        // game's own BulletBehave() on the game's own fixed step. Two things make that safe on a
        // machine that did not fire the shot, and both are guards, not hopes: the bullet is not in
        // BulletManager's pool and never hits anything, so every branch behind `hitlist.Count > 0`
        // (the bombs, the meter spend, the camera shake, the sub-bullets) is dead code for it; and
        // GuardedBulletBehave zeroes `useChargeRemove` around the call and despawns any bullet the
        // call put in the real pool anyway. See StepGhostBullet.
        //
        // WHAT ENDS A BULLET is also the game's: BulletBehave's own off-camera despawns, TimeDelete,
        // and the peer's mirrored death. The old flat 1.5s kill was read from EnableMe's `life`,
        // which despawns a bullet only while it is OFF SCREEN -- an on-screen charged shot outlives
        // it easily, and cutting it at 1.5s is most of "not going as far as intended".
        private const float BulletRingSeconds = 0.15f;
        private const float BulletLingerAfterDeath = 1f; // followers need to SEE isDespawning()
        // Nothing but a safety net: a type whose behave has no despawn rule of its own, on a frame
        // whose death row was dropped at the extras cap, would otherwise fly forever.
        private const float BulletSafetyLife = 12f;
        // A birth is up to a send interval old when it arrives, and the ghost body renders on the
        // core's interpolation delay, so a bullet spawned at its birth POSITION starts behind the
        // one it mirrors and dies short. Spawn replays the missing steps instead; the cap is a
        // sanity bound (30 steps = 0.5s), never reached at a sane send rate.
        private const int BulletCatchUpStepsMax = 30;
        private static readonly FieldInfo BulletPrefabField = typeof(BulletManager).GetField("bullet_prefab", BindingFlags.NonPublic | BindingFlags.Instance);
        // bulletScript.time is PUBLIC. Asking for it with NonPublic alone returned null, so the
        // sprite-advance branch this gated had never once run and drawn-sprite bullets (the lock-on
        // shot, Sable's charged shot) never animated a frame. Found 2026-09-10 reading the field
        // list, not the symptom -- a reflection lookup that fails is silent by construction.
        private static readonly FieldInfo BulletStartSizeField = typeof(bulletScript).GetField("startSize", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo BulletCachePosField = typeof(bulletScript).GetField("cachepos", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo BulletFlagsField = typeof(bulletScript).GetField("flags", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo BulletLifeField = typeof(bulletScript).GetField("life", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo BulletTimeDeleteField = typeof(bulletScript).GetField("TimeDelete", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo BulletStayField = typeof(bulletScript).GetField("isStayAtOwner", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo BulletCounterField = typeof(bulletScript).GetField("counter", BindingFlags.NonPublic | BindingFlags.Instance);
        // The angle's cached sine and cosine, which SetAngle keeps and BulletBehave changes under a
        // homing bullet. Read, never written: recomputing them from `angle` would be our arithmetic
        // standing in for the game's, and it is the game's that steers the bullet.
        private static readonly FieldInfo BulletCosField = typeof(bulletScript).GetField("_cos", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo BulletSinField = typeof(bulletScript).GetField("_sin", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly MethodInfo BulletBehaveMethod = typeof(bulletScript).GetMethod("BulletBehave", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly MethodInfo BulletStayMethod = typeof(bulletScript).GetMethod("StayAtOwner", BindingFlags.NonPublic | BindingFlags.Instance);
        // ShootBullet's own sprite step, which the watcher skipped: a clone off the prefab carries
        // the prefab's sprite, so every drawn bullet wore the wrong one (or none).
        private static readonly MethodInfo BulletManagerSetSprite = typeof(BulletManager).GetMethod("SetSprite", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo OrbShootNormalPs1Field = typeof(OrbShootNormal).GetField("ps1", BindingFlags.NonPublic | BindingFlags.Instance);

        // Effect kinds the sender recognises, by the follower component and its Setup signature.
        private static readonly System.Type[] EffectKindTypes =
        {
            typeof(OrbShootNormal),        // 0  Setup(Color, Direction, bullet)
            typeof(OrbChargeSableTypeA),   // 1  Setup(Direction, bullet)
            typeof(OrbChargeSableTypeB),   // 2  Setup(Direction, bullet)
            typeof(OrbNormalCeliaTypeB),   // 3  Setup(Direction, bullet)
            typeof(OrbNormalSableTypeB),   // 4  Setup(Direction, bullet)
            typeof(OrbChargeCeliaTypeB),   // 5  Setup(float angle, bullet, bool)
            typeof(OrbChargeCeliaTypeC),   // 6  SpawnMe(bullet)
            typeof(FollowBullet),          // 7  SpawnMe(bullet)
        };
        private static readonly string[] EffectKindBulletField = { "b", "b", "b", "b", "b", "bs", "b", "b" };
        private static readonly FieldInfo[] EffectKindFields = new FieldInfo[EffectKindTypes.Length];

        private sealed class BulletBirth { public int Seq; public float At; public object[] Row; public bulletScript B; }
        private readonly List<BulletBirth> bulletBirths = new List<BulletBirth>();
        private readonly List<KeyValuePair<int, float>> bulletDeathRing = new List<KeyValuePair<int, float>>();
        private int bulletSeq;
        private float[] bulletSlotBorn;   // timeCreated seen per pool slot
        private int[] bulletSlotSeq;      // our seq per pool slot, -1 none

        // A bullet's ten counters as "slot:value" pairs, and only the ones that are not zero --
        // almost always the empty string, which is what keeps this affordable inside the extras cap.
        private static string EncodeCounters(bulletScript b)
        {
            var arr = BulletCounterField != null ? BulletCounterField.GetValue(b) as float[] : null;
            if (arr == null) return "";
            string s = null;
            for (int i = 0; i < arr.Length; i++)
            {
                if (arr[i] == 0f || float.IsNaN(arr[i]) || float.IsInfinity(arr[i])) continue;
                string one = i.ToString(System.Globalization.CultureInfo.InvariantCulture) + ":"
                    + (Mathf.Round(arr[i] * 100f) / 100f).ToString(System.Globalization.CultureInfo.InvariantCulture);
                s = s == null ? one : s + "," + one;
            }
            return s ?? "";
        }

        // The birth state BulletBehave reads, as ONE cell: "startSize|counters|flags|life|delete",
        // each half empty when it is the default EnableMe already gave the clone. A cell per field
        // cost ~22 JSON bytes a bullet and bullets are what the extras cap drops first, so a burst
        // of a core expansion would have paid for this in whole shots that never appeared.
        private static string EncodeBirthState(bulletScript b)
        {
            float startSize = ReadFloatField(BulletStartSizeField, b, -1f);
            int flags = ReadIntField(BulletFlagsField, b);
            float life = ReadFloatField(BulletLifeField, b, 1.5f);
            float del = ReadFloatField(BulletTimeDeleteField, b, float.PositiveInfinity);
            string counters = EncodeCounters(b);
            var ci = System.Globalization.CultureInfo.InvariantCulture;
            // Sixth field: the renderer's tint, for the drawn families the shooter colours through
            // SetColor -- lily_groundbreak's fade rings are (16,64,255) on the shooter's screen and
            // were plain white on the ghost (user, 2026-09-10: "white circles").
            string rgba = b._render != null ? Hex(b._render.color) : "FFFFFFFF";
            string s = (startSize >= 0f ? (Mathf.Round(startSize * 100f) / 100f).ToString(ci) : "")
                + "|" + counters
                + "|" + (flags != 0 ? flags.ToString(ci) : "")
                + "|" + (life != 1.5f ? (Mathf.Round(life * 100f) / 100f).ToString(ci) : "")
                + "|" + (float.IsInfinity(del) || float.IsNaN(del) ? "" : (Mathf.Round(del * 100f) / 100f).ToString(ci))
                + "|" + (rgba == "FFFFFFFF" ? "" : rgba);
            return s == "|||||" ? "" : s;
        }

        private static void ApplyBirthState(bulletScript b, object cell, float fallbackScale)
        {
            string[] parts = (cell as string ?? "").Split('|');
            var ci = System.Globalization.CultureInfo.InvariantCulture;
            float startSize;
            if (parts.Length > 0 && parts[0].Length > 0
                && float.TryParse(parts[0], System.Globalization.NumberStyles.Float, ci, out startSize)
                && startSize > 0f)
            {
                // justSpawn:true so the game's own spawn pop runs -- the size read off the wire is
                // the base one, not whatever frame of the pop the sender happened to sample.
                b.SetSpriteSize(startSize, justSpawn: true);
            }
            else if (!float.IsNaN(fallbackScale) && fallbackScale > 0f)
            {
                b.SetSpriteSize(fallbackScale, justSpawn: false);
            }
            if (parts.Length > 1) ApplyCounters(b, parts[1]);
            int flags;
            if (parts.Length > 2 && parts[2].Length > 0 && BulletFlagsField != null
                && int.TryParse(parts[2], System.Globalization.NumberStyles.Integer, ci, out flags) && flags != 0)
            {
                try { BulletFlagsField.SetValue(b, System.Enum.ToObject(BulletFlagsField.FieldType, flags)); }
                catch (System.Exception) { }
            }
            float life;
            if (parts.Length > 3 && parts[3].Length > 0
                && float.TryParse(parts[3], System.Globalization.NumberStyles.Float, ci, out life))
            {
                b.SetLife(life);
            }
            float del;
            if (parts.Length > 4 && parts[4].Length > 0
                && float.TryParse(parts[4], System.Globalization.NumberStyles.Float, ci, out del))
            {
                b.SetTimeDelete(del);
            }
            Color tint;
            if (parts.Length > 5 && parts[5].Length > 0 && b._render != null && TryColor(parts[5], out tint))
            {
                b._render.color = tint;
            }
        }

        private static void ApplyCounters(bulletScript b, object cell)
        {
            string s = cell as string;
            if (string.IsNullOrEmpty(s)) return;
            foreach (string pair in s.Split(','))
            {
                int colon = pair.IndexOf(':');
                if (colon <= 0) continue;
                int slot; float v;
                if (!int.TryParse(pair.Substring(0, colon), System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out slot)) continue;
                if (!float.TryParse(pair.Substring(colon + 1), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out v)) continue;
                if (slot < 0 || slot > 9 || float.IsNaN(v) || float.IsInfinity(v)) continue;
                b.SetCounter(slot, v);
            }
        }

        private static float ReadFloatField(FieldInfo f, object target, float fallback)
        {
            if (f == null || target == null) return fallback;
            object v = f.GetValue(target);
            return v is float fv ? fv : fallback;
        }

        private static int ReadIntField(FieldInfo f, object target)
        {
            if (f == null || target == null) return 0;
            object v = f.GetValue(target);
            try { return v == null ? 0 : System.Convert.ToInt32(v); }
            catch (System.Exception) { return 0; }
        }

        private static float FiniteOrMinusOne(float v)
        {
            return float.IsNaN(v) || float.IsInfinity(v) ? -1f : Mathf.Round(v * 100f) / 100f;
        }

        private object[][] ReadBullets(CharacterBase player)
        {
            if (BulletManager.Instance == null || BulletsField == null || player == null || player.t == null)
            {
                return null;
            }
            var pool = BulletsField.GetValue(BulletManager.Instance) as bulletScript[];
            bool[] enabled = BulletManager.Instance.bullets_enable;
            if (pool == null || enabled == null)
            {
                return null;
            }
            int n = Mathf.Min(pool.Length, enabled.Length);
            TrackFollowerActivity(GemaPoolManager.Instance != null ? GemaPoolManager.Instance.CommonEffectsPooler : null);
            if (bulletSlotBorn == null || bulletSlotBorn.Length != n)
            {
                bulletSlotBorn = new float[n];
                bulletSlotSeq = new int[n];
                for (int i = 0; i < n; i++) { bulletSlotBorn[i] = -1f; bulletSlotSeq[i] = -1; }
            }
            float now = Time.time;
            for (int i = 0; i < n; i++)
            {
                bulletScript b = pool[i];
                if (b == null) continue;
                bool on = enabled[i] && b.gameObject.activeInHierarchy;
                if (on && bulletSlotBorn[i] != b.timeCreated)
                {
                    bulletSlotBorn[i] = b.timeCreated;
                    bulletSlotSeq[i] = -1;
                    if (b.sprite == Bullet.SpriteType.NONE || !BulletIsOurs(b, player))
                    {
                        continue;
                    }
                    int pool_ = -1, kind = -1; float effScale = 0f; string color = "";
                    lastMatchedPoolName = ""; lastMatchedObjectName = "";
                    FindAttachedEffect(b, out pool_, out kind, out effScale, out color);
                    string poolName = lastMatchedPoolName, fxObject = lastMatchedObjectName;
                    int seq = ++bulletSeq;
                    bulletSlotSeq[i] = seq;
                    Vector3 p = b.transform.position;
                    // Cells 13-18 are the state the game's own BulletBehave reads and the shooter
                    // wrote after ShootBullet returned -- without them a ghost's shot runs the same
                    // switch from the wrong start (the normal orb shot homes on counter 3 == 135,
                    // the Sable charged B's zig-zag phase is counters 5/6/7). Cheap when unset:
                    // the counter string is empty for the great majority of bullets.
                    var birthRow = new BulletBirth
                    {
                        Seq = seq, At = now, B = b,
                        Row = new object[]
                        {
                            (float)seq, (float)(int)b.type, (float)(int)b.sprite,
                            Mathf.Round(p.x * 10f) / 10f, Mathf.Round(p.y * 10f) / 10f,
                            Mathf.Round(b.angle * 10f) / 10f, Mathf.Round(b.speed * 100f) / 100f,
                            Mathf.Round(b.transform.localScale.x * 100f) / 100f,
                            (float)pool_, (float)kind, Mathf.Round(effScale * 10f) / 10f, color,
                            b.owner != null && b.owner.direction == Character.Direction.LEFT,
                            Mathf.Round(b.time * 1000f) / 1000f,             // 13 age, refreshed below
                            WithEnumNames(WithPoolName(EncodeBirthState(b), poolName), b), // 14 the rest, packed
                        },
                    };
                    bulletBirths.Add(birthRow);
                    BulletDiag($"SEND slot={i} {RowSummary(birthRow.Row)} typeName={b.type} spriteName={b.sprite} fxObject={fxObject} owner={OwnerTag(b)} rendererOn={(b._render != null && b._render.enabled)} spriteNow={(b._render != null && b._render.sprite != null ? b._render.sprite.name : "-")} rgba={(b._render != null ? Hex(b._render.color) : "-")}");
                }
                else if (!on && bulletSlotBorn[i] >= 0f)
                {
                    if (bulletSlotSeq[i] >= 0)
                    {
                        bulletDeathRing.Add(new KeyValuePair<int, float>(bulletSlotSeq[i], now));
                    }
                    bulletSlotBorn[i] = -1f;
                    bulletSlotSeq[i] = -1;
                }
            }
            // THE EFFECT IS ATTACHED AFTER ShootBullet, in the orb's own update, which may run
            // after ours on the birth frame -- so a birth seen with no follower is re-scanned on
            // the following frames while it is still in the ring, and the row is patched in place
            // (the receiver has not spawned it yet if the first sample was lost, and if it has,
            // the next sample's row carries the effect). Found 2026-09-10: some shots flew unseen.
            foreach (BulletBirth birth in bulletBirths)
            {
                // The age travels with the row, not the row's arrival: a receiver that first sees
                // this birth two samples late still starts the bullet where the real one is now.
                if (birth.B != null) birth.Row[13] = Mathf.Round(birth.B.time * 1000f) / 1000f;
                if (birth.B != null && (int)(float)birth.Row[9] < 0 && birth.B.gameObject.activeInHierarchy)
                {
                    int p2, k2; float es2; string col2;
                    lastMatchedPoolName = ""; lastMatchedObjectName = "";
                    FindAttachedEffect(birth.B, out p2, out k2, out es2, out col2);
                    if (k2 >= 0)
                    {
                        birth.Row[8] = (float)p2; birth.Row[9] = (float)k2;
                        birth.Row[10] = Mathf.Round(es2 * 10f) / 10f; birth.Row[11] = col2;
                        birth.Row[14] = WithPoolName(birth.Row[14] as string, lastMatchedPoolName);
                        BulletDiag($"SEND-PATCH {RowSummary(birth.Row)} typeName={birth.B.type} fxObject={lastMatchedObjectName} owner={OwnerTag(birth.B)}");
                    }
                }
            }
            bulletBirths.RemoveAll(x => now - x.At > BulletRingSeconds);
            if (bulletBirths.Count == 0)
            {
                return null;
            }
            var rows = new object[bulletBirths.Count][];
            for (int i = 0; i < rows.Length; i++) rows[i] = bulletBirths[i].Row;
            return rows;
        }

        private float[] ReadBulletDeaths()
        {
            float now = Time.time;
            bulletDeathRing.RemoveAll(x => now - x.Value > BulletRingSeconds);
            if (bulletDeathRing.Count == 0)
            {
                return null;
            }
            var arr = new float[bulletDeathRing.Count];
            for (int i = 0; i < arr.Length; i++) arr[i] = bulletDeathRing[i].Key;
            return arr;
        }

        // IDENTITY IS NOT ENOUGH FOR A POOLED FOLLOWER (2026-09-10, live: "the blue orb is sometimes
        // shooting red, the red orb is sometimes shooting blue"). BulletManager hands the SAME
        // bulletScript object out again the moment its slot frees, and a follower still playing
        // its end-fade for the previous bullet in that slot keeps its reference -- so its field
        // compares equal to the newborn, and the newborn is sent with the old family's effect.
        // The diagnostic showed one type arriving as three different kinds in one session.
        // The tell a stale one cannot fake is WHEN it went active: the game lights the follower in
        // the same call that shot the bullet, so a match is only real if the effect's activation
        // is no older than the bullet's own timeCreated. Activation is watched every frame over
        // the follower pools only (the same rising-edge watch ReadFlashes keeps for its two).
        private readonly Dictionary<int, float> followerActivatedAt = new Dictionary<int, float>();
        private List<int> followerPools;
        private int followerPoolsSeenCount = -1;
        private string lastMatchedPoolName = "", lastMatchedObjectName = "";

        // The packed state cell's seventh field: the follower pool's prefab name, or nothing.
        private static string WithPoolName(string packed, string poolName)
        {
            if (string.IsNullOrEmpty(poolName)) return packed;
            string[] parts = (packed ?? "").Split('|');
            var sb = new System.Text.StringBuilder();
            for (int i = 0; i < 6; i++) { if (i > 0) sb.Append('|'); sb.Append(i < parts.Length ? parts[i] : ""); }
            sb.Append('|').Append(poolName.Replace('|', '_'));
            return sb.ToString();
        }

        private static string PoolNameOf(object[] row)
        {
            string packed = row != null && row.Length > 14 ? row[14] as string : null;
            if (string.IsNullOrEmpty(packed)) return "";
            string[] parts = packed.Split('|');
            return parts.Length > 6 ? parts[6] : "";
        }

        // The sent pool index if its prefab carries follower kind `kind`, else the first pool
        // whose prefab does, else -1. Kind is OUR table (EffectKindTypes), stable across builds.
        private static int PoolCarryingKind(ObjectPooler op, int pool, int kind)
        {
            if (op == null || op.pooledObjectsList == null || kind < 0 || kind >= EffectKindTypes.Length) return -1;
            System.Func<int, bool> carries = i =>
            {
                if (i < 0 || i >= op.pooledObjectsList.Count) return false;
                List<GameObject> p = op.pooledObjectsList[i];
                return p != null && p.Count > 0 && p[0] != null && p[0].GetComponent(EffectKindTypes[kind]) != null;
            };
            if (carries(pool)) return pool;
            for (int i = 0; i < op.pooledObjectsList.Count; i++) if (carries(i)) return i;
            return -1;
        }

        // THE WIRE CARRIES NAMES, NOT ORDINALS (2026-09-10). BulletType and SpriteType are laid
        // out differently between TEVI builds: the same number the standalone install called
        // ORB_LOCK_NORMAL / SHOT_CYAN decoded on the Steam build as lily_groundbreak /
        // effect_ring1 -- the "white circles" the user saw were a different build's sprite table.
        // Cells 1-2 keep the ordinals for a peer on the previous adapter; fields 7-8 of the packed
        // cell carry the names, and a receiver that can parse them believes them instead.
        private static string WithEnumNames(string packed, bulletScript b)
        {
            string[] parts = (packed ?? "").Split('|');
            var sb = new System.Text.StringBuilder();
            for (int i = 0; i < 7; i++) { if (i > 0) sb.Append('|'); sb.Append(i < parts.Length ? parts[i] : ""); }
            sb.Append('|').Append(b.type.ToString()).Append('|').Append(b.sprite.ToString());
            return sb.ToString();
        }

        private static void ApplyEnumNames(bulletScript b, object[] row)
        {
            string packed = row != null && row.Length > 14 ? row[14] as string : null;
            if (string.IsNullOrEmpty(packed)) return;
            string[] parts = packed.Split('|');
            Bullet.BulletType bt; Bullet.SpriteType st;
            if (parts.Length > 7 && parts[7].Length > 0 && System.Enum.TryParse(parts[7], out bt)) b.type = bt;
            if (parts.Length > 8 && parts[8].Length > 0 && System.Enum.TryParse(parts[8], out st)) b.sprite = st;
        }

        private void TrackFollowerActivity(ObjectPooler op)
        {
            if (op == null || op.pooledObjectsList == null) return;
            if (followerPools == null || followerPoolsSeenCount != op.pooledObjectsList.Count)
            {
                followerPools = new List<int>();
                followerPoolsSeenCount = op.pooledObjectsList.Count;
                for (int i = 0; i < op.pooledObjectsList.Count; i++)
                {
                    List<GameObject> pool = op.pooledObjectsList[i];
                    if (pool == null || pool.Count == 0 || pool[0] == null) continue;
                    for (int k = 0; k < EffectKindTypes.Length; k++)
                    {
                        if (pool[0].GetComponent(EffectKindTypes[k]) != null) { followerPools.Add(i); break; }
                    }
                }
            }
            float now = Time.time;
            foreach (int i in followerPools)
            {
                if (i >= op.pooledObjectsList.Count) continue;
                List<GameObject> pool = op.pooledObjectsList[i];
                if (pool == null) continue;
                for (int j = 0; j < pool.Count; j++)
                {
                    GameObject go = pool[j];
                    if (go == null) continue;
                    int id = go.GetInstanceID();
                    if (go.activeInHierarchy)
                    {
                        if (!followerActivatedAt.ContainsKey(id)) followerActivatedAt[id] = now;
                    }
                    else
                    {
                        followerActivatedAt.Remove(id);
                    }
                }
            }
        }

        // Which pooled effect is following this newborn bullet: identity of its bullet field, AND
        // an activation no older than the bullet (see TrackFollowerActivity).
        private void FindAttachedEffect(bulletScript b, out int poolIndex, out int kind, out float effScale, out string color)
        {
            poolIndex = -1; kind = -1; effScale = 0f; color = ""; // only kind 0 carries one; "" reads as white
            ObjectPooler op = GemaPoolManager.Instance != null ? GemaPoolManager.Instance.CommonEffectsPooler : null;
            if (op == null || op.pooledObjectsList == null)
            {
                return;
            }
            for (int i = 0; i < op.pooledObjectsList.Count; i++)
            {
                List<GameObject> pool = op.pooledObjectsList[i];
                if (pool == null || pool.Count == 0) continue;
                for (int j = 0; j < pool.Count; j++)
                {
                    GameObject go = pool[j];
                    if (go == null || !go.activeInHierarchy) continue;
                    float activatedAt;
                    if (!followerActivatedAt.TryGetValue(go.GetInstanceID(), out activatedAt) || activatedAt < b.timeCreated - 0.001f) continue;
                    for (int k = 0; k < EffectKindTypes.Length; k++)
                    {
                        Component c = go.GetComponent(EffectKindTypes[k]);
                        if (c == null) continue;
                        if (EffectKindFields[k] == null)
                        {
                            EffectKindFields[k] = EffectKindTypes[k].GetField(EffectKindBulletField[k], BindingFlags.NonPublic | BindingFlags.Instance);
                        }
                        if (EffectKindFields[k] == null) continue;
                        if (!ReferenceEquals(EffectKindFields[k].GetValue(c), b)) continue;
                        poolIndex = i; kind = k; effScale = go.transform.localScale.x;
                        // The prefab's NAME is what the receiver looks the pool up by: ObjectPooler
                        // registers pools at runtime (AddObject), so an INDEX only agrees between
                        // two machines if both loaded the same things in the same order -- and
                        // swapping orbs is exactly the kind of event that registers one (user,
                        // 2026-09-10: wrong colours "when the orbitars swap place mid shooting").
                        lastMatchedPoolName = (op.itemsToPool != null && i < op.itemsToPool.Count && op.itemsToPool[i] != null
                            && op.itemsToPool[i].objectToPool != null) ? op.itemsToPool[i].objectToPool.name : "";
                        lastMatchedObjectName = go.name;
                        if (k == 0 && OrbShootNormalPs1Field != null && OrbShootNormalPs1Field.GetValue(c) is ParticleSystem ps1)
                        {
                            // Setup wrote ps1.startColor = c * 1.025; undo that to send what it was given.
                            color = Hex(ps1.startColor / 1.025f);
                        }
                        return;
                    }
                }
            }
        }

        private void ApplyGhostBullets(string playerId, RemoteGhostVisual visual, BridgeClient.RemoteState state, Vector3 worldOffset)
        {
            object[][] rows = state.Bullets;
            if (rows != null && rows.Length > 0)
            {
                int maxSeq = visual.LastBulletSeq;
                foreach (object[] row in rows)
                {
                    if (row == null || row.Length < 13) continue;
                    int seq = (int)CellF(row, 0);
                    if (seq > maxSeq) maxSeq = seq;
                }
                if (!visual.BulletSeqAdopted)
                {
                    // First sight adopts the counter: a ghost created mid-fight must not replay the
                    // peer's last 300ms of shots.
                    visual.BulletSeqAdopted = true;
                    visual.LastBulletSeq = maxSeq;
                }
                else
                {
                    foreach (object[] row in rows)
                    {
                        if (row == null || row.Length < 13) continue;
                        int seq = (int)CellF(row, 0);
                        GhostBullet existing;
                        if (visual.Bullets.TryGetValue(seq, out existing))
                        {
                            if (!existing.EffectAttached && (int)CellF(row, 9) >= 0 && existing.DiedAt == float.NegativeInfinity)
                            {
                                AttachBulletEffect(existing, row);
                                BulletDiag($"ATTACH-LATE {existing.Go?.name} {RowSummary(row)} lived={Time.time - existing.BornAt:F3}s");
                            }
                            continue;
                        }
                        if (seq <= visual.LastBulletSeq) continue;
                        SpawnGhostBullet(playerId, visual, seq, row, worldOffset);
                    }
                    visual.LastBulletSeq = maxSeq;
                }
            }
            if (state.BulletDeaths != null)
            {
                foreach (float f in state.BulletDeaths)
                {
                    if (float.IsNaN(f)) continue;
                    GhostBullet gb;
                    if (visual.Bullets.TryGetValue((int)f, out gb) && gb.DiedAt == float.NegativeInfinity)
                    {
                        KillGhostBullet(gb);
                    }
                }
            }
        }

        private void SpawnGhostBullet(string playerId, RemoteGhostVisual visual, int seq, object[] row, Vector3 worldOffset)
        {
            if (BulletManager.Instance == null || BulletPrefabField == null || cloneTemplate == null) return;
            var prefab = BulletPrefabField.GetValue(BulletManager.Instance) as bulletScript;
            if (prefab == null) return;
            float x = CellF(row, 3), y = CellF(row, 4), angle = CellF(row, 5), speed = CellF(row, 6), scale = CellF(row, 7);
            if (float.IsNaN(x) || float.IsNaN(y) || float.IsNaN(angle) || float.IsNaN(speed) || float.IsInfinity(x) || float.IsInfinity(y)) return;
            int type = (int)CellF(row, 1), sprite = (int)CellF(row, 2);

            GameObject go = Instantiate(prefab.gameObject);
            go.name = $"MeshGhostRemote_{playerId}_bullet{seq}";
            foreach (Collider2D col in go.GetComponentsInChildren<Collider2D>(true)) Destroy(col);
            foreach (Rigidbody2D rb in go.GetComponentsInChildren<Rigidbody2D>(true)) Destroy(rb);
            bulletScript b = go.GetComponent<bulletScript>();
            if (b == null) { Destroy(go); return; }
            // Dormant, but with the references its own helpers dereference (SetAllRef also sets t).
            b.SetAllRef(BulletManager.Instance, CommonResource.Instance, TeamManager.Instance, GameSystem.Instance, WorldManager.Instance);
            b.owner = cloneTemplate; // a follower asks owner.isPlayer(); this bullet is never in the pool
            b.EnableMe();
            b.type = (Bullet.BulletType)type;
            b.sprite = (Bullet.SpriteType)sprite;
            ApplyEnumNames(b, row); // a peer on another build: its NAMES win over its ordinals
            b.SetAngle(angle);
            b.speed = speed;
            // ShootBullet's own two lines for the sprite. Without them a clone off the prefab wore
            // whatever the prefab carried, so every DRAWN bullet (the lock-on shot, Sable's charged
            // shot) was wrong or blank -- the pooled-effect families hid it, since they draw nothing.
            // NONE and USE_PS both draw NOTHING through the bullet's own renderer -- NONE by the
            // game turning it off, USE_PS because its whole visual is the pooled follower effect
            // and `SetSprite` has no case for it. A clone carries the PREFAB's sprite, though, so
            // leaving the renderer on drew a plain white ball where the game draws nothing (user,
            // 2026-09-10: "shooting white circles sometimes instead of proper bullet/projectiles").
            // The renderer is only for the genuinely DRAWN families, and those are the ones
            // ShootBullet hands to SetSprite.
            bool drawnSprite = b.sprite != Bullet.SpriteType.NONE && b.sprite != Bullet.SpriteType.USE_PS;
            if (b._render != null) b._render.enabled = drawnSprite;
            if (drawnSprite && (int)b.sprite < 91 && BulletManagerSetSprite != null)
            {
                try { BulletManagerSetSprite.Invoke(BulletManager.Instance, new object[] { b, b.sprite }); }
                catch (System.Exception) { }
            }
            // The size, counters, flags and lifetimes the shooter gave it -- the state its own
            // BulletBehave reads. A peer on the previous build sends a 13-cell row and gets the
            // straight-line flight it always got, which is what the length guards are for.
            ApplyBirthState(b, row.Length > 14 ? row[14] : null, scale);
            b.time = 0f;
            b.SetPosition(worldOffset + new Vector3(x, y, 0f)); // cachepos too: BulletBehave reads it
            go.SetActive(true);

            var gb = new GhostBullet
            {
                Go = go, B = b, BornAt = Time.time, Speed = speed,
                Cos = Mathf.Cos(Mathf.PI / 180f * angle), Sin = Mathf.Sin(Mathf.PI / 180f * angle),
            };
            visual.Bullets[seq] = gb;
            // CATCH-UP. The row carries the bullet's own age; replay it at the game's step so the
            // ghost's shot starts where the peer's shot IS, not where it was born.
            float fdt = GameFixedStep();
            float age = row.Length > 13 ? CellF(row, 13) : 0f;
            if (!float.IsNaN(age) && age > 0f && fdt > 0f)
            {
                int steps = Mathf.Min(BulletCatchUpStepsMax, Mathf.RoundToInt(age / fdt));
                for (int s = 0; s < steps && !b.isDespawning(); s++) StepGhostBullet(gb, fdt);
            }
            AttachBulletEffect(gb, row);
            BulletDiag($"RECV {go.name} {RowSummary(row)} typeName={b.type} spriteName={b.sprite} effectAttached={gb.EffectAttached} fxObject={gb.EffectObjectName ?? "-"} poolName={PoolNameOf(row)} despawningAfterCatchUp={b.isDespawning()} renderer={(b._render != null && b._render.enabled)} spriteNow={(b._render != null && b._render.sprite != null ? b._render.sprite.name : "-")} stopAnim={b.stopAnim}");
        }

        // The game's own follower effect, the same pooled object with the same Setup.
        private void AttachBulletEffect(GhostBullet gb, object[] row)
        {
            int pool = (int)CellF(row, 8), kind = (int)CellF(row, 9);
            float effScale = CellF(row, 10), angle = CellF(row, 5);
            bool left = row[12] is bool lb && lb;
            bulletScript b = gb.B;
            GameObject go = gb.Go;
            if (b == null || go == null) return;
            if (pool >= 0 && kind >= 0 && kind < EffectKindTypes.Length && GemaPoolManager.Instance != null
                && GemaPoolManager.Instance.CommonEffectsPooler != null)
            {
                gb.EffectAttached = true;
                // By prefab NAME when the row carries one (an index is only as stable as the two
                // machines' load order -- see FindAttachedEffect); the index is the old peer's way.
                // By INDEX, checked: every orb effect prefab is literally named "Orb", so a name
                // cannot pick one (a lookup by name handed every family the first "Orb" pool, live
                // 2026-09-10). What CAN be checked is that the pool at that index carries the
                // follower component the sender matched -- across two different game builds the
                // indices shift, and a wrong index would otherwise light a random effect. If it
                // does not, the first pool that does carry it is the honest fallback: the right
                // family, possibly the wrong variant, never garbage.
                ObjectPooler op = GemaPoolManager.Instance.CommonEffectsPooler;
                int usePool = PoolCarryingKind(op, pool, kind);
                GameObject fx = usePool >= 0 ? op.GetPooledObject(usePool) : null;
                gb.EffectObjectName = fx != null ? $"{fx.name}#{usePool}{(usePool != pool ? "(sent " + pool + ")" : "")}" : "(none)";
                if (fx != null)
                {
                    fx.transform.position = go.transform.position;
                    fx.SetActive(true);
                    Character.Direction dir = left ? Character.Direction.LEFT : Character.Direction.RIGHT;
                    Color c; if (!TryColor(row[11], out c)) c = Color.white;
                    switch (kind)
                    {
                        case 0: fx.GetComponent<OrbShootNormal>()?.Setup(c, dir, b); break;
                        case 1: fx.GetComponent<OrbChargeSableTypeA>()?.Setup(dir, b); break;
                        case 2: fx.GetComponent<OrbChargeSableTypeB>()?.Setup(dir, b); break;
                        case 3: fx.GetComponent<OrbNormalCeliaTypeB>()?.Setup(dir, b); break;
                        case 4: fx.GetComponent<OrbNormalSableTypeB>()?.Setup(dir, b); break;
                        case 5: fx.GetComponent<OrbChargeCeliaTypeB>()?.Setup(angle, b); break;
                        case 6: fx.GetComponent<OrbChargeCeliaTypeC>()?.SpawnMe(b); break;
                        case 7: fx.GetComponent<FollowBullet>()?.SpawnMe(b); break;
                    }
                    if ((kind == 6 || kind == 7) && !float.IsNaN(effScale) && effScale > 0f)
                    {
                        fx.transform.localScale = new Vector3(effScale, effScale, effScale);
                    }
                }
            }
        }

        // MUZZLE FLASHES. NormalShot lights CommonEffects #7 (OrbShootFlash) at the orb and
        // ChargeShot #12 (OrbChargeFlash), each Setup(colour, facing); neither is tied to a bullet,
        // so the bullet mirror never saw them (user, 2026-09-10: "missing some vfx things when
        // shooting"). The sender watches those two pools for an object going ACTIVE that it did not
        // light itself -- the receiver lights the same pools for ghosts, and without that exclusion
        // two symmetric peers would echo each other's flashes (before-mirroring-state.md).
        private static readonly int[] FlashPools = { 7, 12 };
        private static readonly FieldInfo ShootFlashPs1Field = typeof(OrbShootFlash).GetField("ps1", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo ChargeFlashPsField = typeof(OrbChargeFlash).GetField("ps", BindingFlags.NonPublic | BindingFlags.Instance);
        private readonly Dictionary<int, bool> flashWasActive = new Dictionary<int, bool>();
        private readonly HashSet<int> flashesWeLit = new HashSet<int>();
        private readonly List<BulletBirth> flashRing = new List<BulletBirth>();
        private int flashSeq;

        private object[][] ReadFlashes(CharacterBase player)
        {
            ObjectPooler op = GemaPoolManager.Instance != null ? GemaPoolManager.Instance.CommonEffectsPooler : null;
            if (op == null || op.pooledObjectsList == null || player == null)
            {
                return null;
            }
            float now = Time.time;
            foreach (int poolIndex in FlashPools)
            {
                if (poolIndex >= op.pooledObjectsList.Count) continue;
                List<GameObject> pool = op.pooledObjectsList[poolIndex];
                if (pool == null) continue;
                for (int j = 0; j < pool.Count; j++)
                {
                    GameObject go = pool[j];
                    if (go == null) continue;
                    int id = go.GetInstanceID();
                    bool on = go.activeInHierarchy;
                    bool was;
                    flashWasActive.TryGetValue(id, out was);
                    flashWasActive[id] = on;
                    if (!on || was) continue;
                    if (flashesWeLit.Remove(id)) continue; // ours, for a ghost
                    Color c = Color.white;
                    if (poolIndex == 7 && ShootFlashPs1Field != null && ShootFlashPs1Field.GetValue(go.GetComponent<OrbShootFlash>()) is ParticleSystem p1) c = p1.startColor;
                    if (poolIndex == 12 && ChargeFlashPsField != null && ChargeFlashPsField.GetValue(go.GetComponent<OrbChargeFlash>()) is ParticleSystem[] pa && pa.Length > 0 && pa[0] != null) c = pa[0].startColor;
                    bool left = go.transform.localEulerAngles.y > 0f && go.transform.localEulerAngles.y < 180f; // Setup: LEFT -> +90, RIGHT -> -90 (=270)
                    Vector3 p = go.transform.position;
                    flashRing.Add(new BulletBirth
                    {
                        Seq = ++flashSeq, At = now,
                        Row = new object[] { (float)flashSeq, (float)poolIndex, Mathf.Round(p.x * 10f) / 10f, Mathf.Round(p.y * 10f) / 10f, left, Hex(c) },
                    });
                }
            }
            flashRing.RemoveAll(x => now - x.At > BulletRingSeconds);
            if (flashRing.Count == 0) return null;
            var rows = new object[flashRing.Count][];
            for (int i = 0; i < rows.Length; i++) rows[i] = flashRing[i].Row;
            return rows;
        }

        private void ApplyGhostFlashes(RemoteGhostVisual visual, BridgeClient.RemoteState state, Vector3 worldOffset)
        {
            object[][] rows = state.Flashes;
            if (rows == null || rows.Length == 0) return;
            int maxSeq = visual.LastFlashSeq;
            foreach (object[] row in rows)
            {
                if (row == null || row.Length < 6) continue;
                int seq = (int)CellF(row, 0);
                if (seq > maxSeq) maxSeq = seq;
            }
            if (!visual.FlashSeqAdopted)
            {
                visual.FlashSeqAdopted = true;
                visual.LastFlashSeq = maxSeq;
                return;
            }
            ObjectPooler op = GemaPoolManager.Instance != null ? GemaPoolManager.Instance.CommonEffectsPooler : null;
            foreach (object[] row in rows)
            {
                if (row == null || row.Length < 6) continue;
                int seq = (int)CellF(row, 0);
                if (seq <= visual.LastFlashSeq) continue;
                int pool = (int)CellF(row, 1);
                float x = CellF(row, 2), y = CellF(row, 3);
                if (op == null || float.IsNaN(x) || float.IsNaN(y)) continue;
                GameObject fx = op.GetPooledObject(pool);
                if (fx == null) continue;
                bool left = row[4] is bool lb && lb;
                Color c; if (!TryColor(row[5], out c)) c = Color.white;
                Character.Direction dir = left ? Character.Direction.LEFT : Character.Direction.RIGHT;
                fx.transform.position = worldOffset + new Vector3(x, y, 0f);
                flashesWeLit.Add(fx.GetInstanceID());
                fx.SetActive(true);
                if (pool == 7) fx.GetComponent<OrbShootFlash>()?.Setup(c, dir);
                else if (pool == 12) fx.GetComponent<OrbChargeFlash>()?.Setup(c, dir);
            }
            visual.LastFlashSeq = maxSeq;
        }

        // DIAG_GHOST_BULLETS -- one line per event, never per frame: what the sender decided a
        // shot IS (type, sprite, follower kind, pool, colour), what the receiver made of the row,
        // and what ended the ghost's bullet and after how long. Armed 2026-09-10 for three live
        // symptoms on one build ("white circles", "red orb shooting blue", "short distance") that
        // three readings of the code could not separate; the line that pairs a SEND with its RECV
        // is the one that does.
        private const bool DIAG_GHOST_BULLETS = false;
        private const int GhostBulletDiagBudget = 600;
        private int ghostBulletDiagLines;

        private void BulletDiag(string line)
        {
            if (!DIAG_GHOST_BULLETS || ghostBulletDiagLines >= GhostBulletDiagBudget) return;
            ghostBulletDiagLines++;
            Logger.LogInfo("MeshGhost/bul " + line);
        }

        private static string RowSummary(object[] row)
        {
            if (row == null) return "null";
            return $"seq={(int)CellF(row, 0)} type={(int)CellF(row, 1)} sprite={(int)CellF(row, 2)} kind={(int)CellF(row, 9)} pool={(int)CellF(row, 8)}"
                + $" col={(row.Length > 11 ? row[11] : null) ?? "-"} spd={CellF(row, 6)} ang={CellF(row, 5)} scale={CellF(row, 7)}"
                + $" age={(row.Length > 13 ? CellF(row, 13) : float.NaN)} state=\"{(row.Length > 14 ? row[14] : null) ?? ""}\"";
        }

        private void KillGhostBullet(GhostBullet gb, string cause = "peer death")
        {
            gb.DiedAt = Time.time;
            if (gb.B != null) gb.B.DespawnMe(); // followers see isDespawning() and play their hit flash
            BulletDiag($"KILL {gb.Go?.name} cause={cause} lived={Time.time - gb.BornAt:F3}s time={(gb.B != null ? gb.B.time : -1f):F3}");
        }

        // The game's own fixed step, the one bulletScript's arithmetic is written in. Bullets are
        // ticked from FixedUpdate for the same reason: BulletManager ticks the real ones from
        // GameSystem.FixedUpdate, and a bullet that counts physics steps (the Sable charged B counts
        // them to decide when to turn) is not the same bullet if it is stepped once per FRAME.
        private static float GameFixedStep()
        {
            float fdt = MainVar.instance != null ? MainVar.instance.fixedDeltaTime : 0f;
            return fdt > 0f ? fdt : Time.fixedDeltaTime;
        }

        private bool[] bulletPoolWasEnabled;
        private bool loggedBehaveFailure;

        // BulletBehave on a bullet that belongs to somebody else's game. Two guards, then the call:
        //   - `useChargeRemove` is zeroed for the duration, because several charged families erase
        //     bullets in an area while it is set, and those would be the WATCHER's bullets;
        //   - anything the call puts in the real pool is despawned again. Every such path is behind
        //     `hitlist.Count > 0` for a dormant bullet, so this should never fire -- which is the
        //     point of it firing silently rather than being assumed (before-mirroring-state.md).
        // The snapshot is taken per call, not per pass: catch-up steps run from the drain in
        // Update, and a stale snapshot would read the local player's own new shot as ours to kill.
        // OFF, 2026-09-10, live: a peer's shots DAMAGED the watcher ("when standalone shoot, steam
        // takes damage from some of them"). A ghost touching the watcher's health is the one thing
        // that may never happen, so the switch comes first and the diagnosis second. False = the
        // straight-line flight of b3b3ede9: cosmetically wrong for the families that move
        // themselves, and incapable of harm.
        private const bool GhostBulletsRunGameBehaviour = false;

        private void GuardedBulletBehave(GhostBullet gb)
        {
            if (!GhostBulletsRunGameBehaviour || BulletBehaveMethod == null || gb.BehaveFailed) return;
            BulletManager bm = BulletManager.Instance;
            byte charge = 0;
            short countBefore = 0;
            bool[] enabled = bm != null ? bm.bullets_enable : null;
            if (bm != null)
            {
                charge = bm.useChargeRemove;
                bm.useChargeRemove = 0;
                countBefore = bm.bulletcount;
                if (enabled != null)
                {
                    if (bulletPoolWasEnabled == null || bulletPoolWasEnabled.Length != enabled.Length)
                    {
                        bulletPoolWasEnabled = new bool[enabled.Length];
                    }
                    System.Array.Copy(enabled, bulletPoolWasEnabled, enabled.Length);
                }
            }
            try
            {
                BulletBehaveMethod.Invoke(gb.B, null);
            }
            catch (System.Exception e)
            {
                // Straight flight from here on for this one bullet, rather than a throw every step.
                gb.BehaveFailed = true;
                if (!loggedBehaveFailure)
                {
                    loggedBehaveFailure = true;
                    Logger.LogWarning("MeshGhost: a ghost bullet's own behaviour threw; it flies straight from here (said once): " + e);
                }
            }
            finally
            {
                if (bm != null)
                {
                    bm.useChargeRemove = charge;
                    if (bm.bulletcount != countBefore && enabled != null && bulletPoolWasEnabled != null)
                    {
                        for (int i = 0; i < enabled.Length && i < bulletPoolWasEnabled.Length; i++)
                        {
                            if (!enabled[i] || bulletPoolWasEnabled[i]) continue;
                            bulletPoolWasEnabled[i] = true; // never twice: DespawnBullet decrements the count
                            bm.DespawnBullet((short)i);
                        }
                    }
                }
            }
        }

        // One physics step of one ghost bullet, in bulletScript._Update's own order: age it, let its
        // type decide what it does, animate it, move it, then apply the game's despawn rules. What
        // is NOT here is everything _Update does to the world -- hit checks, tile destruction, wall
        // damage, the pool's despawn bookkeeping. That asymmetry is the whole design: the bullet
        // moves exactly as the game moves it and touches nothing.
        private void StepGhostBullet(GhostBullet gb, float fdt)
        {
            bulletScript b = gb.B;
            if (b == null || gb.Go == null || b.isDespawning()) return;
            b.time += fdt;

            float startSize = ReadFloatField(BulletStartSizeField, b, -1f);
            if (startSize >= 0f)
            {
                // _Update's spawn pop: 35% over, easing back down by 0.275s.
                if (b.time < 0.275f)
                {
                    float s = startSize * ((0.275f - b.time) / 0.275f * 0.35f + 1f);
                    gb.Go.transform.localScale = new Vector3(s, s, 1f);
                }
                else if (b.time < 0.28f)
                {
                    gb.Go.transform.localScale = new Vector3(startSize, startSize, 1f);
                }
            }

            // The real bullet fades out instead of behaving during a cutscene, and its death comes
            // to us on the wire like any other, so the ghost simply stops behaving for that window.
            bool eventOff = EventManager.Instance == null
                || EventManager.Instance.getMode() == EventMode.Mode.OFF
                || EventManager.Instance.ForceBulletPlayInEvent
                || b.sprite == Bullet.SpriteType.NONE;
            if (eventOff) GuardedBulletBehave(gb);
            if (b.isDespawning()) return;   // its own rule ended it -- the caller kills it next pass
            if (!b.stopAnim) b.BulletSprite();

            // _Update's motion, read back AFTER the behaviour ran: a type that moves itself writes
            // cachepos, and a homing one has already turned the angle these come from.
            int stay = ReadIntField(BulletStayField, b);
            if (stay == 1)
            {
                if (BulletStayMethod != null)
                {
                    try { BulletStayMethod.Invoke(b, null); }
                    catch (System.Exception) { }
                }
                b.SetPosition(ReadCachePos(b, gb.Go));
            }
            else
            {
                Vector3 cache = ReadCachePos(b, gb.Go);
                float cos = ReadFloatField(BulletCosField, b, gb.Cos);
                float sin = ReadFloatField(BulletSinField, b, gb.Sin);
                if (stay != 2) cache.x += cos * b.speed * (fdt * 60f);
                if (stay != 3) cache.y -= sin * b.speed * (fdt * 60f);
                if (b.owner != null && b.owner.t != null)
                {
                    if (stay == 2) cache.x = b.owner.t.localPosition.x;
                    if (stay == 3) cache.y = b.owner.t.localPosition.y;
                }
                b.SetPosition(cache);
            }

            // What ends it, in the game's own terms. `life` is the OFF-SCREEN rule -- _Update pairs
            // it with the renderer's visibility, and a pooled-effect bullet draws through a particle
            // system rather than that renderer, so the camera bound is the honest form of the same
            // question. Most orbitar families despawn themselves off-camera inside BulletBehave
            // anyway; this covers the ones that do not.
            float timeDelete = ReadFloatField(BulletTimeDeleteField, b, float.PositiveInfinity);
            float life = ReadFloatField(BulletLifeField, b, 1.5f);
            if (b.time > timeDelete)
            {
                gb.Cause = $"TimeDelete {timeDelete:F2}";
                b.DespawnMe();
            }
            else if (life > 0f && b.time > life && CameraScript.Instance != null
                && EventManager.Instance != null && MainVar.instance != null
                && Utility.isOutsideCameraPlayerProjectiles(gb.Go.transform.position, 30f))
            {
                gb.Cause = $"off-camera past life {life:F2}";
                b.DespawnMe();
            }
        }

        private static Vector3 ReadCachePos(bulletScript b, GameObject go)
        {
            if (BulletCachePosField != null)
            {
                object v = BulletCachePosField.GetValue(b);
                if (v is Vector3 cached) return cached;
            }
            return go.transform.position;
        }

        private void TickGhostBullets()
        {
            if (remoteVisuals.Count == 0) return;
            float fdt = GameFixedStep();
            float now = Time.time;
            List<int> done = null;
            foreach (KeyValuePair<string, RemoteGhostVisual> kv in remoteVisuals)
            {
                foreach (KeyValuePair<int, GhostBullet> bk in kv.Value.Bullets)
                {
                    GhostBullet gb = bk.Value;
                    if (gb.Go == null)
                    {
                        done = done ?? new List<int>(); done.Add(bk.Key); continue;
                    }
                    if (gb.DiedAt != float.NegativeInfinity)
                    {
                        if (now - gb.DiedAt > BulletLingerAfterDeath)
                        {
                            Destroy(gb.Go);
                            done = done ?? new List<int>(); done.Add(bk.Key);
                        }
                        continue;
                    }
                    StepGhostBullet(gb, fdt);
                    // Its own behaviour, its own despawn rules, or the safety net -- the peer's
                    // mirrored death arrives on the same path (KillGhostBullet) and guards itself.
                    if (gb.B != null && gb.B.isDespawning())
                    {
                        KillGhostBullet(gb, gb.Cause ?? "own behaviour");
                    }
                    else if (now - gb.BornAt > BulletSafetyLife)
                    {
                        KillGhostBullet(gb, "safety net");
                    }
                }
                if (done != null)
                {
                    foreach (int seq in done) kv.Value.Bullets.Remove(seq);
                    done.Clear();
                }
            }
        }

        private void DestroyGhostBullets(RemoteGhostVisual visual)
        {
            foreach (KeyValuePair<int, GhostBullet> kv in visual.Bullets)
            {
                if (kv.Value.B != null) kv.Value.B.DespawnMe();
                if (kv.Value.Go != null) Destroy(kv.Value.Go);
            }
            visual.Bullets.Clear();
        }

        // DIAG_BULLET_WATCH -- what the PLAYER'S shots are, before deciding how to mirror them
        // (2026-09-10, "missing all the projectiles from everything"). BulletManager keeps a pool
        // of 200 bulletScripts with a public enable flag per slot and an owner per bullet; this
        // walks that pool by reflection (the array is private) and reports, event-triggered:
        //   BIRTH  slot, type, sprite, speed, angle, size, position relative to the owner
        //   DEATH  lifetime, how far speed and angle drifted from birth (0 = flew straight)
        //   COUNT  once a second, live player-owned bullets and the peak
        // Owned means owner == the local player, or a non-player Celia/Sable (a core expansion).
        // The question it answers: can a watcher reproduce a shot from its birth alone?
        private const bool DIAG_BULLET_WATCH = false;
        private const int BulletWatchBudget = 600;
        private static readonly FieldInfo BulletsField = typeof(BulletManager).GetField("bullets", BindingFlags.NonPublic | BindingFlags.Instance);
        private float[] bwBirthTime;
        private float[] bwBirthSpeed, bwBirthAngle, bwMaxSpeedDrift, bwMaxAngleDrift;
        private bool[] bwOurs;
        private int bwLines, bwPeak;
        private float bwLastCount;

        private static string OwnerTag(bulletScript b)
        {
            CharacterBase o = b != null ? b.owner : null;
            if (o == null) return "none";
            return (o.isPlayer() ? "player:" : "summon:") + o.type;
        }

        private static bool BulletIsOurs(bulletScript b, CharacterBase player)
        {
            CharacterBase o = b.owner;
            if (o == null) return false;
            if (o == player) return true;
            return !o.isPlayer() && (o.type == Character.Type.Celia || o.type == Character.Type.Sable);
        }

        private void DiagBulletWatch(CharacterBase player)
        {
            if (BulletManager.Instance == null || BulletsField == null || player == null || player.t == null) return;
            var pool = BulletsField.GetValue(BulletManager.Instance) as bulletScript[];
            bool[] enabled = BulletManager.Instance.bullets_enable;
            if (pool == null || enabled == null) return;
            int n = Mathf.Min(pool.Length, enabled.Length);
            if (bwBirthTime == null || bwBirthTime.Length != n)
            {
                bwBirthTime = new float[n]; bwBirthSpeed = new float[n]; bwBirthAngle = new float[n];
                bwMaxSpeedDrift = new float[n]; bwMaxAngleDrift = new float[n]; bwOurs = new bool[n];
                for (int i = 0; i < n; i++) bwBirthTime[i] = -1f;
            }
            int live = 0;
            for (int i = 0; i < n; i++)
            {
                bulletScript b = pool[i];
                if (b == null) continue;
                bool on = enabled[i] && b.gameObject.activeInHierarchy;
                if (on && bwBirthTime[i] != b.timeCreated)
                {
                    // BIRTH (a re-used slot has a new timeCreated)
                    bwBirthTime[i] = b.timeCreated;
                    bwOurs[i] = BulletIsOurs(b, player);
                    bwBirthSpeed[i] = b.speed; bwBirthAngle[i] = b.angle;
                    bwMaxSpeedDrift[i] = 0f; bwMaxAngleDrift[i] = 0f;
                    if (bwOurs[i] && bwLines < BulletWatchBudget)
                    {
                        bwLines++;
                        Vector3 d = b.transform.position - player.t.position;
                        string spr = b._render != null && b._render.sprite != null ? b._render.sprite.name : "none";
                        Logger.LogInfo($"MeshGhost/probe bullet: BIRTH slot={i} type={b.type} sprite={b.sprite}/{spr} "
                            + $"speed={b.speed:0.##} angle={b.angle:0.#} scale={b.transform.localScale.x:0.##} "
                            + $"rel=({d.x:0},{d.y:0}) owner={(b.owner == player ? "player" : b.owner.type.ToString())} t={Time.time:0.000}");
                    }
                }
                else if (!on && bwBirthTime[i] >= 0f)
                {
                    // DEATH
                    if (bwOurs[i] && bwLines < BulletWatchBudget)
                    {
                        bwLines++;
                        Logger.LogInfo($"MeshGhost/probe bullet: DEATH slot={i} type={b.type} lived={Time.time - bwBirthTime[i]:0.00}s "
                            + $"speedDrift={bwMaxSpeedDrift[i]:0.##} angleDrift={bwMaxAngleDrift[i]:0.#} t={Time.time:0.000}");
                    }
                    bwBirthTime[i] = -1f;
                }
                if (on && bwOurs[i])
                {
                    live++;
                    bwMaxSpeedDrift[i] = Mathf.Max(bwMaxSpeedDrift[i], Mathf.Abs(b.speed - bwBirthSpeed[i]));
                    float da = Mathf.Abs(Mathf.DeltaAngle(b.angle, bwBirthAngle[i]));
                    bwMaxAngleDrift[i] = Mathf.Max(bwMaxAngleDrift[i], da);
                }
            }
            if (live > bwPeak) bwPeak = live;
            if (Time.time - bwLastCount >= 1f && (live > 0 || bwPeak > 0))
            {
                bwLastCount = Time.time;
                Logger.LogInfo($"MeshGhost/probe bullet: COUNT live={live} peak={bwPeak} lines={bwLines}/{BulletWatchBudget}");
            }
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
            int configuredPort = Config.Bind(
                "Network",
                "BridgePort",
                DefaultBridgePort,
                "First local core process bridge port to try. The adapter WALKS " +
                "BridgePortCount ports upward from here, so a second TEVI instance on the same " +
                "machine finds its own core without this being set at all -- since 2026-08-27. " +
                "Change it only to move the whole range. Left at the default, " +
                "\"local_game_bridge\" in the client's own config.json is used instead, so the " +
                "port has one owner rather than two that can disagree.").Value;

            // TWO SETTINGS COULD NAME THIS PORT, so the tie is broken explicitly rather than by
            // whichever happens to be read last.
            //
            // A BridgePort that differs from the default is a decision somebody made HERE, in this
            // game's own config, and it wins. Left alone, the client's config.json decides -- that
            // is the file every README tells a player to edit, it travels with meshghost.exe, and
            // before 2026-08-28 editing it moved the core while this adapter kept walking 7778,
            // after which the two could never meet. A silently broken connection is the worst
            // possible outcome for a setting, and it was the shipped one.
            int bridgePort = configuredPort != DefaultBridgePort
                ? configuredPort
                : CoreLauncher.ResolveBridgeBasePort(DefaultBridgePort);
            if (bridgePort != DefaultBridgePort)
            {
                Logger.LogInfo($"MeshGhost: bridge ports {bridgePort}-" +
                    $"{bridgePort + BridgeClient.BridgePortCount - 1}.");
            }
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
                launcher.TickDisconnected(bridge.CurrentPort, bridge.LastBusyPort);
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

            // Trails spawn on FRAMES, not on messages -- see TickTrails.
            TickTrails(cloneTemplate);

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

            int trailMode = ReadTrailMode(player);
            float trailRate, trailDecay; int trailRgba, trailOrder; bool trailFx;
            ReadTrailParams(player, out trailRate, out trailDecay, out trailRgba, out trailOrder, out trailFx);

            bridge.SendLocalState(new BridgeClient.RemoteState
            {
                AreaId = area.ToString(),
                Position = new[] { pos.x, pos.y },
                Orientation = player.direction.ToString(),
                Anim = clipName,
                RoomX = roomX,
                RoomY = roomY,
                TrailMode = trailMode,
                TrailRate = trailMode == 1 ? (float?)trailRate : null,
                TrailDecay = trailMode == 1 ? (float?)trailDecay : null,
                TrailRgba = trailMode == 1 ? (int?)trailRgba : null,
                TrailOrder = trailMode == 1 ? (int?)trailOrder : null,
                TrailHaveEffect = trailMode == 1 ? (bool?)trailFx : null,
                WeaponRgba = ReadWeaponStrobe(player),
                VfxSeq = localVfxSeq,
                VfxEffect = localVfxEffect,
                VfxFacingLeft = localVfxFacingLeft,
                TempPause = GameSystem.Instance != null ? GameSystem.Instance.GetTempPause() : 0f,
                AnimTime = ReadAnimTime(player),
                Orbs = ReadOrbs(player),
                Summons = ReadSummons(player),
                Shield = ReadShield(player),
                Bullets = ReadBullets(player),
                BulletDeaths = ReadBulletDeaths(),
                Flashes = ReadFlashes(player),
                Platforms = ReadPlatforms(player),
                OrbFxSeq = localOrbFxSeq,
                OrbFxOrb = localOrbFxOrb,
                OrbFxWhite = localOrbFxWhite,
            });

            // Watcher-side and purely cosmetic: wakes a warp device a peer ghost is standing in,
            // without going near the trigger that would save, heal and mark the local minimap.
            //
            // ALSO while a device still thinks a ghost is inside it. The only code that closes a
            // portal is the transition branch inside the scan, and with the guard on ghost count
            // alone the LAST ghost leaving -- a disconnect, a despawn, an area change -- dropped
            // the count to zero on the same frame, so the scan stopped running before that branch
            // could fire. The portal stayed on its "assembling" glow until somebody walked on and
            // off it again. User-reported 2026-08-29 and again 2026-09-02 (a ghost disconnecting on
            // a portal); the set drains on the next scan and the guard falls back to zero cost.
            if (remoteVisuals.Count > 0 || warpsWithGhostInside.Count > 0)
            {
                UpdateWarpDevicesForGhosts();
            }

            WatchLocalVfx(player);
            WatchLocalOrbFx(player);
            if (DIAG_BULLET_WATCH) DiagBulletWatch(player);
            KeepShieldPostprocess(player);

            // TEMPORARY, with DIAG_HITSTOP_PHASE: ALL FIVE sprite layers, once per hitstop, with
            // full RGBA. The earlier layer probe edge-triggered on RGB only, so a layer that
            // varies by ALPHA alone was structurally invisible to it -- which is the shape the
            // held pose's white-vs-blue difference must have, since the effect layer's colour
            // follows correctly everywhere else.
            if (DIAG_HITSTOP_PHASE && GameSystem.Instance != null
                && player.spranim_prefer != null && player.spranim_prefer.pixel != null)
            {
                bool paused = GameSystem.Instance.GetTempPause() > 0f;
                if (paused && !loggedThisFreeze)
                {
                    loggedThisFreeze = true;
                    var px2 = player.spranim_prefer.pixel;
                    var sb2 = new System.Text.StringBuilder("MeshGhost/probe freeze-layers:");
                    AppendLayer(sb2, "base", px2.basesprite);
                    AppendLayer(sb2, "outline", px2.outlinesprite);
                    AppendLayer(sb2, "effect", px2.effectsprite);
                    AppendLayer(sb2, "flash", px2.flashsprite);
                    AppendLayer(sb2, "support", px2.supportsprite);
                    Logger.LogInfo(sb2.ToString());
                }
                else if (!paused)
                {
                    loggedThisFreeze = false;
                }
            }

            // TEMPORARY, with DIAG_HITSTOP_PHASE: which sprite-layer COLOR carries the weapon's
            // white/blue variant. Edge-triggered on the RGB part only (alpha fades every frame),
            // so a combo logs a handful of lines, not a stream.
            if (DIAG_HITSTOP_PHASE && player.spranim_prefer != null && player.spranim_prefer.pixel != null)
            {
                var px = player.spranim_prefer.pixel;
                if (px.effectsprite != null)
                {
                    Color ec = px.effectsprite.color;
                    var rgb = new Vector3(ec.r, ec.g, ec.b);
                    if ((rgb - lastEffectRgb).sqrMagnitude > 0.0001f)
                    {
                        lastEffectRgb = rgb;
                        Logger.LogInfo($"MeshGhost/probe layer: effectsprite rgb=({ec.r:0.00},{ec.g:0.00},{ec.b:0.00}) a={ec.a:0.00} frame={Time.frameCount} clip={player.spranim_prefer.GetAnimationTrueName()}");
                    }
                }
                if (px.flashsprite != null)
                {
                    Color fc = px.flashsprite.color;
                    var rgbF = new Vector3(fc.r, fc.g, fc.b);
                    if ((rgbF - lastFlashRgb).sqrMagnitude > 0.0001f)
                    {
                        lastFlashRgb = rgbF;
                        Logger.LogInfo($"MeshGhost/probe layer: flashsprite rgb=({fc.r:0.00},{fc.g:0.00},{fc.b:0.00}) a={fc.a:0.00}");
                    }
                }
            }

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
