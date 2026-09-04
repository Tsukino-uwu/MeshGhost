// peer_json_fuzz -- hostile input against Pseudoregalia's SHIPPED peer-JSON readers.
//
// WHAT THIS REACHES, stated plainly so a green tick is not read as more than it is. It reaches the
// seven functions in PeerJson.hpp and the bounds beside them -- json_escape, append_utf8,
// json_hex4, json_string_field, json_vec3_field, json_number_field, clamp_to_uint8, finite_or,
// clamp_to_float, clamp_count_to_int -- compiled from the real header, never a copy. It does NOT
// reach handle_bridge_line's DISPATCH, which is welded to Unreal thousands of lines further down
// in Plugin.cpp. TEVI's harness is stronger on that axis because its whole decode-and-dispatch
// path lives in one engine-free file; this adapter's does not, and pretending otherwise would be
// the "verification that answers a different question" failure lua.yml's header warns about.
//
// WHY THE ADAPTER TARGETS EXIST AT ALL. Every value in a bridge message has already passed the Go
// core's wire limits and ValidateState -- MaxLineBytes, MaxExtrasBytes, MaxJSONDepth,
// IsValidPosition, SanitizeDisplayName. These checks are for the case those cannot reach: a bridge
// that is not ours, or a core that is compromised or buggy. An adapter that is only safe when
// paired with a correct core is not safe.
//
// LIBC MATTERS HERE. sscanf's "%lf" acceptance set is libc-specific: glibc takes nan, inf,
// infinity, hex floats, leading whitespace and a sign, none of which JSON emits. Every leniency
// number this prints is therefore a LINUX number and a strong hint -- not a measurement -- about
// the MSVC build that actually ships.
//
// A DETERMINISTIC SEEDED LOOP, not libFuzzer. The input space is one line of text; a fixed corpus
// plus a seeded generator finds the same defects with no new toolchain, and reproduces exactly.
//
// NO assert(). NDEBUG would silently empty this file. Every check appends to `failures` and the
// run always reaches the end, because the next run costs a push.

#include <PeerJson.hpp>

#include <cinttypes>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <string>
#include <vector>

using namespace MeshGhostPseudo;

namespace
{
    std::vector<std::string> g_failures;
    std::vector<std::string> g_report;
    long g_checks = 0;

    auto fail(const std::string& msg) -> void
    {
        g_failures.push_back(msg);
    }

    auto note(const std::string& msg) -> void
    {
        g_report.push_back(msg);
    }

    // Printable form of an arbitrary byte string, so a failure line is readable and a control
    // character in the corpus cannot scramble the terminal reporting it.
    auto show(const std::string& s) -> std::string
    {
        std::string out = "\"";
        size_t shown = 0;
        for (unsigned char c : s)
        {
            if (shown++ >= 60)
            {
                out += "...";
                break;
            }
            if (c >= 0x20 && c < 0x7F)
            {
                out.push_back(static_cast<char>(c));
            }
            else
            {
                char buf[8];
                std::snprintf(buf, sizeof buf, "\\x%02X", c);
                out += buf;
            }
        }
        out += "\" (" + std::to_string(s.size()) + "B)";
        return out;
    }

    auto expect_str(const std::string& label, const std::string& got, const std::string& want) -> void
    {
        ++g_checks;
        if (got != want)
        {
            fail(label + ": got " + show(got) + ", want " + show(want));
        }
    }

    auto expect_num(const std::string& label, double got, double want) -> void
    {
        ++g_checks;
        if (!(std::fabs(got - want) < 1e-9))
        {
            fail(label + ": got " + std::to_string(got) + ", want " + std::to_string(want));
        }
    }

    auto expect_true(const std::string& label, bool cond) -> void
    {
        ++g_checks;
        if (!cond)
        {
            fail(label);
        }
    }

