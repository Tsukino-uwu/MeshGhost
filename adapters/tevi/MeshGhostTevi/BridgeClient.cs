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
    // Phase 6, step 6.4/6.5: the adapter side of the bridge wire protocol
    // (internal/bridge/bridge.go), written from adapters/_template/PROTOCOL.md's pseudocode --
    // "local_state" out, "render_remote"/"despawn_remote" in, NDJSON framing, core listens,
    // adapter dials. No handshake, no auth, localhost only, per contract.md.
    //
    // Connect and read happen on a background thread because NetworkStream.Read blocks; Unity's
    // Update() runs on the main thread and must never block on it. Sending is done directly from
    // Update() on the main thread -- small, infrequent, localhost writes, matching the Lua
    // adapter's own "the bridge is localhost, that cost is free" reasoning in contract.md.
    public sealed class BridgeClient
    {
        public sealed class RemoteState
        {
            public string AreaId;
            public float[] Position;
            public string Orientation;
            public string Anim;

            // Room-grid coordinates (TEVI's map is room-based, not continuous-position-based --
            // see agent_docs/phases/phase6.md's 6.7 entry), carried in the wire protocol's
            // free-form "extras" dict (contract.md) rather than a schema change. Null means
            // "not present on this message" (e.g. an older peer, or a state with no room data
            // yet), distinct from a real 0,0 room.
            public int? RoomX;
            public int? RoomY;

            // WHICH afterimage trail this character is currently spawning, as TEVI's own
            // SpriteAnimation decides it: 0 none, 1 the trailcolor trail (slide and quickdrop),
            // 2 the dodge trail. Carried in `extras` for the same reason RoomX/RoomY are -- it is
            // game-specific and the core must never interpret it (contract.md: opaque outside the
            // adapter that produced it).
            //
            // A MODE, not a colour and not a move name. The game keys its own trail off a byte
            // computed each frame from three public values, and mirroring that DECISION is what
            // makes every move using the system work at once instead of one move at a time --
            // see Plugin.ReadTrailMode. Null means "not present on this message", i.e. a peer
            // that predates this field, which must render as no trail rather than as mode 0
            // asserted.
            public int? TrailMode;

            // A ONE-SHOT pooled VFX the game spawned for this character, as a monotonic counter
            // plus which effect it was. A counter rather than a flag because the state plane is
            // latest-wins: a boolean impulse can be missed entirely between two frames, while a
            // counter survives a dropped frame and cannot double-fire on a repeated one. The
            // effect id is an index into the game's own CommonEffectsPooler -- opaque to the core,
            // meaningful only between two TEVI clients, exactly like Anim and TrailMode.
            public int? VfxSeq;
            public int? VfxEffect;

            // Facing AT THE MOMENT the effect fired, not when it is rendered. The attack can be
            // performed while turning, so by the time a peer draws it the character's current
            // facing may already be the other one -- which mirrored the effects onto the wrong
            // side when moving left/right mid-move. An impulse carries its own context.
            public bool? VfxFacingLeft;

            // Seconds of HITSTOP this character's game is currently holding
            // (`GameSystem.GetTempPause()`). Carried because the hitstop is not only feedback to
            // the person swinging: it freezes THEIR animation, so a second real player watching
            // over a network would see a frozen character. We sync the clip NAME, not the clip
            // TIME, so without this the ghost's Animator keeps advancing through a pause the peer
            // is actually holding -- the attack reads as rushed. The watcher's own game is never
            // paused; only the ghost's Animator is.
            public float? TempPause;

            // WHERE IN THE CLIP this character is, 0..1. Anim carries WHICH clip; without this the
            // ghost's Animator starts whenever the name changed and then advances on its own, so
            // the two drift out of phase. That was invisible until the hitstop arrived: freezing
            // the ghost when the peer pauses freezes it at ITS phase, not the peer's, so the hold
            // lands early or late and the star fired at that instant inherits the error.
            // Also what makes a REPEATED identical clip replay: Anim alone cannot express
            // "the same attack again", because the name never changed.
            public float? AnimTime;
        }

        private readonly string host;

        // THE PORT WALK, 2026-08-27. A core serves exactly one adapter, so two games (or two
        // copies of one game) on one machine each need their own -- and before this, TEVI dialled
        // a single fixed port and the second instance silently shared or failed. basePort is the
        // configured start; the walk covers basePort .. basePort + BridgePortCount - 1.
        //
        // The constants match the other three adapters deliberately, and preflight.ps1 checks
        // that they still agree: 7778, eight ports. Shape copied from Pseudoregalia's
        // BridgeClient, which is the version that has been tested live.
        public const int BridgePortCount = 8;

        private readonly int basePort;
        private int walkOffset;

        // The port the LIVE CONNECTION is on, as opposed to CurrentPort, which is where the walk
        // CURSOR sits. They are not the same thing and conflating them was a real bug (fixed
        // 2026-08-27, measured): DrainInto runs on the main thread and handles a `reject` some
        // frames after it arrived, by which time the cursor may have moved on -- so the reject was
        // attributed to the wrong port. That meant the genuinely busy port was never cooled down
        // and innocent free ports were, and the walk churned until a spawn landed somewhere free
        // by luck. Set when a connection is published, read wherever a received message has to
        // name the port it came from.
        private volatile int connectedPort;

        // A port whose core answered "busy" is a live core that simply is not ours; re-dialling it
        // every two seconds is noise. Ten seconds, matching the other adapters' cooldown. Touched
        // from both threads -- the read loop marks a port on reject, TryConnect reads it -- hence
        // the concurrent map.
        private static readonly TimeSpan BusyPortCooldown = TimeSpan.FromSeconds(10);
        private readonly ConcurrentDictionary<int, DateTime> portCooldownUntil =
            new ConcurrentDictionary<int, DateTime>();

        // A port that REFUSES the connection outright -- nothing listening -- also has to release
        // the walk, and until 2026-08-28 nothing did. The walk advanced on a core that answered
        // "busy", and on one that accepted then went silent, but a refusal only logged and left the
        // cursor where it was. That is a DEADLOCK in combination with CoreLauncher, which returns
        // early while the child it spawned is still running: an adapter could own a live core on
        // one port, have its cursor parked on a different, empty one, and neither side could move.
        // The launcher thought its job was done; the walk had nothing to move it. Found live that
        // day, and invisible before it because the adapter's own core had always won the base port,
        // so the cursor never sat anywhere empty.
        //
        // Counted rather than immediate, and that is the whole design of it. A refusal is the
        // NORMAL first thing that happens on a cold start -- the adapter dials before its core has
        // bound -- so advancing on the first one would walk the cursor off the base port every
        // launch and the whole range would creep upward run after run. At ReconnectInterval (2s)
        // this waits ~8s, comfortably past CoreLauncher's 5s spawn cooldown plus a bind, so a core
        // that is merely still starting keeps its port and only a genuinely dead one loses it.
        private const int RefusalsBeforeWalking = 4;
        private readonly ConcurrentDictionary<int, int> portRefusals =
            new ConcurrentDictionary<int, int>();

        // SILENCE IS NOT ACCEPTANCE. Something that accepts a TCP connection and never answers a
        // hello is far more likely an unrelated program holding a port in our range than a core,
        // and committing to it would strand the session with no ghosts and no explanation. 1.5s,
        // the same bound the Lua adapters use (90 frames).
        private static readonly TimeSpan HelloAnswerTimeout = TimeSpan.FromSeconds(1.5);
        private DateTime helloSentAt = DateTime.MinValue;

        // Set when the core answers our hello with bridge_ready; the gate SendLocalState waits on.
        // MUST be cleared on every fresh connection, or a reconnect that misses the ready silences
        // the adapter completely -- which is the hazard the old code's own comment named as the
        // reason this gate had not been closed yet.
        private volatile bool bridgeReady;

        private readonly ConcurrentQueue<string> incoming = new ConcurrentQueue<string>();

        // Log lines from the background connect/read thread are queued, never written directly
        // via a callback into BepInEx's logger from that thread. BepInEx's ManualLogSource isn't
        // documented as safe for concurrent cross-thread calls, and Unity's own API is main-
        // thread-only besides -- DrainLogsInto (called from Update, on the main thread) is the
        // only place these actually get logged.
        private readonly ConcurrentQueue<string> pendingLogs = new ConcurrentQueue<string>();

        private volatile bool connected;
        // Set true whenever ConnectAndReadLoop establishes a fresh connection, cleared once
        // SendHelloIfNeeded actually sends -- a Hello is per-connection, not per-process, since
        // TryConnect/ConnectAndReadLoop can reconnect after a dropped bridge (see the "fresh
        // bridge connection means a fresh core process" reasoning the Lua adapter documents for
        // the same situation).
        private volatile bool needsHello;
        private TcpClient client;
        private NetworkStream stream;
        private DateTime lastConnectAttempt = DateTime.MinValue;
        private static readonly TimeSpan ReconnectInterval = TimeSpan.FromSeconds(2);

        // Bumped by TryConnect before spawning a new ConnectAndReadLoop thread. A stale thread's
        // `finally` compares its own captured generation against the current one before clearing
        // connected/stream/client -- without this, a slow-to-unwind old thread (e.g. blocked in
        // stream.Read on a connection that's already been superseded by a newer TryConnect) can
        // null out a newer, live connection's state after the fact.
        private int connectionGeneration;

        public bool IsConnected => connected;

        public BridgeClient(string host, int port)
        {
            this.host = host;
            this.basePort = port;
        }

        // The port this instance is currently dialling or connected to. Logged, because "which
        // core am I talking to" is the first question a two-instance session asks.
        public int CurrentPort => basePort + walkOffset;

        // True once the core has answered our hello with bridge_ready. Nothing may be sent before
        // this: _template/PROTOCOL.md requires local_state to wait for it.
        public bool IsReady => connected && bridgeReady;

        private void Log(string message)
        {
            pendingLogs.Enqueue(message);
        }

        // Call once per frame from the main thread to actually emit anything the background
        // thread queued since the last call.
        public void DrainLogsInto(Action<string> logger)
        {
            while (pendingLogs.TryDequeue(out string message))
            {
                logger(message);
            }
        }

        // Call once per frame from the main thread. Non-blocking: starts a background connect
        // attempt at most once per ReconnectInterval and returns immediately either way, per
        // PROTOCOL.md's "try to connect (non-blocking, retry next frame on failure)".
        public void TryConnect()
        {
            DateTime now = DateTime.UtcNow;

            if (connected)
            {
                // Connected but never answered: not a core, or not one that wants us. Give up on
                // this port and let the walk move on rather than sitting here forever with no
                // ghosts and nothing in the log saying why.
                if (!bridgeReady && helloSentAt != DateTime.MinValue &&
                    now - helloSentAt >= HelloAnswerTimeout)
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

            // A port that has refused us this many times running has nothing on it. Release the
            // cursor BEFORE the cooldown scan below, so the freed port is a candidate for that
            // scan rather than being reconsidered next tick.
            if (portRefusals.TryGetValue(CurrentPort, out int refusals) && refusals >= RefusalsBeforeWalking)
            {
                int dead = CurrentPort;
                portRefusals[dead] = 0;
                AdvanceWalkPast(dead);
                // Named, because the refusal message itself cannot name it -- see the catch in
                // ConnectAndReadLoop. A walk with no port in the log is what made the 2026-08-27
                // churn so hard to attribute.
                Log($"MeshGhost: nothing has answered on bridge port {dead} in {refusals} attempts " +
                    $"-- walking on to {CurrentPort}.");
            }

            // Skip ports a core has already refused us on, unless every port is cooling down --
            // in which case dial anyway rather than going silent, since a cooldown is an
            // optimisation and never a reason to stop trying.
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

        // One step from the cursor. Correct for scanning PAST cooled-down ports, where the cursor
        // is exactly what is being advanced and no specific port is implicated.
        private void AdvanceWalk()
        {
            walkOffset = (walkOffset + 1) % BridgePortCount;
        }

        // Move the cursor to just past a SPECIFIC port -- the one that refused us or went silent --
        // rather than one step from wherever the cursor happens to sit. Those differ for the same
        // reason connectedPort exists: a refusal is handled frames after it arrived. Advancing from
        // the cursor made the walk's next target arbitrary, which is half of why it churned.
        private void AdvanceWalkPast(int port)
        {
            int offset = port - basePort;
            if (offset < 0 || offset >= BridgePortCount)
            {
                // A port outside our own range should be impossible; treat it as "no information"
                // and take one step rather than computing a nonsense cursor.
                walkOffset = (walkOffset + 1) % BridgePortCount;
                return;
            }
            walkOffset = (offset + 1) % BridgePortCount;
        }

        private void ConnectAndReadLoop(int generation, int dialPort)
        {
            TcpClient c = null;
            bool establishedThisDial = false;
            try
            {
                c = new TcpClient();
                c.Connect(host, dialPort);
                if (generation != connectionGeneration)
                {
                    // Superseded by a newer TryConnect while this one was still dialing --
                    // don't publish this connection as the live one.
                    c.Close();
                    return;
                }
                client = c;
                stream = c.GetStream();
                connected = true;
                establishedThisDial = true;
                // Something answered here, so this port is not dead. Reset rather than decrement:
                // the counter means "consecutive failures", and one success ends the run.
                portRefusals[dialPort] = 0;
                // Not written here: NetworkStream isn't safe for concurrent writes from this
                // background thread and the main thread's SendLocalState, so the actual send is
                // deferred to SendHelloIfNeeded, called from Update() on the main thread, same
                // as every other outbound message.
                needsHello = true;
                // Cleared on EVERY fresh connection. A reconnect that inherited a stale true here
                // would send state to a core that had not accepted it; a reconnect that inherited
                // a stale false and never got another ready would go silent forever. Both are why
                // this gate was left open until now.
                bridgeReady = false;
                helloSentAt = DateTime.MinValue;
                connectedPort = dialPort;
                Log($"MeshGhost: connected to bridge at {host}:{dialPort}.");

                var buffer = new StringBuilder();
                var readBuf = new byte[4096];
                int n;
                while ((n = stream.Read(readBuf, 0, readBuf.Length)) > 0)
                {
                    buffer.Append(Encoding.UTF8.GetString(readBuf, 0, n));
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
                }
            }
            catch (Exception e)
            {
                // The port belongs in this line. Without it the log said only "actively refused"
                // over and over, which cannot distinguish "the cursor is stuck on one dead port"
                // from "the walk is sweeping a range that is genuinely empty" -- and those want
                // opposite responses. That ambiguity is what made the 2026-08-28 deadlock read as
                // a networking problem for several minutes.
                Log($"MeshGhost: bridge connection ended on port {dialPort}: {e.Message}");
                // Only a dial that never got a live connection counts as a refusal. A connection
                // that established and later dropped says nothing about whether the port is dead,
                // and counting it would eventually walk the cursor off a perfectly good core.
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

        // Actively drops the bridge connection -- distinct from a connection failure or the
        // core going away, this is the adapter choosing to leave (returning to TEVI's main
        // menu, confirmed live 2026-08-13 to be a real, detectable transition, unlike the
        // pause menu -- see agent_docs/phases/phase6.md). The core observes this as a bridge
        // disconnect and closes its own relay connection in response (2026-08-13 ADR in
        // architecture.md), which the relay turns into a real Leave for any peer -- the same
        // despawn path a real game-close already took. TryConnect() redials automatically on a
        // later frame once IsConnected is false, the same as any other dropped connection.
        public void Disconnect()
        {
            // Also invalidates any in-flight ConnectAndReadLoop's generation, so if that thread
            // is still dialing or blocked in stream.Read, its eventual finally block won't
            // clobber the state of whatever TryConnect() dials next.
            Interlocked.Increment(ref connectionGeneration);
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

        // Call once per frame from the main thread, before SendLocalState. Must be the first
        // message on a fresh connection -- see internal/bridge.Hello -- so it's sent from here
        // rather than the background connect thread, ahead of any local_state Update() sends
        // this same frame. No-op once already sent for the current connection, or before one
        // exists.
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
                payload = new { game_id = gameId, game_version = gameVersion },
            });

            try
            {
                byte[] bytes = Encoding.UTF8.GetBytes(json + "\n");
                stream.Write(bytes, 0, bytes.Length);
                // Starts the clock the hello-answer timeout measures. Stamped on the SEND,
                // not on the connect: a core slow to accept is fine, one that never answers
                // is not.
                helloSentAt = DateTime.UtcNow;
            }
            catch (Exception e)
            {
                Log($"MeshGhost: bridge send failed: {e.Message}");
                connected = false;
            }
        }

        // "state" is null when the local player isn't in a renderable state (matches
        // get_local_state() returning nil in the contract) -- sent every frame regardless per
        // PROTOCOL.md: "send it anyway". player_id/seq/timestamp are stamped by the core, never
        // sent by the adapter.
        public void SendLocalState(RemoteState state)
        {
            if (!connected || stream == null)
            {
                return;
            }
            // THE SEND GATE, closed 2026-08-27. _template/PROTOCOL.md requires local_state to wait
            // for bridge_ready; TEVI recognised that message from 2026-08-18 and sent anyway, which
            // is entry 5 in BANDAGES.md. Dropping these frames costs nothing: a core that has not
            // accepted us has nowhere to forward them, and the next frame sends a fresher state
            // than the one withheld -- the state plane is latest-wins by contract.
            if (!bridgeReady)
            {
                return;
            }

            // Built as a dictionary rather than another anonymous type: room coords and the trail
            // mode are independently present or absent, and the two-anonymous-types-in-a-ternary
            // shape this replaced would have needed one type per combination.
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
                // Only sent while a trail is actually running. Omitting it while idle keeps the
                // common frame the same size it was, and means "absent" and "no trail" agree
                // rather than being two states a reader has to reconcile.
                if (state.TrailMode.HasValue && state.TrailMode.Value > 0)
                {
                    extrasMap = extrasMap ?? new Dictionary<string, object>();
                    extrasMap["trail"] = state.TrailMode.Value;
                }
                // Sent every frame once non-zero, not only on the frame it changed: the receiver
                // dedupes on the counter, so repeating it is what makes a dropped frame harmless.
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
                if (state.VfxSeq.HasValue && state.VfxSeq.Value > 0)
                {
                    extrasMap = extrasMap ?? new Dictionary<string, object>();
                    extrasMap["vfx_seq"] = state.VfxSeq.Value;
                    extrasMap["vfx_id"] = state.VfxEffect ?? -1;
                    extrasMap["vfx_left"] = state.VfxFacingLeft ?? false;
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

        // Call once per frame from the main thread. Drains everything buffered since the last
        // call and invokes the matching callback per PROTOCOL.md's "drain all buffered
        // render_remote / despawn_remote messages". Unknown/malformed lines are logged and
        // skipped, never thrown -- a single bad line must not take down the plugin.
        public void DrainInto(Action<string, RemoteState> onRenderRemote, Action<string> onDespawnRemote)
        {
            while (incoming.TryDequeue(out string line))
            {
                try
                {
                    // TryGetValue throughout rather than indexer + cast: an indexer miss returns
                    // a JToken null, and a raw `(JObject)`/`(string)` cast on a shape the core
                    // didn't actually send (or a value of the wrong JSON type) throws instead of
                    // giving this catch a chance -- this loop must survive a malformed line, not
                    // just a deserialization failure.
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
                                Position = st["position"]?.ToObject<float[]>(),
                                Orientation = (string)st["orientation"],
                                Anim = (string)st["anim"],
                                RoomX = (int?)extras?["room_x"],
                                RoomY = (int?)extras?["room_y"],
                                TrailMode = (int?)extras?["trail"],
                                TempPause = (float?)extras?["pause"],
                                AnimTime = (float?)extras?["anim_t"],
                                VfxSeq = (int?)extras?["vfx_seq"],
                                VfxEffect = (int?)extras?["vfx_id"],
                                VfxFacingLeft = (bool?)extras?["vfx_left"],
                            };
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
                            onDespawnRemote(playerId);
                            break;
                        }
                        case "bridge_ready":
                            // The core accepted our hello. Recognised explicitly rather than
                            // falling through to the unknown-type warning below, which is what
                            // used to happen -- so every healthy session logged a warning about
                            // the one message that means everything is fine.
                            //
                            // AND it is the send gate, since 2026-08-27. This comment used to say
                            // the gate could not be closed until "the reconnect path resets the
                            // flag too, or a missed ready silences the adapter completely" -- so
                            // that is what ConnectAndReadLoop now does, on every fresh connection.
                            bridgeReady = true;
                            Log($"MeshGhost: bridge ready on port {connectedPort} -- the core " +
                                "accepted this adapter.");
                            break;
                        case "reject":
                        {
                            // The core refused us: wrong game_id, or it already has an adapter.
                            // Previously this landed in the unknown-type default and we kept
                            // pushing local_state at a core that had already refused and closed.
                            string reason = "unspecified";
                            if (payload != null && payload.TryGetValue("reason", out JToken reasonToken))
                            {
                                reason = (string)reasonToken;
                            }
                            // A refusal is information, not a dead end: this is a live core that is
                            // not ours, so cool the port down and let TryConnect walk to the next
                            // rather than re-dialling the same refusal every two seconds.
                            // The port the CONNECTION is on, not the walk cursor: this runs on the
                            // main thread, frames after the reject arrived, and the cursor may have
                            // moved. Using the cursor cooled down innocent ports and left the busy
                            // one hot, which is what made the walk churn.
                            int refusedPort = connectedPort;
                            portCooldownUntil[refusedPort] = DateTime.UtcNow + BusyPortCooldown;
                            Log($"MeshGhost: the core on port {refusedPort} rejected this adapter " +
                                $"({reason}) -- walking to the next bridge port.");
                            connected = false;
                            AdvanceWalkPast(refusedPort);
                            break;
                        }
                        default:
                            Log($"MeshGhost: ignoring unknown bridge message type '{type}'.");
                            break;
                    }
                }
                catch (Exception e)
                {
                    Log($"MeshGhost: bad bridge message ignored: {e.Message}");
                }
            }
        }
    }
}
