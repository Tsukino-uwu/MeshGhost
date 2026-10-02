// Hostile input against TEVI's shipped bridge line decoder. BridgeClient.DrainInto parses and dispatches a line with no
// Unity or BepInEx, so the whole path from bytes to callback arguments runs here.
// The private queue is reached by reflection, so shipped code carries no test seam. A fixed corpus, not a
// coverage-guided fuzzer: the decoder's whole input is one line of text. Newtonsoft here comes from NuGet, while the
// plugin binds to the game's own copy, so a green run bounds our parse and dispatch, not that exact deserializer.
// Each category asserts that values arrive at the callback, so a key nothing reads fails the run.

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.Reflection;
using System.Text;
using MeshGhostTevi;

internal static class BridgeFuzz
{
    private static readonly List<string> Failures = new List<string>();
    private static int checks;

    private static void Fail(string fmt, params object[] args) => Failures.Add(string.Format(fmt, args));

    // The private queue DrainInto pulls from; a rename fails loudly at startup rather than silently testing nothing.
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

    // Feed returns what one line produced; it throws only if the decoder threw, which is itself a finding.
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
        ExtrasRealKeys();
        Malformed();
        WrongTypes();
        ExtrasWrongTypes();
        Extremes();
        Depth();
        PeerStrings();
        ForeignGamePeer();
        NonFinitePosition();
        NarrowEnumOrdinals();

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


    // A peer's bullet ordinals against stand-ins as narrow as the game's bullet type and sprite enums, which cannot be
    // loaded here: Enum.IsDefined throws on a value boxed at the wrong width.
    private enum ShortStandIn : short { Zero = 0, One = 1, Big = 300 }
    private enum ByteStandIn : byte { Zero = 0, Top = 255 }

    private static void NarrowEnumOrdinals()
    {
        (Type type, float value, int want)[] cases =
        {
            (typeof(ShortStandIn), 1f, 1), (typeof(ShortStandIn), 300f, 300), (typeof(ShortStandIn), 0f, 0),
            (typeof(ShortStandIn), 2f, -1), (typeof(ShortStandIn), 70000f, -1), (typeof(ShortStandIn), -40000f, -1),
            (typeof(ShortStandIn), 1.5f, -1), (typeof(ShortStandIn), float.NaN, -1), (typeof(ShortStandIn), float.PositiveInfinity, -1),
            (typeof(ByteStandIn), 255f, 255), (typeof(ByteStandIn), 0f, 0), (typeof(ByteStandIn), 256f, -1),
            (typeof(ByteStandIn), -1f, -1), (typeof(ByteStandIn), 7f, -1), (typeof(ByteStandIn), 511f, -1),
        };
        foreach (var c in cases)
        {
            checks++;
            try
            {
                int got = BridgeClient.DefinedOrdinalOrMinusOne(c.type, c.value);
                if (got != c.want)
                    Fail("ordinal {0} on {1}: got {2}, want {3}", c.value, c.type.Name, got, c.want);
            }
            catch (Exception ex)
            {
                Fail("ordinal {0} on {1}: THREW {2} -- a narrow enum must be checked in its own width, or " +
                     "every peer bullet is lost: {3}", c.value, c.type.Name, ex.GetType().Name, ex.Message);
            }
        }
    }

    // A state arrives with a fully finite position or with none: a NaN position spreads into the physics state of
    // whatever it touches and stays there.
    private static void NonFinitePosition()
    {
        string[] positions =
        {
            "[\"NaN\",0]", "[0,\"NaN\"]", "[\"Infinity\",0]", "[\"-Infinity\",0]",
            "[1e999,0]", "[0,-1e999]", "[3.5e38,0]", "[\"NaN\",\"NaN\"]",
        };
        foreach (string pos in positions)
        {
            string line = "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p1\",\"state\":{" +
                          "\"area_id\":\"a\",\"position\":" + pos + ",\"anim\":\"idle\"}}}";
            if (!Survives("non-finite position", line, out Drain drain))
            {
                continue;
            }
            foreach ((string _, BridgeClient.RemoteState st) in drain.Rendered)
            {
                if (st.Position == null)
                {
                    continue; // refused whole, which is the intended answer
                }
                for (int i = 0; i < st.Position.Length; i++)
                {
                    if (float.IsNaN(st.Position[i]) || float.IsInfinity(st.Position[i]))
                    {
                        Fail("a non-finite position reached the callback from {0} -- it lands in " +
                             "transform.position and Vector3.Distance, and a NaN transform spreads " +
                             "into the physics state of whatever it touches", pos);
                    }
                }
            }
        }

        // A real position still arrives, or refusing everything would pass.
        string good = "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p1\",\"state\":{" +
                      "\"area_id\":\"a\",\"position\":[12.5,-3.25],\"anim\":\"idle\"}}}";
        if (Survives("finite position", good, out Drain ok))
        {
            bool arrived = false;
            foreach ((string _, BridgeClient.RemoteState st) in ok.Rendered)
            {
                if (st.Position != null && st.Position.Length == 2
                    && Math.Abs(st.Position[0] - 12.5f) < 0.001f
                    && Math.Abs(st.Position[1] + 3.25f) < 0.001f)
                {
                    arrived = true;
                }
            }
            if (!arrived)
            {
                Fail("an ordinary finite position did not reach the callback -- the guard is " +
                     "refusing everything, which would make every assertion above vacuous");
            }
        }
    }

