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
//
// WHAT A WRONG KEY COST THIS FILE, and why the counters below are assertions rather than prints.
// Until 2026-09-08 the extreme-numerics loop fed `extras` keys named `anim_time` and `temp_pause`
// -- the names of the C# FIELDS on RemoteState -- while the decoder reads `extras["anim_t"]` and
// `extras["pause"]` (BridgeClient.cs:727-728). Every value therefore decoded to null, the loop
// that exists to prove "a non-finite float reaching a callback is impossible" inspected nothing,
// and it printed `0 reached a callback non-finite (want 0)` whatever the decoder did. The wrong-
// type category had the same hole one level up: `anim_time`/`temp_pause` sat at STATE level, where
// the decoder reads only area_id/position/orientation/anim/extras, so those 18 lines exercised the
// handling of an unknown field and nothing more. That is the 2026-09-03 "passed while exercising
// nothing" lesson quoted at the top of this file, reproduced inside the file that quotes it.
// The fix is not a better comment. It is that each category now has an assertion that can only be
// satisfied by a value ARRIVING at the callback, so a key nothing reads fails the run.

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
        ExtrasRealKeys();
        Malformed();
        WrongTypes();
        ExtrasWrongTypes();
        Extremes();
        Depth();
        PeerStrings();
        ForeignGamePeer();

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
            // Two unknown STATE-level keys, kept deliberately as the one pair that stays here.
            // They were `anim_time`/`temp_pause` × nine shapes until 2026-09-08, written in the
            // belief that this was the timing fields' wrong-type coverage; the decoder reads
            // neither name and reads nothing at state level beyond area_id/position/orientation/
            // anim/extras, so all 18 lines were testing "an unknown key is ignored" twice over.
            // That property is worth one line each, and the real coverage moved to
            // ExtrasWrongTypes below, at the keys BridgeClient.cs:723-731 actually reads.
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"anim_time\":1}}}",
            "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p\",\"state\":{\"temp_pause\":{\"a\":1}}}}",
        };

        foreach (string line in lines)
        {
            Survives("wrong type", line, out _);
        }
    }

    // 5b. THE SAME CATEGORY, AT THE KEYS THE DECODER READS. Every peer-controlled `extras` key in
    // BridgeClient.cs:723-731 -- room_x, room_y, trail, weapon_rgba, anim_t, pause, vfx_seq,
    // vfx_id, vfx_left -- crossed with every JSON shape a peer can put there. None of these keys
    // was fed at its real name by any test before 2026-09-08 (review item H5), so the casts that
    // read them had no hostile-input coverage at all: `(int?)extras["room_x"]` on a string, on a
    // container, on a value past int, and `(bool?)extras["vfx_left"]` on a number.
    //
    // TWO OUTCOMES ARE BOTH CORRECT and the harness does not pick between them: Newtonsoft either
    // coerces the value (a bool becomes 1) or throws, and a throw lands in DrainInto's per-line
    // catch and the line is dropped. What is asserted is the pair of properties that must hold
    // whichever way it goes -- nothing escapes to the caller, and one odd extras value never
    // corrupts the rest of the same state.
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
            // Past int in both directions. -2147483648 IS a legal int, so it decodes and reaches
            // the callback: the place it is judged is the plugin's own bound
            // (Plugin.cs:378-380), which is where review item I22 lives -- that is plugin source
            // and out of this harness's reach, since only BridgeClient.cs compiles here.
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

        // The harness fails if the whole category was dropped, because "every line was refused"
        // and "every line was fed at a key nothing reads" produce the same silence -- which is the
        // 2026-09-08 defect this category was rewritten to close.
        if (decoded == 0)
        {
            Fail("extras wrong types: all {0} line(s) were dropped, so not one extras cast was " +
                 "exercised -- either the decoder stopped decoding or these keys are wrong again",
                keys.Length * values.Length);
        }
        Console.WriteLine("  TEVI: extras wrong-typed values: " + decoded + " decoded, " + dropped +
                          " dropped (both are correct answers for a bad value; a throw is not)");
    }

    // 6. EXTREME NUMERICS, high and low (shared corpus category 2). Type boundaries and the values
    // just past them, plus the ones a peer reaches legally -- 1e999 is VALID JSON, so infinity
    // arrives without anyone writing "inf". Newtonsoft's float cast turns out-of-range doubles and
    // the "NaN"/"Infinity" strings into non-finite values WITHOUT throwing, which is why
    // BridgeClient.FiniteOrNull exists; this asserts that guard actually holds rather than
    // assuming it, for every shape a peer can send.
    //
    // THE KEYS ARE `anim_t` AND `pause`, INSIDE `extras`, AND NOTHING ELSE WILL DO -- see the
    // header. Two assertions now stand between this loop and a repeat of the 2026-09-08 defect:
    // a finite raw MUST arrive at the callback with the value it had (a null there means the key
    // is being ignored again), and `reached` MUST end non-zero (a category that inspects nothing
    // is a failure, not a pass).
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
                // Refusing the line outright is a legal answer -- Newtonsoft may decline to read
                // the literal at all. Counted and printed rather than passed over in silence,
                // because a dropped line inspects exactly as much as a wrong key does.
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

        // THE ASSERTION THAT MAKES THE PRINT ABOVE MEAN SOMETHING. Without it, `nonFinite == 0`
        // reads identically whether FiniteOrNull is holding or the loop is inspecting nothing --
        // and until the keys were corrected on 2026-09-08 it was the latter. Reproduced that day by
        // putting the old key names back: 27 assertions fire, 26 of them "arrived absent".
        if (reached == 0)
        {
            Fail("extremes: not one of the {0} extreme form(s) reached the callback with a value, so " +
                 "the FiniteOrNull guard was never exercised -- check the extras keys against " +
                 "BridgeClient.cs:727-728 before believing the count below", raws.Length);
        }

        Console.WriteLine("  TEVI: " + raws.Length + " extreme numeric form(s) fed; " + reached +
                          " value(s) reached a callback, " + dropped + " line(s) dropped; " + nonFinite +
                          " reached a callback non-finite (want 0)");
    }

    // What FiniteOrNull SHOULD be handed for a given raw JSON scalar, computed rather than
    // hard-coded so the expectation cannot drift out of step with the corpus above. Returns false
    // for anything non-finite once narrowed to float -- which includes 3.4028236e38, just past
    // float.MaxValue, where the double-to-float narrowing yields infinity and raises nothing.
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

    // 1b. THE SECOND CONTROL: EVERY `extras` KEY, AT ITS WIRE NAME, CARRYING A LEGAL VALUE.
    // Added 2026-09-08 with the H5 fix, and it is the piece that makes a wrong key impossible to
    // miss again: Control() above proves the decoder decodes, but it sends no extras at all, so
    // every extras key could be renamed on either side and Control() would stay green.
    //
    // These nine names are the wire contract between TEVI and TEVI, written by SendLocalState
    // (BridgeClient.cs:600-640) and read by DrainInto (:723-731) with the core carrying them
    // through opaquely (contract.md: extras is free-form and never interpreted by the core). Both
    // halves live in one file, which is exactly why a rename in one half is easy to miss -- so
    // each assertion below names the RemoteState field and the wire key together.
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

    // 8. A COHERENT PEER FROM ANOTHER GAME (review item N3, 2026-09-08). Every fuzz category above
    // feeds an INVALID value; this one is interesting because every field is individually valid and
    // only the COMBINATION is wrong -- an Emerald adapter that changed one constant and joined a
    // TEVI room. `game_id` is self-declared and `only_game` is a plain string compare, so nothing
    // upstream can refuse this without the core or the relay learning what a game is, which is the
    // invariant the whole project is built on (CLAUDE.md, ADR 08-20). So this is not a defect to
    // prevent: the work is to KNOW what TEVI does with it, and to pin that rather than assume it.
    //
    // The shape is Emerald's own: area_id "mapGroup:mapNum" (meshghost_emerald.lua:1332), anim one
    // of idle/walking/running (:1324-1328), a compass-word orientation, a two-element TILE position
    // (:811), and an extras dict of Emerald's own keys (:811) -- none of which is one of TEVI's.
    //
    // WHAT IS ASSERTED, and it is deliberately not "this is refused":
    //   * The line is decoded and dispatched, exactly once. Refusing it would be the surprise.
    //   * Every value arrives verbatim. area_id, anim and the coordinates are peer data the
    //     decoder must never coerce, clamp or rescale -- a transform the game never displayed is
    //     the nonsense outcome, and inventing one is the only way this could produce one.
    //   * Not one of Emerald's extras keys lands in a TEVI field. This is the assertion that
    //     fires if a future TEVI extras key is named after one another adapter already sends: a
    //     foreign number would then be adopted as a TEVI room coordinate or effect id.
    //
    // WHAT REFUSES IT, and why it cannot be asserted here: the anim is refused by
    // IsPlayableAnimName, which asks the ghost's own Animator (Plugin.cs:589, HasState -- the same
    // lookup Play does), and the map marker is refused by `state.AreaId == currentLocalArea`
    // (Plugin.cs:383), which a foreign area_id never satisfies. Both live in Plugin.cs, which needs
    // Unity and is not compiled here (see the .csproj header) -- so this harness pins the half it
    // owns, that both gates are handed the peer's real string to judge.
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

        // Emerald's extras keys and TEVI's do not overlap, so every TEVI extras field must be
        // absent. "Absent" is the only honest reading of a key that was never sent: RemoteState's
        // own comments define null as "not present on this message", and a defaulted 0 would be a
        // room 0,0 and effect 0 asserted on the peer's behalf.
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

        // The other direction of the same case: a foreign peer whose numbers happen to land on
        // TEVI's OWN extras keys. Emerald tile coordinates are small, so they sail through the
        // plugin's sanity bound (Plugin.cs:378-380, |v| <= 100000) -- that bound is not what stops
        // a foreign peer, and this pins that it is not, so nobody later reads it as the defence.
        // The area compare at Plugin.cs:383 is.
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
