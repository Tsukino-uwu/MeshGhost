using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace MeshGhostTevi
{
    // The adapter side of the bridge: NDJSON over loopback TCP, local_state out, render_remote and despawn_remote in.
    // Connect and read run on a background thread because NetworkStream.Read blocks and Unity's main thread must not;
    // sends are small loopback writes straight from Update() on the main thread.
    public sealed class BridgeClient
    {
        public sealed class RemoteState
        {
            public string AreaId;
            public float[] Position;
            public string Orientation;
            public string Anim;

            // Room-grid coordinates for the map marker. Null means absent from this message, never room 0,0.
            public int? RoomX;
            public int? RoomY;

            // Which afterimage trail the game's own decision spawns: 0 or null none, 1 a slide, a quickdrop or any
            // SetTrail call, 2 dodge.
            public int? TrailMode;
            // Mode 1's own parameters: anything in the game may call SetTrail with its own rate, decay, colour, order.
            public float? TrailRate;
            public float? TrailDecay;
            public int? TrailRgba;
            public int? TrailOrder;
            public bool? TrailHaveEffect;

            // A one-shot pooled effect, as a monotonic counter plus its CommonEffectsPooler index. A counter, not a
            // flag: on a latest-wins plane a flag can be missed between two frames, and a counter cannot double-fire.
            public int? VfxSeq;
            public int? VfxEffect;

            // Facing when the effect fired, not when it renders: the attack can turn mid-move.
            public bool? VfxFacingLeft;

            // Seconds of hitstop the peer is in: it freezes the attacker's animation, so it freezes the ghost's
            // Animator, never the watcher's game.
            public float? TempPause;

            // Where in the clip the peer is, 0..1. Without it the ghost drifts out of phase, so a hitstop freezes the
            // wrong pose, and a repeated identical clip never replays because Anim never changes.
            public float? AnimTime;

            // The weapon layer's strobe colour, packed 0xAARRGGBB, 0 or absent for plain white. The decision travels,
            // not the frames: the strobe sampled through the state stream would alias, so the ghost strobes locally.
            public int? WeaponRgba;

            // One row per orb the peer's game shows, read off its OrbBall: root-relative offsets, and sprites as
            // indices into the game's own orb tables (-1 hidden, -2 not a table sprite).
            public float[][] Orbs;

            // One row per summoned Celia or Sable, read off its sprite rig. Absolute positions, since a summon stands
            // still while the peer moves; the controller name lets the watcher show the peer's skin, not its own.
            public object[][] Summons;

            // The boost shield around a summon and the platforms under it, while up or animating. Absolute positions;
            // colours travel as 8-hex-digit strings to survive the float-only number path.
            public object[] Shield;
            public object[][] Platforms;

            // Projectiles, spawn-and-fly: one row per birth of a visible bullet the peer owns, repeated for a short
            // window so a lossy sample still carries it; the receiver dedupes on seq and flies the bullet itself.
            public object[][] Bullets;
            // Seqs of bullets that died early (a wall, a hit), over the same window.
            public float[] BulletDeaths;
            // x,y pairs, in BulletDeaths' order: where each bullet stopped.
            public float[] BulletDeathPos;
            // seq,flags pairs for bullets whose flags changed after birth.
            public float[] BulletFlagUpdates;
            // Muzzle flashes at the orb, not tied to a bullet.
            public object[][] Flashes;

            // The flash of an orbitar turning into its summon: a one-shot, counter-deduped like the VFX impulse.
            // OrbFxWhite says which of the game's two pooled flashes it was.
            public int? OrbFxSeq;
            public int? OrbFxOrb;
            public bool? OrbFxWhite;
        }

        private readonly string host;

        // A core serves exactly one adapter, so two games on one machine need two cores: the walk covers basePort ..
        // basePort + BridgePortCount - 1. The range matches the other three adapters, and preflight checks they agree.
        public const int BridgePortCount = 8;

        private readonly int basePort;
        private int walkOffset;

        // The port of the live connection, as opposed to CurrentPort, the walk's cursor: DrainInto handles a reject
        // frames after it arrived, when the cursor may have moved, so a received message names its port from this.
        private volatile int connectedPort;

        // A port whose core answered busy is a live core that is not ours; re-dialling it every two seconds is noise.
        private static readonly TimeSpan BusyPortCooldown = TimeSpan.FromSeconds(10);

        // How long to stay on a core that says it cannot reach the relay. That core is fine: walking on would cool
        // every port in turn and, with autostart, spawn cores nobody can use.
        private static readonly TimeSpan RelayDownBackoff = TimeSpan.FromSeconds(10);

        // Until this passes the walk does not advance and no port is cooled: there is nothing to walk to.
        private DateTime relayDownUntil = DateTime.MinValue;
        private readonly ConcurrentDictionary<int, DateTime> portCooldownUntil =
            new ConcurrentDictionary<int, DateTime>();

        // Consecutive refused dials before the walk leaves a port. Not one: a cold start refuses until our own core
        // binds, and this many at ReconnectInterval outlast CoreLauncher's spawn cooldown plus a bind.
        private const int RefusalsBeforeWalking = 4;
        private readonly ConcurrentDictionary<int, int> portRefusals =
            new ConcurrentDictionary<int, int>();

        // Silence is not acceptance: a listener that never answers hello is likelier an unrelated program than a core.
        private static readonly TimeSpan HelloAnswerTimeout = TimeSpan.FromSeconds(1.5);
        private DateTime helloSentAt = DateTime.MinValue;

        // The answer is read by DrainInto on the main thread, so a wall-clock deadline alone can expire against an
        // answer that arrived unread: the hello timeout also needs this many drains since the hello went out.
        private const int MinDrainsBeforeHelloTimeout = 20;
        private int drainsSinceHello;

        // Bridge message types this adapter knowingly ignores, so the "not acted on" line is written once per run.
        private readonly HashSet<string> noOpMessagesLogged = new HashSet<string>();

        // Set by bridge_ready, the answer to our hello; SendLocalState waits on it. Cleared on every fresh connection.
        private volatile bool bridgeReady;

        private readonly ConcurrentQueue<string> incoming = new ConcurrentQueue<string>();

        // The background thread's log lines, written on the main thread: BepInEx's logger is not known thread-safe.
        private readonly ConcurrentQueue<string> pendingLogs = new ConcurrentQueue<string>();

        private volatile bool connected;
        // Set on every fresh connection, cleared once SendHelloIfNeeded sends: a hello is per connection.
        private volatile bool needsHello;
        private TcpClient client;
        private NetworkStream stream;
        private DateTime lastConnectAttempt = DateTime.MinValue;
        private static readonly TimeSpan ReconnectInterval = TimeSpan.FromSeconds(2);

        // Bumped before each dial and by Disconnect. A reader's finally clears connected/stream/client only if its own
        // generation is still current, so an old thread still blocked in Read cannot null out a newer connection.
        private int connectionGeneration;

        public bool IsConnected => connected;

        public BridgeClient(string host, int port)
        {
            this.host = host;
            this.basePort = port;
        }

        // The walk's cursor: the port dialled next, and the one CoreLauncher starts a core on.
        public int CurrentPort => basePort + walkOffset;
        // The last port whose core answered busy (another game is attached), 0 until one does. CoreLauncher compares
        // it with the port it spawned on: that, and only that, is the signal its child now serves another game.
        public volatile int LastBusyPort;

        // True once the core has answered our hello with bridge_ready; no local_state goes out before it.
        public bool IsReady => connected && bridgeReady;

        private void Log(string message)
        {
            pendingLogs.Enqueue(message);
        }

        // Once per frame, on the main thread: writes what the background thread queued.
        public void DrainLogsInto(Action<string> logger)
        {
            while (pendingLogs.TryDequeue(out string message))
            {
                logger(message);
            }
        }

        // Once per frame, on the main thread. Non-blocking: starts a background dial at most every ReconnectInterval.
        public void TryConnect()
        {
            DateTime now = DateTime.UtcNow;

            if (connected)
            {
                // Connected but never answered: not a core, or not one that wants us, so walk on.
                if (!bridgeReady && helloSentAt != DateTime.MinValue &&
                    now - helloSentAt >= HelloAnswerTimeout &&
                    drainsSinceHello >= MinDrainsBeforeHelloTimeout)
                {
                    int silent = connectedPort;
                    Log($"MeshGhost: bridge port {silent} accepted a connection but never answered " +
                        $"hello within {HelloAnswerTimeout.TotalSeconds:0.#}s -- treating it as not a " +
                        "core and walking on.");
                    portCooldownUntil[silent] = now + BusyPortCooldown;
                    Disconnect();
                    AdvanceWalkPast(silent);
                }
                return;
            }
            if (now - lastConnectAttempt < ReconnectInterval)
            {
                return;
            }
            lastConnectAttempt = now;

            // Move off a dead port before the cooldown scan below, so the scan starts from the next port this tick.
            if (portRefusals.TryGetValue(CurrentPort, out int refusals) && refusals >= RefusalsBeforeWalking)
            {
                int dead = CurrentPort;
                portRefusals[dead] = 0;
                AdvanceWalkPast(dead);
                Log($"MeshGhost: nothing has answered on bridge port {dead} in {refusals} attempts " +
                    $"-- walking on to {CurrentPort}.");
            }

            // A core said its relay is unreachable: no walking, cooling or dialling until the backoff passes.
            lock (portCooldownUntil)
            {
                if (now < relayDownUntil)
                {
                    return;
                }
            }

            // Skip cooling ports, unless all are: a cooldown is an optimisation, never a reason to stop trying.
            for (int tried = 0; tried < BridgePortCount; tried++)
            {
                if (!portCooldownUntil.TryGetValue(CurrentPort, out DateTime until) || now >= until)
                {
                    break;
                }
                AdvanceWalk();
            }

            int generation = Interlocked.Increment(ref connectionGeneration);
            int dialPort = CurrentPort;
            var thread = new Thread(() => ConnectAndReadLoop(generation, dialPort)) { IsBackground = true };
            thread.Start();
        }

        // One step from the cursor, for scanning past cooled ports, where no specific port is implicated.
        private void AdvanceWalk()
        {
            walkOffset = (walkOffset + 1) % BridgePortCount;
        }

        // Moves the cursor just past the port that refused or went silent, not one step from wherever the cursor sits:
        // those differ because a refusal is handled frames after it arrived.
        private void AdvanceWalkPast(int port)
        {
            int offset = port - basePort;
            if (offset < 0 || offset >= BridgePortCount)
            {
                // Out of range should be impossible; take one step rather than compute a nonsense cursor.
                walkOffset = (walkOffset + 1) % BridgePortCount;
                return;
            }
            walkOffset = (offset + 1) % BridgePortCount;
        }

        // The longest partial line held before deciding the core is not speaking NDJSON. Above protocol.MaxLineBytes on
        // purpose: render_remote re-wraps a peer's state line of up to 4095 bytes, so a core line can be longer.
        private const int MaxLineChars = 16 * 1024;

        private void ConnectAndReadLoop(int generation, int dialPort)
        {
            TcpClient c = null;
            bool establishedThisDial = false;
            try
            {
                c = new TcpClient();
                // Nagle off: the bridge writes one small line per frame, and Nagle holds each until the last is acked.
                c.NoDelay = true;
                // Writes happen on Unity's main thread and .NET's default SendTimeout is infinite, so a core that stops
                // reading would freeze the game. A timeout throws into the catch below, which redials: a frame's state
                // is worthless long before two seconds, since the next frame restates it.
                c.SendTimeout = 2000;
                c.Connect(host, dialPort);
                if (generation != connectionGeneration)
                {
                    // Superseded by a newer dial while this one connected: don't publish it.
                    c.Close();
                    return;
                }
                // The per-connection state is reset before connected is published: the main thread ticks
                // independently, and a tick in the gap would see a fresh connection wearing the last one's flags.
                needsHello = true;
                bridgeReady = false;
                helloSentAt = DateTime.MinValue;
                drainsSinceHello = 0;
                client = c;
                stream = c.GetStream();
                connected = true;
                establishedThisDial = true;
                portRefusals[dialPort] = 0;
                // No hello from here: NetworkStream is not safe for concurrent writes, so SendHelloIfNeeded sends it.
                // A dead session's queued lines must go, or Plugin.Update's drain recreates a ghost it just despawned.
                DiscardQueuedMessages();
                connectedPort = dialPort;
                Log($"MeshGhost: connected to bridge at {host}:{dialPort}.");

                var buffer = new StringBuilder();
                var readBuf = new byte[4096];
                var charBuf = new char[4096];
                // This connection's own stream, never the field, which the next dial reassigns: a reader that has not
                // seen its socket die would otherwise split the new connection's bytes with the new reader.
                var myStream = c.GetStream();
                // A decoder held across reads: decoding per chunk turns a multi-byte character split across a read into
                // U+FFFD, and the line stays valid JSON, so a non-ASCII anim or area_id silently changes.
                var decoder = Encoding.UTF8.GetDecoder();
                int n;
                while ((n = myStream.Read(readBuf, 0, readBuf.Length)) > 0)
                {
                    int chars = decoder.GetChars(readBuf, 0, n, charBuf, 0);
                    buffer.Append(charBuf, 0, chars);
                    int newlineIndex;
                    while ((newlineIndex = IndexOfNewline(buffer)) >= 0)
                    {
                        string line = buffer.ToString(0, newlineIndex).TrimEnd('\r');
                        buffer.Remove(0, newlineIndex + 1);
                        if (line.Length > 0)
                        {
                            incoming.Enqueue(line);
                        }
                    }
                    // Bounded, or a core that never sends a newline grows this until the game runs out of memory.
                    if (buffer.Length > MaxLineChars)
                    {
                        Log($"MeshGhost: bridge buffered {buffer.Length} characters with no " +
                            "newline -- dropping this connection rather than growing without bound.");
                        break;
                    }
                }
            }
            catch (Exception e)
            {
                // The port belongs in this line: without it a stuck cursor and an empty range log the same.
                Log($"MeshGhost: bridge connection ended on port {dialPort}: {e.Message}");
                // Only a dial that never connected counts: a connection that later dropped says nothing about the port.
                if (!establishedThisDial)
                {
                    portRefusals.AddOrUpdate(dialPort, 1, (_, prev) => prev + 1);
                }
            }
            finally
            {
                try { c?.Close(); } catch (Exception) { /* already ending; nothing to do */ }
                if (generation == connectionGeneration)
                {
                    connected = false;
                    stream = null;
                    client = null;
                }
            }
        }

        // A peer's float bound for the Animator: Newtonsoft's float cast turns "NaN"/"Infinity" and out-of-range
        // doubles into non-finite values without throwing, and a NaN freezes that ghost's Animator. Treated as absent.
        private static float? FiniteOrNull(float? v)
        {
            return v.HasValue && !float.IsNaN(v.Value) && !float.IsInfinity(v.Value) ? v : null;
        }

        // A normalised phase: finite and within 0..1, else absent. The sender wraps its own value, so anything outside
        // is a peer's invention; refused rather than clamped, because a clamp is a phase the peer never sent.
        private static float? UnitOrNull(float? v)
        {
            float? f = FiniteOrNull(v);
            return f.HasValue && f.Value >= 0f && f.Value <= 1f ? f : null;
        }

        // A peer's enum ordinal, as a float off the wire: the value when this build's enum defines it, else -1.
        // Enum.IsDefined throws on a value not boxed as the enum's own type, and the game's bullet enums are narrower
        // than int. Here, not in Plugin.cs, so the harness can reach it.
        public static int DefinedOrdinalOrMinusOne(Type enumType, float value)
        {
            if (float.IsNaN(value) || float.IsInfinity(value) || value != Math.Floor(value)) return -1;
            double min, max;
            switch (Type.GetTypeCode(Enum.GetUnderlyingType(enumType)))
            {
                case TypeCode.Byte: min = byte.MinValue; max = byte.MaxValue; break;
                case TypeCode.SByte: min = sbyte.MinValue; max = sbyte.MaxValue; break;
                case TypeCode.Int16: min = short.MinValue; max = short.MaxValue; break;
                case TypeCode.UInt16: min = ushort.MinValue; max = ushort.MaxValue; break;
                case TypeCode.Int32: min = int.MinValue; max = int.MaxValue; break;
                default: return -1; // no TEVI enum this is used on is wider; refuse rather than guess
            }
            if (value < min || value > max) return -1;
            int ordinal = (int)value;
            return Enum.IsDefined(enumType, Enum.ToObject(enumType, ordinal)) ? ordinal : -1;
        }

        // The position reaches transform.position and Vector3.Distance, where a NaN spreads into the physics state of
        // whatever it touches. Refused whole: null is already the "no position" case, and half of one is meaningless.
        private static float[] FinitePositionOrNull(float[] p)
        {
            if (p == null)
            {
                return null;
            }
            for (int i = 0; i < p.Length; i++)
            {
                if (float.IsNaN(p[i]) || float.IsInfinity(p[i]))
                {
                    return null;
                }
            }
            return p;
        }

        private static int IndexOfNewline(StringBuilder sb)
        {
            for (int i = 0; i < sb.Length; i++)
            {
                if (sb[i] == '\n')
                {
                    return i;
                }
            }
            return -1;
        }

        // Which bridge session this is: every dial and every Disconnect bumps it. Plugin.Update drops the ghosts it
        // built when it changes, because despawn_remote arrives over the very connection that just died.
        public int SessionEpoch => Interlocked.CompareExchange(ref connectionGeneration, 0, 0);

        // Public because the epoch changes when a dial starts, not when it completes: Plugin.Update clears the queue
        // itself when it despawns for a new session, or the dead session's leftovers recreate what it removed.
        public void DiscardQueuedMessages()
        {
            while (incoming.TryDequeue(out _))
            {
            }
        }

        // The adapter leaving on purpose (a main menu return, a quit, or a port that never answered). The core closes
        // its relay connection in response, which the relay turns into a real leave; TryConnect redials later.
        public void Disconnect()
        {
            Interlocked.Increment(ref connectionGeneration);
            DiscardQueuedMessages();
            TcpClient c = client;
            connected = false;
            client = null;
            stream = null;
            try
            {
                c?.Close();
            }
            catch (Exception e)
            {
                Log($"MeshGhost: error closing bridge connection: {e.Message}");
            }
        }

        // Once per frame, on the main thread, before SendLocalState: the hello must be a connection's first message. A
        // no-op once sent for this connection, or before one exists.
        public void SendHelloIfNeeded(string gameId, string gameVersion)
        {
            if (!needsHello || !connected || stream == null)
            {
                return;
            }
            needsHello = false;

            string json = JsonConvert.SerializeObject(new
            {
                type = "hello",
                // min_protocol_version is this adapter's floor: raised by hand, never automatically.
                payload = new { game_id = gameId, game_version = gameVersion, min_protocol_version = 2 },
            });

            try
            {
                byte[] bytes = Encoding.UTF8.GetBytes(json + "\n");
                stream.Write(bytes, 0, bytes.Length);
                // The hello timeout runs from the send: a core slow to accept is fine, a silent one is not.
                helloSentAt = DateTime.UtcNow;
                drainsSinceHello = 0;
            }
            catch (Exception e)
            {
                Log($"MeshGhost: bridge send failed: {e.Message}");
                connected = false;
            }
        }

        // A null state means the local player is not renderable, and is still sent every frame. player_id, seq and
        // timestamp are stamped by the core, never sent by the adapter.
        public void SendLocalState(RemoteState state)
        {
            if (!connected || stream == null)
            {
                return;
            }
            // Nothing before bridge_ready: a core that has not accepted us has nowhere to forward these, and the next
            // frame restates a fresher state anyway.
            if (!bridgeReady)
            {
                return;
            }

            // A dictionary, not an anonymous type: each extra is independently present or absent.
            Dictionary<string, object> extrasMap = null;
            if (state != null)
            {
                if (state.RoomX.HasValue && state.RoomY.HasValue)
                {
                    extrasMap = new Dictionary<string, object>
                    {
                        { "room_x", state.RoomX.Value },
                        { "room_y", state.RoomY.Value },
                    };
                }
                // Only while a trail runs, so absent and no trail are one state and an idle frame stays small.
                if (state.TrailMode.HasValue && state.TrailMode.Value > 0)
                {
                    extrasMap = extrasMap ?? new Dictionary<string, object>();
                    extrasMap["trail"] = state.TrailMode.Value;
                    if (state.TrailRate.HasValue) extrasMap["trail_rate"] = state.TrailRate.Value;
                    if (state.TrailDecay.HasValue) extrasMap["trail_decay"] = state.TrailDecay.Value;
                    if (state.TrailRgba.HasValue) extrasMap["trail_rgba"] = state.TrailRgba.Value;
                    if (state.TrailOrder.HasValue) extrasMap["trail_order"] = state.TrailOrder.Value;
                    if (state.TrailHaveEffect.HasValue) extrasMap["trail_fx"] = state.TrailHaveEffect.Value;
                }
                if (state.WeaponRgba.HasValue && state.WeaponRgba.Value != 0)
                {
                    extrasMap = extrasMap ?? new Dictionary<string, object>();
                    extrasMap["weapon_rgba"] = state.WeaponRgba.Value;
                }
                if (state.AnimTime.HasValue)
                {
                    extrasMap = extrasMap ?? new Dictionary<string, object>();
                    extrasMap["anim_t"] = state.AnimTime.Value;
                }
                if (state.TempPause.HasValue && state.TempPause.Value > 0f)
                {
                    extrasMap = extrasMap ?? new Dictionary<string, object>();
                    extrasMap["pause"] = state.TempPause.Value;
                }
                // Sent every frame once non-zero, not only when it changes: the receiver dedupes on the counter, so
                // repeating it is what makes a dropped frame harmless.
                if (state.VfxSeq.HasValue && state.VfxSeq.Value > 0)
                {
                    extrasMap = extrasMap ?? new Dictionary<string, object>();
                    extrasMap["vfx_seq"] = state.VfxSeq.Value;
                    extrasMap["vfx_id"] = state.VfxEffect ?? -1;
                    extrasMap["vfx_left"] = state.VfxFacingLeft ?? false;
                }
                if (state.Orbs != null && state.Orbs.Length > 0)
                {
                    extrasMap = extrasMap ?? new Dictionary<string, object>();
                    extrasMap["orbs"] = state.Orbs;
                }
                if (state.Summons != null && state.Summons.Length > 0)
                {
                    extrasMap = extrasMap ?? new Dictionary<string, object>();
                    extrasMap["summons"] = state.Summons;
                }
                if (state.Bullets != null && state.Bullets.Length > 0)
                {
                    extrasMap = extrasMap ?? new Dictionary<string, object>();
                    extrasMap["bul"] = state.Bullets;
                }
                if (state.Flashes != null && state.Flashes.Length > 0)
                {
                    extrasMap = extrasMap ?? new Dictionary<string, object>();
                    extrasMap["flash"] = state.Flashes;
                }
                if (state.BulletDeaths != null && state.BulletDeaths.Length > 0)
                {
                    extrasMap = extrasMap ?? new Dictionary<string, object>();
                    extrasMap["buld"] = state.BulletDeaths;
                    if (state.BulletDeathPos != null && state.BulletDeathPos.Length > 0) extrasMap["buldp"] = state.BulletDeathPos;
                }
                if (state.BulletFlagUpdates != null && state.BulletFlagUpdates.Length > 0)
                {
                    extrasMap = extrasMap ?? new Dictionary<string, object>();
                    extrasMap["bulf"] = state.BulletFlagUpdates;
                }
                if (state.Shield != null && state.Shield.Length > 0)
                {
                    extrasMap = extrasMap ?? new Dictionary<string, object>();
                    extrasMap["shield"] = state.Shield;
                }
                if (state.Platforms != null && state.Platforms.Length > 0)
                {
                    extrasMap = extrasMap ?? new Dictionary<string, object>();
                    extrasMap["plats"] = state.Platforms;
                }
                if (state.OrbFxSeq.HasValue && state.OrbFxSeq.Value > 0)
                {
                    extrasMap = extrasMap ?? new Dictionary<string, object>();
                    extrasMap["orbfx_seq"] = state.OrbFxSeq.Value;
                    extrasMap["orbfx_orb"] = state.OrbFxOrb ?? 0;
                    extrasMap["orbfx_white"] = state.OrbFxWhite ?? false;
                }
            }
            // The core drops a state whose extras pass its 1024-byte cap whole, freezing the ghost. Bullets are the one
            // elastic field, so they go first when a frame is over.
            if (extrasMap != null && (extrasMap.ContainsKey("bul") || extrasMap.ContainsKey("buld")))
            {
                int len = JsonConvert.SerializeObject(extrasMap).Length;
                if (len > ExtrasSoftCap)
                {
                    // Oldest births first: the newest are the ones a receiver has not seen yet.
                    object[][] bul = extrasMap.ContainsKey("bul") ? extrasMap["bul"] as object[][] : null;
                    while (bul != null && bul.Length > 0 && JsonConvert.SerializeObject(extrasMap).Length > ExtrasSoftCap)
                    {
                        var trimmed = new object[bul.Length - 1][];
                        System.Array.Copy(bul, 1, trimmed, 0, trimmed.Length);
                        bul = trimmed;
                        if (bul.Length == 0) extrasMap.Remove("bul"); else extrasMap["bul"] = bul;
                    }
                    if (JsonConvert.SerializeObject(extrasMap).Length > ExtrasSoftCap)
                    {
                        extrasMap.Remove("buld");
                        extrasMap.Remove("buldp");
                    }
                    if (!warnedExtrasCap)
                    {
                        warnedExtrasCap = true;
                        Log($"MeshGhost: extras hit {len} bytes this frame; bullets dropped from it to stay under the core's cap (said once).");
                    }
                }
            }
            object extras = extrasMap;
            object payloadState = state == null
                ? null
                : (object)new
                {
                    area_id = state.AreaId,
                    position = state.Position,
                    orientation = state.Orientation,
                    anim = state.Anim,
                    extras,
                };

            string json = JsonConvert.SerializeObject(new
            {
                type = "local_state",
                payload = new { state = payloadState },
            });

            try
            {
                byte[] bytes = Encoding.UTF8.GetBytes(json + "\n");
                stream.Write(bytes, 0, bytes.Length);
            }
            catch (Exception e)
            {
                Log($"MeshGhost: bridge send failed: {e.Message}");
                connected = false;
            }
        }

        // A malformed field drops that field, never the whole render_remote: one bad extra must not blank the ghost.
        private static float[][] ParseOrbs(JToken token)
        {
            if (token == null || token.Type != JTokenType.Array)
            {
                return null;
            }
            try
            {
                return token.ToObject<float[][]>();
            }
            catch (Exception)
            {
                return null;
            }
        }

        private static float[] ParseFloats(JToken token)
        {
            if (token == null || token.Type != JTokenType.Array)
            {
                return null;
            }
            try
            {
                return token.ToObject<float[]>();
            }
            catch (Exception)
            {
                return null;
            }
        }

        private static object[] ParseRow(JToken token)
        {
            if (token == null || token.Type != JTokenType.Array)
            {
                return null;
            }
            object[][] rows = ParseRows(new JArray(token));
            return rows != null && rows.Length == 1 ? rows[0] : null;
        }

        // Mixed rows: numbers come out as float, strings as string, bools as bool, anything else as null.
        private static object[][] ParseRows(JToken token)
        {
            if (token == null || token.Type != JTokenType.Array)
            {
                return null;
            }
            try
            {
                var rows = new List<object[]>();
                foreach (JToken rowToken in (JArray)token)
                {
                    if (rowToken.Type != JTokenType.Array)
                    {
                        continue;
                    }
                    var row = new List<object>();
                    foreach (JToken cell in (JArray)rowToken)
                    {
                        switch (cell.Type)
                        {
                            case JTokenType.String: row.Add((string)cell); break;
                            case JTokenType.Integer:
                            case JTokenType.Float: row.Add((float)cell); break;
                            case JTokenType.Boolean: row.Add((bool)cell); break;
                            default: row.Add(null); break;
                        }
                    }
                    rows.Add(row.ToArray());
                }
                return rows.ToArray();
            }
            catch (Exception)
            {
                return null;
            }
        }

        // Once per frame, on the main thread: dispatches every buffered line. A bad line is logged and skipped, never
        // thrown, so one line cannot take down the plugin.
        public void DrainInto(Action<string, RemoteState> onRenderRemote, Action<string> onDespawnRemote)
        {
            // Counted whether or not anything was queued: it means the main thread had a chance to read an answer.
            if (drainsSinceHello < int.MaxValue)
            {
                drainsSinceHello++;
            }

            while (incoming.TryDequeue(out string line))
            {
                // Names which side threw: the catch wraps the parse and the callbacks, which are Unity code, so a fault
                // in the ghost update must not be logged as a bad bridge message.
                string stage = "parsing the line";
                try
                {
                    var env = JsonConvert.DeserializeObject<JObject>(line);
                    if (env == null || !env.TryGetValue("type", out JToken typeToken))
                    {
                        Log("MeshGhost: bad bridge message ignored: missing 'type'.");
                        continue;
                    }
                    string type = (string)typeToken;
                    env.TryGetValue("payload", out JToken payloadToken);
                    JObject payload = payloadToken as JObject;

                    switch (type)
                    {
                        case "render_remote":
                        {
                            if (payload == null || !payload.TryGetValue("player_id", out JToken playerIdToken)
                                || !(payload["state"] is JObject st))
                            {
                                Log("MeshGhost: bad render_remote ignored: missing player_id/state.");
                                break;
                            }
                            string playerId = (string)playerIdToken;
                            JObject extras = st["extras"] as JObject;
                            var remote = new RemoteState
                            {
                                AreaId = (string)st["area_id"],
                                Position = FinitePositionOrNull(st["position"]?.ToObject<float[]>()),
                                Orientation = (string)st["orientation"],
                                Anim = (string)st["anim"],
                                RoomX = (int?)extras?["room_x"],
                                RoomY = (int?)extras?["room_y"],
                                TrailMode = (int?)extras?["trail"],
                                TrailRate = FiniteOrNull((float?)extras?["trail_rate"]),
                                TrailDecay = FiniteOrNull((float?)extras?["trail_decay"]),
                                TrailRgba = (int?)extras?["trail_rgba"],
                                TrailOrder = (int?)extras?["trail_order"],
                                TrailHaveEffect = (bool?)extras?["trail_fx"],
                                WeaponRgba = (int?)extras?["weapon_rgba"],
                                TempPause = FiniteOrNull((float?)extras?["pause"]),
                                AnimTime = UnitOrNull((float?)extras?["anim_t"]),
                                VfxSeq = (int?)extras?["vfx_seq"],
                                VfxEffect = (int?)extras?["vfx_id"],
                                VfxFacingLeft = (bool?)extras?["vfx_left"],
                                Orbs = ParseOrbs(extras?["orbs"]),
                                Summons = ParseRows(extras?["summons"]),
                                Shield = ParseRow(extras?["shield"]),
                                Bullets = ParseRows(extras?["bul"]),
                                BulletDeaths = ParseFloats(extras?["buld"]),
                                BulletDeathPos = ParseFloats(extras?["buldp"]),
                                BulletFlagUpdates = ParseFloats(extras?["bulf"]),
                                Flashes = ParseRows(extras?["flash"]),
                                Platforms = ParseRows(extras?["plats"]),
                                OrbFxSeq = (int?)extras?["orbfx_seq"],
                                OrbFxOrb = (int?)extras?["orbfx_orb"],
                                OrbFxWhite = (bool?)extras?["orbfx_white"],
                            };
                            stage = "the adapter's render_remote handler (Unity code, not the bridge)";
                            onRenderRemote(playerId, remote);
                            break;
                        }
                        case "despawn_remote":
                        {
                            if (payload == null || !payload.TryGetValue("player_id", out JToken playerIdToken))
                            {
                                Log("MeshGhost: bad despawn_remote ignored: missing player_id.");
                                break;
                            }
                            string playerId = (string)playerIdToken;
                            stage = "the adapter's despawn_remote handler (Unity code, not the bridge)";
                            onDespawnRemote(playerId);
                            break;
                        }
                        case "bridge_ready":
                            bridgeReady = true;
                            Log($"MeshGhost: bridge ready on port {connectedPort} -- the core " +
                                "accepted this adapter.");
                            break;
                        case "reject":
                        {
                            string reason = "unspecified";
                            if (payload != null && payload.TryGetValue("reason", out JToken reasonToken))
                            {
                                reason = (string)reasonToken;
                            }
                            int refusedPort = connectedPort;
                            // Only busy and already_serving walk on; any other code means this core is fine and
                            // something upstream is not, and walking would cool every port in turn. Never match the
                            // reason instead: every permanent refusal's reason contains "relay" and busy's does not.
                            // An absent code is an older core, and only then is the reason searched.
                            string code = null;
                            if (payload != null && payload.TryGetValue("code", out JToken codeToken))
                            {
                                code = (string)codeToken;
                            }
                            bool retryable = false;
                            if (payload != null && payload.TryGetValue("retryable", out JToken retryableToken))
                            {
                                retryable = retryableToken.Type == JTokenType.Boolean && (bool)retryableToken;
                            }
                            bool walkOn = string.IsNullOrEmpty(code)
                                ? !(reason != null && reason.IndexOf("relay", StringComparison.OrdinalIgnoreCase) >= 0)
                                : (code == "busy" || code == "already_serving");
                            if (!walkOn)
                            {
                                lock (portCooldownUntil)
                                {
                                    relayDownUntil = DateTime.UtcNow + RelayDownBackoff;
                                }
                                if (!string.IsNullOrEmpty(code) && !retryable)
                                {
                                    Log($"MeshGhost: the core on port {refusedPort} refused this adapter " +
                                        $"PERMANENTLY ({code}: {reason}) -- waiting will NOT fix it; " +
                                        "check the client's config.json.");
                                }
                                else
                                {
                                    Log($"MeshGhost: the core on port {refusedPort} refused this adapter " +
                                        $"({reason}) -- waiting on this core rather than walking; it retries by itself.");
                                }
                                connected = false;
                                break;
                            }
                            portCooldownUntil[refusedPort] = DateTime.UtcNow + BusyPortCooldown;
                            bool isBusy = string.IsNullOrEmpty(code)
                                ? (reason != null && reason.IndexOf("busy", StringComparison.OrdinalIgnoreCase) >= 0)
                                : code == "busy";
                            if (isBusy)
                            {
                                LastBusyPort = refusedPort;
                            }
                            Log($"MeshGhost: the core on port {refusedPort} rejected this adapter " +
                                $"({reason}) -- walking to the next bridge port.");
                            connected = false;
                            AdvanceWalkPast(refusedPort);
                            break;
                        }
                        case "session_policy":
                        case "recording_state":
                        case "remote_name":
                            // Named, or the default would warn per message per peer; logged once each, because an
                            // adapter that does not act on a shared setting says so.
                            //   session_policy  -- a ghost clone has every Collider2D and Rigidbody2D destroyed, so it
                            //                      is never solid whatever the room asks for.
                            //   recording_state -- this game draws no recording indicator.
                            //   remote_name     -- this game draws no nametags.
                            if (noOpMessagesLogged.Add(type))
                            {
                                Log($"MeshGhost: '{type}' received and intentionally not acted on " +
                                    "in TEVI -- see BridgeClient.cs for why. Logged once per run.");
                            }
                            break;
                        default:
                            Log($"MeshGhost: ignoring unknown bridge message type '{type}'.");
                            break;
                    }
                }
                catch (Exception e)
                {
                    // The full trace once per distinct message, then a short line per DrainErrorRepeatInterval at most:
                    // what throws is usually the peer's state, so it throws again next frame.
                    if (loggedTraces.Add(e.Message))
                    {
                        Log($"MeshGhost: failure while {stage}: {e}");
                        lastDrainErrorAt = DateTime.UtcNow;
                    }
                    else if (DateTime.UtcNow - lastDrainErrorAt >= DrainErrorRepeatInterval)
                    {
                        lastDrainErrorAt = DateTime.UtcNow;
                        Log($"MeshGhost: still failing while {stage}: {e.Message}");
                    }
                }
            }
        }

        private readonly HashSet<string> loggedTraces = new HashSet<string>();
        private static readonly TimeSpan DrainErrorRepeatInterval = TimeSpan.FromSeconds(5);
        private DateTime lastDrainErrorAt = DateTime.MinValue;
        private const int ExtrasSoftCap = 1000;
        private bool warnedExtrasCap;
    }
}
