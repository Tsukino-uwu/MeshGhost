using System.Collections.Generic;
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
    // Step 6.3: a placeholder ghost at a fixed offset from the local player, no network yet --
    // TEVI's analogue of Emerald's Phase 2 magenta-box ghost. Proves screen/world placement
    // before tackling a real character-visual clone (TEVI's characters are plain SpriteRenderer
    // + Animator, not Spine -- confirmed by decompiling PixelCharacter.cs, zero Spine
    // references, unlike the ~14 boss/environment files that do use it).
    // Step 6.4/6.5: a real bridge connection (see BridgeClient.cs) to the local core process,
    // sending local_state every frame and rendering whatever render_remote/despawn_remote comes
    // back -- proven with the relay's dev-only -loopback flag so a single real TEVI instance can
    // see a real network round trip (Steam blocks running TEVI twice, confirmed by the user
    // 2026-08-12, so two-real-players testing (6.6) is deferred until a second machine is
    // available -- see agent_docs/phases/phase6.md).
    [BepInPlugin(PluginGuid, PluginName, PluginVersion)]
    public class Plugin : BaseUnityPlugin
    {
        public const string PluginGuid = "dev.meshghost.tevi";
        public const string PluginName = "MeshGhost";
        public const string PluginVersion = "0.1.0";

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
        private Vector3 lastLoggedPos;
        private Character.Direction lastLoggedDir;
        private Character.PlayerAniState lastLoggedAnim;
        private byte lastLoggedArea;

        // Step 6.3: a simple translucent placeholder square, offset from the local player.
        // Fixed offset (no network) is deliberate -- this step only proves the ghost can be
        // created and kept positioned correctly every frame, the same scope Emerald's Phase 2
        // had before any networking existed.
        private static readonly Vector3 GhostOffset = new Vector3(80f, 0f, 0f);

        // World-scale calibration: CharacterBase.charHeight = 65f (a real, cited field read
        // from Assembly-CSharp.dll) means TEVI's characters are ~65 world units tall. The first
        // attempt used Sprite.Create's default-ish pixelsPerUnit of 100, which shrank a 32px
        // texture down to 0.32 world units -- about 1/200th the player's height, invisible in
        // practice even though it was genuinely created with no exception (confirmed in the
        // log). pixelsPerUnit=1 makes GhostSizeUnits below the sprite's actual world size.
        private const float GhostSizeUnits = 48f; // roughly 0.7x charHeight -- clearly visible, not oversized
        private const float GhostPixelsPerUnit = 1f;
        private static readonly Color LocalGhostColor = new Color(1f, 0f, 1f, 0.5f); // translucent magenta, matches Emerald's Phase 2 placeholder
        private GameObject ghost;

        private BridgeClient bridge;
        private const string BridgeHost = "127.0.0.1";
        private const int BridgePort = 7778;

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
        }

        private readonly Dictionary<string, RemoteGhostVisual> remoteVisuals = new Dictionary<string, RemoteGhostVisual>();

        // Diagnostic-only, for solo loopback testing: renders the remote ghost offset to one
        // side rather than exactly on top of the real player, so "is it actually tracking me"
        // is easy to see at a glance (same reasoning as 6.3's GhostOffset, opposite direction so
        // the two ghosts don't overlap). Must NOT ship for a real 6.6 two-player test -- a real
        // remote's position should render exactly where it is, not offset.
        private static readonly Vector3 RemoteVisualTestOffset = new Vector3(-80f, 0f, 0f);

        // Set once per Update from EventManager.Instance.mainCharacter, before bridge.DrainInto
        // runs, so UpsertRemoteGhost has a live template to clone from the first time a remote
        // shows up. Cloning the *local* player's own visual is exactly correct for the loopback
        // test (the remote genuinely is you); for a real different remote character later this
        // would need its own per-character template, deferred until 6.6 has a real second peer.
        private CharacterBase cloneTemplate;

        private GameObject CreateRealGhostVisual(CharacterBase templatePlayer, string name, out PixelCharacter pc, out Vector3 anchorOffset)
        {
            // Measure the real offset before instantiating a detached copy loses the parent
            // relationship that produced it.
            anchorOffset = templatePlayer.spranim_prefer.pixel.transform.position - templatePlayer.t.position;

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

            pc = clone.GetComponent<PixelCharacter>();
            return clone;
        }

        private GameObject CreatePlaceholderGhost(string name, Color color)
        {
            var go = new GameObject(name);
            var sr = go.AddComponent<SpriteRenderer>();

            // A flat-color texture is enough to prove placement; real character-visual
            // rendering is a later step (Emerald's equivalent didn't get a real sprite until
            // Phase 5.5, well after basic placement was proven).
            const int texturePixels = 32;
            var tex = new Texture2D(texturePixels, texturePixels);
            var pixels = new Color[texturePixels * texturePixels];
            for (int i = 0; i < pixels.Length; i++)
            {
                pixels[i] = color;
            }
            tex.SetPixels(pixels);
            tex.Apply();

            // pixelsPerUnit=1 with a 32px texture gives a 32x32-unit sprite; scale the transform
            // up to GhostSizeUnits so its on-screen size is calibrated against the real
            // charHeight fact (CharacterBase.charHeight = 65f) rather than the arbitrary
            // texture resolution -- see the step 6.3 note in verified.md for why this matters.
            sr.sprite = Sprite.Create(
                tex, new Rect(0, 0, texturePixels, texturePixels), new Vector2(0.5f, 0.5f), GhostPixelsPerUnit);
            go.transform.localScale = Vector3.one * (GhostSizeUnits / texturePixels);
            sr.sortingOrder = 1000; // draw on top rather than guessing this scene's layer setup

            return go;
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
                GameObject go = CreateRealGhostVisual(cloneTemplate, $"MeshGhostRemote_{playerId}", out PixelCharacter pc, out Vector3 anchorOffset);
                visual = new RemoteGhostVisual { Go = go, Pc = pc, LastAnim = null, AnchorOffset = anchorOffset };
                remoteVisuals[playerId] = visual;
                Logger.LogInfo($"MeshGhost: real remote ghost visual created for {playerId} (step 6.4/6.5+).");
            }

            visual.Go.SetActive(true);
            visual.Go.transform.position = new Vector3(state.Position[0], state.Position[1], 0f)
                + visual.AnchorOffset + RemoteVisualTestOffset;

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
        }

        private void DespawnRemoteGhost(string playerId)
        {
            if (remoteVisuals.TryGetValue(playerId, out RemoteGhostVisual visual) && visual.Go != null)
            {
                visual.Go.SetActive(false);
            }
        }

        private void Awake()
        {
            Logger.LogInfo($"{PluginName} v{PluginVersion} loaded (Phase 6 step 6.1 hello-world).");
            bridge = new BridgeClient(BridgeHost, BridgePort);
        }

        private void Update()
        {
            timeSinceLastLog += Time.deltaTime;

            // EventManager.Instance / mainCharacter / WorldManager.Instance can all be null
            // outside a real play session (main menu, loading) -- a null read must not crash
            // the plugin, per CLAUDE.md's "a wrong read returns a plausible number instead of
            // crashing" standard applied to a missing reference instead of a bad address.
            CharacterBase player = EventManager.Instance != null ? EventManager.Instance.mainCharacter : null;
            cloneTemplate = (player != null && player.t != null) ? player : cloneTemplate;

            bridge.DrainLogsInto(msg => Logger.LogInfo(msg));
            bridge.TryConnect();
            bridge.SendHelloIfNeeded(GameId);
            bridge.DrainInto(UpsertRemoteGhost, DespawnRemoteGhost);

            if (player == null || player.t == null)
            {
                if (hadPlayerLastFrame)
                {
                    Logger.LogInfo("MeshGhost: no local player yet (not in a play session).");
                    hadPlayerLastFrame = false;
                    timeSinceLastLog = 0f;
                }
                if (ghost != null)
                {
                    ghost.SetActive(false);
                }
                // PROTOCOL.md: send local_state every frame even when there's nothing to send.
                bridge.SendLocalState(null);
                return;
            }

            // A scene unload (area transition) can destroy the ghost GameObject along with
            // everything else in that scene -- recreate lazily rather than assuming it survives.
            if (ghost == null)
            {
                ghost = CreatePlaceholderGhost("MeshGhostPlaceholder", LocalGhostColor);
                Logger.LogInfo("MeshGhost: placeholder ghost created (step 6.3).");
            }
            ghost.SetActive(true);
            ghost.transform.position = player.t.position + GhostOffset;

            Vector3 pos = player.t.position;
            byte area = WorldManager.Instance != null ? WorldManager.Instance.Area : (byte)255;

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
            });

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
