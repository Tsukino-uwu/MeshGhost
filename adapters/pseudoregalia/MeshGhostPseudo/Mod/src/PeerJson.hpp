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
    inline auto json_string_field(const std::string& s, const std::string& key) -> std::string
    {
        std::string needle = "\"" + key + "\":\"";
        size_t pos = s.find(needle);
        if (pos == std::string::npos)
        {
            return {};
        }
        pos += needle.size();

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