    // Valid input still dispatches: without it, nothing crashing reads the same as a decoder that stopped decoding.
    private static void Control()
    {
        // bridge.RenderRemote nests the sample under "state", not flat in the payload.
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

    // Malformed and hostile lines: the bar is only that the decoder comes back, since dropping nonsense is correct.
    private static void Malformed()
    {
        string[] lines =
        {
            "", " ", "\n", "{", "[", "null", "true", "0", "\"a string\"", "[]", "{}",
            "{\"type\":", "{\"type\":1}", "{\"type\":null}", "{\"type\":[]}", "{\"type\":{}}",
            "{\"type\":\"render_remote\"}",                                  // no payload at all
            "{\"type\":\"render_remote\",\"payload\":null}",
            "{\"type\":\"render_remote\",\"payload\":\"a string\"}",         // payload of the wrong type
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

    // Deep nesting: the core refuses extras past protocol.MaxJSONDepth, but an adapter must not rely on its core.
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

        // Reported, not failed: Newtonsoft owns the depth rule and DrainInto's catch drops the line. Printed so a
        // Newtonsoft upgrade that moves it shows here.
        Console.WriteLine("  TEVI: deepest nesting accepted = " + deepestAccepted +
                          " (deeper input is dropped, not crashed)");
    }

    // Every state field at every wrong JSON type (the shared corpus's first category): DrainInto must return.
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
            // Two unknown state-level keys, which must be ignored; the timing fields' coverage is ExtrasWrongTypes.
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"anim_time\":1}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"temp_pause\":{\"a\":1}}}}",
        };

        foreach (string line in lines)
        {
            Survives("wrong type", line, out _);
        }
    }

    // The same category at nine extras keys the decoder casts, crossed with every JSON shape a peer can put there.
    // Newtonsoft either coerces a value or throws into DrainInto's per-line catch, and both are correct; what must hold
    // either way is that nothing escapes to the caller and one odd value never corrupts the rest of the state.
    private static void ExtrasWrongTypes()
    {
        string[] keys =
        {
            "room_x", "room_y", "trail", "weapon_rgba", "anim_t", "pause", "vfx_seq", "vfx_id", "vfx_left",
        };
        string[] values =
        {
            "1", "-1", "0", "\"text\"", "\"\"", "true", "false", "null",
            "[1,2,3]", "{\"a\":1}", "[]", "{}",
            // Past int both ways. int.MinValue is a legal int and reaches the callback; the plugin's bound judges it.
            "-2147483648", "2147483648", "-2147483649",
        };

        int decoded = 0;
        int dropped = 0;
        foreach (string key in keys)
        {
            foreach (string value in values)
            {
                string label = "extras " + key + "=" + value;
                string line =
                    "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{" +
                    "\"position\":[1.0,2.0],\"area_id\":\"a\",\"anim\":\"idle\",\"extras\":{\"" +
                    key + "\":" + value + "}}}}";
                if (!Survives(label, line, out Drain d))
                {
                    continue;
                }
                if (d.Rendered.Count == 0)
                {
                    dropped++;
                    continue;
                }
                decoded++;

                var st = d.Rendered[0].State;
                if (st == null || st.Position == null || st.Position.Length != 2
                    || st.Position[0] != 1f || st.Position[1] != 2f || st.AreaId != "a" || st.Anim != "idle")
                {
                    Fail("{0}: the line decoded but the rest of the state did not survive intact -- " +
                         "one odd extras value must not disturb the fields beside it", label);
                }
                foreach (float? v in new[] { st?.AnimTime, st?.TempPause })
                {
                    if (v.HasValue && (float.IsNaN(v.Value) || float.IsInfinity(v.Value)))
                    {
                        Fail("{0}: a non-finite float reached the callback -- FiniteOrNull " +
                             "(BridgeClient.cs:465) must turn these into absent", label);
                    }
                }
            }
        }

        // Every line refused and every line fed at a key nothing reads produce the same silence, so that fails.
        if (decoded == 0)
        {
            Fail("extras wrong types: all {0} line(s) were dropped, so not one extras cast was " +
                 "exercised -- either the decoder stopped decoding or these keys are wrong again",
                keys.Length * values.Length);
        }
        Console.WriteLine("  TEVI: extras wrong-typed values: " + decoded + " decoded, " + dropped +
                          " dropped (both are correct answers for a bad value; a throw is not)");
    }