    // ------------------------------------------------------------------------------------------
    // The line the adapter actually receives, in the order Go actually emits.
    //
    // Field order is NOT cosmetic here and must not be "tidied": protocol.State declares
    // player_id, seq, timestamp, area_id, position, orientation(omitempty), anim,
    // extras(omitempty), prev(omitempty), and encoding/json marshals struct fields in declaration
    // order. json_number_field finds a key by whole-string search and takes the FIRST match, so
    // that order is what decides whether a peer can shadow a real field. Shadowing() below tests
    // exactly that, and it is only meaningful against a realistic line.
    const std::string kControlLine =
        "{\"type\":\"render_remote\",\"payload\":{\"player_id\":\"p1\",\"state\":{"
        "\"player_id\":\"p1\",\"seq\":42,\"timestamp\":1690000000000,"
        "\"area_id\":\"ZONE_Dungeon\",\"position\":[1.5,-2.25,3.0],"
        "\"orientation\":[0.0,90.0,0.0],\"anim\":\"run\","
        "\"extras\":{\"h_speed\":420.5,\"move_state\":3,\"slide_t\":0.75,"
        "\"outfit_mesh\":\"/Game/Char/SK_Sybil.SK_Sybil\"}}}}";

    // Strings a hostile peer might send, plus strings a PERFECTLY LEGITIMATE modded peer sends.
    //
    // THE MOD-COMPATIBILITY RULE, and it is a requirement rather than a nicety: a peer running a
    // modded outfit or a modded weapon must still be visible to a watcher who has that mod
    // installed locally. resolve_peer_named_asset (Plugin.cpp) enforces that correctly today by
    // resolving a peer's name against a catalog of the LOCAL game's own loaded assets -- so
    // anything the watcher could render, it renders, mods included, and only a name absent locally
    // is refused. Nothing in this harness, and nothing any later hardening pass adds, may narrow
    // that to a hardcoded vanilla allowlist. At THIS layer the property is narrower and still
    // load-bearing: an asset path must survive the parser byte-for-byte, because a truncated or
    // mangled path is a mod that silently stops working.
    const std::vector<std::string> kHostileStrings = {
        "p1",
        "Player One",
        "",
        "../../etc/passwd",
        "..\\..\\windows\\system32",
        "%s%s%s%n",
        "{0}",
        "'; DROP TABLE peers; --",
        "<script>alert(1)</script>",
        "a\"b",
        "a\b",
        "\"h_speed\":9999",              // the escaped-needle control -- must NOT shadow
        "\\\"h_speed\\\":9999",
        "\xE2\x80\xAE" "evil",           // RTL override
        "\xF0\x9F\x98\x80",              // U+1F600, 4-byte UTF-8
        "caf\xC3\xA9",                   // non-ASCII name
        std::string("x", 1) + std::string(4000, 'x'),
        std::string(1, '\x01') + "ctrl",
        // Vanilla asset paths.
        "/Game/Char/SK_Sybil.SK_Sybil",
        "/Game/VFX/Systems/NS_Healing.NS_Healing",
        // MODDED asset paths -- these must round-trip exactly, see the rule above.
        "/Game/Mods/AttireOverhaul/SK_GoldDress.SK_GoldDress",
        "/Game/Mods/My Weapon Pack/SK_Blade #2.SK_Blade #2",
        "/Game/Mods/\xC3\x9C" "bermod/SK_Caf\xC3\xA9.SK_Caf\xC3\xA9",
    };

