#pragma once

// The readers of peer-written JSON, and the bounds that make their results safe to hand to the engine. Standard
// library only, so MeshGhostPseudo.Tests compiles them on Linux with no game: to_utf8 and to_wide_ascii need Windows
// or UE4SS types and stay in Plugin.cpp. <cstdint> is explicit because g++, unlike MSVC, does not supply it.

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <unordered_set>
#include <vector>

namespace MeshGhostPseudo
{
    // Minimal field extraction, not a parser. The input is untrusted: a render_remote line a remote peer wrote, which
    // the core bounds by total size, never by per-field type, range or finiteness.

    // Escapes quote and backslash, the two JSON specials an Unreal object path can realistically hold.
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

    // Appends one code point to out as UTF-8.
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

    // Exactly four hex digits at pos; not strtol, which reads past four and accepts a sign.
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

    // Decodes a JSON string body from `pos`, the byte after the opening quote, escapes included: a name holding a
    // quote arrives as \", and a raw scan to the next quote would cut it there.
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
                // A surrogate pair is two escapes for one character; a lone or mispaired surrogate becomes U+FFFD.
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

    // A whole-string search: a peer string value is escaped on the wire, so it can never hold a bare "key": needle,
    // but other fields can (see scoped reading below). The value is attacker-controlled either way.
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

    // static_cast<uint8_t>(double) is undefined, not a wrap, for NaN or anything outside [0, 255], and extras values
    // reach here unchecked by the core.
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

    // Scoped reading. The whole-string search above is shadowable, because not every field is an escaped string
    // (protocol.State marshals in declaration order: player_id, seq, timestamp, area_id, position, orientation, anim,
    // extras, prev):
    //   - orientation is raw JSON and marshals before anim and extras, so it can carry a bare needle;
    //   - extras is omitempty, so a sample with none of its own matches the needle in prev's;
    //   - map keys marshal sorted, so a peer nests the needle in an extras key that sorts first.
    // These read a named member of a named object at its own top level, tracking depth and string state. The
    // unscoped readers stay correct for the envelope (type, payload, player_id), where no peer key precedes a real one.
    //
    // Named byte constants rather than escapes: this code is about quotes and backslashes.
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

    // Position of the value of top-level member `key` within the object body [begin, end), or npos. Nested members are
    // skipped, so a key inside a sub-object never matches.
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
        // A digit, or a minus then a digit, as JSON requires: sscanf also takes nan, inf, "-inf", a leading plus and
        // hex floats, so a non-finite value cannot enter here.
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

    // A JSON bool, exact match only: `true` is the only thing that means true, and every other input, a truncated line
    // included, reads false, the side that hides a stale indicator.
    inline auto json_bool_member(const std::string& s, size_t begin, size_t end, const std::string& key) -> bool
    {
        const size_t v = json_member_value(s, begin, end, key);
        if (v == std::string::npos)
        {
            return false;
        }
        return s.compare(v, 4, "true") == 0;
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

    // Bounds for peer doubles, named here beside clamp_to_uint8 so every narrowing site uses a fuzzed one. isfinite is
    // not enough before a float cast: 1e300 is finite and not a float, so clamp_to_float bounds magnitude.

    // A non-finite peer value becomes the caller's fallback, for a double that is never narrowed.
    inline auto finite_or(double value, double fallback) -> double
    {
        return std::isfinite(value) ? value : fallback;
    }

    // NaN and anything outside [lo, hi] are pinned, not refused: these are continuous visual quantities, where a
    // bounded wrong value looks odd for a frame.
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

    // Arrays, with the same scoped discipline: an array member is a span, and a caller walks only inside it.
    // Body span of the array whose opening bracket sits at `pos`; [begin, end) excludes the brackets.
    inline auto json_array_body_at(const std::string& s, size_t pos, size_t limit, size_t& begin, size_t& end) -> bool
    {
        if (limit > s.size())
        {
            limit = s.size();
        }
        if (pos >= limit || s[pos] != '[')
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
            if (c == '[' || c == '{')
            {
                ++depth;
            }
            else if ((c == ']' || c == '}') && --depth == 0)
            {
                end = i;
                return c == ']';
            }
        }
        return false;
    }

    // The body of a named array member.
    inline auto json_array_member(const std::string& s, size_t begin, size_t end, const std::string& key,
                                  size_t& out_begin, size_t& out_end) -> bool
    {
        const size_t v = json_member_value(s, begin, end, key);
        return v != std::string::npos && json_array_body_at(s, v, end, out_begin, out_end);
    }

