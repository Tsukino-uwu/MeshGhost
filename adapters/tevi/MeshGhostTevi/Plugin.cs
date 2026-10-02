using System.Collections.Generic;
using System.Reflection;
using BepInEx;
using FXV;
using UnityEngine;

namespace MeshGhostTevi
{
    [BepInPlugin(PluginGuid, PluginName, PluginVersion)]
    public class Plugin : BaseUnityPlugin
    {
        public const string PluginGuid = "dev.meshghost.tevi";
        public const string PluginName = "MeshGhost";
        // Also the bridge Hello's game_version: this plugin's revision, not TEVI's build. A room refuses a member whose
        // value differs, so a bump splits older adapters from newer ones.
        public const string PluginVersion = "0.2.0";

        // Logs each remote's position and active state every 2s, for as long as it is on.
        private const bool DIAG_REDRAW_TRACE = false;

        // Logs how old each visible map marker's data is, once a second and only while the map is open.
        private const bool DIAG_MARKER_STALENESS = false;
        private const float MarkerStalenessLogInterval = 1f;
        private float lastMarkerStalenessLogTime;

        // Logs what the adapter sees at each play-session edge (player, EventManager, map open), one line per edge.
        private const bool DIAG_MENU_GATE = false;

        // Logs every object appearing or disappearing under the player and each ghost, by instance id (pooling defeats
        // counts), unfiltered by name. Its coverage line reports the scan's cost: a quiet log is not "nothing".
        private const bool DIAG_SPAWN_DIFF = false;
        // 20Hz: a one-frame effect is unlikely to fall between two samples.
        private const float SpawnDiffSampleInterval = 0.05f;
        // World units: a character and its effects, not most of the room.
        private const float SpawnDiffRadius = 400f;
        // One budget per question: a shared one is spent by whatever happens most, never the rare thing hunted.
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

        // State logging: a discrete change (direction, anim, area) logs at once, while position drift logs at a capped
        // cadence, since one frame's movement is about the size of the epsilon.
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

        // The base of the port walk: BridgeClient.BridgePortCount ports up from here, so two local instances each find
        // their own core with nothing configured.
        private const int DefaultBridgePort = 7778;

        // Sent in the bridge Hello so the core joins the right game; matches the games/tevi/ folder in the release.
        private const string GameId = "tevi";

        // A clone of the local player's own visual object (spranim_prefer.pixel.gameObject). PixelCharacter has no
        // Update/Awake/Start, so it clones standalone without CharacterBase's gameplay logic.
        private sealed class RemoteGhostVisual
        {
            public GameObject Go;
            public PixelCharacter Pc;
            public string LastAnim;

            // Highest one-shot VFX counter played. 0 until the first message adopts the peer's counter, so effects
            // fired before this ghost appeared do not replay.
            public int LastVfxSeq;

            public float LastAnimTime;

            // Playback speed correcting this ghost's clip phase, 1 when it is in step.
            public float PhaseCatchup = 1f;

            // The local wall test for this peer's bullets only means something when it shares the local player's room.
            public bool SameRoom;
            // The peer's strobe colour and when it was last seen, so the strobe's white frames do not read as a stop.
            public int StrobeRgb = 0xFFFFFF;
            public float StrobeSeenAt = float.NegativeInfinity;

            // Hitstop by phase, not by arrival: freezing when the message arrives lags the peer's freeze under jitter.
            // PendingFreezePhase is where the peer froze (-1 none armed, -2 at once, phase unknown).
            public float PendingFreezePhase = -1f;
            public float FreezeArmedAt;
            public bool Frozen;


            // Per ghost, so two peers trailing at once do not share a cadence.
            public float TrailTimer;
            // The trail the peer is running now, latched from the last message; TickTrails spawns it every frame.
            public int TrailMode;
            public float TrailRate = TrailSpawnRate;
            public float TrailDecay = TrailDecaySpeed;
            public Color TrailColor = new Color32(0, 223, 255, 128);
            public int TrailOrder = TrailSortingOrder;
            public bool TrailHaveEffect;

            // The source player's offset from t.position to spranim_prefer.pixel's position, read at clone time: the
            // visual sits at its own local offset, which a standalone Instantiate loses.
            public Vector3 AnchorOffset;

            // Throttles DIAG_REDRAW_TRACE.
            public float LastDiagLogTime = float.NegativeInfinity;

            // Names this peer sent that no local controller has, so each is logged once; created lazily, and capped.
            public HashSet<string> RejectedAnims;

            // The peer's two orbitars, cloned lazily from the game's orb prefab the first time one is visible.
            public GhostOrb[] Orbs = new GhostOrb[2];

            // The peer's core expansions (summoned Celia/Sable), keyed by character type, each driven like the ghost.
            public Dictionary<string, SummonGhost> Summons = new Dictionary<string, SummonGhost>();

            // Highest orb-to-human flash counter already played for this peer.
            public int LastOrbFxSeq;

            // The peer's live projectiles, by birth seq.
            public Dictionary<int, GhostBullet> Bullets = new Dictionary<int, GhostBullet>();
            public int LastBulletSeq;
            public bool BulletSeqAdopted;
            public int LastFlashSeq;
            public bool FlashSeqAdopted;

            // The peer's boost shield and platforms.
            public GhostShield Shield;
            public GhostPlatform[] Platforms = new GhostPlatform[2];
        }

        // A dormant bullet: the game's prefab outside BulletManager's pool, so its script never hits, tests walls or
        // spends anything. We fly it; the game's pooled effect follows it.
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
            public bool PopDone;            // the wall-hit pop reached zero; nothing steps it again
            public bool WallTestOk;         // the shooter is in our room, so our geometry is theirs
            public GameObject Fx;           // the pooled follower, for clearing its trail on a snap
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
            // A clone of the game's orb-to-humanoid trail, flown from the ghost orb to this summon and back. Its mover
            // never stops itself, so TrailOffAt is when we park it.
            public GemaOrbToHumanoidTrail Trail;
            public float TrailOffAt = float.NegativeInfinity;
            public bool WasPresent;
        }

        // EventManager's private trail array; its first trail is the template a ghost's trail is cloned from.
        private static readonly FieldInfo O2HTrailsField = typeof(EventManager).GetField("O2Htrails", BindingFlags.NonPublic | BindingFlags.Instance);

        // The orb prefab's renderers with OrbBall removed, so nothing on it can shoot, aim, register a light or read
        // the save; only the peer's reported values drive it.
        private sealed class GhostOrb
        {
            public GameObject Go;
            public SpriteRenderer Render;
            public SpriteRenderer Glow;
            public SpriteRenderer Crystal;
            public SpriteRenderer Charge;
            public Transform ChargeTransform;
            // The prefab's GemaOrbTrail pool, held here because a trail detaches itself from the orb on first use.
            public GemaOrbTrail[] Trails;
        }

        private readonly Dictionary<string, RemoteGhostVisual> remoteVisuals = new Dictionary<string, RemoteGhostVisual>();

        // A peer's marker on the map screen (FullMap), shown while it is open, on a room the player has discovered.
        private sealed class RemoteMapMarker
        {
            public GameObject Go;

            // When the state this marker draws arrived, not when it was last redrawn (every frame). Read only by
            // DIAG_MARKER_STALENESS.
            public float LastUpdateTime;
        }

        private readonly Dictionary<string, RemoteMapMarker> remoteMapMarkers = new Dictionary<string, RemoteMapMarker>();

        // The last state each peer sent and when, recorded before UpsertRemoteGhost's early returns, so the marker
        // refreshes each frame even for a peer that stopped sending or whose ghost cannot be built yet.
        private sealed class RemoteMarkerState
        {
            public BridgeClient.RemoteState State;
            public float ArrivedAt;
        }

        private readonly Dictionary<string, RemoteMarkerState> remoteMarkerStates = new Dictionary<string, RemoteMarkerState>();

        // How long a marker may claim a position after its last state. The core re-sends every remote it tracks on
        // every adapter frame, even a still one, so silence means states stopped arriving.
        private const float MarkerStaleSeconds = 1f;