    // ------------------------------------------------------------------------------------------
    // 1. THE CONTROL. First and non-negotiable.
    //
    // Without it, "nothing crashed" reads identically whether the parser works or has quietly
    // stopped parsing. TEVI's harness reported 0 renders for every input on its first run and
    // looked exactly like a broken decoder; it was a broken test using the wrong message shape.
    auto control() -> void
    {
        const std::string& l = kControlLine;

        expect_str("control type", json_string_field(l, "type"), "render_remote");
        expect_str("control player_id", json_string_field(l, "player_id"), "p1");
        expect_str("control area_id", json_string_field(l, "area_id"), "ZONE_Dungeon");
        expect_str("control anim", json_string_field(l, "anim"), "run");
        expect_str("control outfit_mesh", json_string_field(l, "outfit_mesh"), "/Game/Char/SK_Sybil.SK_Sybil");

        double x = 0, y = 0, z = 0;
        expect_true("control position parses", json_vec3_field(l, "position", x, y, z));
        expect_num("control position.x", x, 1.5);
        expect_num("control position.y", y, -2.25);
        expect_num("control position.z", z, 3.0);

        double p = 0, yw = 0, r = 0;
        expect_true("control orientation parses", json_vec3_field(l, "orientation", p, yw, r));
        expect_num("control orientation.yaw", yw, 90.0);

        double v = 0;
        expect_true("control h_speed parses", json_number_field(l, "h_speed", v));
        expect_num("control h_speed", v, 420.5);
        expect_true("control move_state parses", json_number_field(l, "move_state", v));
        expect_num("control move_state", v, 3.0);
        expect_true("control slide_t parses", json_number_field(l, "slide_t", v));
        expect_num("control slide_t", v, 0.75);

        expect_true("control absent field reports absent", !json_number_field(l, "no_such_key", v));
        expect_str("control absent string is empty", json_string_field(l, "no_such_key"), "");

        // The escape decoder, value by value -- a table rather than a spot check, because this
        // decoder was rewritten on 2026-09-03 after a display name with a quote in it rendered
        // cut off at a backslash.
        struct EscCase { std::string json; std::string want; };
        // One backslash, built from its byte value so this source contains no ambiguous
        // escape of its own -- these cases are ABOUT backslashes, and writing them as source
        // escapes makes the test unreadable and easy to get silently wrong.
        const std::string B(1, static_cast<char>(92));
        const EscCase esc[] = {
            {"{\"n\":\"a" + B + "\"b\"}", std::string("a\"b")},
            {"{\"n\":\"a" + B + B + "b\"}", "a" + B + "b"},
            {"{\"n\":\"a" + B + "/b\"}", "a/b"},
            {"{\"n\":\"a" + B + "nb\"}", std::string("a\nb")},
            {"{\"n\":\"a" + B + "tb\"}", std::string("a\tb")},
            {"{\"n\":\"" + B + "u0041\"}", "A"},
            {"{\"n\":\"" + B + "u00e9\"}", std::string("\xC3\xA9")},
            {"{\"n\":\"" + B + "u4e2d\"}", std::string("\xE4\xB8\xAD")},
            {"{\"n\":\"" + B + "ud83d" + B + "ude00\"}", std::string("\xF0\x9F\x98\x80")},  // surrogate PAIR
            {"{\"n\":\"" + B + "ud83d\"}", std::string("\xEF\xBF\xBD")},  // lone high -> U+FFFD
            {"{\"n\":\"" + B + "ude00\"}", std::string("\xEF\xBF\xBD")},  // lone low  -> U+FFFD
            {"{\"n\":\"" + B + "ud83dA\"}", std::string("\xEF\xBF\xBD") + "A"},  // mispaired
        };
        for (const EscCase& c : esc)
        {
            expect_str(std::string("escape ") + c.json, json_string_field(c.json, "n"), c.want);
        }
    }

    // ------------------------------------------------------------------------------------------
    // 2. ROUND TRIP. json_escape is the sender, json_string_field is the receiver, and the whole
    // safety argument for a whole-string needle search rests on the pair being exact. Currently
    // taken on trust; this is the strongest single check available here.
    auto round_trip() -> void
    {
        for (const std::string& s : kHostileStrings)
        {
            const std::string line = "{\"anim\":\"" + json_escape(s) + "\"}";
            const std::string back = json_string_field(line, "anim");
            ++g_checks;
            if (back != s)
            {
                fail("round trip: " + show(s) + " came back as " + show(back) +
                     " -- json_escape and json_string_field must be exact inverses, and a mangled "
                     "asset path is a modded outfit that silently stops working");
            }
        }
    }

