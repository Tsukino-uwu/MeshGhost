// BridgeFuzz -- hostile input against TEVI's SHIPPED bridge line decoder.
//
// WHAT THIS REACHES, which is more than the Lua harness does. BridgeClient.DrainInto parses a line
// AND dispatches it: the switch on "type", the payload extraction, and the RemoteState it hands to
// the callbacks. All of that lives in one file with no Unity and no BepInEx, so the whole path from
// bytes to callback arguments runs here. Emerald's and Crystal's decoders can only be exercised as
// far as the decode, because their dispatch sits thousands of lines further down, past the point
// where the file starts calling BizHawk.
//
// NOTHING IN THE ADAPTER IS MODIFIED to make this possible. The queue DrainInto reads is private,
// so lines go in through reflection. That is the right trade: a test seam added to shipped code is
// a change to shipped code, and this file is not worth one.
//
// A DETERMINISTIC SEEDED LOOP, not a coverage-guided fuzzer. SharpFuzz would mean a new toolchain
// in CI for a decoder whose entire input space is "one line of text"; a fixed corpus plus a seeded
// generator gets the same defects and reproduces exactly from the seed printed on failure.
//
// What a green run does NOT mean: Newtonsoft here comes from NuGet, while the plugin binds to the
// game's own copy. This bounds our parse and dispatch, not that exact deserializer.

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Reflection;
using System.Text;
using MeshGhostTevi;

internal static class BridgeFuzz
{
    private static readonly List<string> Failures = new List<string>();
    private static int checks;

    private static void Fail(string fmt, params object[] args) => Failures.Add(string.Format(fmt, args));

    // The private queue DrainInto pulls from. Reached once and cached; if the field is ever renamed
    // this fails loudly at startup rather than silently testing nothing -- which is the failure mode
    // that made the Go replay fuzzer pass while exercising nothing (2026-09-03).
    private static readonly FieldInfo IncomingField =
        typeof(BridgeClient).GetField("incoming", BindingFlags.NonPublic | BindingFlags.Instance)
        ?? throw new InvalidOperationException(
            "BridgeClient has no private field 'incoming' -- the decoder was restructured and this harness " +
            "is now testing nothing. Find the new queue and point this at it.");

    private sealed class Drain
    {
        public readonly List<(string Id, BridgeClient.RemoteState State)> Rendered = new();
        public readonly List<string> Despawned = new();
    }

    // Feed returns what one line produced, or throws only if the DECODER threw -- which is itself
    // the finding, because DrainInto's whole contract is that it survives a malformed line.
    private static Drain Feed(string line)
    {
        checks++;
        var client = new BridgeClient("127.0.0.1", 7778);
        var queue = (ConcurrentQueue<string>)IncomingField.GetValue(client);
        queue.Enqueue(line);

        var drain = new Drain();
        client.DrainInto((id, st) => drain.Rendered.Add((id, st)), id => drain.Despawned.Add(id));
        return drain;
    }

    private static bool Survives(string label, string line, out Drain drain)
    {
        drain = null;
        try
        {
            drain = Feed(line);
            return true;
        }
        catch (Exception ex)
        {
            Fail("{0}: DrainInto threw {1} on {2} -- it must survive a malformed line, not just a " +
                 "deserialization failure: {3}", label, ex.GetType().Name, Truncate(line), ex.Message);
            return false;
        }
    }

    private static string Truncate(string s) =>
        s.Length <= 70 ? "\"" + s + "\"" : "\"" + s.Substring(0, 70) + "\"... (" + s.Length + " chars)";

    private static void Main()
    {
        Control();
        Malformed();
        WrongTypes();
        Extremes();
        Depth();
        PeerStrings();

        Console.WriteLine("  " + checks + " line(s) fed through the shipped DrainInto");
        if (Failures.Count > 0)
        {
            Console.WriteLine();
            Console.WriteLine("FAIL: " + Failures.Count + " problem(s)");
            foreach (string f in Failures)
            {
                Console.WriteLine("  - " + f);
            }
            Environment.Exit(1);
        }

        Console.WriteLine();
        Console.WriteLine("OK: the decoder survived every line, valid input still dispatches, and no peer " +
                          "string escaped being data.");
    }

