#pragma once

// The bridge client: NDJSON over a plain Winsock TCP socket to the local core's bridge port. It handles the core's
// answers to the hello itself and hands every other line up to Plugin.

#include <mutex>
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

    // Bounds the partial-line remainder left after poll_lines extracts complete lines, never the raw total one recv
    // appended; generous above any real bridge message.
    inline constexpr size_t MAX_RECV_BUFFER_BYTES = 16 * 1024;

    // Minimum time between connect sweeps, so a down core is not dialled every tick. Per sweep, not per port: a sweep
    // tries every candidate in one tick (each at most the 2 ms select), so a per-port throttle would only slow it.
    inline constexpr std::chrono::milliseconds RECONNECT_INTERVAL{2000};

    // The bridge ports an adapter may use, low to high: a core serves one adapter, so a second copy of the game needs
    // a second core on a second port. A fixed range rather than any free port, so a core started by hand or by a
    // launcher stays findable. BRIDGE_BASE_PORT is the default base, which resolve_bridge_base_port can move; preflight
    // checks the four adapters agree on it.
    inline constexpr uint16_t BRIDGE_BASE_PORT = 7778;
    inline constexpr uint16_t BRIDGE_PORT_COUNT = 8;

    // How long a port that answered busy is skipped: otherwise every sweep reconnects to a core that has a game and
    // makes it log another refusal.
    inline constexpr std::chrono::milliseconds BUSY_PORT_COOLDOWN{10000};

    // How long to wait on the same core after it says it cannot reach the relay: that core is fine, and walking on
    // marks every port busy in turn and then spawns fresh cores at the retry cadence.
    inline constexpr std::chrono::milliseconds RELAY_DOWN_BACKOFF{10000};

    // How long the core has to answer a hello before this port is given up. Silence is not acceptance: only
    // bridge_ready counts (is_ready).
    inline constexpr std::chrono::milliseconds HELLO_ANSWER_TIMEOUT{1500};

    class BridgeClient
    {
      public:
        // Walks base_port..+BRIDGE_PORT_COUNT for a core that will have it; base_port is resolved once by the caller.
        BridgeClient(std::string host, uint16_t base_port);
        ~BridgeClient();

        BridgeClient(const BridgeClient&) = delete;
        auto operator=(const BridgeClient&) -> BridgeClient& = delete;

        // Call every tick; non-blocking. A fresh connection resets hello_sent.
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

        // True once the core has answered bridge_ready. Nothing game-related goes out before it: a busy core's answer
        // is a reject, and frames sent meanwhile would talk to a session about to close.
        auto is_ready() const -> bool;

        // The port this client is connected to (0 if not connected).
        auto resolved_port() const -> uint16_t
        {
            return connected ? current_port : 0;
        }

        // The last port whose core answered busy, 0 until one does.
        auto last_busy_port_answered() const -> uint16_t
        {
            return last_busy_port;
        }
        auto set_own_core_port(uint16_t port) -> void
        {
            own_core_port = port;
        }
        // A port where nothing listened in the last sweep, where a core could be started; never a port that answered
        // busy, which is someone else's core.
        auto spawnable_port(uint16_t& out) const -> bool
        {
            if (!have_spawnable_port)
            {
                return false;
            }
            out = spawnable;
            return true;
        }

        // Appends '\n' and sends. False (and the connection closed) on a real send error; a would-block counts as sent,
        // since fresh state goes out next tick anyway.
        auto send_line(const std::string& line) -> bool;
        // send_line for a message sent once, on a change, and never restated (player_frozen): a would-block is a
        // failure here, so the caller keeps its latch and retries next tick. A dropped player_frozen would run the
        // chaser clock through the whole pause.
        auto send_edge_line(const std::string& line) -> bool;
        // The shared body. `dropped` reports a line the OS refused to buffer: fine for state, a failure for an edge.
        auto send_line_inner(const std::string& line, bool& dropped) -> bool;

        // Drains all currently-available bytes and returns any complete '\n'-terminated lines.
        // A trailing partial line (no '\n' yet) is buffered internally, not returned.
        auto poll_lines() -> std::vector<std::string>;

        auto stats() const -> const BridgeStats&
        {
            return counters;
        }

      private:
        auto close_socket() -> void;
        // One candidate, one attempt; true if connected. Sets refused when nothing was listening.
        auto try_port(uint16_t candidate, bool& refused) -> bool;

        // Whether a listener can bind here now: the authoritative free-port test, since a connect to a closed port
        // does not reliably answer on Windows.
        auto port_is_bindable(uint16_t candidate) const -> bool;

        std::string host;
        uint16_t current_port{0};
        uintptr_t sock; // SOCKET, stored as uintptr_t so this header doesn't need <winsock2.h>
        bool connected{false};
        bool hello_sent_this_connection{false};
        std::string recv_buffer;
        BridgeStats counters{};

        // The resolved base of the walk; busy_until is indexed from it, never from BRIDGE_BASE_PORT.
        uint16_t base_port{BRIDGE_BASE_PORT};

        // Per-candidate "answered busy, skip until" stamps.
        std::chrono::steady_clock::time_point busy_until[BRIDGE_PORT_COUNT]{};

        // Set when a core rejects us because it cannot reach the relay; until it passes the sweep does not run.
        std::chrono::steady_clock::time_point relay_down_until{};
        uint16_t spawnable{0};
        bool have_spawnable_port{false};
        // CoreLauncher compares this with the port it spawned on: the only signal its child now serves someone else.
        uint16_t last_busy_port{0};
        // The port of the core this mod spawned and still owns (0 when none). While set and not answered busy, the
        // sweep tries only it: otherwise a second instance attaches to the core the first just started, and the two
        // chase each other's spawns round the range.
        uint16_t own_core_port{0};
        // Handshake state for the current connection: set when the hello goes out, cleared by close_socket().
        std::chrono::steady_clock::time_point hello_sent_at{};
        bool core_answered_ready{false};
        // Epoch, so the first tick_connect() attempts at once.
        std::chrono::steady_clock::time_point last_connect_attempt{};
    };
} // namespace MeshGhostPseudo