    // ------------------------------------------------------------------------------------------
    // 3. KEY SHADOWING -- assumption 1, MEASURED rather than restated.
    //
    // json_number_field's own comment argues a whole-string search is safe against a hostile peer
    // because JSON string values are escaped when serialized, so a peer-controlled string field
    // can never contain a literal, unescaped needle. That argument is correct about STRINGS and
    // does not cover everything on the wire. Three corners below are expected FINDINGS; three are
    // expected safe and are asserted, so a later change shows up here.
    auto shadowing() -> void
    {
        double v = 0;

        // (f) THE HARNESS OWN CONTROL. An escaped needle inside a peer string must not shadow.
        // If this ever shadows, this function cannot tell a shadow from a non-shadow and every
        // other result in it is worthless.
        {
            const std::string l =
                "{\"area_id\":\"a\",\"anim\":\"\\\"h_speed\\\":9999\",\"extras\":{\"h_speed\":1.0}}";
            expect_true("shadow control: escaped needle parses", json_number_field(l, "h_speed", v));
            ++g_checks;
            if (std::fabs(v - 1.0) > 1e-9)
            {
                fail("shadow control: an ESCAPED needle inside a peer string shadowed the real "
                     "h_speed (got " + std::to_string(v) + ", want 1) -- the escaping argument is "
                     "wrong at its root and every other shadowing result here is meaningless");
            }
        }

        // (e) Prefix and suffix collisions. Safe because the needle carries the trailing colon.
        {
            const std::string l = "{\"anim_h_speed\":7,\"xh_speed\":8,\"extras\":{\"h_speed\":1.0}}";
            json_number_field(l, "h_speed", v);
            ++g_checks;
            if (std::fabs(v - 1.0) > 1e-9)
            {
                fail("prefix collision: a key merely CONTAINING h_speed matched (got " +
                     std::to_string(v) + ", want 1)");
            }
        }

        // (a) A peer-controlled extras KEY named after a real top-level field. Safe, because
        // extras marshals AFTER area_id/position/anim and first match wins.
        {
            const std::string l =
                "{\"area_id\":\"REAL\",\"position\":[1.0,2.0,3.0],\"anim\":\"run\","
                "\"extras\":{\"area_id\":\"EVIL\",\"anim\":\"EVIL\"}}";
            ++g_checks;
            if (json_string_field(l, "area_id") != "REAL" || json_string_field(l, "anim") != "run")
            {
                fail("extras-key shadowing: a peer extras key shadowed a real top-level field. "
                     "This is decided by FIELD ORDER in protocol.State -- if that struct were "
                     "reordered so extras precedes area_id/anim, this is the consequence");
            }
        }
    }

    // The three corners the escaping argument does NOT cover. These REPORT rather than fail: they
    // are the truth about a documented assumption, and fixing them is a separate change from
    // measuring them. Turning them into failures before that fix would make the harness red on
    // arrival and its own extraction commit unreviewable.
    auto shadowing_findings() -> void
    {
        double v = 0;

        // (c) orientation is json.RawMessage -- raw, UNESCAPED JSON, bounded only by bytes and
        // depth -- and it marshals BEFORE anim and extras. A peer therefore places a real,
        // unescaped needle ahead of the real field. The escaping argument never covered this,
        // because orientation is not a string.
        {
            const std::string l =
                "{\"area_id\":\"a\",\"position\":[0,0,0],\"orientation\":{\"h_speed\":1e999},"
                "\"anim\":\"run\",\"extras\":{\"h_speed\":1.0}}";
            v = 0;
            const bool ok = json_number_field(l, "h_speed", v);
            note("assumption 1 / orientation (json.RawMessage, marshals before extras): returned " +
                 std::string(ok ? "true" : "false") + " value=" + std::to_string(v) +
                 (std::isfinite(v) ? "" : "  [NON-FINITE, from a field extras validation never saw]") +
                 (std::fabs(v - 1.0) > 1e-9 ? "  [SHADOWED: real value was 1.0]" : "  [not shadowed]"));
        }

        // (b) prev is last, so it cannot shadow a field that is PRESENT -- but extras is
        // omitempty. A sample with no extras of its own, carrying a prev that has them, leaves
        // exactly one match and it is prev's. The adapter then mirrors a stale value as current.
        {
            const std::string l =
                "{\"area_id\":\"a\",\"position\":[0,0,0],\"anim\":\"run\","
                "\"prev\":{\"seq\":41,\"extras\":{\"h_speed\":99.0}}}";
            v = 0;
            const bool ok = json_number_field(l, "h_speed", v);
            note("assumption 1 / prev+omitempty (no current extras, prev has h_speed=99): returned " +
                 std::string(ok ? "true" : "false") + " value=" + std::to_string(v) +
                 (ok ? "  [READ FROM prev -- a stale value mirrored as current]" : "  [absent, correct]"));
        }

        // (d) encoding/json marshals MAP keys sorted, so a peer picks an extras key that sorts
        // before the real one and nests the needle inside it. Depth 2, well inside
        // MaxJSONDepth=32, so the core's shape bound never touches it.
        {
            const std::string l =
                "{\"area_id\":\"a\",\"extras\":{\"aaa\":{\"h_speed\":9999.0},\"h_speed\":1.0}}";
            v = 0;
            json_number_field(l, "h_speed", v);
            note("assumption 1 / sorted map keys (nested aaa.h_speed=9999 before real h_speed=1): "
                 "value=" + std::to_string(v) +
                 (std::fabs(v - 1.0) > 1e-9 ? "  [SHADOWED]" : "  [not shadowed]"));
        }
    }