    // 1. THE CONTROL. Without it, "nothing crashed" reads identically whether the decoder is working
    // or has quietly stopped decoding -- which is exactly how a Go fuzz target here spent its whole
    // life exercising nothing (agent_docs/pitfalls/method.md, 2026-09-03).
    private static void Control()
    {
        // The real shape: bridge.RenderRemote nests the sample under "state" (bridge/bridge.go),
        // it is not flat in the payload. Getting this wrong the first time is exactly why the
        // control exists -- a harness with the wrong shape reports "0 renders" for every input and
        // looks like a broken decoder rather than a broken test.
        const string render =
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p1\",\"state\":{" +
            "\"position\":[1.5,-2.25,3.0],\"area_id\":\"room-a\",\"anim\":\"run\"}}}";
        if (Survives("control", render, out Drain d))
        {
            if (d.Rendered.Count != 1)
            {
                Fail("control: a valid render_remote produced {0} render(s), want 1 -- the decoder is not decoding", d.Rendered.Count);
            }
            else
            {
                var (id, st) = d.Rendered[0];
                if (id != "p1")
                {
                    Fail("control: player_id came through as \"{0}\", want \"p1\"", id);
                }
                if (st == null || st.Position == null || st.Position.Length != 3)
                {
                    Fail("control: position did not survive the decode");
                }
                else if (Math.Abs(st.Position[0] - 1.5f) > 1e-6 || Math.Abs(st.Position[1] + 2.25f) > 1e-6)
                {
                    Fail("control: position decoded to the wrong values ({0}, {1})", st.Position[0], st.Position[1]);
                }
                if (st != null && st.AreaId != "room-a")
                {
                    Fail("control: area_id came through as \"{0}\"", st?.AreaId);
                }
            }
        }

        const string despawn = "{\"type\":\"despawn_remote\",\"payload\":{\"player_id\":\"p1\"}}";
        if (Survives("control", despawn, out Drain d2) && d2.Despawned.Count != 1)
        {
            Fail("control: a valid despawn_remote produced {0} despawn(s), want 1", d2.Despawned.Count);
        }
    }