        // Private on FullMap: playerPos is the local player's marker, maxroom the per-area stride into roomtilelist.
        private static readonly FieldInfo FullMapPlayerPosField =
            typeof(FullMap).GetField("playerPos", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo FullMapMaxRoomField =
            typeof(FullMap).GetField("maxroom", BindingFlags.NonPublic | BindingFlags.Instance);

        // Cyan, so a peer's marker is told apart from the local player's own.
        private static readonly Color RemoteMapMarkerColor = new Color(0f, 1f, 1f, 1f);

        // Set each Update before DrainInto and RefreshRemoteMapMarkers, so the marker gate need not parse AreaId.
        private byte currentLocalArea = 255;

        // The FullMapTile for (area, x, y), found the way FullMap.MoveMapToCurrentRoom finds the player's own room.
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

        // Not a game constant: a generous bound on a peer's room_x/room_y before it reaches GetRoomWalkedBool, whose
        // internals are unknown.
        private const int MaxRoomCoordinate = 100000;

        // "map_markers" in config.json, polled once a second by the file's timestamp; on by default.
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

        // Every peer's marker, each frame, from its last state; right after DrainInto, so a new state draws at once.
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
                    // Hidden, not destroyed: the peer may be mid-hitch; the core's despawn destroys it.
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
            // A range test, never Mathf.Abs: Abs(int.MinValue) throws, and this runs outside DrainInto's try/catch.
            bool roomInRange = state.RoomX.HasValue && state.RoomY.HasValue
                && state.RoomX.Value >= -MaxRoomCoordinate && state.RoomX.Value <= MaxRoomCoordinate
                && state.RoomY.Value >= -MaxRoomCoordinate && state.RoomY.Value <= MaxRoomCoordinate;
            bool wantVisible = map != null && map.isFullMap
                && roomInRange
                && state.AreaId == currentLocalArea.ToString()
                // Never reveal a room the local player has not discovered; FullMapTile.SetVisible asks the same.
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
                // Same parent as the original, so it scales with the map's zoom like the game's own icons.
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

        // Probe: each visible marker's age while the map is open, once a second. A climbing age is a marker left stale.
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
                // Destroyed, not hidden: each respawn of this peer builds a fresh marker.
                if (marker.Go != null)
                {
                    Destroy(marker.Go);
                }
                remoteMapMarkers.Remove(playerId);
            }
            // Dropped too, or RefreshRemoteMapMarkers would rebuild a marker for a peer the core has despawned.
            remoteMarkerStates.Remove(playerId);
        }

        // Set each Update from EventManager.Instance.mainCharacter before DrainInto, so a new remote has a template.
        private CharacterBase cloneTemplate;

        private GameObject CreateRealGhostVisual(CharacterBase templatePlayer, string name, out PixelCharacter pc, out Vector3 anchorOffset, out string inheritedSpriteState)
        {
            // Read before a detached copy loses the parent that produced the offset.
            anchorOffset = templatePlayer.spranim_prefer.pixel.transform.position - templatePlayer.t.position;

            // For the creation log: the render state Instantiate inherits, read before the reset below.
            SpriteRenderer templateBase = templatePlayer.spranim_prefer.pixel.basesprite;
            inheritedSpriteState = templateBase != null
                ? $"enabled={templateBase.enabled} color={templateBase.color}"
                : "basesprite=null";

            GameObject clone = Instantiate(templatePlayer.spranim_prefer.pixel.gameObject);
            clone.name = name;

            // Strip anything with a gameplay side effect; none is known here, but a stray collider would fail silently.
            foreach (var collider in clone.GetComponentsInChildren<Collider2D>(true))
            {
                Destroy(collider);
            }
            foreach (var rb in clone.GetComponentsInChildren<Rigidbody2D>(true))
            {
                Destroy(rb);
            }

            // Instantiate copies the source's transient render state (a renderer disabled mid fade-in after a zone
            // load), and nothing re-enables it on a clone. Only enabled is reset: the outline is not meant to be white.
            foreach (var sr in clone.GetComponentsInChildren<SpriteRenderer>(true))
            {
                sr.enabled = true;
            }

            pc = clone.GetComponent<PixelCharacter>();
            return clone;
        }

        // In front of the hash so a long name costs nothing to refuse; a real clip name is far shorter.
        private const int MaxAnimNameLength = 96;

        // Each rejected name is logged once, for the first few only, so peer input cannot drive a per-frame log line.
        private const int MaxRejectedAnimNamesPerPeer = 4;

        // Bounds visual.Summons, keyed on a peer string with a sprite rig per key; ReadSummons sends two.
        private const int MaxSummonTypesPerGhost = 4;

        // A peer's clip name is checked against the ghost's own controller, never a list written here. HasState is the
        // lookup Play does, asked on every layer because Play searches them all.
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

        // Empty: out of play there is nothing to render onto, and the next state rebuilds everything. They let
        // DrainInto run out of play for the control plane without reaching the remote callbacks.
        private void DiscardRemoteWhileOutOfPlay(string playerId, BridgeClient.RemoteState state)
        {
        }

        private void DiscardDespawnWhileOutOfPlay(string playerId)
        {
        }

        private void UpsertRemoteGhost(string playerId, BridgeClient.RemoteState state)
        {
            // Above every early return: a peer with no position, or no local player to clone, still belongs on the map.
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
                Vector3 initialGhostPos = new Vector3(state.Position[0], state.Position[1], 0f) + anchorOffset;
                Logger.LogInfo($"MeshGhost: real remote ghost visual created for {playerId} (step 6.4/6.5+). "
                    + $"anchorOffset={anchorOffset} templatePos={cloneTemplate.t.position} "
                    + $"templateScene={cloneTemplate.spranim_prefer.pixel.gameObject.scene.name} cloneScene={go.scene.name} "
                    + $"remoteStatePos=({state.Position[0]:F2},{state.Position[1]:F2}) computedGhostPos={initialGhostPos} "
                    + $"inheritedSpriteState=[{inheritedSpriteState}]");
            }

            visual.Go.SetActive(true);
            // A loopback echo (id ending "-ghost") would sit on the player, so it is drawn beside them; render only.
            float loopbackOffsetX = playerId.EndsWith("-ghost", System.StringComparison.Ordinal) ? 160f : 0f;
            visual.Go.transform.position = new Vector3(state.Position[0] + loopbackOffsetX, state.Position[1], 0f)
                + visual.AnchorOffset;

            // Each sub-feature is walled off so its exception cannot abort the pose, facing, trail and hitstop below.
            // The orbitars ride the peer's root position, so the sprite clone's anchor offset is not added for them.
            Vector3 worldNudge = new Vector3(loopbackOffsetX, 0f, 0f);
            try { ApplyGhostOrbs(playerId, visual, state.Orbs, new Vector3(state.Position[0] + loopbackOffsetX, state.Position[1], 0f)); }
            catch (System.Exception e) { LogSubfeatureFailure("orbitars", e); }
            // World-fixed things (summon, shield, platforms) are absolute positions and get only the loopback nudge.
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

            if (DIAG_REDRAW_TRACE && Time.time - visual.LastDiagLogTime >= 2f)
            {
                visual.LastDiagLogTime = Time.time;
                Logger.LogInfo($"MeshGhost: remote {playerId} redraw: pos={visual.Go.transform.position} "
                    + $"activeInHierarchy={visual.Go.activeInHierarchy} scene={visual.Go.scene.name} "
                    + $"localArea={currentLocalArea} remoteAreaId={state.AreaId}");
            }

            // All five layers flip together: the game's SpriteAnimation, which a clone lacks, keeps them in step.
            if (visual.Pc != null)
            {
                bool flip = state.Orientation == "RIGHT";
                if (visual.Pc.basesprite != null) visual.Pc.basesprite.flipX = flip;
                if (visual.Pc.outlinesprite != null) visual.Pc.outlinesprite.flipX = flip;
                if (visual.Pc.effectsprite != null) visual.Pc.effectsprite.flipX = flip;
                if (visual.Pc.flashsprite != null) visual.Pc.flashsprite.flipX = flip;
                if (visual.Pc.supportsprite != null) visual.Pc.supportsprite.flipX = flip;
            }

            // The clip name is peer-controlled: two unknown names alternating would defeat the LastAnim dedupe and warn
            // every frame on this machine.
            bool animPlayable = IsPlayableAnimName(visual, state.Anim);

            // Play only on a change: every frame would restart the clip from 0.
            if (animPlayable && state.Anim != visual.LastAnim)
            {
                // At the peer's reported phase, not 0: the delivered state is already that far in.
                visual.Pc.anim.Play(state.Anim, 0, state.AnimTime ?? 0f);
                visual.LastAnim = state.Anim;
                visual.LastAnimTime = state.AnimTime ?? 0f;
            }
            else if (animPlayable && state.AnimTime.HasValue)
            {
                // Phase correction only past a tolerance the eye can see: re-seeking a close Animator stutters. It also
                // replays a repeated clip, whose name never changes but whose phase jumps back.
                float peerT = state.AnimTime.Value;
                float ghostT = visual.Pc.anim.GetCurrentAnimatorStateInfo(0).normalizedTime;
                ghostT -= Mathf.Floor(ghostT);
                // Signed and wrapped the short way: near the end and near the start are adjacent, and the sign says
                // whether the ghost is behind or ahead.
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
                    // The peer restarted the clip (a repeated attack keeps its name), so seeking matches its own snap.
                    visual.Pc.anim.Play(state.Anim, 0, peerT);
                    visual.PhaseCatchup = 1f;
                }
                else
                {
                    // Small drift is repaid as a speed nudge, never a seek: jitter crosses the tolerance constantly and
                    // each seek is a visible jump. Clamped so it never reads as a different speed of the move.
                    visual.PhaseCatchup = Mathf.Clamp(1f + drift * PhaseCatchupGain,
                        1f - PhaseCatchupRange, 1f + PhaseCatchupRange);
                }
                visual.LastAnimTime = peerT;
            }

            // Every frame, not on change: SetTrail arms a countdown, and skipping a frame lets it lapse mid-slide.
            LatchTrail(visual, state);

            // The weapon strobe, reproduced locally at the game's cadence; with none reported the layer rests white,
            // which also clears a strobe frame the clone inherited.
            if (visual.Pc != null && visual.Pc.effectsprite != null)
            {
                int packed = state.WeaponRgba ?? 0;
                // Only the colour travels. The clone's own animation drives this layer's alpha, and with no
                // SpriteAnimation to clear the layer, writing alpha would light a stale attack frame for good.
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
                        visual.StrobeRgb = rgb;
                        visual.StrobeSeenAt = Time.time;
                    }
                    if (visual.Frozen)
                    {
                        // Held pose: the paused peer's colour, since the game's strobe holds its colour in hitstop.
                        visual.Pc.effectsprite.color = new Color(
                            ((rgb >> 16) & 255) / 255f, ((rgb >> 8) & 255) / 255f, (rgb & 255) / 255f, a);
                    }
                    else
                    {
                        // Locally, 2 coloured frames in 5: sampled through the state stream it would alias.
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

            // Hitstop on the ghost's animator only: pausing our own game would let a peer's attack stutter local play.
            // Written every frame, so a peer that vanishes mid-pause cannot leave a ghost frozen.
            if (visual.Pc != null && visual.Pc.anim != null)
            {
                if ((state.TempPause ?? 0f) > 0f)
                {
                    if (visual.PendingFreezePhase == -1f)
                    {
                        // Seek to the held pose and stop at once: the peer's own animation snapped, and waiting for the
                        // ghost's clip to arrive shows frames the peer never did.
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

            // One-shot pooled VFX, played on a rise; a first sighting adopts the peer's counter and plays nothing.
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
                // On arrival, never phase-gated: the impulse and the pause share one timeline, so arrival keeps the
                // game's star-then-freeze order.
                PlayGhostVfx(visual, state.VfxEffect ?? -1, state.VfxFacingLeft ?? false);
            }
        }

        // The session this frame's ghosts were built under; a change means they belong to a connection that is gone.
        private int lastBridgeSessionEpoch;

        // The last session swept, only ever one that reached ready.
        private int lastSweptSessionEpoch;

        // Destroys ghost objects no live instance tracks (left by a hot reload or a plugin that died), found by name:
        // everything ours is MeshGhostRemote_<id> or MeshGhostMapMarker_<id>. It enumerates the scene, so it runs only
        // at load and once per session that reaches ready.
        private void SweepOrphanGhosts(string reason)
        {
            int destroyed = 0;
            // Includes inactive objects: a map marker is inactive whenever the map is closed.
            foreach (GameObject go in Resources.FindObjectsOfTypeAll<GameObject>())
            {
                // FindObjectsOfTypeAll also returns prefabs, which have no scene; ours are all scene objects.
                if (go != null && !go.scene.IsValid())
                {
                    continue;
                }
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
                    // An orbitar is <ghost>_orb<i>, and its detached afterimage <ghost>_orb<i>_trail<k>.
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

        // Every peer ghost at once, for leaving play rather than for one peer leaving.
        private void DespawnAllRemoteGhosts(string reason = "leaving play")
        {
            // Before the early return: a peer can have a marker state and no ghost.
            remoteMarkerStates.Clear();
            // Pooled effects we lit go back off, also before the early return: one can outlive its ghost.
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
            // Destroyed, not hidden: a returning peer gets a fresh clone from UpsertRemoteGhost.
            if (remoteVisuals.TryGetValue(playerId, out RemoteGhostVisual visual))
            {
                // So a real despawn can be told apart from a ghost going invisible without one.
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

        // The local player's afterimage-trail mode (0 none, 1 blue, 2 dodge yellow), from the values SpriteAnimation
        // itself reads each frame: mirroring the game's decision covers every move that trails. Opaque to the core.
        private static int ReadTrailMode(CharacterBase player)
        {
            if (player == null)
            {
                return 0;
            }
            // The game's order: speed bonus, then dodge, so dodge wins when both hold.
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
            // The timed trail any code may set through SetTrail (hover does) wins last, as in the game.
            if (player.spranim_prefer != null && player.spranim_prefer.GetTrail() > 0f)
            {
                mode = 1;
            }
            return mode;
        }

        private const float AnimPhaseTolerance = 0.06f;

        // Past this drift the peer restarted the clip, so a seek is right; below it nothing is seeked.
        private const float AnimReseekThreshold = 0.25f;

        // How hard a phase error pulls on playback speed, and the cap, so a correction never reads as another speed.
        private const float PhaseCatchupGain = 2f;
        private const float PhaseCatchupRange = 0.25f;

        private const float FreezePhaseTimeout = 0.25f;

        // Logs each hitstop transition, effect impulse sent and received, and sprite-layer colour change.
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

        // The local player's phase in its clip, 0..1, or null in a looping clip outside hitstop: an idle's phase
        // advances forever and would defeat the core's change suppression. Two still idles may drift until one acts.
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
            // Wrapped: a ghost needs the phase, not how many times the peer has looped.
            float t = info.normalizedTime;
            return t - Mathf.Floor(t);
        }

        // Private on SpriteAnimation, so read by reflection, with the defaults above if a build renames them.
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

        // Latch what the peer's trail is this frame. Spawning happens in TickTrails.
        private static void LatchTrail(RemoteGhostVisual visual, BridgeClient.RemoteState state)
        {
            int mode = state.TrailMode ?? 0;
            if (mode <= 0)
            {
                visual.TrailTimer = 0f;
                visual.TrailMode = 0;
                return;
            }
            visual.TrailMode = mode;
            if (mode == 2)
            {
                // The game's dodge branch: its own yellow, a faster decay, never the effect layer.
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
            // Clamped to the sorting-order range Unity honours: past it, a peer's trail would draw over the HUD.
            visual.TrailOrder = state.TrailOrder.HasValue ? Mathf.Clamp(state.TrailOrder.Value, -32767, 32767) : TrailSortingOrder;
            visual.TrailHaveEffect = state.TrailHaveEffect ?? false;
        }

        // Spawns each ghost's afterimages itself: SetTrail lives on SpriteAnimation, which the clone (the pixel child)
        // lacks. Only the cadence is ours, timed on frames because the core delivers states on its own tick.
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
                // Nothing drawn, no trail: the game makes the same check before spawning.
                if (!visual.Pc.basesprite.enabled || visual.Pc.basesprite.sprite == null)
                {
                    continue;
                }
                visual.TrailTimer += dt;
                if (visual.TrailTimer < visual.TrailRate)
                {
                    continue;
                }
                // Subtract, never zero, so a long frame does not drop a spawn.
                visual.TrailTimer -= visual.TrailRate;

                GhostEffect effect = GemaPoolManager.Instance.CreateGhostEffect();
                if (effect == null)
                {
                    continue;
                }
                Sprite fxSprite = visual.TrailHaveEffect && visual.Pc.effectsprite != null ? visual.Pc.effectsprite.sprite : null;
                // The local player, never null: SetSprite dereferences it on its isPlayer() branch.
                effect.SetSprite(localPlayer, visual.Pc.basesprite.flipX, visual.Pc.basesprite.sprite,
                    fxSprite, visual.TrailColor, visual.TrailColor, visual.TrailOrder, visual.TrailOrder - 1);
                effect.SetDecaySpeed(visual.TrailDecay);
                effect.transform.localScale = visual.Pc.transform.localScale;
                effect.transform.position = visual.Pc.transform.position;
            }
        }

        // Warp devices wake for a ghost, the visual half only. The game's own trigger would also autosave and heal the
        // local player, so it never fires for a ghost; WarpDevice.Update draws the whole wake-up from its ready flags,
        // and a ghost is "inside" by the device's own trigger collider.
        private const float WarpScanInterval = 0.5f;
        private float lastWarpScanTime;
        private WarpDevice[] warpDevices = new WarpDevice[0];
        // Devices with a ghost inside, so the close request is sent once, when the last ghost leaves.
        private readonly HashSet<int> warpsWithGhostInside = new HashSet<int>();
        // Scratch for pruning warpsWithGhostInside; a set cannot be modified while enumerated.
        private readonly List<int> staleWarpIds = new List<int>();

        private static readonly FieldInfo WarpReadyOpenField =
            typeof(WarpDevice).GetField("readyopen", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo WarpReadyCloseField =
            typeof(WarpDevice).GetField("readyclose", BindingFlags.NonPublic | BindingFlags.Instance);
        // Zeroed every frame a ghost is inside, as OnTriggerStay2D does for the player. Optional: readyclose held false
        // keeps the portal open without it.
        private static readonly FieldInfo WarpReadyCloseTimerField =
            typeof(WarpDevice).GetField("readyclosetimer", BindingFlags.NonPublic | BindingFlags.Instance);

        // Trigger colliders per device, cached at scan time: GetComponentsInChildren allocates on every call.
        private Collider2D[][] warpTriggers = new Collider2D[0][];

        private void UpdateWarpDevicesForGhosts()
        {
            // A build that renames either field gets no wake-up rather than an exception every frame.
            if (WarpReadyOpenField == null || WarpReadyCloseField == null)
            {
                return;
            }
            // On a timer: FindObjectsOfType walks the scene, and the devices only change with the room.
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
                // An entry left from the previous scene would otherwise keep the caller scanning forever.
                warpsWithGhostInside.Clear();
                return;
            }

            // Forget devices that no longer exist: a scene change hands out new ids, and a stale entry keeps the caller
            // scanning every frame.
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
                // Off camera the game disables the component, and nothing would read the flag.
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
                    // Every frame, as OnTriggerStay2D does: the local player walking out sets readyclose, and only a
                    // per-frame test answers "is anyone still here". readyopen is a request Update clears once open.
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
                    // The last ghost left: a transition, so the game's own open and close are not overridden. A local
                    // player still inside keeps it open, since the game zeroes readyclosetimer every frame for them.
                    WarpReadyCloseField.SetValue(device, true);
                    WarpReadyOpenField.SetValue(device, false);
                }
            }
        }

        // A pooled effect we mirror. The local side reports that the game itself activated it, as a counter that
        // survives a dropped frame; the ghost plays it. When it fires stays the game's rule, which also reads the local
        // badges. An allowlist, since a pooled activation near the player may be the world's or an enemy's. Each row's
        // numbers are that effect's own spawn site, and the placement differs per effect.
        private struct MirroredEffect
        {
            public int Index;
            public float OffsetX;
            public float OffsetY;
            public float ScaleX;         // 0 = leave the prefab's own scale alone
            public float ScaleY;
            public bool NegateOnLeft;    // false = negate when facing right (CutinStar, opposite the blast)
            public bool FlipScaleByFacing; // does the game mirror this effect's scale at all?
        }

        private static readonly MirroredEffect[] MirroredCommonEffectTable =
        {
            // "Normal4H Blast": offset and scale both mirrored by facing.
            new MirroredEffect { Index = 56, OffsetX = 105f, OffsetY = -64f, ScaleX = 55f, ScaleY = 55f,
                                 NegateOnLeft = true, FlipScaleByFacing = true },
            // "CutinStar": the prefab's own scale.
            new MirroredEffect { Index = 0, OffsetX = 109f, OffsetY = -18f, ScaleX = 0f, ScaleY = 0f,
                                 NegateOnLeft = false, FlipScaleByFacing = false },
            // The perfect-timing extra, on some attacks only: the blast's X and negate rule, a scale never mirrored.
            new MirroredEffect { Index = 37, OffsetX = 105f, OffsetY = -107f, ScaleX = 225f, ScaleY = 260f,
                                 NegateOnLeft = true, FlipScaleByFacing = false },
        };
        // Farther than this from the local player, an activation is not the local player's.
        private const float MirroredEffectOwnershipRange = 200f;
        private readonly Dictionary<int, int> mirroredEffectActive = new Dictionary<int, int>();
        private int localVfxSeq;
        private int localVfxEffect;
        // Facing when the effect fired, sent with it: the character may have turned by the time a peer renders it.
        private bool localVfxFacingLeft;

        // Instance ids of pooled objects we activated for a ghost. Counting them as local activity would echo an effect
        // between two peers forever, and the distance guard cannot tell them apart when the characters stand close.
        private readonly HashSet<int> ghostSpawnedEffects = new HashSet<int>();

        // The pooled objects behind those ids, so teardown can switch off anything still lit.
        private readonly List<GameObject> ghostEffectObjects = new List<GameObject>(16);

        // Local side, every frame (an interval would only add latency): when the game activates a mirrored effect near
        // the player, bump the counter the peer reads. It walks only the allowlisted pools.
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
                    if (go == null)
                    {
                        continue;
                    }
                    if (!go.activeInHierarchy)
                    {
                        // The mark lasts only as long as the activation: the game reuses the object, and a stale mark
                        // would hide the local player's own next effect on it.
                        ghostSpawnedEffects.Remove(go.GetInstanceID());
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
                // A rise near the player, after a baseline: the first sample must not report the resting state.
                if (known && active > prev && nearPlayer)
                {
                    localVfxSeq++;
                    localVfxEffect = index;
                    localVfxFacingLeft = player.direction == Character.Direction.LEFT;
                    if (DIAG_HITSTOP_PHASE)
                    {
                        Logger.LogInfo($"MeshGhost/probe vfx: SEND rise idx={index} seq={localVfxSeq}");
                        // One dump per rise, of what the game just spawned, to diff a white attack against a blue one.
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

        // For DIAG_HITSTOP_PHASE: everything colour-bearing on one effect object, to diff the player's instance against
        // the ghost's. The mode and both bounds, since startColor.color means nothing in a gradient mode.
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

        // Just above the strobe's white gap: long enough to bridge it, short enough to leave no tail after the combo.
        private const float WeaponStrobeHold = 0.07f;
        private int lastWeaponRgb = 0xFFFFFF;
        private float lastWeaponSeenAt = float.NegativeInfinity;

        // The local weapon layer's colour as 0xAARRGGBB. Some combos strobe it between white and a colour every frame;
        // sampling that through the state stream would alias, so the ghost reproduces the strobe from the colour.
        private int? ReadWeaponStrobe(CharacterBase player)
        {
            if (player.spranim_prefer == null || player.spranim_prefer.pixel == null
                || player.spranim_prefer.pixel.effectsprite == null)
            {
                return null;
            }
            Color c = player.spranim_prefer.pixel.effectsprite.color;

            // Alpha decides whether the layer exists: the game drops alpha when an attack ends and leaves the colour.
            if (c.a <= 0.02f)
            {
                lastWeaponSeenAt = float.NegativeInfinity;
                return 0;
            }

            // This frame's colour, never the remembered one: a hitstop can freeze the peer on white, and the receiver
            // bridges the strobe's white frames itself.
            return ((int)(c.a * 255f) << 24)
                | ((int)(c.r * 255f) << 16) | ((int)(c.g * 255f) << 8) | (int)(c.b * 255f);
        }

        // Whether ghostPhase is at or past target on a looping 0..1 clip, measured the short way round.
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

        // Watcher side: the peer's effect on its ghost, at the game's own offsets and the facing it fired with.
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
            // An effect with no row here (a newer peer's) is dropped, never placed at an invented offset.
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
            // The game places these from the character's transform, and the ghost is the pixel child, so the anchor
            // offset comes off first.
            Vector3 logicalPos = visual.Go.transform.position - visual.AnchorOffset;
            go.transform.position = logicalPos + new Vector3(offX, eff.OffsetY, 0f);
            if (eff.ScaleX > 0f)
            {
                float sx = eff.FlipScaleByFacing ? (left ? -1f : 1f) * eff.ScaleX : eff.ScaleX;
                go.transform.localScale = new Vector3(sx, eff.ScaleY, eff.ScaleY);
            }
            // So our watcher does not echo it back; bounded by the pools, whose ids recur.
            ghostSpawnedEffects.Add(go.GetInstanceID());
            // The object too, so teardown can switch off the game's object we lit: nothing else would after a reload.
            // Oldest out, since only a recent one can still be lit.
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

        // The orbitars: what the peer's orbs show (position, which of the game's sprites, glow, charge halo) travels,
        // never the OrbBall rule that places them, which reads a dozen inputs. The peer's look, not ours: two saves can
        // have different orbs. OrbBall's renderers are private; a build renaming one loses that layer.
        private static readonly FieldInfo OrbGlowField = typeof(OrbBall).GetField("_glowrender", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo OrbCrystalField = typeof(OrbBall).GetField("_cerender", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo OrbChargeField = typeof(OrbBall).GetField("_chargerender", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo OrbChargeTransformField = typeof(OrbBall).GetField("_ct", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo OrbTrailsField = typeof(OrbBall).GetField("GemaOrbTrails", BindingFlags.NonPublic | BindingFlags.Instance);

        // Above the length of the game's orb sprite tables.
        private const int OrbSpriteTableProbe = 8;

        // This sprite's index in the game's own table, by reference. -2 is a sprite not in the table: still visible, so
        // the receiver keeps what it has.
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

        // The local player's orbs, every frame, in RemoteState.Orbs' layout; hidden orbs are omitted.
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
                // Before its Start, which would take the local player's orb light slot, and its Update, which shoots
                // and spends the local save's MP. Immediate: a deferred Destroy still lets Start run next frame.
                DestroyImmediate(ob);
            }
            // The prefab's afterimage children are self-contained (StartMe places one, its FixedUpdate fades it). They
            // stay, named for the orphan sweep, and our FixedUpdate lights them as the real orb does.
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

                    // Sprite indices bounded and the lookup caught (what the game does past its table is unknown); the
                    // draw layer kept to the sorting-order range Unity honours.
                    int sprite = Mathf.Clamp((int)row[3], -1, OrbSpriteIndexMax);
                    if (orb.Render != null)
                    {
                        orb.Render.enabled = sprite != -1;
                        if (sprite >= 0 && CommonResource.Instance != null)
                        {
                            Sprite s = null;
                            try { s = CommonResource.Instance.GetOrb(sprite); } catch (System.Exception) { }
                            if (s != null) orb.Render.sprite = s;
                        }
                        orb.Render.sortingOrder = Mathf.Clamp((int)row[4], -32767, 32767);
                    }
                    int glowSprite = Mathf.Clamp((int)row[5], -1, OrbSpriteIndexMax);
                    if (orb.Glow != null)
                    {
                        orb.Glow.enabled = glowSprite != -1;
                        if (glowSprite >= 0 && CommonResource.Instance != null)
                        {
                            Sprite s = null;
                            try { s = CommonResource.Instance.GetGlowOrb(glowSprite); } catch (System.Exception) { }
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
                    // The ring's size x100; past a limit far above any ring the game draws, it reads as none.
                    int chargeScale = (int)row[10];
                    if (chargeScale > OrbChargeScaleMax) chargeScale = 0;
                    if (orb.Charge != null)
                    {
                        orb.Charge.enabled = chargeScale > 0;
                        // The game keeps the halo's sprite equal to the glow's.
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

        // OrbBall.FixedUpdate's rule: while the crystal ring renders, one afterimage per physics step in the ring's
        // colour (StartMe sets its own alpha).
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

        // Probe: what the summon filter sees, once a second while a non-player Celia or Sable is alive.
        private const bool DIAG_SUMMON_TRACE = false;
        private float lastSummonDiagTime = float.NegativeInfinity;

        // Core expansions (the boost skills): the game summons a real Celia or Sable, and a non-player one is the
        // player's own, which is the identity read here. On the watcher a summon is only a sprite clone driven by clip
        // and phase, never a character, so this reader can never pick up a peer's.
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
                // Absolute: the summon stands still while the peer moves, and relative to the root it would inherit the
                // ghost's interpolated motion.
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
                    // The summon's clips do not all run at speed 1.
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
                    // Bounded as well as finite: a speed past the limit reads as 1, a scale past it skips the row.
                    float peerSpeed = row.Length > 10 && row[10] is float ps && !float.IsNaN(ps) && !float.IsInfinity(ps)
                        && ps >= 0f && ps <= PeerAnimSpeedMax ? ps : 1f;
                    if (string.IsNullOrEmpty(type) || string.IsNullOrEmpty(controllerName)
                        || float.IsNaN(dx) || float.IsNaN(dy) || float.IsInfinity(dx) || float.IsInfinity(dy)
                        || float.IsNaN(sx) || float.IsNaN(sy) || float.IsInfinity(sx) || float.IsInfinity(sy)
                        || Mathf.Abs(sx) > PeerScaleMax || Mathf.Abs(sy) > PeerScaleMax)
                    {
                        continue;
                    }
                    SummonGhost sg;
                    if (!visual.Summons.TryGetValue(type, out sg) || sg.Go == null)
                    {
                        // A peer does not decide how many sprite rigs we build: type is a free string, one valid
                        // controller name passes the guard below, and the sweep only hides, never destroys.
                        if (visual.Summons.Count >= MaxSummonTypesPerGhost)
                        {
                            visual.RejectedAnims = visual.RejectedAnims ?? new HashSet<string>();
                            if (visual.RejectedAnims.Count < MaxRejectedAnimNamesPerPeer
                                && visual.RejectedAnims.Add("summoncap"))
                            {
                                Logger.LogWarning($"MeshGhost: {playerId} is naming more than {MaxSummonTypesPerGhost} "
                                    + $"summon types; the game itself produces two, so the rest are not rendered.");
                            }
                            continue;
                        }
                        if (cloneTemplate == null || cloneTemplate.spranim_prefer == null
                            || cloneTemplate.spranim_prefer.pixel == null || AreaResource.Instance == null)
                        {
                            continue;
                        }
                        RuntimeAnimatorController controller = AreaResource.Instance.GetNPC(controllerName);
                        if (controller == null)
                        {
                            // Said once, through the rejected-name set and under its cap.
                            visual.RejectedAnims = visual.RejectedAnims ?? new HashSet<string>();
                            if (visual.RejectedAnims.Count < MaxRejectedAnimNamesPerPeer
                                && visual.RejectedAnims.Add("summon:" + controllerName))
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
                    // The row appearing is the orb-to-humanoid moment: the trail flies from the ghost orb to the
                    // summon, parked when the summon turns visible, as the game parks its own.
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
                        // As on the ghost, flipX true is facing right.
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
                                // The ghost's rule: a big jump is a restart and is seeked, small drift a bounded speed
                                // change on top of the peer's speed.
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
                    // The row disappearing is the humanoid-to-orb moment: the trail flies back to the ghost orb.
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

        // Sable rides the black orb (index 0), Celia the white (1), as the game pairs them. The trail is cloned from
        // the game's first one on first use.
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

        // The orb-to-human flash: the rise of an orb's invButNotSummon is the event, and the watcher plays the same
        // pooled effect at its ghost orb. Not parented to it as the game does: our orb can die while the effect is
        // live, and a destroyed pooled object corrupts the pool.
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

        // The boost shield a core expansion raises (an FXVShield) and its two platforms. Its position, size, spin and
        // three material colours travel, read off the peer's material since they are the game's decision. The clone
        // is the game's own shield with isBoostShield cleared, or it would erase the watcher's enemies' bullets.
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
            // Probe, a line per change: when the shield flips between up and fading, to time the ghost's fade.
            if (DIAG_SHIELD_TIMING && sh.GetIsShieldActive() != lastShieldUpSent)
            {
                lastShieldUpSent = sh.GetIsShieldActive();
                Logger.LogInfo($"MeshGhost/probe shield: SEND up={lastShieldUpSent} anim={sh.GetIsDuringActivationAnim()} t={Time.time:0.000}");
            }
            // Absolute, like the summon it sits on: root-relative it would inherit the ghost's interpolated motion.
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
                // Up or fading: the row lasts through the peer's fade, and the clone starts its own fade with it.
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
                // Every value finite (an infinite rotation logs a Unity error every frame) and the scale bounded.
                bool finite = !(float.IsNaN(dx) || float.IsNaN(dy) || float.IsNaN(dz) || float.IsNaN(sc)
                    || float.IsNaN(rx) || float.IsNaN(ry) || float.IsNaN(rz)
                    || float.IsInfinity(dx) || float.IsInfinity(dy) || float.IsInfinity(dz) || float.IsInfinity(sc)
                    || float.IsInfinity(rx) || float.IsInfinity(ry) || float.IsInfinity(rz))
                    && Mathf.Abs(sc) <= PeerScaleMax;
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
                            // The template rests inactive between boosts, so the clone is born without the materials
                            // Awake builds. Activating once runs Awake, whose own DisableMe parks it again.
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
                            // The template's setup strips ACTIVATION_EFFECT_ON from its own material, which the clone
                            // builds from, so the bloom and fade need it back on the activation materials.
                            bool keyworded = false;
                            if (fx != null)
                            {
                                Material am = ShieldActivationMaterialField != null ? ShieldActivationMaterialField.GetValue(fx) as Material : null;
                                Material pam = ShieldPostActivationMaterialField != null ? ShieldPostActivationMaterialField.GetValue(fx) as Material : null;
                                if (am != null) { am.EnableKeyword("ACTIVATION_EFFECT_ON"); keyworded = true; }
                                if (pam != null) { pam.EnableKeyword("ACTIVATION_EFFECT_ON"); }
                            }
                            // The glow is the camera's post-process, which the clone's Awake may have joined through a
                            // different Camera.main than the one CameraScript holds.
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
                // The peer's barrier came down; DisableMe parks ours when its own fade ends.
                visual.Shield.Up = false;
                if (visual.Shield.Fx != null)
                {
                    visual.Shield.Fx.SetShieldActive(active: false);
                    if (DIAG_SHIELD_TIMING) Logger.LogInfo($"MeshGhost/probe shield: RECV row gone, fade starts t={Time.time:0.000}");
                }
            }

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

        // The game has one shield post-process, and any shield ending its fade switches it off, a ghost's included; so
        // it is switched back on every frame while any shield here is up.
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

        // Projectiles. A bullet's look is a pooled effect that follows the bulletScript, so the watcher spawns the
        // game's bullet prefab as a dormant object outside BulletManager's pool (no hits, walls or damage) and hands it
        // to the same effect, which then ends itself as for a real bullet. The sender finds that effect by identity:
        // the pooled object whose bullet field points at the newborn. The flight is the game's step on the fixed tick
        // (BulletBehave only under GhostBulletsRunGameBehaviour), ended by the game's despawn rules or a peer's death.
        //
        // Births and deaths ride rings this wide, so a lossy sample still carries them; the receiver dedupes on seq.
        // Bullets are what BridgeClient drops first near the extras cap, and a wider ring overflowed it in a burst.
        private const float BulletRingSeconds = 0.15f;
        private const float BulletLingerAfterDeath = 1f; // followers need to see isDespawning()
        // A safety net only: a type with no despawn rule of its own, whose death row was dropped, would fly forever.
        private const float BulletSafetyLife = 12f;
        // A birth arrives up to a send interval late, so spawn replays the missed steps or the bullet starts behind and
        // dies short. A sanity bound, never reached at a sane send rate.
        private const int BulletCatchUpStepsMax = 30;
        private static readonly FieldInfo BulletPrefabField = typeof(BulletManager).GetField("bullet_prefab", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo BulletStartSizeField = typeof(bulletScript).GetField("startSize", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo BulletCachePosField = typeof(bulletScript).GetField("cachepos", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo BulletFlagsField = typeof(bulletScript).GetField("flags", BindingFlags.NonPublic | BindingFlags.Instance);

        // Bounds on peer-chosen values, far past anything the game produces, so only a peer's invention is refused.
        private const int OrbSpriteIndexMax = 4095;
        private const int OrbChargeScaleMax = 10000; // x100, so a ring 100 times its natural size
        private const float PeerScaleMax = 100f;
        private const float PeerAnimSpeedMax = 100f;
        private const float BulletTimeMax = 3600f; // seconds; the ghost's own safety life is 12

        // A peer's bullet flags, masked to the bits this build's enum defines: Enum.ToObject accepts any integer, and
        // an undefined bit would reach BulletBehave as a state no shooter here can produce.
        private static int bulletFlagsDefinedMask = -1;
        private static int BulletFlagsDefined(int flags)
        {
            if (bulletFlagsDefinedMask == -1)
            {
                int mask = 0;
                try
                {
                    if (BulletFlagsField != null)
                    {
                        foreach (object v in System.Enum.GetValues(BulletFlagsField.FieldType)) mask |= System.Convert.ToInt32(v);
                    }
                }
                catch (System.Exception) { mask = 0; }
                bulletFlagsDefinedMask = mask;
            }
            return flags & bulletFlagsDefinedMask;
        }
        private static readonly FieldInfo BulletLifeField = typeof(bulletScript).GetField("life", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo BulletTimeDeleteField = typeof(bulletScript).GetField("TimeDelete", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo BulletStayField = typeof(bulletScript).GetField("isStayAtOwner", BindingFlags.NonPublic | BindingFlags.Instance);
        // The wall-hit pop, set by DestroyMe; StepGhostBullet advances it the way _Update does.
        private static readonly FieldInfo BulletInDestroyField = typeof(bulletScript).GetField("inDestroy", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo BulletCounterField = typeof(bulletScript).GetField("counter", BindingFlags.NonPublic | BindingFlags.Instance);
        // The angle's cached cosine and sine, which BulletBehave changes for a homing bullet. Read, never recomputed
        // from the angle: the game's own values steer the bullet.
        private static readonly FieldInfo BulletCosField = typeof(bulletScript).GetField("_cos", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly FieldInfo BulletSinField = typeof(bulletScript).GetField("_sin", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly MethodInfo BulletBehaveMethod = typeof(bulletScript).GetMethod("BulletBehave", BindingFlags.NonPublic | BindingFlags.Instance);
        private static readonly MethodInfo BulletStayMethod = typeof(bulletScript).GetMethod("StayAtOwner", BindingFlags.NonPublic | BindingFlags.Instance);
        // ShootBullet's own sprite step: a clone off the prefab carries the prefab's sprite.
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

        private sealed class BulletBirth { public int Seq; public float At; public object[] Row; public bulletScript B; public int BirthFlags; }
        private readonly List<BulletBirth> bulletBirths = new List<BulletBirth>();
        // A death carries where the bullet stopped: it arrives a sample late, after the ghost's bullet has flown on.
        private sealed class BulletDeath { public int Seq; public float At; public float X, Y; }
        private readonly List<BulletDeath> bulletDeathRing = new List<BulletDeath>();
        private int bulletSeq;
        private float[] bulletSlotBorn;   // timeCreated seen per pool slot
        private int[] bulletSlotSeq;      // our seq per pool slot, -1 none
        private bool[] bulletSlotDeathSent; // the death for this slot's seq is already in the ring
        private int[] bulletSlotFlagsSent;  // the flags last reported for this slot's seq

        // A bullet's non-zero counters as "slot:value" pairs; almost always empty, which fits the extras cap.
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

        // The birth state BulletBehave reads, as one cell "startSize|counters|flags|life|delete|tint", each part empty
        // at EnableMe's default. One cell, because bullets are what the extras cap drops first.
        private static string EncodeBirthState(bulletScript b)
        {
            float startSize = ReadFloatField(BulletStartSizeField, b, -1f);
            int flags = ReadIntField(BulletFlagsField, b);
            float life = ReadFloatField(BulletLifeField, b, 1.5f);
            float del = ReadFloatField(BulletTimeDeleteField, b, float.PositiveInfinity);
            string counters = EncodeCounters(b);
            var ci = System.Globalization.CultureInfo.InvariantCulture;
            // The renderer's tint, for the drawn families the shooter colours through SetColor.
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
                // justSpawn, so the game's spawn pop runs: the size sent is the base one, not a frame of the pop.
                b.SetSpriteSize(startSize, justSpawn: true);
            }
            else if (!float.IsNaN(fallbackScale) && fallbackScale > 0f)
            {
                b.SetSpriteSize(fallbackScale, justSpawn: false);
            }
            if (parts.Length > 1) ApplyCounters(b, parts[1]);
            // Flags masked; life and delete time finite and within 0..BulletTimeMax, since a NaN or negative one
            // reaches the game's timers as a state no shooter produces.
            int flags;
            if (parts.Length > 2 && parts[2].Length > 0 && BulletFlagsField != null
                && int.TryParse(parts[2], System.Globalization.NumberStyles.Integer, ci, out flags) && BulletFlagsDefined(flags) != 0)
            {
                try { BulletFlagsField.SetValue(b, System.Enum.ToObject(BulletFlagsField.FieldType, BulletFlagsDefined(flags))); }
                catch (System.Exception) { }
            }
            float life;
            if (parts.Length > 3 && parts[3].Length > 0
                && float.TryParse(parts[3], System.Globalization.NumberStyles.Float, ci, out life)
                && !float.IsNaN(life) && !float.IsInfinity(life) && life >= 0f && life <= BulletTimeMax)
            {
                b.SetLife(life);
            }
            float del;
            if (parts.Length > 4 && parts[4].Length > 0
                && float.TryParse(parts[4], System.Globalization.NumberStyles.Float, ci, out del)
                && !float.IsNaN(del) && !float.IsInfinity(del) && del >= 0f && del <= BulletTimeMax)
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
            pendingFlagUpdates = null;
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
                bulletSlotDeathSent = new bool[n];
                bulletSlotFlagsSent = new int[n];
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
                    bulletSlotDeathSent[i] = false;
                    bulletSlotFlagsSent[i] = ReadIntField(BulletFlagsField, b);
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
                    // Cell 14 packs the state BulletBehave reads that the shooter wrote after ShootBullet returned:
                    // without it a ghost's shot runs the same switch from the wrong start.
                    var birthRow = new BulletBirth
                    {
                        Seq = seq, At = now, B = b, BirthFlags = ReadIntField(BulletFlagsField, b),
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
                else if (on && bulletSlotSeq[i] >= 0 && !bulletSlotDeathSent[i] && b.isDespawning())
                {
                    // A death is the frame the bullet stops, not the frame its slot frees: on a wall it halts and pops
                    // before the slot clears, and isDespawning() is true from the first frame of either path.
                    bulletSlotDeathSent[i] = true;
                    Vector3 stop = b.transform.position;
                    bulletDeathRing.Add(new BulletDeath { Seq = bulletSlotSeq[i], At = now, X = Mathf.Round(stop.x * 10f) / 10f, Y = Mathf.Round(stop.y * 10f) / 10f });
                }
                else if (!on && bulletSlotBorn[i] >= 0f)
                {
                    if (bulletSlotSeq[i] >= 0 && !bulletSlotDeathSent[i])
                    {
                        Vector3 stop = b.transform.position; // an inactive object keeps its transform
                        bulletDeathRing.Add(new BulletDeath { Seq = bulletSlotSeq[i], At = now, X = Mathf.Round(stop.x * 10f) / 10f, Y = Mathf.Round(stop.y * 10f) / 10f });
                    }
                    bulletSlotBorn[i] = -1f;
                    bulletSlotSeq[i] = -1;
                    bulletSlotDeathSent[i] = false;
                }
            }
            pendingFlagUpdates = ReadBulletFlagUpdates(pool, enabled, n);

            // The effect is attached after ShootBullet, in the orb's update, which may run after ours: a birth with no
            // follower yet is re-scanned while it is in the ring, and its row patched in place.
            foreach (BulletBirth birth in bulletBirths)
            {
                // The age travels with the row, so a receiver that sees the birth late still starts it where it is now.
                if (birth.B != null)
                {
                    birth.Row[13] = Mathf.Round(birth.B.time * 1000f) / 1000f;
                    birth.Row[14] = WithFlags(birth.Row[14] as string, ReadIntField(BulletFlagsField, birth.B));
                }
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
            bulletDeathRing.RemoveAll(x => now - x.At > BulletRingSeconds);
            if (bulletDeathRing.Count == 0)
            {
                return null;
            }
            var arr = new float[bulletDeathRing.Count];
            for (int i = 0; i < arr.Length; i++) arr[i] = bulletDeathRing[i].Seq;
            return arr;
        }

        // seq,flags pairs for bullets whose flags changed since birth, under their own key so they survive the trim
        // that drops whole bullet rows, oldest first, near the extras cap.
        private float[] pendingFlagUpdates; // filled by ReadBullets, read by the state assembly

        // For the bullet's whole life, keyed on the pool slot: the birth ring expires long before a far shot lands.
        // Emitted only on a change, so a straight flight costs nothing.
        private float[] ReadBulletFlagUpdates(bulletScript[] pool, bool[] enabled, int n)
        {
            if (pool == null || enabled == null || bulletSlotFlagsSent == null) return null;
            List<float> outp = null;
            for (int i = 0; i < n && i < bulletSlotFlagsSent.Length; i++)
            {
                bulletScript b = pool[i];
                if (b == null || !enabled[i] || bulletSlotSeq[i] < 0) continue;
                int now = ReadIntField(BulletFlagsField, b);
                if (now == bulletSlotFlagsSent[i]) continue;
                bulletSlotFlagsSent[i] = now;
                outp = outp ?? new List<float>(4);
                outp.Add(bulletSlotSeq[i]);
                outp.Add(now);
                BulletDiag($"SEND-FLAGS seq={bulletSlotSeq[i]} now={now} age={b.time:F3} type={b.type}");
            }
            return outp != null ? outp.ToArray() : null;
        }

        // The stop positions, x,y pairs in ReadBulletDeaths' order, under a key an older receiver ignores.
        private float[] ReadBulletDeathPositions()
        {
            if (bulletDeathRing.Count == 0) return null;
            var arr = new float[bulletDeathRing.Count * 2];
            for (int i = 0; i < bulletDeathRing.Count; i++) { arr[i * 2] = bulletDeathRing[i].X; arr[i * 2 + 1] = bulletDeathRing[i].Y; }
            return arr;
        }

        // Identity is not enough for a pooled follower: the game reuses a slot's bulletScript at once, and a follower
        // still fading for the previous bullet points at the newborn too. A match is real only if the follower went
        // active no earlier than the bullet's timeCreated, since the game lights it in the call that shot the bullet.
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

        // Flags are not a birth fact (the lock-on shot adds CannotPassWall to itself after launch), so the ring
        // refreshes them each frame and the receiver applies them to a bullet it already spawned.
        private static string WithFlags(string packed, int flags)
        {
            string[] parts = (packed ?? "").Split('|');
            var sb = new System.Text.StringBuilder();
            for (int i = 0; i < parts.Length; i++)
            {
                if (i > 0) sb.Append('|');
                sb.Append(i == 2 ? (flags != 0 ? flags.ToString(System.Globalization.CultureInfo.InvariantCulture) : "") : parts[i]);
            }
            return sb.ToString();
        }

        private static void ApplyFlagsFromRow(bulletScript b, object[] row)
        {
            if (b == null || BulletFlagsField == null) return;
            string packed = row != null && row.Length > 14 ? row[14] as string : null;
            if (string.IsNullOrEmpty(packed)) return;
            string[] parts = packed.Split('|');
            int flags;
            // Masked like the birth and update paths: a re-sent row is peer input too.
            if (parts.Length > 2 && parts[2].Length > 0
                && int.TryParse(parts[2], System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out flags))
            {
                try { BulletFlagsField.SetValue(b, System.Enum.ToObject(BulletFlagsField.FieldType, BulletFlagsDefined(flags))); }
                catch (System.Exception) { }
            }
        }

        private static string PoolNameOf(object[] row)
        {
            string packed = row != null && row.Length > 14 ? row[14] as string : null;
            if (string.IsNullOrEmpty(packed)) return "";
            string[] parts = packed.Split('|');
            return parts.Length > 6 ? parts[6] : "";
        }

        // The sent pool index if its prefab carries follower kind `kind`, else the first pool that does, else -1. Kind
        // indexes our own EffectKindTypes, stable across builds.
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

        // BulletType and SpriteType ordinals differ between TEVI builds, so fields 7-8 of the packed cell carry the
        // names, which a receiver believes over the ordinals in cells 1-2 (kept for an older peer).
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
            // Enum.TryParse accepts "999", so a name must start with a letter and be one this build defines.
            Bullet.BulletType bt; Bullet.SpriteType st;
            if (parts.Length > 7 && parts[7].Length > 0 && char.IsLetter(parts[7][0])
                && System.Enum.TryParse(parts[7], out bt) && System.Enum.IsDefined(typeof(Bullet.BulletType), bt)) b.type = bt;
            if (parts.Length > 8 && parts[8].Length > 0 && char.IsLetter(parts[8][0])
                && System.Enum.TryParse(parts[8], out st) && System.Enum.IsDefined(typeof(Bullet.SpriteType), st)) b.sprite = st;
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

        // The pooled effect following this newborn: its bullet field's identity, and an activation no older than it.
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
                        // Sent for the receiver's diagnostic only: every orb effect prefab is named "Orb".
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
            // Flags gained after birth, for bullets already flying.
            if (state.BulletFlagUpdates != null && BulletFlagsField != null)
            {
                for (int i = 0; i + 1 < state.BulletFlagUpdates.Length; i += 2)
                {
                    float seqF = state.BulletFlagUpdates[i], flagsF = state.BulletFlagUpdates[i + 1];
                    if (float.IsNaN(seqF) || float.IsNaN(flagsF) || float.IsInfinity(seqF) || float.IsInfinity(flagsF)) continue;
                    GhostBullet gbf;
                    bool have = visual.Bullets.TryGetValue((int)seqF, out gbf);
                    if (DIAG_GHOST_BULLETS && (int)seqF != lastRecvFlagDiagSeq)
                    {
                        lastRecvFlagDiagSeq = (int)seqF;
                        BulletDiag($"RECV-FLAGS seq={(int)seqF} flags={(int)flagsF} spawned={have} dead={(have && gbf.DiedAt != float.NegativeInfinity)}");
                    }
                    if (!have || gbf.B == null || gbf.DiedAt != float.NegativeInfinity) continue;
                    try { BulletFlagsField.SetValue(gbf.B, System.Enum.ToObject(BulletFlagsField.FieldType, BulletFlagsDefined((int)flagsF))); }
                    catch (System.Exception) { }
                }
            }

            // WorldManager answers for the local player's room, so the local wall test only means something in it.
            WorldManager wmRoom = WorldManager.Instance;
            visual.SameRoom = wmRoom != null && state.RoomX.HasValue && state.RoomY.HasValue
                && state.RoomX.Value == wmRoom.CurrentRoomX && state.RoomY.Value == wmRoom.CurrentRoomY;
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
                    // First sight adopts the counter, so a ghost created mid-fight replays none of the ring's shots.
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
                            // Flags the shooter's bullet has gained since it was born.
                            if (existing.DiedAt == float.NegativeInfinity) ApplyFlagsFromRow(existing.B, row);
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
                float[] pos = state.BulletDeathPos;
                for (int i = 0; i < state.BulletDeaths.Length; i++)
                {
                    float f = state.BulletDeaths[i];
                    if (float.IsNaN(f)) continue;
                    GhostBullet gb;
                    if (DIAG_GHOST_BULLETS && visual.Bullets.TryGetValue((int)f, out gb) && gb.DiedAt != float.NegativeInfinity
                        && gb.Go != null && pos != null && pos.Length >= i * 2 + 2)
                    {
                        // Already ended here by the local wall test: how far from where the real one stopped?
                        Vector3 peerStop = worldOffset + new Vector3(pos[i * 2], pos[i * 2 + 1], 0f);
                        Vector3 d = gb.Go.transform.position - peerStop;
                        BulletDiag($"PEER-DEATH-AFTER-LOCAL {gb.Go.name} cause={gb.Cause} localStop={gb.Go.transform.position} peerStop={peerStop} delta=({d.x:F1},{d.y:F1}) speed={gb.Speed}");
                    }
                    if (visual.Bullets.TryGetValue((int)f, out gb) && gb.DiedAt == float.NegativeInfinity)
                    {
                        // Back to where it really stopped, then the pop happens there.
                        if (pos != null && pos.Length >= i * 2 + 2 && gb.B != null
                            && !float.IsNaN(pos[i * 2]) && !float.IsNaN(pos[i * 2 + 1])
                            && !float.IsInfinity(pos[i * 2]) && !float.IsInfinity(pos[i * 2 + 1]))
                        {
                            gb.B.SetPosition(worldOffset + new Vector3(pos[i * 2], pos[i * 2 + 1], 0f));
                            // A follower's TrailRenderer would draw the snap back as a streak.
                            ClearGhostBulletTrails(gb);
                        }
                        KillGhostBullet(gb);
                    }
                }
            }
        }

        // Only when the game's pool cannot be read (a scene load, a renamed field); generous, so a missed read never
        // refuses an honest player's shots.
        private const int GhostBulletCapFallback = 512;

        // The game's own concurrent-bullet ceiling for this build, read live.
        private int GhostBulletCap()
        {
            if (BulletManager.Instance != null && BulletsField != null
                && BulletsField.GetValue(BulletManager.Instance) is bulletScript[] pool && pool.Length > 0)
            {
                return pool.Length;
            }
            return GhostBulletCapFallback;
        }

        private void SpawnGhostBullet(string playerId, RemoteGhostVisual visual, int seq, object[] row, Vector3 worldOffset)
        {
            if (BulletManager.Instance == null || BulletPrefabField == null || cloneTemplate == null) return;
            // A peer does not decide how many bullets we build (each a prefab clone, stepped for seconds). Capped at
            // the game's own pool, the most bullets it can hold for everyone at once, which no honest peer exceeds.
            if (visual.Bullets.Count >= GhostBulletCap())
            {
                visual.RejectedAnims = visual.RejectedAnims ?? new HashSet<string>();
                if (visual.RejectedAnims.Count < MaxRejectedAnimNamesPerPeer
                    && visual.RejectedAnims.Add("bulletcap"))
                {
                    Logger.LogWarning($"MeshGhost: {playerId} has more live bullets than this build's own "
                        + $"bullet pool holds ({GhostBulletCap()}); the rest are not spawned.");
                }
                return;
            }
            var prefab = BulletPrefabField.GetValue(BulletManager.Instance) as bulletScript;
            if (prefab == null) return;
            float x = CellF(row, 3), y = CellF(row, 4), angle = CellF(row, 5), speed = CellF(row, 6), scale = CellF(row, 7);
            // Infinity refused too: an infinite angle is NaN after the cosine, an infinite speed a bullet nowhere.
            if (float.IsNaN(x) || float.IsNaN(y) || float.IsNaN(angle) || float.IsNaN(speed) || float.IsInfinity(x) || float.IsInfinity(y)
                || float.IsInfinity(angle) || float.IsInfinity(speed)) return;
            // Ordinals this build defines, else the prefab's value stays (the names may still win). Through the helper:
            // Enum.IsDefined on an int throws for these enums, which are narrower than int.
            int type = BridgeClient.DefinedOrdinalOrMinusOne(typeof(Bullet.BulletType), CellF(row, 1));
            int sprite = BridgeClient.DefinedOrdinalOrMinusOne(typeof(Bullet.SpriteType), CellF(row, 2));

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
            if (type != -1) b.type = (Bullet.BulletType)type;
            if (sprite != -1) b.sprite = (Bullet.SpriteType)sprite;
            ApplyEnumNames(b, row); // a peer on another build: its names win over its ordinals
            b.SetAngle(angle);
            b.speed = speed;
            // ShootBullet's sprite step. NONE and USE_PS draw nothing through the bullet's renderer (USE_PS is all
            // follower effect), so for them the clone's renderer, carrying the prefab's sprite, goes off.
            bool drawnSprite = b.sprite != Bullet.SpriteType.NONE && b.sprite != Bullet.SpriteType.USE_PS;
            if (b._render != null) b._render.enabled = drawnSprite;
            if (drawnSprite && (int)b.sprite < 91 && BulletManagerSetSprite != null)
            {
                try { BulletManagerSetSprite.Invoke(BulletManager.Instance, new object[] { b, b.sprite }); }
                catch (System.Exception) { }
            }
            // The state the shooter gave it, which BulletBehave reads; an older peer's 13-cell row has none.
            ApplyBirthState(b, row.Length > 14 ? row[14] : null, scale);
            b.time = 0f;
            b.SetPosition(worldOffset + new Vector3(x, y, 0f)); // cachepos too: BulletBehave reads it
            go.SetActive(true);

            var gb = new GhostBullet
            {
                Go = go, B = b, BornAt = Time.time, Speed = speed,
                Cos = Mathf.Cos(Mathf.PI / 180f * angle), Sin = Mathf.Sin(Mathf.PI / 180f * angle),
            };
            gb.WallTestOk = visual.SameRoom; // the catch-up steps test walls too, or none of them do
            visual.Bullets[seq] = gb;
            // Replay the bullet's age at the game's step, so it starts where the peer's shot is, not where it was born.
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
                // By index, checked: the pool must carry the follower the sender matched, since indices shift between
                // builds (a name cannot pick one: every orb prefab is "Orb"). Else the first pool that carries it.
                ObjectPooler op = GemaPoolManager.Instance.CommonEffectsPooler;
                int usePool = PoolCarryingKind(op, pool, kind);
                GameObject fx = usePool >= 0 ? op.GetPooledObject(usePool) : null;
                gb.EffectObjectName = fx != null ? $"{fx.name}#{usePool}{(usePool != pool ? "(sent " + pool + ")" : "")}" : "(none)";
                gb.Fx = fx;
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

        // Muzzle flashes (OrbShootFlash, OrbChargeFlash), tied to no bullet. The sender watches their pools for an
        // object going active that it did not light itself, or two peers would echo each other's flashes.
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
                    // Setup turns the flash to +90 for LEFT and -90 (270) for RIGHT.
                    bool left = go.transform.localEulerAngles.y > 0f && go.transform.localEulerAngles.y < 180f;
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
                // Bounded: what GetPooledObject does out of range is unknown, so a peer must not choose it.
                if (op == null || op.pooledObjectsList == null
                    || pool < 0 || pool >= op.pooledObjectsList.Count
                    || float.IsNaN(x) || float.IsNaN(y)
                    || float.IsInfinity(x) || float.IsInfinity(y)) continue;
                // And a flash pool, tested by its template's component since pool indices differ between builds: a peer
                // must not light any other pooled effect at will.
                List<GameObject> flashPool = op.pooledObjectsList[pool];
                if (flashPool == null || flashPool.Count == 0 || flashPool[0] == null
                    || (flashPool[0].GetComponent<OrbShootFlash>() == null && flashPool[0].GetComponent<OrbChargeFlash>() == null)) continue;
                GameObject fx = op.GetPooledObject(pool);
                if (fx == null) continue;
                bool left = row[4] is bool lb && lb;
                Color c; if (!TryColor(row[5], out c)) c = Color.white;
                Character.Direction dir = left ? Character.Direction.LEFT : Character.Direction.RIGHT;
                fx.transform.position = worldOffset + new Vector3(x, y, 0f);
                flashesWeLit.Add(fx.GetInstanceID());
                fx.SetActive(true);
                // Dispatched by component, not by pool number, for the reason the guard above gives.
                fx.GetComponent<OrbShootFlash>()?.Setup(c, dir);
                fx.GetComponent<OrbChargeFlash>()?.Setup(c, dir);
            }
            visual.LastFlashSeq = maxSeq;
        }

        // One line per event: what the sender decided a shot is, what the receiver made of the row, and what ended the
        // ghost's bullet and when. A SEND paired with its RECV separates symptoms that reading code cannot.
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

        // Every trail on the bullet and its follower emptied, so no segment spans a teleport; it keeps emitting.
        private static void ClearGhostBulletTrails(GhostBullet gb)
        {
            if (gb.Go != null)
            {
                foreach (TrailRenderer tr in gb.Go.GetComponentsInChildren<TrailRenderer>(true)) tr.Clear();
            }
            if (gb.Fx != null)
            {
                foreach (TrailRenderer tr in gb.Fx.GetComponentsInChildren<TrailRenderer>(true)) tr.Clear();
                foreach (ParticleSystem ps in gb.Fx.GetComponentsInChildren<ParticleSystem>(true))
                {
                    // A stretched-billboard particle spans the jump the same way a trail does.
                    if (ps.main.simulationSpace == ParticleSystemSimulationSpace.World) ps.Clear(true);
                }
            }
        }

        private void KillGhostBullet(GhostBullet gb, string cause = "peer death")
        {
            gb.DiedAt = Time.time;
            // DestroyMe, as the game calls on a wall or a hit: the bullet halts and pops, and followers see it despawn.
            if (gb.B != null)
            {
                gb.B.DestroyMe();
                // One family leaves DestroyMe not despawning, waiting for a next step a ghost never gets.
                if (!gb.B.isDespawning()) gb.B.DespawnMe();
            }
            // inWall: a bullet dying inside solid tile is one the local wall test never ran on (no CannotPassWall yet,
            // or the shooter in another room).
            WorldManager wmK = WorldManager.Instance;
            Vector3 at = gb.Go != null ? gb.Go.transform.position : Vector3.zero;
            string wall = wmK != null ? $"{wmK.CheckIsWall(at, any: false)}/{wmK.CheckIsWall(at, any: true)}" : "?";
            BulletDiag($"KILL {gb.Go?.name} type={(gb.B != null ? gb.B.type.ToString() : "?")} cause={cause}"
                + $" cpw={(gb.B != null && gb.B.HaveFlag(Bullet.Flags.CannotPassWall))} wallTestOk={gb.WallTestOk}"
                + $" inWall={wall} at={at} lived={Time.time - gb.BornAt:F3}s time={(gb.B != null ? gb.B.time : -1f):F3}"
                + $" fx={gb.EffectObjectName ?? "-"}");
        }

        // The game's fixed step, which bulletScript's arithmetic is written in; ghost bullets tick from FixedUpdate as
        // the real ones do, since some count physics steps.
        private static float GameFixedStep()
        {
            float fdt = MainVar.instance != null ? MainVar.instance.fixedDeltaTime : 0f;
            return fdt > 0f ? fdt : Time.fixedDeltaTime;
        }

        private bool[] bulletPoolWasEnabled;
        private bool loggedBehaveFailure;

        // Off, because on it a peer's shots damage the watcher. Off is the straight-line flight: wrong for the families
        // that move themselves, and incapable of harm.
        private const bool GhostBulletsRunGameBehaviour = false;

        // BulletBehave on another game's bullet, with useChargeRemove zeroed (charged families erase the watcher's
        // bullets while it is set) and anything the call puts in the real pool despawned again. The pool snapshot is
        // per call: catch-up steps run from Update, and a stale one would kill the local player's own new shot.
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

        // One physics step in bulletScript._Update's order (age, behave, animate, move, despawn rules), without
        // anything _Update does to the world: hits, tiles, wall damage, the pool's bookkeeping.
        private void StepGhostBullet(GhostBullet gb, float fdt)
        {
            bulletScript b = gb.B;
            if (b == null || gb.Go == null) return;
            if (gb.PopDone) return; // shrunk to nothing: the real one left the pool here
            float inDestroy = ReadFloatField(BulletInDestroyField, b, 0f);
            if (inDestroy > 0f)
            {
                // _Update's pop: no movement, grow, then shrink to nothing. The ghost's bullet lingers for its
                // followers, so it must stop at zero, or the scale goes negative and grows every frame.
                inDestroy += fdt;
                if (BulletInDestroyField != null) BulletInDestroyField.SetValue(b, inDestroy);
                float popSize = ReadFloatField(BulletStartSizeField, b, -1f);
                if (popSize < 0f)
                {
                    popSize = 0.75f;
                    if (BulletStartSizeField != null) BulletStartSizeField.SetValue(b, popSize);
                }
                float scale = gb.Go.transform.localScale.x;
                if (inDestroy < 0.1125f)
                {
                    b.SetSpriteSize(scale + fdt * 60f * (popSize / 7.5f * 1.67f), justSpawn: false);
                }
                else
                {
                    float next = scale - fdt * 60f * (popSize * 1.67f);
                    if (next <= 0f)
                    {
                        b.SetSpriteSize(0f, justSpawn: false);
                        if (b._render != null) b._render.enabled = false;
                        b.DespawnMe();
                        gb.PopDone = true;
                    }
                    else
                    {
                        b.SetSpriteSize(next, justSpawn: false);
                    }
                }
                return;
            }
            if (b.isDespawning()) return;
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

            // In a cutscene the real bullet fades instead of behaving, and its death arrives on the wire.
            bool eventOff = EventManager.Instance == null
                || EventManager.Instance.getMode() == EventMode.Mode.OFF
                || EventManager.Instance.ForceBulletPlayInEvent
                || b.sprite == Bullet.SpriteType.NONE;
            if (eventOff) GuardedBulletBehave(gb);
            if (b.isDespawning()) return;   // its own rule ended it -- the caller kills it next pass
            if (!b.stopAnim) b.BulletSprite();

            // _Update's motion, read back after the behaviour ran: a type that moves itself writes cachepos, and a
            // homing one has turned the angle.
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

                // The wall, locally: _Update's test minus the call that writes (DestroyTileInArea), so the bullet stops
                // on the frame it touches, where the mirrored death arrives a sample late. A tile the shooter broke is
                // intact here; world custody is never mirrored. CheckIsWall reads the area's tile grid, valid anywhere
                // in a shared area; CheckIsTerrainBox2D overlaps our room's colliders, so it alone is room-gated.
                WorldManager wm = WorldManager.Instance;
                if (wm != null && b.HaveFlag(Bullet.Flags.CannotPassWall)
                    && ((b.GetHSizeH() >= 1f && wm.CheckIsWall(cache, any: false) > 0)
                        || (gb.WallTestOk && wm.CheckIsTerrainBox2D(cache))))
                {
                    gb.Cause = gb.WallTestOk ? "wall (local test)" : "wall (local tile grid)";
                    b.DestroyMe();
                    if (!b.isDespawning()) b.DespawnMe();
                    return;
                }
            }

            // The game's despawn rules. life applies only off screen; _Update asks the renderer, but a pooled-effect
            // bullet draws through a particle system, so the camera bound asks instead.
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
                bool sameRoom = kv.Value.SameRoom;
                foreach (KeyValuePair<int, GhostBullet> bk in kv.Value.Bullets)
                {
                    GhostBullet gb = bk.Value;
                    gb.WallTestOk = sameRoom;
                    if (gb.Go == null)
                    {
                        done = done ?? new List<int>(); done.Add(bk.Key); continue;
                    }
                    if (gb.DiedAt != float.NegativeInfinity)
                    {
                        StepGhostBullet(gb, fdt); // only the pop advances on a dead bullet
                        if (now - gb.DiedAt > BulletLingerAfterDeath)
                        {
                            RetireGhostBullet(gb.Go);
                            done = done ?? new List<int>(); done.Add(bk.Key);
                        }
                        continue;
                    }
                    StepGhostBullet(gb, fdt);
                    // Its own behaviour, despawn rules or the safety net; the peer's death takes the same path.
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
                RetireGhostBullet(kv.Value.Go);
            }
            visual.Bullets.Clear();
        }

        // Never destroy a bullet a follower may still hold: a follower reads it every frame and throws before its own
        // end check. The game only deactivates bullets; we deactivate, then destroy after the longest follower fade.
        private const float GhostBulletDestroyGrace = 10f;
        private bool orphanSweepDone;
        private int lastRecvFlagDiagSeq = -1;
        private static void RetireGhostBullet(GameObject go)
        {
            if (go == null) return;
            go.SetActive(false);
            Destroy(go, GhostBulletDestroyGrace);
        }

        // Once, at load: a follower holding a bullet that no longer exists (after a reload) is ended the way the game
        // ends it, so the session recovers without a restart.
        private void SweepOrphanFollowers()
        {
            ObjectPooler op = GemaPoolManager.Instance != null ? GemaPoolManager.Instance.CommonEffectsPooler : null;
            if (op == null || op.pooledObjectsList == null) return;
            int swept = 0;
            for (int i = 0; i < op.pooledObjectsList.Count; i++)
            {
                List<GameObject> pool = op.pooledObjectsList[i];
                if (pool == null) continue;
                for (int j = 0; j < pool.Count; j++)
                {
                    GameObject go = pool[j];
                    if (go == null || !go.activeInHierarchy) continue;
                    for (int k = 0; k < EffectKindTypes.Length; k++)
                    {
                        Component c = go.GetComponent(EffectKindTypes[k]);
                        if (c == null) continue;
                        if (EffectKindFields[k] == null)
                        {
                            EffectKindFields[k] = EffectKindTypes[k].GetField(EffectKindBulletField[k], BindingFlags.NonPublic | BindingFlags.Instance);
                        }
                        if (EffectKindFields[k] == null) continue;
                        var held = EffectKindFields[k].GetValue(c) as bulletScript;
                        // Unity's overloaded bool: false for null and for a destroyed object.
                        if (held) continue;
                        go.SetActive(false); swept++;
                        break;
                    }
                }
            }
            if (swept > 0) Logger.LogInfo($"MeshGhost: ended {swept} follower effect(s) whose bullet no longer existed.");
        }

        // Probe: the local player's shots (owner the player or a core expansion), walking BulletManager's private pool.
        // BIRTH and DEATH lines (lifetime, speed and angle drift since birth), and a COUNT once a second.
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
                    // A birth: a re-used slot has a new timeCreated.
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

        // Probe: every rise in a pool's active count, with the pool's prefab name, the game's own name for what it
        // spawned. Effects that do not parent to a character still come from a pool. It reports its own cost; if that
        // is too high, slow the sample, never quiet the log.
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
        // Active count per pool, keyed "poolerName#index"; a rise means the game just spawned one.
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
                // AreaPooler hangs off AreaResource, not GemaPoolManager.
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
                    // The first sample is a baseline; reporting it would spend the budget on the resting state.
                    if (!known || active <= prev || poolWatchLines >= PoolWatchBudget)
                    {
                        continue;
                    }
                    string prefab = (i < op.itemsToPool.Count && op.itemsToPool[i] != null
                        && op.itemsToPool[i].objectToPool != null)
                        ? op.itemsToPool[i].objectToPool.name
                        : "<unnamed>";
                    // Distance to the player and to the nearest ghost: which of the two the effect belongs to.
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

        // Probe (DIAG_SPAWN_DIFF): objects appearing or disappearing under a character, by instance id.
        private void DiagSpawnDiff(CharacterBase player)
        {
            if (Time.time - lastSpawnDiffSampleTime < SpawnDiffSampleInterval)
            {
                return;
            }
            lastSpawnDiffSampleTime = Time.time;

            var watch = System.Diagnostics.Stopwatch.StartNew();

            // The local player and every ghost in one pass, so both lists come from the same frames.
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

            // Each anchor's own subtree, not the scene, which costs more than a frame to walk; effects the game parents
            // to a character appear here, and one that never does is found in a pool (DIAG_POOL_WATCH).
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
                    // Never filtered by name: a wrong guess still returns a complete-looking list.
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

            // The first sample has nothing to diff against and would spend the budget on the whole room.
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

            // Coverage, so a quiet log can be told from a slow scan or a spent budget; if the worst scan is bad, raise
            // SpawnDiffSampleInterval.
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

        // Component type names only, never values.
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
                // A missing script leaves a null entry.
                sb.Append(comps[i] == null ? "<null>" : comps[i].GetType().Name);
            }
            return sb.ToString();
        }

        private void Awake()
        {
            Logger.LogInfo($"{PluginName} v{PluginVersion} loaded.");
            // Anything of ours already in the scene belongs to an instance that is gone (a hot reload, or a crash).
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

            // Two settings can name this port: a BridgePort changed from the default wins; otherwise the client's
            // config.json decides, the file a player is told to edit, so the core and adapter cannot disagree.
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

        // Nothing else closes the bridge socket, and an open one delays this player's despawn for every peer. The ghost
        // despawn is for a ScriptEngine reload: ghosts live in the scene and would outlive this instance as orphans.
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

        // mainCharacter is a property on the current build and a field on an older one, where a direct read throws
        // MissingMethodException every frame; reflection resolves whichever shape is present, once.
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

            // EventManager, mainCharacter and WorldManager can each be null outside play (main menu, loading).
            CharacterBase player = EventManager.Instance != null ? GetMainCharacter(EventManager.Instance) : null;
            cloneTemplate = (player != null && player.t != null) ? player : cloneTemplate;
            // Before DrainInto and RefreshRemoteMapMarkers, which gate markers on the local area.
            currentLocalArea = WorldManager.Instance != null ? WorldManager.Instance.Area : (byte)255;

            bridge.DrainLogsInto(msg => Logger.LogInfo(msg));
            bridge.TryConnect();
            // Autostart lives here, not in Awake: only trying to connect answers whether a core is already running.
            if (bridge.IsConnected)
            {
                launcher.TickConnected();
            }
            else
            {
                // The port the walk is on, not the base, or a second instance would spawn its core on the first's port.
                launcher.TickDisconnected(bridge.CurrentPort, bridge.LastBusyPort);
            }
            bridge.SendHelloIfNeeded(GameId, PluginVersion);

            // A new bridge session invalidates every ghost: despawn_remote rode the old connection, and the next core
            // has never heard of these player ids.
            if (bridge.SessionEpoch != lastBridgeSessionEpoch)
            {
                lastBridgeSessionEpoch = bridge.SessionEpoch;
                // Discard first, or this frame's drain recreates a tracked ghost for a dead id that nothing removes.
                bridge.DiscardQueuedMessages();
                DespawnAllRemoteGhosts("the bridge session changed");
            }

            // The scene sweep runs once per session that reached ready, not per epoch: the epoch changes on every dial
            // attempt, failed ones included.
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
                        // Opening the pause overlay must not print this; quitting to the title must.
                        FullMap gateMap = FullMap.Instance;
                        Logger.LogInfo("MeshGhost/probe menu-gate: took the LEFT-PLAY branch. "
                            + $"player==null={player == null} "
                            + $"playerTransform==null={(player == null ? "n/a" : (player.t == null).ToString())} "
                            + $"eventManager==null={EventManager.Instance == null} "
                            + $"fullMapOpen={(gateMap == null ? "no-instance" : gateMap.isFullMap.ToString())}");
                    }
                    timeSinceLastLog = 0f;
                    // TryConnect reconnects once back in play.
                    bridge.Disconnect();
                    // Our ghost is gone for peers, so theirs go too: nothing else destroys them. This is the main menu,
                    // never the pause overlay, where ghosts stay: the pause overlay does not null the player. A build
                    // that did would despawn every ghost here mid-session.
                    DespawnAllRemoteGhosts();
                }
                // Drained out of play too: bridge_ready and reject are parsed in DrainInto, and an unread answer to the
                // hello walks the port range spawning cores. Remote state is discarded: no ghost without a player.
                bridge.DrainInto(DiscardRemoteWhileOutOfPlay, DiscardDespawnWhileOutOfPlay);

                // local_state goes every frame, even with nothing to send.
                bridge.SendLocalState(null);
                return;
            }

            bridge.DrainInto(UpsertRemoteGhost, DespawnRemoteGhost);

            if (!orphanSweepDone && GemaPoolManager.Instance != null)
            {
                orphanSweepDone = true;
                SweepOrphanFollowers();
            }
            TickTrails(cloneTemplate);

            // Every frame, not per message: a marker moved only by messages cannot hide when they stop.
            RefreshRemoteMapMarkers();

            Vector3 pos = player.t.position;
            byte area = currentLocalArea;

            // Room-grid coordinates for the map marker: the map is a grid of rooms.
            int? roomX = WorldManager.Instance != null ? (int?)WorldManager.Instance.CurrentRoomX : null;
            int? roomY = WorldManager.Instance != null ? (int?)WorldManager.Instance.CurrentRoomY : null;

            // The real clip name, so a ghost can Play it with no invented mapping; the enum name only on an early frame
            // before the animator chain exists.
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
                BulletDeathPos = ReadBulletDeathPositions(),
                BulletFlagUpdates = pendingFlagUpdates,
                Flashes = ReadFlashes(player),
                Platforms = ReadPlatforms(player),
                OrbFxSeq = localOrbFxSeq,
                OrbFxOrb = localOrbFxOrb,
                OrbFxWhite = localOrbFxWhite,
            });

            // Also while a device still holds a ghost: only the scan closes a portal, and the last ghost leaving would
            // otherwise stop the scan first.
            if (remoteVisuals.Count > 0 || warpsWithGhostInside.Count > 0)
            {
                UpdateWarpDevicesForGhosts();
            }

            WatchLocalVfx(player);
            WatchLocalOrbFx(player);
            if (DIAG_BULLET_WATCH) DiagBulletWatch(player);
            KeepShieldPostprocess(player);

            // All five sprite layers once per hitstop, full RGBA: the RGB-edge probe below cannot see an alpha change.
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

            // Which layer's colour carries the weapon's variant, edge-triggered on RGB (alpha fades every frame).
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
                // The other edge, the frame the player comes back; the pause overlay produces neither.
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