    // The next object inside an array span, starting the search at `pos`; on success `pos` is
    // moved past it. Anything that is not an object between elements (a string, a number, a
    // nested array) is skipped whole.
    inline auto json_next_object(const std::string& s, size_t& pos, size_t end, size_t& out_begin, size_t& out_end) -> bool
    {
        if (end > s.size())
        {
            end = s.size();
        }
        while (pos < end)
        {
            const char c = s[pos];
            if (c == '{')
            {
                if (!json_body_at(s, pos, end, out_begin, out_end))
                {
                    return false;
                }
                pos = out_end + 1;
                return true;
            }
            if (c == kJsonQuote)
            {
                const size_t close = json_skip_string(s, pos, end);
                if (close == std::string::npos)
                {
                    return false;
                }
                pos = close + 1;
                continue;
            }
            if (c == '[')
            {
                size_t b = 0, e = 0;
                if (!json_array_body_at(s, pos, end, b, e))
                {
                    return false;
                }
                pos = e + 1;
                continue;
            }
            ++pos;
        }
        return false;
    }

    // Every top-level string in an array span, decoded, at most `max`.
    inline auto json_string_array(const std::string& s, size_t begin, size_t end, size_t max) -> std::vector<std::string>
    {
        std::vector<std::string> out;
        if (end > s.size())
        {
            end = s.size();
        }
        size_t i = begin;
        while (i < end && out.size() < max)
        {
            const char c = s[i];
            if (c == kJsonQuote)
            {
                out.push_back(json_decode_string_at(s, i + 1));
                const size_t close = json_skip_string(s, i, end);
                if (close == std::string::npos)
                {
                    break;
                }
                i = close + 1;
                continue;
            }
            if (c == '{' || c == '[')
            {
                size_t b = 0, e = 0;
                const bool ok = c == '{' ? json_body_at(s, i, end, b, e) : json_array_body_at(s, i, end, b, e);
                if (!ok)
                {
                    break;
                }
                i = e + 1;
                continue;
            }
            ++i;
        }
        return out;
    }

    // Every top-level number in an array span, with json_number_member's rules (a digit or a
    // minus-then-digit starts one; nothing else does); at most `max`, returns how many.
    inline auto json_number_array(const std::string& s, size_t begin, size_t end, double* out, size_t max) -> size_t
    {
        size_t n = 0;
        if (end > s.size())
        {
            end = s.size();
        }
        size_t i = begin;
        while (i < end && n < max)
        {
            const char c = s[i];
            size_t d = i;
            if (c == '-')
            {
                ++d;
            }
            if (d < end && s[d] >= '0' && s[d] <= '9')
            {
                double v = 0.0;
                if (std::sscanf(s.c_str() + i, "%lf", &v) == 1)
                {
                    out[n++] = v;
                }
                while (d < end && (s[d] == '.' || s[d] == 'e' || s[d] == 'E' || s[d] == '+' || s[d] == '-' || (s[d] >= '0' && s[d] <= '9')))
                {
                    ++d;
                }
                i = d;
                continue;
            }
            if (c == kJsonQuote)
            {
                const size_t close = json_skip_string(s, i, end);
                if (close == std::string::npos)
                {
                    break;
                }
                i = close + 1;
                continue;
            }
            if (c == '{' || c == '[')
            {
                size_t b = 0, e = 0;
                const bool ok = c == '{' ? json_body_at(s, i, end, b, e) : json_array_body_at(s, i, end, b, e);
                if (!ok)
                {
                    break;
                }
                i = e + 1;
                continue;
            }
            ++i;
        }
        return n;
    }

    // Out of range refuses to the fallback, unlike clamp_to_float: for counts and discrete states a clamped value is a
    // wrong action taken confidently, and the fallback behaves as though the peer had not sent it.
    inline auto clamp_count_to_int(double value, int lo, int hi, int fallback) -> int
    {
        if (!std::isfinite(value) || value < static_cast<double>(lo) || value > static_cast<double>(hi))
        {
            return fallback;
        }
        return static_cast<int>(value);
    }
    // json_top_level_string reads a top-level string field of one NDJSON line, never looking inside a nested object: a
    // render_remote carries a peer's raw orientation JSON, so any substring rule lets a peer forge our control words.
    // It tracks string state, escapes and depth; anything it cannot answer confidently comes back empty.
    inline std::string json_top_level_string(const std::string& line, const char* key)
    {
        const std::string want = std::string("\"") + key + "\"";
        bool in_string = false;
        bool escaped = false;
        int depth = 0;
        for (size_t i = 0; i < line.size(); ++i)
        {
            const char c = line[i];
            if (escaped)
            {
                escaped = false;
                continue;
            }
            if (in_string)
            {
                if (c == '\\')
                {
                    escaped = true;
                }
                else if (c == '"')
                {
                    in_string = false;
                }
                continue;
            }
            if (c == '"')
            {
                if (depth == 1 && line.compare(i, want.size(), want) == 0)
                {
                    size_t j = i + want.size();
                    while (j < line.size() && (line[j] == ' ' || line[j] == '\t')) ++j;
                    if (j >= line.size() || line[j] != ':')
                    {
                        in_string = true;
                        continue;
                    }
                    ++j;
                    while (j < line.size() && (line[j] == ' ' || line[j] == '\t')) ++j;
                    if (j >= line.size() || line[j] != '"')
                    {
                        return std::string(); // present, but not a string value
                    }
                    ++j;
                    std::string out;
                    bool esc = false;
                    for (; j < line.size(); ++j)
                    {
                        const char v = line[j];
                        if (esc)
                        {
                            // Anything else passes through as written: this value is only compared and logged.
                            switch (v)
                            {
                            case 'n': out.push_back('\n'); break;
                            case 't': out.push_back('\t'); break;
                            case 'r': out.push_back('\r'); break;
                            default: out.push_back(v); break;
                            }
                            esc = false;
                            continue;
                        }
                        if (v == '\\')
                        {
                            esc = true;
                            continue;
                        }
                        if (v == '"')
                        {
                            return out;
                        }
                        out.push_back(v);
                    }
                    return std::string(); // unterminated
                }
                in_string = true;
                continue;
            }
            if (c == '{' || c == '[') ++depth;
            else if (c == '}' || c == ']') --depth;
        }
        return std::string();
    }