    // 2. Malformed and hostile lines. The bar is only that the decoder comes back: dropping a line
    // is the correct answer to nonsense, and dispatching it would be the bug.
    private static void Malformed()
    {
        string[] lines =
        {
            "", " ", "\n", "{", "[", "null", "true", "0", "\"a string\"", "[]", "{}",
            "{\"type\":", "{\"type\":1}", "{\"type\":null}", "{\"type\":[]}", "{\"type\":{}}",
            "{\"type\":\"render_remote\"}",                                  // no payload at all
            "{\"type\":\"render_remote\",\"payload\":null}",
            "{\"type\":\"render_remote\",\"payload\":\"a string\"}",         // payload of the wrong TYPE
            "{\"type\":\"render_remote\",\"payload\":[1,2,3]}",
            "{\"type\":\"render_remote\",\"payload\":{}}",                   // no player_id
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":null}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":123}}",  // wrong type
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"position\":\"nope\"}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"position\":[1]}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"position\":[null,null]}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"position\":[1e400,0,0]}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"position\":[\"a\",\"b\"]}}",
            "{\"type\":\"despawn_remote\",\"payload\":{}}",
            "{\"type\":\"despawn_remote\",\"payload\":{\"player_id\":[]}}",
            "{\"type\":\"an_unknown_type\",\"payload\":{}}",
            "{\"type\":\"remote_name\",\"payload\":{\"player_id\":\"p\",\"name\":{}}}",
            "{\"type\":\"session_policy\",\"payload\":{\"ghost_collision\":[]}}",
            "{\"type\":\"bridge_ready\"", "{\"type\":\"reject\",\"payload\":{\"reason\":null}}",
            "\0", "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"\0\"}}",
            "{\"a\":1,\"a\":2}",                                             // duplicate keys
        };

        foreach (string line in lines)
        {
            Survives("malformed", line, out _);
        }
    }

    // 3. DEPTH. The same exposure the Lua harness measured on the Pokemon adapters, asked of this
    // one: `extras` is bounded by SIZE and never by SHAPE upstream, so a peer fits several hundred
    // levels of nesting into a message the relay forwards. Since 2026-09-03 protocol.MaxJSONDepth
    // (32) refuses those before they leave the core -- but an adapter should not be relying on the
    // core it happens to be paired with, and this is the check that says whether it does.
    private static void Depth()
    {
        int deepestAccepted = 0;
        foreach (int depth in new[] { 8, 32, 64, 100, 490, 5000 })
        {
            var sb = new StringBuilder();
            sb.Append("{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"extras\":");
            sb.Append('[', depth);
            sb.Append(']', depth);
            sb.Append("}}}");
            if (Survives("depth " + depth, sb.ToString(), out Drain d) && d.Rendered.Count == 1)
            {
                deepestAccepted = depth;
            }
        }

        // Reported rather than failed. Unlike the Lua decoders, this one does not own its own depth
        // rule -- Newtonsoft applies one and DrainInto's catch turns the refusal into a dropped
        // line, which is the correct outcome. The number is printed so it is a KNOWN fact rather
        // than an assumed one, and so a Newtonsoft upgrade that changes it is visible here.
        Console.WriteLine("  TEVI: deepest nesting accepted = " + deepestAccepted +
                          " (deeper input is dropped, not crashed)");
    }

    // 5. WRONG TYPE FOR EVERY FIELD (shared corpus category 1, adapters/_template/README.md).
    // Each field that should be a number arrives as a string, a bool, null, an array and an
    // object, and each string field as a number and a container. The bar is only that DrainInto
    // returns: rejecting a wrong-typed field is the adapter's job, crashing on one is nobody's.
    // This is the category the Emerald gender bug lived in -- a table where a string was expected
    // made the draw loop error every frame for every peer sorted after it.
    private static void WrongTypes()
    {
        string[] lines =
        {
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"player_id\":1}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"player_id\":\"text\"}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"player_id\":true}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"player_id\":false}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"player_id\":null}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"player_id\":[1,2,3]}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"player_id\":{\"a\":1}}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"player_id\":[]}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"player_id\":{}}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"area_id\":1}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"area_id\":\"text\"}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"area_id\":true}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"area_id\":false}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"area_id\":null}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"area_id\":[1,2,3]}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"area_id\":{\"a\":1}}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"area_id\":[]}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"area_id\":{}}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"anim\":1}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"anim\":\"text\"}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"anim\":true}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"anim\":false}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"anim\":null}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"anim\":[1,2,3]}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"anim\":{\"a\":1}}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"anim\":[]}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"anim\":{}}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"position\":1}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"position\":\"text\"}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"position\":true}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"position\":false}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"position\":null}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"position\":[1,2,3]}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"position\":{\"a\":1}}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"position\":[]}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"position\":{}}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"extras\":1}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"extras\":\"text\"}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"extras\":true}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"extras\":false}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"extras\":null}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"extras\":[1,2,3]}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"extras\":{\"a\":1}}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"extras\":[]}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"extras\":{}}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"orientation\":1}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"orientation\":\"text\"}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"orientation\":true}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"orientation\":false}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"orientation\":null}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"orientation\":[1,2,3]}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"orientation\":{\"a\":1}}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"orientation\":[]}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"orientation\":{}}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"anim_time\":1}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"anim_time\":\"text\"}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"anim_time\":true}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"anim_time\":false}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"anim_time\":null}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"anim_time\":[1,2,3]}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"anim_time\":{\"a\":1}}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"anim_time\":[]}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"anim_time\":{}}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"temp_pause\":1}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"temp_pause\":\"text\"}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"temp_pause\":true}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"temp_pause\":false}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"temp_pause\":null}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"temp_pause\":[1,2,3]}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"temp_pause\":{\"a\":1}}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"temp_pause\":[]}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"temp_pause\":{}}}}",
        };

        foreach (string line in lines)
        {
            Survives("wrong type", line, out _);
        }
    }

    // 6. EXTREME NUMERICS, high and low (shared corpus category 2). Type boundaries and the values
    // just past them, plus the ones a peer reaches legally -- 1e999 is VALID JSON, so infinity
    // arrives without anyone writing "inf". Newtonsoft's float cast turns out-of-range doubles and
    // the "NaN"/"Infinity" strings into non-finite values WITHOUT throwing, which is why
    // BridgeClient.FiniteOrNull exists; this asserts that guard actually holds rather than
    // assuming it, for every shape a peer can send.
    private static void Extremes()
    {
        string[] raws =
        {
            "0", "-0", "1", "-1", "255", "256", "-1",
            "2147483647", "2147483648", "-2147483649", "9007199254740993",
            "3.4028235e38", "3.4028236e38", "1e300", "1e308", "1e309", "1e999", "-1e999", "1e-999",
            "\"NaN\"", "\"Infinity\"", "\"-Infinity\"",
        };

        int nonFinite = 0;
        foreach (string raw in raws)
        {
            string line =
                "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{" +
                "\"position\":[0,0,0],\"extras\":{\"anim_time\":" + raw + ",\"temp_pause\":" + raw + "}}}}";
            if (!Survives("extreme " + raw, line, out Drain d))
            {
                continue;
            }
            if (d.Rendered.Count == 1)
            {
                var st = d.Rendered[0].State;
                foreach (float? v in new[] { st?.AnimTime, st?.TempPause })
                {
                    if (v.HasValue && (float.IsNaN(v.Value) || float.IsInfinity(v.Value)))
                    {
                        nonFinite++;
                        Fail("extreme {0}: a non-finite value reached the callback -- FiniteOrNull " +
                             "is meant to turn these into absent, and a NaN here freezes that " +
                             "ghost's Animator", raw);
                    }
                }
            }
        }
        Console.WriteLine("  TEVI: " + raws.Length + " extreme numeric form(s) fed; " + nonFinite +
                          " reached a callback non-finite (want 0)");
    }

    // 4. PEER STRINGS STAY DATA. The property the ACE audit names: a peer-controlled string must
    // arrive at the callback as the string it was, and must never have been used as a lookup on the
    // way. This checks the first half, which is the half a decoder owns -- and pins pass-through, so
    // a future "sanitiser" that silently rewrites a peer's id shows up here rather than as two
    // players unable to see each other.
    private static void PeerStrings()
    {
        string[] ids =
        {
            "p1", "../../etc/passwd", "..\\..\\windows", "{0}", "%s%s%s", "a\"b", "a\\b",
            "a\"b", "a\\b", "‮evil", "Player One", "'; DROP TABLE", "<script>", "&amp;",
            new string('x', 4000),
        };

        foreach (string id in ids)
        {
            string line = Newtonsoft.Json.JsonConvert.SerializeObject(new
            {
                type = "render_remote",
                payload = new
                {
                    player_id = id,
                    state = new { position = new[] { 0.0, 0.0, 0.0 }, area_id = "a", anim = "idle" },
                },
            });

            if (!Survives("peer id", line, out Drain d))
            {
                continue;
            }
            if (d.Rendered.Count != 1)
            {
                Fail("peer id {0}: produced {1} render(s), want 1 -- a legal id was dropped", Truncate(id), d.Rendered.Count);
                continue;
            }
            if (d.Rendered[0].Id != id)
            {
                Fail("peer id {0}: arrived as {1} -- a peer id must reach the adapter as the string it was",
                    Truncate(id), Truncate(d.Rendered[0].Id));
            }
        }
    }
}