    // ------------------------------------------------------------------------------------------
    // 4. THE NUMBER INTAKE -- assumption 2.
    //
    // clamp_to_uint8 is sound in itself. The gap the audit found is that nine narrowings in
    // Plugin.cpp never call it, and that isfinite is not a sufficient guard in front of a float
    // cast anyway: 1e300 is a finite double that is NOT representable as float, so
    // static_cast<float>(1e300) is undefined behaviour exactly as static_cast<float>(NaN) is.
    //
    // THE OFFENDING CAST IS NEVER PERFORMED HERE. Under -fno-sanitize-recover the demonstration
    // would abort the run and nothing else would be reported. The value is classified instead.
    auto numbers() -> void
    {
        const char* raws[] = {
            "0", "-0", "1", "-1", "255", "255.9999", "256", "-0.0001",
            "2147483647", "2147483648", "-2147483649", "9007199254740993",
            "3.4028235e38", "3.4028236e38", "1e300", "1e308", "1e309", "1e999", "-1e999",
            "1e-999", "0.1", "1.5", "00123", "+1", " 1", "1.", ".5", "1e", "--1", "0x1p999",
            "nan", "-nan", "inf", "-inf", "infinity", "null", "true", "[]", "{}",
        };

        int accepted = 0;
        int beyond_float = 0;
        for (const char* raw : raws)
        {
            const std::string line = std::string("{\"extras\":{\"slide_t\":") + raw + "}}";
            double v = 12345.0;
            const bool ok = json_number_field(line, "slide_t", v);
            ++g_checks;
            if (ok)
            {
                ++accepted;
            }

            if (ok && (!std::isfinite(v) ||
                       std::fabs(v) > static_cast<double>(std::numeric_limits<float>::max())))
            {
                ++beyond_float;
                note(std::string("  sscanf accepted \"") + raw + "\" -> " +
                     (std::isfinite(v) ? "finite but OUTSIDE FLOAT RANGE" : "NON-FINITE") +
                     "; slide_t reaches static_cast<float> at Plugin.cpp:18566 with no guard");
            }

            // Whatever came back, the bounds must tame it. This is the property that matters, and
            // it is what Part B routes the nine unguarded narrowings through.
            const float f = clamp_to_float(v, 0.0f, 1.0f);
            if (!(f >= 0.0f && f <= 1.0f))
            {
                fail(std::string("clamp_to_float escaped [0,1] on input ") + raw);
            }
            const int n = clamp_count_to_int(v, 1, 64, 6);
            if (n < 1 || n > 64)
            {
                fail(std::string("clamp_count_to_int escaped [1,64] on input ") + raw);
            }
        }
        note("sscanf %lf accepted " + std::to_string(accepted) + " of " +
             std::to_string(sizeof raws / sizeof raws[0]) +
             " raw forms, several of which JSON never emits (glibc; MSVC unmeasured)");
        note(std::to_string(beyond_float) +
             " accepted values are non-finite or outside float range -- each is undefined "
             "behaviour today at an unguarded static_cast<float>");
    }