    // json_top_level_true reports whether a top-level key is literally true (retryable).
    inline bool json_top_level_true(const std::string& line, const char* key)
    {
        const std::string want = std::string("\"") + key + "\"";
        bool in_string = false;
        bool escaped = false;
        int depth = 0;
        for (size_t i = 0; i < line.size(); ++i)
        {
            const char c = line[i];
            if (escaped)
            {
                escaped = false;
                continue;
            }
            if (in_string)
            {
                if (c == '\\') escaped = true;
                else if (c == '"') in_string = false;
                continue;
            }
            if (c == '"')
            {
                if (depth == 1 && line.compare(i, want.size(), want) == 0)
                {
                    size_t j = i + want.size();
                    while (j < line.size() && (line[j] == ' ' || line[j] == '\t')) ++j;
                    if (j < line.size() && line[j] == ':')
                    {
                        ++j;
                        while (j < line.size() && (line[j] == ' ' || line[j] == '\t')) ++j;
                        return line.compare(j, 4, "true") == 0;
                    }
                }
                in_string = true;
                continue;
            }
            if (c == '{' || c == '[') ++depth;
            else if (c == '}' || c == ']') --depth;
        }
        return false;
    }


    // Shortest-arc interpolation between two angles in degrees: the wire carries pitch/yaw/roll, and a plain lerp from
    // 350 to 10 spins the long way round. Not re-wrapped, since FRotator normalizes on use and a clamp adds a seam.
    // Each input is folded before subtracting: two finite doubles near the range ends subtract to infinity, fmod(inf)
    // is NaN, and a ghost with a NaN rotation stops rendering. A value it cannot trust holds `from`.
    inline double lerp_angle_deg(double from, double to, double t)
    {
        if (!std::isfinite(from) || !std::isfinite(to) || !std::isfinite(t))
        {
            return std::isfinite(from) ? from : 0.0;
        }
        const double folded_from = std::fmod(from, 360.0);
        const double folded_to = std::fmod(to, 360.0);
        double delta = std::fmod(folded_to - folded_from, 360.0);
        if (delta > 180.0)
        {
            delta -= 360.0;
        }
        else if (delta < -180.0)
        {
            delta += 360.0;
        }
        const double out = from + delta * t;
        return std::isfinite(out) ? out : from;
    }

    // collapse_latest_render_remote keeps, in order, every line except a render_remote that a newer one for the same
    // player_id supersedes: the state plane is latest-wins, so nothing owed is dropped, and every other line (despawn,
    // names, policy) keeps its place. The drain uses it, and so does the queue, which grows while a pause stops it.
    inline auto collapse_latest_render_remote(std::vector<std::string>& lines) -> void
    {
        if (lines.size() < 2)
        {
            return;
        }
        std::unordered_set<std::string> seen_ids;
        std::vector<bool> keep(lines.size(), true);
        for (size_t i = lines.size(); i-- > 0;)
        {
            if (json_string_field(lines[i], "type") != "render_remote")
            {
                continue;
            }
            if (!seen_ids.insert(json_string_field(lines[i], "player_id")).second)
            {
                keep[i] = false; // an older state for a player whose newer one is already kept
            }
        }
        size_t out = 0;
        for (size_t i = 0; i < lines.size(); ++i)
        {
            if (keep[i])
            {
                if (out != i)
                {
                    lines[out] = std::move(lines[i]);
                }
                ++out;
            }
        }
        lines.resize(out);
    }

} // namespace MeshGhostPseudo
