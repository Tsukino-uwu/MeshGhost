using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace MeshGhostAutoplay
{
    // The driver's side of autoplay's link for a BepInEx host (DEV TOOL, never shipped; agent_docs/phases/phase13.md,
    // ADR 0071). The wire is protocol 1, stated at the top of autoplay/driver/driver.go: a hello, then requests with ids
    // answered by a result or an error, and events sent unasked.
    //
    // Game-blind. A background thread connects to the core on 127.0.0.1, says the hello the game plugin last set, and
    // reads lines; the game's main thread takes requests with Poll and answers with Reply or Fail. Nothing of Unity is
    // touched off the main thread, and log lines from the thread wait in a queue the main thread drains.
    public sealed class Link : IDisposable
    {
        public const int Protocol = 1;
        public const int MaxLineBytes = 64 * 1024;
        private const int RetryMs = 1000;
        private const int RejectBackoffMs = 10000;
        private const int WelcomeTimeoutMs = 5000;

        public sealed class Request
        {
            public long Id;
            public string Type;
            public JObject Payload;
            public int Generation;
        }

        private readonly string host;
        private readonly int port;
        private readonly Thread thread;
        private readonly object writeLock = new object();
        private readonly Queue<Request> requests = new Queue<Request>();
        private readonly Queue<string> logs = new Queue<string>();
        private volatile bool stopping;
        private volatile string helloLine;
        private string sentHello;
        private NetworkStream stream;
        private TcpClient client;
        private int generation;
        private volatile bool connected;

        public Link(string host, int port)
        {
            this.host = host;
            this.port = port;
            thread = new Thread(Run) { IsBackground = true, Name = "autoplay link" };
            thread.Start();
        }

        public bool Connected => connected;

        // The generation of the current connection: a request carries the one it arrived on, so an answer meant for a
        // core that has gone is never sent to the next one.
        public int Generation => generation;

        // Set on the main thread whenever what the hello says may have changed. A connection made with an older hello
        // is dropped, so a core never keeps a stale one; the thread reconnects with this.
        public void SetHello(JObject hello)
        {
            string line = hello.ToString(Formatting.None);
            if (line == helloLine) return;
            helloLine = line;
            if (connected && sentHello != null && sentHello != line)
            {
                Log("the hello changed; reconnecting so the core has the new one");
                Drop();
            }
        }

        public List<Request> Poll()
        {
            var out_ = new List<Request>();
            lock (requests)
            {
                while (requests.Count > 0) out_.Add(requests.Dequeue());
            }
            return out_;
        }

        public List<string> DrainLogs()
        {
            var out_ = new List<string>();
            lock (logs)
            {
                while (logs.Count > 0) out_.Add(logs.Dequeue());
            }
            return out_;
        }

        public void Reply(Request req, JToken payload)
        {
            Send(req, new JObject { ["id"] = req.Id, ["type"] = "result", ["payload"] = payload ?? new JObject() });
        }

        public void Fail(Request req, string message)
        {
            Send(req, new JObject { ["id"] = req.Id, ["type"] = "error", ["payload"] = new JObject { ["message"] = message } });
        }

        public void Event(JObject payload)
        {
            WriteLine(new JObject { ["type"] = "event", ["payload"] = payload }, generation);
        }

        private void Send(Request req, JObject envelope)
        {
            if (req.Generation != generation)
            {
                Log("not answering request " + req.Id + ": its core has gone");
                return;
            }
            WriteLine(envelope, req.Generation);
        }

        private bool WriteLine(JObject envelope, int gen)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(envelope.ToString(Formatting.None) + "\n");
            if (bytes.Length > MaxLineBytes)
            {
                Log("dropping an outgoing " + envelope["type"] + " line of " + bytes.Length + " bytes, over the link's cap");
                if (envelope["id"] != null)
                {
                    // The core would otherwise wait out its timeout: say why instead.
                    var err = new JObject
                    {
                        ["id"] = envelope["id"],
                        ["type"] = "error",
                        ["payload"] = new JObject { ["message"] = "the answer is " + bytes.Length + " bytes, over the link's " + MaxLineBytes },
                    };
                    bytes = Encoding.UTF8.GetBytes(err.ToString(Formatting.None) + "\n");
                }
                else
                {
                    return false;
                }
            }
            lock (writeLock)
            {
                if (stream == null || gen != generation) return false;
                try
                {
                    stream.Write(bytes, 0, bytes.Length);
                    return true;
                }
                catch (Exception e)
                {
                    Log("send failed: " + e.Message);
                    DropLocked();
                    return false;
                }
            }
        }

        private void Log(string msg)
        {
            lock (logs)
            {
                if (logs.Count < 200) logs.Enqueue(msg);
            }
        }

        private void Drop()
        {
            lock (writeLock) DropLocked();
        }

        private void DropLocked()
        {
            connected = false;
            try { client?.Close(); } catch { }
            client = null;
            stream = null;
        }

        private void Run()
        {
            while (!stopping)
            {
                string hello = helloLine;
                if (hello == null)
                {
                    Thread.Sleep(200);
                    continue;
                }
                int backoff = RetryMs;
                TcpClient c = new TcpClient { NoDelay = true };
                try
                {
                    if (!c.ConnectAsync(host, port).Wait(RetryMs))
                    {
                        throw new IOException("no answer");
                    }
                    NetworkStream s = c.GetStream();
                    var reader = new StreamReader(s, new UTF8Encoding(false));
                    lock (writeLock)
                    {
                        client = c;
                        stream = s;
                        generation++;
                    }
                    byte[] helloBytes = Encoding.UTF8.GetBytes(new JObject
                    {
                        ["type"] = "hello",
                        ["payload"] = JObject.Parse(hello),
                    }.ToString(Formatting.None) + "\n");
                    s.Write(helloBytes, 0, helloBytes.Length);
                    sentHello = hello;

                    s.ReadTimeout = WelcomeTimeoutMs;
                    JObject first = JObject.Parse(reader.ReadLine() ?? throw new IOException("closed before a welcome"));
                    string type = (string)first["type"];
                    if (type == "reject")
                    {
                        Log("the core rejected this driver: " + first["payload"]?["reason"]);
                        backoff = RejectBackoffMs;
                        throw new IOException("rejected");
                    }
                    if (type != "welcome")
                    {
                        throw new IOException("the core's first line was " + type + ", not a welcome");
                    }
                    s.ReadTimeout = Timeout.Infinite;
                    connected = true;
                    Log("connected to the core on " + host + ":" + port);

                    while (!stopping)
                    {
                        string line = reader.ReadLine();
                        if (line == null) throw new IOException("the core closed the link");
                        if (line.Length > MaxLineBytes) throw new IOException("a line over the link's cap");
                        JObject msg;
                        try
                        {
                            msg = JObject.Parse(line);
                        }
                        catch (Exception e)
                        {
                            Log("dropping a line that does not parse: " + e.Message);
                            continue;
                        }
                        var req = new Request
                        {
                            Id = (long?)msg["id"] ?? 0,
                            Type = (string)msg["type"],
                            Payload = msg["payload"] as JObject ?? new JObject(),
                            Generation = generation,
                        };
                        if (req.Id == 0 || string.IsNullOrEmpty(req.Type))
                        {
                            Log("ignoring a line with no id or type");
                            continue;
                        }
                        lock (requests) requests.Enqueue(req);
                    }
                }
                catch (Exception e)
                {
                    if (connected) Log("link down: " + (e.InnerException ?? e).Message);
                }
                finally
                {
                    lock (writeLock)
                    {
                        if (client == c) DropLocked();
                    }
                    try { c.Close(); } catch { }
                    connected = false;
                }
                if (!stopping) Thread.Sleep(backoff);
            }
        }

        public void Dispose()
        {
            stopping = true;
            Drop();
        }
    }
}