    // Extreme numerics (the shared corpus's second category) at extras anim_t and pause: 1e999 is valid JSON, so
    // infinity arrives unasked, and FiniteOrNull must hold for every shape. A finite raw must arrive with its value,
    // and reached must end above zero.
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
        int reached = 0;
        int dropped = 0;
        int refused = 0;
        foreach (string raw in raws)
        {
            string line =
                "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{" +
                "\"position\":[0,0,0],\"extras\":{\"anim_t\":" + raw + ",\"pause\":" + raw + "}}}}";
            if (!Survives("extreme " + raw, line, out Drain d))
            {
                continue;
            }
            if (d.Rendered.Count != 1)
            {
                // Refusing the line is legal; counted, because a dropped line inspects as little as a wrong key does.
                dropped++;
                continue;
            }

            bool finite = ExpectedFloat(raw, out float expected);
            var st = d.Rendered[0].State;
            foreach ((string key, float? v) in new[] { ("anim_t", st?.AnimTime), ("pause", st?.TempPause) })
            {
                if (v.HasValue)
                {
                    reached++;
                    if (float.IsNaN(v.Value) || float.IsInfinity(v.Value))
                    {
                        nonFinite++;
                        Fail("extreme {0}: a non-finite value reached the callback via extras[\"{1}\"] -- " +
                             "FiniteOrNull is meant to turn these into absent, and a NaN here freezes " +
                             "that ghost's Animator", raw, key);
                        continue;
                    }
                }

                if (finite && key == "anim_t" && !v.HasValue && (expected < 0f || expected > 1f))
                {
                    // A refusal, not a missing key: UnitOrNull drops a finite anim_t outside 0..1.
                    refused++;
                    continue;
                }

                if (finite && !v.HasValue)
                {
                    Fail("extreme {0}: extras[\"{1}\"] arrived absent, but {0} narrows to the finite float " +
                         "{2} -- the decoder reads this key (BridgeClient.cs:727-728), so an absent value " +
                         "means this loop is feeding a key nothing reads, which is the 2026-09-08 defect " +
                         "returning", raw, key, expected);
                }
                else if (finite && Math.Abs(v.Value - expected) > Math.Abs(expected) * 1e-6f + 1e-9f)
                {
                    Fail("extreme {0}: extras[\"{1}\"] arrived as {2}, want {3} -- an extreme value must " +
                         "pass through unaltered or be refused, never be quietly rewritten",
                        raw, key, v.Value, expected);
                }
                else if (!finite && v.HasValue && !float.IsNaN(v.Value) && !float.IsInfinity(v.Value))
                {
                    Fail("extreme {0}: extras[\"{1}\"] is non-finite as a float but arrived as the finite " +
                         "value {2} -- a clamp invented here is a position/animation the peer never sent",
                        raw, key, v.Value);
                }
            }
        }

        // Without this, nonFinite == 0 reads the same whether FiniteOrNull holds or the loop inspects nothing.
        if (reached == 0)
        {
            Fail("extremes: not one of the {0} extreme form(s) reached the callback with a value, so " +
                 "the FiniteOrNull guard was never exercised -- check the extras keys against " +
                 "BridgeClient.cs:727-728 before believing the count below", raws.Length);
        }