    // ------------------------------------------------------------------------------------------
    // 5. THE BOUNDS THEMSELVES. clamp_to_uint8 is the one function claimed correct, so pin it,
    // and pin the three added beside it -- Part B routes nine unguarded narrowings through these,
    // so a defect here would be a defect at all nine sites at once.
    auto bounds() -> void
    {
        const double qnan = std::numeric_limits<double>::quiet_NaN();
        const double inf = std::numeric_limits<double>::infinity();
        const double vals[] = {qnan, inf, -inf, 0.0, -0.0, -1.0, 1.0, 254.9, 255.0, 255.9999,
                               256.0, 1e300, -1e300, 1e-320, 2147483648.0, -2147483649.0};
        for (double v : vals)
        {
            ++g_checks;
            const uint8_t b = clamp_to_uint8(v);
            if ((std::isnan(v) || v < 0.0) && b != 0)
            {
                fail("clamp_to_uint8(" + std::to_string(v) + ") = " + std::to_string(b) + ", want 0");
            }
            if (!std::isnan(v) && v > 255.0 && b != 255)
            {
                fail("clamp_to_uint8(" + std::to_string(v) + ") = " + std::to_string(b) + ", want 255");
            }

            const float f = clamp_to_float(v, -10.0f, 10.0f);
            if (std::isnan(f) || !(f >= -10.0f && f <= 10.0f))
            {
                fail("clamp_to_float(" + std::to_string(v) + ") left [-10,10] or is NaN");
            }

            const int n = clamp_count_to_int(v, 1, 64, 6);
            if (n < 1 || n > 64)
            {
                fail("clamp_count_to_int(" + std::to_string(v) + ") = " + std::to_string(n) +
                     ", outside [1,64]");
            }

            if (!std::isfinite(finite_or(v, 0.0)))
            {
                fail("finite_or(" + std::to_string(v) + ") returned a non-finite value");
            }
        }

        // In-range values must pass through UNCHANGED, or a bound is a silent behaviour change at
        // every call site rather than a guard.
        expect_true("clamp_to_uint8 passes 3 through", clamp_to_uint8(3.0) == 3);
        expect_true("clamp_to_float passes 0.75 through", clamp_to_float(0.75, 0.0f, 1.0f) == 0.75f);
        expect_true("clamp_count_to_int passes 6 through", clamp_count_to_int(6.0, 1, 64, 0) == 6);
        expect_true("finite_or passes 1.5 through", finite_or(1.5, 0.0) == 1.5);
    }

    // ------------------------------------------------------------------------------------------
    // 6. MALFORMED AND TRUNCATED. The bar is only that the function RETURNS -- dropping a field is
    // the correct answer to nonsense. Every prefix of the control line is fed through every
    // reader, which is the technique that found the 2026-08-25 Lua hang and costs nothing here.
    auto malformed() -> void
    {
        const std::string B(1, static_cast<char>(92));
        for (size_t cut = 0; cut < kControlLine.size(); ++cut)
        {
            const std::string s = kControlLine.substr(0, cut);
            ++g_checks;
            (void)json_string_field(s, "anim");
            (void)json_string_field(s, "outfit_mesh");
            double a = 0, b = 0, c = 0;
            (void)json_vec3_field(s, "position", a, b, c);
            (void)json_number_field(s, "h_speed", a);
            (void)json_escape(s);
        }

        const std::vector<std::string> lines = {
            "", " ", "\n", "{", "}", "[", "null", "true", "0", "\"a string\"", "[]", "{}",
            "{\"anim\":", "{\"anim\":\"", "{\"anim\":\"unterminated",
            "{\"anim\":\"trailing backslash\\",
            "{\"anim\":\"" + B + "q\"}",                 // not a JSON escape
            "{\"anim\":\"" + B + "u\"}", "{\"anim\":\"" + B + "u00\"}", "{\"anim\":\"" + B + "uZZZZ\"}",
            "{\"anim\":\"" + B + "ud83d",                // truncated after a high surrogate
            "{\"position\":[",  "{\"position\":[1", "{\"position\":[1,2", "{\"position\":[1,2,",
            "{\"position\":[\"a\",\"b\",\"c\"]}",
            "{\"h_speed\":",
            std::string("{\"anim\":\"") + std::string(1, '\0') + "nul\"}",
            "{\"anim\":\"a\",\"anim\":\"b\"}",          // duplicate keys
            std::string(4096, '{'),
            std::string(4096, '\\'),
            "{\"anim\":\"" + std::string(65536, 'x') + "\"}",
            "{\"h_speed\":" + std::string(4000, '9') + "}",
        };
        for (const std::string& l : lines)
        {
            ++g_checks;
            (void)json_string_field(l, "anim");
            double a = 0, b = 0, c = 0;
            (void)json_vec3_field(l, "position", a, b, c);
            (void)json_number_field(l, "h_speed", a);
        }

        // Needle at the very last byte: pos == s.size(), so c_str() + pos lands on the terminator.
        // Legal, and worth pinning because it is the one index the readers compute rather than
        // find.
        ++g_checks;
        double d = 0;
        (void)json_number_field("{\"h_speed\":", "h_speed", d);
        (void)json_string_field("{\"anim\":\"", "anim");
    }

