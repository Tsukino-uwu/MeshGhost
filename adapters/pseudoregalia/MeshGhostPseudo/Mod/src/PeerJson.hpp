#pragma once

// PeerJson -- the peer-facing JSON field readers, and the bounds that make their results safe to
// hand to the engine.
//
// WHY THIS IS A HEADER AND NOT PART OF Plugin.cpp. These functions read bytes a STRANGER wrote.
// They lived file-local in Plugin.cpp's anonymous namespace, which meant nothing could call them
// without UE4SS, Unreal and a running game -- so the one part of this adapter that parses hostile
// input was the one part that could never be tested. Lifted here 2026-09-04 so
// MeshGhostPseudo.Tests/peer_json_fuzz.cpp can compile them on a Linux CI runner with no game at
// all. Nothing else changed: every function below is the code that shipped, comments included,
// because those comments record the reasoning that is now under test.
//
// STANDARD LIBRARY ONLY, AND THAT IS THE POINT. No UE4SS type, no Unreal type, no windows.h. The
// two conversions that DO need them -- to_utf8 (WideCharToMultiByte) and to_wide_ascii (returns
// StringType) -- deliberately stay in Plugin.cpp. Pulling either one in here would make this
// header un-compilable on Linux and retire the whole exercise.
//
// <cstdint> is included explicitly. MSVC supplies uint32_t transitively through other headers and
// g++ does not, and this header is compiled by g++ for the first time in its life.

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>

namespace MeshGhostPseudo
{
    // Minimal, non-general JSON field extraction -- deliberately not a full parser, matching
    // the Lua adapter's own minimalism (its jsonString()/hand-built envelopes, not a generic
    // decoder). This data is NOT trusted input, despite the fixed envelope shape: it arrives
    // over the bridge socket as a render_remote line originated by a remote peer, forwarded
    // by the Go core, which only bounds it by total serialized byte size
    // (protocol.MaxExtrasBytes) -- not by per-field type, range, or finiteness. See
    // adapters/_template/PROTOCOL.md's own "peer-controlled" warning on render_remote data,
    // and clamp_to_uint8's comment below for the specific narrowing hazard this file already
    // guards against. What actually makes this minimal string-search parser safe to use on
    // untrusted bytes is narrower than "the format is fixed-shape": see json_number_field's
    // comment just below for the real reason a whole-string search doesn't misparse.

    // Minimal JSON string escaping -- only quote and backslash are realistically possible in
    // an Unreal object path (e.g. "/Game/Maps/ZONE_LowerCastle.ZONE_LowerCastle:PersistentLevel"),
    // but escaped defensively to match the Lua adapter's jsonString() safety.
    inline auto json_escape(const std::string& s) -> std::string
    {
        std::string out;
        out.reserve(s.size() + 2);
        for (char c : s)
        {
            if (c == '"' || c == '\\')
            {
                out.push_back('\\');
            }
            out.push_back(c);
        }
        return out;
    }

