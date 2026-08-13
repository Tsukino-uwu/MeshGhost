#pragma once

// Real TCP bridge client, real C++ Winsock -- the actual point of the C++ rewrite (7.5's Lua
// version hit a receive-side corruption bug in the vendored LuaSocket DLL under sustained
// traffic, never resolved; see agent_docs/risks.md). Wire format ported from the already-proven
// Lua adapter (adapters/pseudoregalia/probe_ghost/Scripts/main.lua) and
// adapters/_template/PROTOCOL.md -- NDJSON over a plain TCP socket to the local core's bridge
// port. Deliberately minimal: connect/send/receive-lines only, no JSON parsing of received
// payloads yet -- step 2 of the phase's C++ rewrite is proving the transport itself is reliable
// before building anything on top of it (agent_docs/phases/phase7.md).

#include <string>
#include <vector>

namespace MeshGhostPseudo
{
    struct BridgeStats
    {
        uint64_t connect_attempts{};
        uint64_t send_ok{};
        uint64_t send_fail{};
        uint64_t lines_received{};
        uint64_t lines_malformed{}; // doesn't start with '{' and end with '}' after trimming \r
    };

    class BridgeClient
    {
      public:
        BridgeClient(std::string host, uint16_t port);
        ~BridgeClient();

        BridgeClient(const BridgeClient&) = delete;
        auto operator=(const BridgeClient&) -> BridgeClient& = delete;

        // Call every tick. Non-blocking: returns immediately whether or not a connection exists
        // yet. On the tick a fresh connection is established, hello_sent_this_connection resets.
        auto tick_connect() -> void;

        auto is_connected() const -> bool
        {
            return connected;
        }

        auto hello_sent() const -> bool
        {
            return hello_sent_this_connection;
        }

        auto mark_hello_sent() -> void
        {
            hello_sent_this_connection = true;
        }

        // Appends '\n' and sends. Returns false (and closes the connection) on a real send
        // error; a would-block on a non-blocking socket is not treated as an error since we
        // resend fresh state next tick regardless (PROTOCOL.md's tick loop already expects that).
        auto send_line(const std::string& line) -> bool;

        // Drains all currently-available bytes and returns any complete '\n'-terminated lines.
        // A trailing partial line (no '\n' yet) is buffered internally, not returned.
        auto poll_lines() -> std::vector<std::string>;

        auto stats() const -> const BridgeStats&
        {
            return counters;
        }

      private:
        auto close_socket() -> void;

        std::string host;
        uint16_t port;
        uintptr_t sock; // SOCKET, stored as uintptr_t so this header doesn't need <winsock2.h>
        bool connected{false};
        bool hello_sent_this_connection{false};
        std::string recv_buffer;
        BridgeStats counters{};
    };
} // namespace MeshGhostPseudo