    // ------------------------------------------------------------------------------------------
    // 7. WRONG TYPE FOR EVERY FIELD. A field that should be a number arrives as a string, a bool,
    // null, an array or an object -- and vice versa. This is the category the Emerald gender bug
    // lived in (a table where a string was expected made the draw loop error every frame for every
    // peer sorted after it), and the one no adapter harness covered systematically.
    auto wrong_types() -> void
    {
        const char* shapes[] = {"\"text\"", "true", "false", "null", "[1,2,3]", "{\"a\":1}", "[]", "{}"};
        const char* keys[] = {"anim", "area_id", "player_id", "h_speed", "slide_t", "move_state",
                              "position", "orientation", "outfit_mesh", "montage", "vfx"};
        for (const char* key : keys)
        {
            for (const char* shape : shapes)
            {
                const std::string l = std::string("{\"") + key + "\":" + shape + "}";
                ++g_checks;
                (void)json_string_field(l, key);
                double a = 0, b = 0, c = 0;
                (void)json_vec3_field(l, key, a, b, c);
                (void)json_number_field(l, key, a);
            }
        }
    }

    // ------------------------------------------------------------------------------------------
    // 8. A SEEDED MUTATOR over the control line. Deterministic: the seed is printed, so a failure
    // reproduces exactly. Not a coverage-guided fuzzer -- the input space is one line of text, and
    // a fixed corpus plus this finds the same defects with no new toolchain in CI.
    auto mutate(uint64_t seed, int rounds) -> void
    {
        uint64_t st = seed;
        auto next = [&st]() -> uint64_t {
            st ^= st << 13;
            st ^= st >> 7;
            st ^= st << 17;
            return st;
        };
        const char* inject = "\"\{}[],:0123456789eE.+-naifty\xC3\xA9\xF0\x9F\x98\x80";
        const size_t inject_len = 34;

        for (int i = 0; i < rounds; ++i)
        {
            std::string s = kControlLine;
            const int edits = static_cast<int>(next() % 8) + 1;
            for (int e = 0; e < edits && !s.empty(); ++e)
            {
                const size_t pos = static_cast<size_t>(next() % s.size());
                switch (next() % 4)
                {
                case 0: s[pos] = inject[next() % inject_len]; break;
                case 1: s.erase(pos, 1 + next() % 8); break;
                case 2: s.insert(pos, 1, inject[next() % inject_len]); break;
                default: s = s.substr(0, pos); break;
                }
            }
            ++g_checks;
            (void)json_string_field(s, "anim");
            (void)json_string_field(s, "outfit_mesh");
            (void)json_string_field(s, "player_id");
            double a = 0, b = 0, c = 0;
            (void)json_vec3_field(s, "position", a, b, c);
            (void)json_vec3_field(s, "orientation", a, b, c);
            (void)json_number_field(s, "h_speed", a);
            (void)json_number_field(s, "slide_t", a);
            (void)clamp_to_uint8(a);
            (void)clamp_to_float(a, 0.0f, 1.0f);
            (void)clamp_count_to_int(a, 1, 64, 6);
            (void)json_escape(s);
        }
    }
} // namespace

auto main() -> int
{
    const uint64_t seed = 0x9E3779B97F4A7C15ULL;

    control();
    round_trip();
    shadowing();
    shadowing_findings();
    numbers();
    bounds();
    malformed();
    wrong_types();
    mutate(seed, 20000);

    std::printf("  %ld checks across the shipped peer-JSON readers (mutator seed 0x%016llx)\n",
                g_checks, static_cast<unsigned long long>(seed));
    if (!g_report.empty())
    {
        std::printf("\nMEASURED (reported, not failed):\n");
        for (const std::string& r : g_report)
        {
            std::printf("  - %s\n", r.c_str());
        }
    }

    if (!g_failures.empty())
    {
        std::printf("\nFAIL: %zu problem(s)\n", g_failures.size());
        for (const std::string& f : g_failures)
        {
            std::printf("  - %s\n", f.c_str());
        }
        return 1;
    }

    std::printf("\nOK: every reader returned on every input, valid input still decodes to the right\n"
                "    values, an asset path (modded ones included) round-trips through json_escape\n"
                "    unchanged, and the bounds hold for every value sscanf will produce.\n");
    return 0;
}
