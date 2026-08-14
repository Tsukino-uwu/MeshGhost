using System;
using System.Collections.Concurrent;
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
        }

        private readonly string host;
        private readonly int port;

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
            this.port = port;
        }

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
            if (connected)
            {
                return;
            }
            if (DateTime.UtcNow - lastConnectAttempt < ReconnectInterval)
            {
                return;
            }
            lastConnectAttempt = DateTime.UtcNow;

            int generation = Interlocked.Increment(ref connectionGeneration);
            var thread = new Thread(() => ConnectAndReadLoop(generation)) { IsBackground = true };
            thread.Start();
        }

        private void ConnectAndReadLoop(int generation)
        {
            TcpClient c = null;
            try
            {
                c = new TcpClient();
                c.Connect(host, port);
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
                // Not written here: NetworkStream isn't safe for concurrent writes from this
                // background thread and the main thread's SendLocalState, so the actual send is
                // deferred to SendHelloIfNeeded, called from Update() on the main thread, same
                // as every other outbound message.
                needsHello = true;
                Log($"MeshGhost: connected to bridge at {host}:{port}.");

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
                Log($"MeshGhost: bridge connection ended: {e.Message}");
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

            object extras = (state != null && state.RoomX.HasValue && state.RoomY.HasValue)
                ? new { room_x = state.RoomX.Value, room_y = state.RoomY.Value }
                : null;
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