        Console.WriteLine("  TEVI: " + raws.Length + " extreme numeric form(s) fed; " + reached +
                          " value(s) reached a callback, " + dropped + " line(s) dropped, " + refused +
                          " anim_t value(s) refused as outside 0..1; " + nonFinite +
                          " reached a callback non-finite (want 0)");
    }

    // What FiniteOrNull should be handed for a raw JSON scalar, computed so it cannot drift from the corpus. False for
    // anything non-finite as a float, including 3.4028236e38, which narrows to infinity and raises nothing.
    private static bool ExpectedFloat(string raw, out float expected)
    {
        expected = 0f;
        string s = raw.Trim('"');
        if (!double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out double d))
        {
            return false;
        }
        expected = (float)d;
        return !float.IsNaN(expected) && !float.IsInfinity(expected);
    }

    // A peer id arrives as the string it was: pass-through is pinned, so a sanitiser that rewrites an id fails here.
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

    // A second control, since Control sends no extras: nine extras keys at their wire names with legal values.
    // SendLocalState writes them and DrainInto reads them in one file, so each assertion names the field and the key.
    private static void ExtrasRealKeys()
    {
        const string line =
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p1\",\"state\":{" +
            "\"position\":[1.0,2.0],\"area_id\":\"room-a\",\"anim\":\"idle\",\"extras\":{" +
            "\"room_x\":7,\"room_y\":-3,\"trail\":2,\"weapon_rgba\":-16711936," +
            "\"anim_t\":0.25,\"pause\":0.5,\"vfx_seq\":9,\"vfx_id\":4,\"vfx_left\":true}}}}";

        if (!Survives("extras keys", line, out Drain d))
        {
            return;
        }
        if (d.Rendered.Count != 1)
        {
            Fail("extras keys: a state carrying every extras key produced {0} render(s), want 1", d.Rendered.Count);
            return;
        }

        var st = d.Rendered[0].State;
        Expect("RoomX", "room_x", st?.RoomX, 7);
        Expect("RoomY", "room_y", st?.RoomY, -3);
        Expect("TrailMode", "trail", st?.TrailMode, 2);
        Expect("WeaponRgba", "weapon_rgba", st?.WeaponRgba, -16711936);
        Expect("VfxSeq", "vfx_seq", st?.VfxSeq, 9);
        Expect("VfxEffect", "vfx_id", st?.VfxEffect, 4);
        if (st?.VfxFacingLeft != true)
        {
            Fail("extras keys: VfxFacingLeft came through as {0}, want true -- the wire key is " +
                 "\"vfx_left\" (BridgeClient.cs:731)", st?.VfxFacingLeft);
        }
        if (!st.AnimTime.HasValue || Math.Abs(st.AnimTime.Value - 0.25f) > 1e-6f)
        {
            Fail("extras keys: AnimTime came through as {0}, want 0.25 -- the wire key is \"anim_t\", " +
                 "not \"anim_time\" (BridgeClient.cs:728)", st.AnimTime);
        }
        if (!st.TempPause.HasValue || Math.Abs(st.TempPause.Value - 0.5f) > 1e-6f)
        {
            Fail("extras keys: TempPause came through as {0}, want 0.5 -- the wire key is \"pause\", " +
                 "not \"temp_pause\" (BridgeClient.cs:727)", st.TempPause);
        }
    }

    private static void Expect(string field, string wireKey, int? got, int want)
    {
        if (got != want)
        {
            Fail("extras keys: {0} came through as {1}, want {2} -- the wire key is \"{3}\", and a " +
                 "mismatch here means one half of BridgeClient.cs was renamed without the other",
                field, got.HasValue ? got.Value.ToString(CultureInfo.InvariantCulture) : "absent", want, wireKey);
        }
    }

    // A coherent peer from another game, in Emerald's own shape: every field valid, only the combination wrong. game_id
    // is self-declared, so nothing upstream can refuse it without learning what a game is; this pins what the decoder
    // does with it: one dispatch, every value verbatim, and no Emerald extras key landing in a TEVI field. What refuses
    // it lives in Plugin.cs, which needs Unity: the ghost's Animator refuses the anim, the area compare the marker.
    private static void ForeignGamePeer()
    {
        const string line =
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"emerald-peer\",\"state\":{" +
            "\"area_id\":\"0:9\",\"position\":[5,12],\"orientation\":\"south\",\"anim\":\"walking\"," +
            "\"extras\":{\"gender\":\"male\",\"gfx\":0,\"sanim\":4,\"sidx\":1,\"act\":0," +
            "\"sox\":0,\"soy\":0,\"spaused\":1,\"pspeed\":0,\"noanim\":0}}}}";

        if (!Survives("foreign game", line, out Drain d))
        {
            return;
        }
        if (d.Rendered.Count != 1 || d.Despawned.Count != 0)
        {
            Fail("foreign game: produced {0} render(s) and {1} despawn(s), want 1 and 0 -- a state " +
                 "whose every field is individually valid reaches the adapter, and pretending " +
                 "otherwise here would hide what actually happens", d.Rendered.Count, d.Despawned.Count);
            return;
        }
        if (d.Rendered[0].Id != "emerald-peer")
        {
            Fail("foreign game: player_id arrived as {0}", Truncate(d.Rendered[0].Id));
        }

        var st = d.Rendered[0].State;
        if (st?.AreaId != "0:9")
        {
            Fail("foreign game: area_id arrived as \"{0}\", want \"0:9\" -- area_id is opaque and " +
                 "compared by equality only, so it must reach Plugin.cs:383 as the string the peer " +
                 "sent; a rewrite here could make a foreign area MATCH the local one", st?.AreaId);
        }
        if (st?.Anim != "walking")
        {
            Fail("foreign game: anim arrived as \"{0}\", want \"walking\" -- an anim TEVI has never " +
                 "heard of must reach IsPlayableAnimName (Plugin.cs:589) intact to be refused there; " +
                 "the decoder does no lookup of its own and must not start", st?.Anim);
        }
        if (st?.Position == null || st.Position.Length != 2)
        {
            Fail("foreign game: position arrived as {0} element(s), want 2 -- Emerald sends a tile " +
                 "PAIR and TEVI's own sender does too (BridgeClient.cs:600-640), so the length gate " +
                 "at Plugin.cs:634 cannot be what separates them",
                st?.Position == null ? "no" : st.Position.Length.ToString(CultureInfo.InvariantCulture));
        }
        else if (st.Position[0] != 5f || st.Position[1] != 12f)
        {
            Fail("foreign game: position arrived as ({0}, {1}), want (5, 12) -- tile coordinates in " +
                 "world units are the WRONG PLACE, which is TEVI's to judge; a value this decoder " +
                 "rescaled or clamped would be a position no peer ever sent",
                st.Position[0], st.Position[1]);
        }

        // The two games' extras keys do not overlap, so every TEVI field must be absent; a 0 would assert room 0,0.
        foreach ((string field, bool present) in new[]
        {
            ("RoomX", st?.RoomX.HasValue == true), ("RoomY", st?.RoomY.HasValue == true),
            ("TrailMode", st?.TrailMode.HasValue == true), ("WeaponRgba", st?.WeaponRgba.HasValue == true),
            ("AnimTime", st?.AnimTime.HasValue == true), ("TempPause", st?.TempPause.HasValue == true),
            ("VfxSeq", st?.VfxSeq.HasValue == true), ("VfxEffect", st?.VfxEffect.HasValue == true),
            ("VfxFacingLeft", st?.VfxFacingLeft.HasValue == true),
        })
        {
            if (present)
            {
                Fail("foreign game: {0} was filled from another game's extras dict -- none of " +
                     "Emerald's keys is one of TEVI's, so a value here means a TEVI extras key now " +
                     "collides with a name another adapter already sends", field);
            }
        }

        // A foreign peer's numbers on TEVI's own keys pass the plugin's coordinate bound; the area compare refuses it.
        const string collide =
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"emerald-peer\",\"state\":{" +
            "\"area_id\":\"0:9\",\"position\":[5,12],\"anim\":\"walking\"," +
            "\"extras\":{\"room_x\":5,\"room_y\":12}}}}";
        if (Survives("foreign game (colliding keys)", collide, out Drain d2) && d2.Rendered.Count == 1)
        {
            var st2 = d2.Rendered[0].State;
            if (st2?.RoomX != 5 || st2?.RoomY != 12)
            {
                Fail("foreign game: room coordinates arrived as ({0}, {1}), want (5, 12) -- a " +
                     "foreign peer's room numbers are in range and must arrive unaltered; what " +
                     "refuses this peer is the area_id compare, never the coordinate bound",
                    st2?.RoomX, st2?.RoomY);
            }
        }
        else
        {
            Fail("foreign game: a state with in-range room coordinates was dropped -- if this ever " +
                 "becomes the behaviour it is a change worth knowing about, not a pass");
        }
    }
}
