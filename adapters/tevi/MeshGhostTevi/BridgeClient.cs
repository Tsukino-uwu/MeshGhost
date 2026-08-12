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
        private TcpClient client;
        private NetworkStream stream;
        private DateTime lastConnectAttempt = DateTime.MinValue;
        private static readonly TimeSpan ReconnectInterval = TimeSpan.FromSeconds(2);

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

            var thread = new Thread(ConnectAndReadLoop) { IsBackground = true };
            thread.Start();
        }

        private void ConnectAndReadLoop()
        {
            try
            {
                var c = new TcpClient();
                c.Connect(host, port);
                client = c;
                stream = c.GetStream();
                connected = true;
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
                connected = false;
                stream = null;
                client = null;
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

            object payloadState = state == null
                ? null
                : (object)new
                {
                    area_id = state.AreaId,
                    position = state.Position,
                    orientation = state.Orientation,
                    anim = state.Anim,
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
                    var env = JsonConvert.DeserializeObject<JObject>(line);
                    string type = (string)env["type"];
                    JObject payload = (JObject)env["payload"];

                    switch (type)
                    {
                        case "render_remote":
                        {
                            string playerId = (string)payload["player_id"];
                            JObject st = (JObject)payload["state"];
                            var remote = new RemoteState
                            {
                                AreaId = (string)st["area_id"],
                                Position = st["position"]?.ToObject<float[]>(),
                                Orientation = (string)st["orientation"],
                                Anim = (string)st["anim"],
                            };
                            onRenderRemote(playerId, remote);
                            break;
                        }
                        case "despawn_remote":
                        {
                            string playerId = (string)payload["player_id"];
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
