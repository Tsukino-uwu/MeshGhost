#pragma once

// Real TCP bridge client, real C++ Winsock -- the actual point of the C++ rewrite (7.5's Lua
// version hit a receive-side corruption bug in the vendored LuaSocket DLL under sustained
// traffic, never resolved; see agent_docs/risks.md). Wire format ported from the already-proven
// Lua adapter (adapters/pseudoregalia/probe_ghost/Scripts/main.lua) and
// adapters/_template/PROTOCOL.md -- NDJSON over a plain TCP socket to the local core's bridge
// port. Deliberately minimal: connect/send/receive-lines only, no JSON parsing of received
// payloads yet -- step 2 of the phase's C++ rewrite is proving the transport itself is reliable
// before building anything on top of it (agent_docs/phases/phase7.md).

#include <chrono>
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

    // Bounds recv_buffer's post-extraction partial-line remainder -- see poll_lines's own
    // comment for why this checks only the remainder, not the raw total a single recv() call
    // appended (a legitimate burst of many small complete lines must not trip this). Generous
    // above any real bridge message: render_remote's largest component, Extras, is itself
    // capped at internal/protocol.MaxExtrasBytes=1024 on the Go side. Found in a review pass --
    // previously unbounded.
    inline constexpr size_t MAX_RECV_BUFFER_BYTES = 16 * 1024;

    // Minimum time between connect SWEEPS -- found in a review pass: tick_connect() used to
    // attempt a fresh connect every single call (this codebase's own on_update() runs at
    // roughly the UE4SS polling thread's ~5ms cadence), so with the core down that was on the
    // order of 200 socket create/connect/abort cycles per second. Matches the shape of TEVI's
    // own BridgeClient.cs ReconnectInterval (2s), a different language but the same problem.
    //
    // Deliberately per sweep, not per port: a sweep tries every candidate in one tick (each
    // costs at most the 2ms select below), so throttling per port would multiply time-to-connect
    // by the number of candidates for no benefit.
    inline constexpr std::chrono::milliseconds RECONNECT_INTERVAL{2000};

    // The bridge ports an adapter may use, low to high. A core serves one adapter
    // (agent_docs/contract.md), so a second copy of the game needs a second core on a second
    // port -- this range is what lets that happen with no configuration, and it is what makes
    // "two instances" or "two different games at once" work at all.
    //
    // A fixed, documented range rather than any free high port: a core someone started by hand,
    // or one of dev-scripts' launchers, has to remain findable. A random port would be invisible
    // to everything except the adapter that chose it.
    inline constexpr uint16_t BRIDGE_BASE_PORT = 7778;
    inline constexpr uint16_t BRIDGE_PORT_COUNT = 8;

    // How long a port that answered "busy" is skipped before being tried again. Without this,
    // every sweep would reconnect to a core that already has a game, make it log another refusal,
    // and hang up -- correct but noisy in someone else's log, which is where a bug report comes
    // from.
    inline constexpr std::chrono::milliseconds BUSY_PORT_COOLDOWN{10000};

    // How long to wait on the SAME core after it says it cannot reach the relay.
    //
    // A core that cannot reach the relay is a perfectly good core, so treating that rejection like
    // a busy port makes the adapter walk on, find nothing, mark every port busy in turn, and then
    // start spawning fresh cores at the retry cadence. Crystal has guarded against this since
    // 2026-08-19 and its comment names the measurement: EMERALD at 5fps doing exactly that while a
    // relay was full. Emerald got the guard back on 2026-08-28; this is the third sibling, and the
    // symptom a 0.9.9 user reported -- "the sweep found NO free port to start a core on, every port
    // in the range either answered or never refused" -- is what it looks like from outside.
    inline constexpr std::chrono::milliseconds RELAY_DOWN_BACKOFF{10000};

    // How long to wait for the core to answer a hello before assuming it is an older build that
    // predates bridge_ready/reject (agent_docs/contract.md). Treating silence as acceptance keeps
    // a mixed setup working exactly as it did before, rather than refusing a perfectly good core.
    inline constexpr std::chrono::milliseconds HELLO_ANSWER_TIMEOUT{1500};

    class BridgeClient
    {
      public:
        // Walks BRIDGE_BASE_PORT..+BRIDGE_PORT_COUNT looking for a core that will have it.
        explicit BridgeClient(std::string host);
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

        // Call after actually sending the hello line: starts the clock on the core's answer.
        auto mark_hello_sent() -> void;

        // True once the core has accepted this adapter -- either by answering bridge_ready, or by
        // staying silent past HELLO_ANSWER_TIMEOUT, which means an older core that predates that
        // message. Nothing game-related should be sent before this: on a busy core the answer is a
        // reject, and frames sent in the meantime would be talking to a session that is about to
        // be closed.
        auto is_ready() const -> bool;

        // The port this client is actually connected to (0 if not connected). Worth logging: with
        // a walk, "which core am I talking to" stops being a constant anyone can assume.
        auto resolved_port() const -> uint16_t
        {
            return connected ? current_port : 0;
        }

        // A port in the range where nothing was listening at all, if the last sweep found one --
        // i.e. somewhere a new core could be started. Distinct from a port that answered and said
        // it was busy, which is somebody else's core and must be left alone.
        auto spawnable_port(uint16_t& out) const -> bool
        {
            if (!have_spawnable_port)
            {
                return false;
            }
            out = spawnable;
            return true;
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
        // One candidate, one attempt. Returns true if connected. Sets refused when nothing was
        // listening, which is what makes the port a candidate for starting a core on.
        auto try_port(uint16_t candidate, bool& refused) -> bool;

        // Can a listener be bound here right now? This is the authoritative "is this port free"
        // test, because a connect to a closed port does not reliably answer on Windows -- see the
        // call site in tick_connect for the measurement that forced this.
        auto port_is_bindable(uint16_t candidate) const -> bool;

        std::string host;
        uint16_t current_port{0};
        uintptr_t sock; // SOCKET, stored as uintptr_t so this header doesn't need <winsock2.h>
        bool connected{false};
        bool hello_sent_this_connection{false};
        std::string recv_buffer;
        BridgeStats counters{};

        // Per-candidate "answered busy, skip me until" stamps, index-aligned with the port range.
        std::chrono::steady_clock::time_point busy_until[BRIDGE_PORT_COUNT]{};

        // Set when a core rejects us because IT cannot reach the relay. Until it passes, the
        // sweep does not run at all: there is nothing to walk to, and walking anyway is the
        // defect above.
        std::chrono::steady_clock::time_point relay_down_until{};
        // Where the last sweep found nothing listening, for CoreLauncher to spawn on.
        uint16_t spawnable{0};
        bool have_spawnable_port{false};
        // Handshake state for the current connection: set when the hello goes out, cleared by an
        // answer or by close_socket().
        std::chrono::steady_clock::time_point hello_sent_at{};
        bool core_answered_ready{false};
        // Default-constructed (epoch) so the very first tick_connect() call always attempts
        // immediately, not after waiting out RECONNECT_INTERVAL.
        std::chrono::steady_clock::time_point last_connect_attempt{};
    };
} // namespace MeshGhostPseudo