    // Appends one code point to out as UTF-8. Used by json_string_field's \uXXXX handling.
    inline auto append_utf8(std::string& out, uint32_t cp) -> void
    {
        if (cp <= 0x7F)
        {
            out.push_back(static_cast<char>(cp));
        }
        else if (cp <= 0x7FF)
        {
            out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
        else if (cp <= 0xFFFF)
        {
            out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
        else
        {
            out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
    }

    // Reads exactly four hex digits at pos. Not strtol, which would read past four and accept
    // a sign.
    inline auto json_hex4(const std::string& s, size_t pos, uint32_t& out) -> bool
    {
        if (pos + 4 > s.size())
        {
            return false;
        }
        uint32_t v = 0;
        for (size_t i = 0; i < 4; ++i)
        {
            const char c = s[pos + i];
            v <<= 4;
            if (c >= '0' && c <= '9') { v |= static_cast<uint32_t>(c - '0'); }
            else if (c >= 'a' && c <= 'f') { v |= static_cast<uint32_t>(c - 'a' + 10); }
            else if (c >= 'A' && c <= 'F') { v |= static_cast<uint32_t>(c - 'A' + 10); }
            else { return false; }
        }
        out = v;
        return true;
    }

    // ESCAPES ARE HONOURED HERE, AND IT IS NOT POLISH. Until 2026-09-03 this scanned for the
    // next bare '"' and returned the raw bytes between, so a display name containing a quote --
    // which the wire carries as \" -- ended the string early and the player saw their name cut
    // at a backslash. Found live by the user testing a deliberately nasty name:
    // uwu325235#"..."****?_ rendered on the ghost's nametag as `uwu325235#\`. The same bug
    // handed back \uXXXX and \ literally, so either one displayed as its escape rather than
    // as the character it stands for.
    //
    // Both Pokemon adapters had their own JSON decoders fixed the same day (a depth cap on
    // one, a \uXXXX decoder on the other). This file is the sibling that was missed -- the
    // shape ideas.md calls "rules that live in one code path and are missing from their
    // sibling".
    //
    // Still deliberately NOT a general JSON parser: it finds one key by whole-string search
    // and reads one string value. Why that stays safe on hostile input is json_number_field's
    // comment below -- and note that argument RESTS on values being properly escaped on the
    // wire, which is exactly what this function now decodes instead of taking on trust.
    // Decode a JSON string body starting at `pos`, which is the byte AFTER the opening quote.
    // Split out of json_string_field 2026-09-04 so the scoped readers below can reuse the
    // escape handling without re-finding the key. The body is untouched.
    inline auto json_decode_string_at(const std::string& s, size_t pos) -> std::string
    {
        std::string out;
        for (size_t i = pos; i < s.size(); ++i)
        {
            const char c = s[i];
            if (c == '"')
            {
                return out; // the real end of the string
            }
            if (c != '\\')
            {
                out.push_back(c);
                continue;
            }
            if (++i >= s.size())
            {
                break; // trailing backslash: a truncated line
            }
            switch (s[i])
            {
            case '"': out.push_back('"'); break;
            case '\\': out.push_back('\\'); break;
            case '/': out.push_back('/'); break;
            case 'b': out.push_back('\b'); break;
            case 'f': out.push_back('\f'); break;
            case 'n': out.push_back('\n'); break;
            case 'r': out.push_back('\r'); break;
            case 't': out.push_back('\t'); break;
            case 'u':
            {
                uint32_t cp = 0;
                if (!json_hex4(s, i + 1, cp))
                {
                    return {}; // malformed: refuse the field rather than guess
                }
                i += 4;
                // A surrogate PAIR is two escapes standing for one character; a lone or
                // mispaired surrogate is not a code point at all and becomes U+FFFD rather
                // than being encoded as though it were one.
                if (cp >= 0xD800 && cp <= 0xDBFF)
                {
                    uint32_t lo = 0;
                    if (i + 6 < s.size() && s[i + 1] == '\\' && s[i + 2] == 'u' && json_hex4(s, i + 3, lo) && lo >= 0xDC00 && lo <= 0xDFFF)
                    {
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        i += 6;
                    }
                    else
                    {
                        cp = 0xFFFD;
                    }
                }
                else if (cp >= 0xDC00 && cp <= 0xDFFF)
                {
                    cp = 0xFFFD;
                }
                append_utf8(out, cp);
                break;
            }
            default:
                return {}; // not a JSON escape: this line is not what it claims to be
            }
        }
        return {}; // no closing quote before the end of the line
    }

    inline auto json_string_field(const std::string& s, const std::string& key) -> std::string
    {
        std::string needle = "\"" + key + "\":\"";
        size_t pos = s.find(needle);
        if (pos == std::string::npos)
        {
            return {};
        }
        return json_decode_string_at(s, pos + needle.size());
    }

    inline auto json_vec3_field(const std::string& s, const std::string& key, double& a, double& b, double& c) -> bool
    {
        std::string needle = "\"" + key + "\":[";
        size_t pos = s.find(needle);
        if (pos == std::string::npos)
        {
            return false;
        }
        pos += needle.size();
        return std::sscanf(s.c_str() + pos, "%lf,%lf,%lf", &a, &b, &c) == 3;
    }

    // Same minimal-parser philosophy as json_string_field/json_vec3_field above. Used for the
    // animation-state fields nested under "extras" -- key names (move_state, h_speed, etc.)
    // are distinct enough that a whole-string search is safe without properly scoping to the
    // "extras" object, same tradeoff already made for every other field here. This holds even
    // against a hostile peer, not just a well-behaved one: JSON string values are escaped when
    // serialized, so a peer-controlled string field (e.g. anim, area_id, player_id) can never
    // contain a literal, unescaped `"h_speed":` substring that this search could mistake for
    // the real key -- any such content would itself be escaped (e.g. `\"h_speed\":`) in the
    // serialized bytes, which does not match the bare needle searched for here. The numeric
    // *value* found this way is still fully attacker-controlled, though -- that's what
    // clamp_to_uint8 below exists to bound before use.
    inline auto json_number_field(const std::string& s, const std::string& key, double& out) -> bool
    {
        std::string needle = "\"" + key + "\":";
        size_t pos = s.find(needle);
        if (pos == std::string::npos)
        {
            return false;
        }
        pos += needle.size();
        return std::sscanf(s.c_str() + pos, "%lf", &out) == 1;
    }

    // Clamps a remote-controlled double to a valid uint8_t range before narrowing. Added in
    // a review pass: static_cast<uint8_t>(double) is undefined behavior -- not just "wraps",
    // the way an integer-to-integer narrowing would -- if the value is NaN or outside
    // [0, 255]. move_state/action_state/anim_jump_type/movement_mode all come from a remote
    // peer's extras map, which the Go core only bounds by serialized byte size
    // (protocol.MaxExtrasBytes), not by per-field numeric range or finiteness -- unlike
    // Position, which the core's own storeRemoteState now rejects outright if non-finite
    // (see the ADR in agent_docs/architecture.md), extras values reach here unchecked.
    inline auto clamp_to_uint8(double value) -> uint8_t
    {
        if (std::isnan(value) || value < 0.0)
        {
            return 0;
        }
        if (value > 255.0)
        {
            return 255;
        }
        return static_cast<uint8_t>(value);
    }

    // ---------------------------------------------------------------------------------------
    // SCOPED READING, 2026-09-04 -- because the whole-string search above is shadowable.
    //
    // json_number_field's comment argues a bare needle search is safe against a hostile peer
    // because peer STRINGS are escaped, so one can never contain a bare needle. That is true, and
    // it is not the whole wire. Measured by MeshGhostPseudo.Tests/peer_json_fuzz.cpp against the
    // real field order of protocol.State (player_id, seq, timestamp, area_id, position,
    // orientation, anim, extras, prev -- encoding/json emits struct fields in declaration order):
    //
    //   * orientation is json.RawMessage: raw, UNESCAPED JSON, bounded only by bytes and depth,
    //     and it marshals BEFORE anim and extras. "orientation":{"h_speed":1e999} put +inf in
    //     front of the real h_speed. The escaping argument never covered it, because orientation
    //     is not a string.
    //   * extras is omitempty, so a sample carrying no extras of its own but carrying a prev
    //     that has them left exactly one match, and it was prev's: a stale value read as current.
    //   * encoding/json marshals MAP keys sorted, so a peer picks an extras key that sorts before
    //     the real one and nests the needle inside it. Depth 2, well inside MaxJSONDepth.
    //
    // The fix is to stop searching the whole line and instead read a named member of a named
    // object at ITS OWN top level. Still not a general JSON parser and still allocation-free: it
    // tracks nesting depth and string state, which is exactly what "first match wins" lacked.
    //
    // The unscoped readers above are KEPT and still correct for the bridge envelope (type,
    // payload, player_id), where there is one object and no peer-controlled key precedes a real
    // one.
    //
    // These use named byte constants rather than character escapes on purpose: this code is
    // ABOUT quotes and backslashes, and spelling them as escapes is how such a scanner ends up
    // subtly wrong in a way review does not catch.
    inline constexpr char kJsonQuote = static_cast<char>(34);
    inline constexpr char kJsonBackslash = static_cast<char>(92);

    inline auto json_is_space(char c) -> bool
    {
        return c == ' ' || c == static_cast<char>(9) || c == static_cast<char>(10) || c == static_cast<char>(13);
    }

    // Skips the string whose opening quote is at s[i]; returns the index of the closing quote.
    inline auto json_skip_string(const std::string& s, size_t i, size_t end) -> size_t
    {
        for (++i; i < end; ++i)
        {
            if (s[i] == kJsonBackslash)
            {
                ++i;
                continue;
            }
            if (s[i] == kJsonQuote)
            {
                return i;
            }
        }
        return std::string::npos;
    }

    // Position of the VALUE of top-level member `key` within the object body [begin, end), or
    // npos. Nested members are skipped, so a key inside a sub-object never matches.
    inline auto json_member_value(const std::string& s, size_t begin, size_t end, const std::string& key) -> size_t
    {
        if (end > s.size())
        {
            end = s.size();
        }
        int depth = 0;
        size_t i = begin;
        while (i < end)
        {
            const char c = s[i];
            if (c == kJsonQuote)
            {
                const size_t start = i + 1;
                const size_t close = json_skip_string(s, i, end);
                if (close == std::string::npos)
                {
                    return std::string::npos;
                }
                if (depth == 0)
                {
                    size_t k = close + 1;
                    while (k < end && json_is_space(s[k]))
                    {
                        ++k;
                    }
                    if (k < end && s[k] == ':')
                    {
                        const size_t len = close - start;
                        if (len == key.size() && s.compare(start, len, key) == 0)
                        {
                            size_t v = k + 1;
                            while (v < end && json_is_space(s[v]))
                            {
                                ++v;
                            }
                            return v < end ? v : std::string::npos;
                        }
                    }
                }
                i = close + 1;
                continue;
            }
            if (c == '{' || c == '[')
            {
                ++depth;
            }
            else if (c == '}' || c == ']')
            {
                if (depth == 0)
                {
                    return std::string::npos;
                }
                --depth;
            }
            ++i;
        }
        return std::string::npos;
    }

    // Body span of the object whose opening brace sits at `pos`; [begin, end) excludes the braces.
    inline auto json_body_at(const std::string& s, size_t pos, size_t limit, size_t& begin, size_t& end) -> bool
    {
        if (limit > s.size())
        {
            limit = s.size();
        }
        if (pos >= limit || s[pos] != '{')
        {
            return false;
        }
        begin = pos + 1;
        int depth = 1;
        for (size_t i = begin; i < limit; ++i)
        {
            const char c = s[i];
            if (c == kJsonQuote)
            {
                const size_t close = json_skip_string(s, i, limit);
                if (close == std::string::npos)
                {
                    return false;
                }
                i = close;
                continue;
            }
            if (c == '{')
            {
                ++depth;
            }
            else if (c == '}' && --depth == 0)
            {
                end = i;
                return true;
            }
        }
        return false;
    }

    // The body of the outermost object -- the whole bridge line.
    inline auto json_root_body(const std::string& s, size_t& begin, size_t& end) -> bool
    {
        const size_t open = s.find('{');
        return open != std::string::npos && json_body_at(s, open, s.size(), begin, end);
    }

    // The body of a named object member, e.g. "extras" inside the state object.
    inline auto json_object_member(const std::string& s, size_t begin, size_t end, const std::string& key,
                                   size_t& out_begin, size_t& out_end) -> bool
    {
        const size_t v = json_member_value(s, begin, end, key);
        return v != std::string::npos && json_body_at(s, v, end, out_begin, out_end);
    }

    inline auto json_string_member(const std::string& s, size_t begin, size_t end, const std::string& key) -> std::string
    {
        const size_t v = json_member_value(s, begin, end, key);
        if (v == std::string::npos || s[v] != kJsonQuote)
        {
            return {};
        }
        return json_decode_string_at(s, v + 1);
    }

    inline auto json_number_member(const std::string& s, size_t begin, size_t end, const std::string& key, double& out) -> bool
    {
        const size_t v = json_member_value(s, begin, end, key);
        if (v == std::string::npos)
        {
            return false;
        }
        // The value must START with a digit or a minus sign. JSON allows nothing else to begin a
        // number, while glibc's sscanf happily accepts nan, inf, infinity, a leading plus, and
        // hex floats -- 34 of 39 raw forms, measured by the harness. Refusing them here means a
        // non-finite value cannot enter through this door at all, rather than being caught later
        // by whichever clamp the call site remembered to apply.
        // A minus sign may lead, but a DIGIT must follow it. Checking only "digit or minus" is
        // not enough and the harness caught exactly that: "-inf" passes a leading-sign test and
        // sscanf then returns -infinity. JSON has no leading plus and no bare sign either.
        size_t d = v;
        if (s[d] == '-')
        {
            ++d;
        }
        if (d >= s.size() || !(s[d] >= '0' && s[d] <= '9'))
        {
            return false;
        }
        return std::sscanf(s.c_str() + v, "%lf", &out) == 1;
    }

    inline auto json_vec3_member(const std::string& s, size_t begin, size_t end, const std::string& key,
                                 double& a, double& b, double& c) -> bool
    {
        const size_t v = json_member_value(s, begin, end, key);
        if (v == std::string::npos || s[v] != '[')
        {
            return false;
        }
        return std::sscanf(s.c_str() + v + 1, "%lf,%lf,%lf", &a, &b, &c) == 3;
    }

    // ---------------------------------------------------------------------------------------
    // THE BOUNDING VOCABULARY, 2026-09-04. clamp_to_uint8 above was the first of these and was
    // the only one until 2026-09-04; an audit of every peer double in Plugin.cpp then found NINE
    // narrowings that never called it, including static_cast<uint8_t>(target_weapon_state) --
    // literally the operation it exists for. Three more shapes were needed, so they are named
    // here, next to it, rather than hand-written at each call site where nobody can check them.
    //
    // isfinite IS NOT ENOUGH IN FRONT OF A float CAST, and that is the part that keeps being
    // missed. 1e300 is a perfectly finite double and is NOT representable as a float, so
    // static_cast<float>(1e300) is undefined behaviour exactly as static_cast<float>(NaN) is.
    // Any guard that only asks isfinite still admits it. clamp_to_float therefore bounds
    // MAGNITUDE, and its lo/hi are floats precisely so that the value is provably inside float's
    // range by the time the cast happens.

    // A non-finite peer value becomes the caller's stated fallback. Use where the value is a
    // double all the way down and no narrowing follows -- the shape the orientation guard in
    // handle_bridge_line already applies by hand.
    inline auto finite_or(double value, double fallback) -> double
    {
        return std::isfinite(value) ? value : fallback;
    }

    // Narrow a peer double to float, safely. NaN and anything outside [lo, hi] are pinned to the
    // range rather than refused, because these are continuous visual quantities (a capsule
    // height, a timeline position, a colour channel) where a bounded wrong value is a ghost that
    // looks odd for one frame and an unbounded one is undefined behaviour.
    inline auto clamp_to_float(double value, float lo, float hi) -> float
    {
        if (std::isnan(value) || value < static_cast<double>(lo))
        {
            return lo;
        }
        if (value > static_cast<double>(hi))
        {
            return hi;
        }
        return static_cast<float>(value);
    }

    // Narrow a peer double to int, safely. Out of range REFUSES to the fallback rather than
    // pinning, which is the opposite of clamp_to_float and deliberately so: these are counts and
    // discrete states, where a clamped value is a wrong action taken confidently and the
    // fallback is "behave as though the peer had not sent this". Generalised from the bound
    // afterimage_n already carries (finite, 1..MAX_PEER_AFTERIMAGE_SPAWN, else the historical 6).
    inline auto clamp_count_to_int(double value, int lo, int hi, int fallback) -> int
    {
        if (!std::isfinite(value) || value < static_cast<double>(lo) || value > static_cast<double>(hi))
        {
            return fallback;
        }
        return static_cast<int>(value);
    }
} // namespace MeshGhostPseudo
