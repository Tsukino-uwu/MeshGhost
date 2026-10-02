#include <BridgeClient.hpp>
#include <PeerJson.hpp>

#include <DynamicOutput/DynamicOutput.hpp>

// WIN32_LEAN_AND_MEAN keeps windows.h from pulling in winsock1, which conflicts with winsock2.
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>

namespace MeshGhostPseudo
{
    using namespace RC;

    namespace
    {
        // Winsock reference-counts WSAStartup/WSACleanup per process, so one static guard is enough.
        struct WinsockGuard
        {
            WinsockGuard()
            {
                WSADATA wsa_data{};
                WSAStartup(MAKEWORD(2, 2), &wsa_data);
            }
            ~WinsockGuard()
            {
                WSACleanup();
            }
        };
        WinsockGuard winsock_guard{};

        // The core's reject reasons are plain ASCII it wrote itself, so a byte-widen is safe for one log line.
        auto to_wide_ascii(const std::string& s) -> RC::StringType
        {
            return RC::StringType(s.begin(), s.end());
        }
    } // namespace

    BridgeClient::BridgeClient(std::string host_, uint16_t base_port_)
        : base_port(base_port_), host(std::move(host_)), sock(static_cast<uintptr_t>(INVALID_SOCKET))
    {
    }

    BridgeClient::~BridgeClient()
    {
        close_socket();
    }

    auto BridgeClient::close_socket() -> void
    {
        if (sock != static_cast<uintptr_t>(INVALID_SOCKET))
        {
            closesocket(static_cast<SOCKET>(sock));
            sock = static_cast<uintptr_t>(INVALID_SOCKET);
        }
        connected = false;
        hello_sent_this_connection = false;
        core_answered_ready = false;
        hello_sent_at = {};
        current_port = 0;
        // recv_buffer is not cleared here: a refusing core writes its reject and closes, and poll_lines must still
        // parse the reject it read before the close. The sweep clears it when a connection is established.
    }

    auto BridgeClient::mark_hello_sent() -> void
    {
        hello_sent_this_connection = true;
        hello_sent_at = std::chrono::steady_clock::now();
    }

    auto BridgeClient::is_ready() const -> bool
    {
        if (!connected || !hello_sent_this_connection)
        {
            return false;
        }
        // Only an explicit bridge_ready counts: a silent listener is more likely an unrelated program squatting a port
        // in our range, and committing to it strands the adapter, while skipping an old core costs nothing.
        return core_answered_ready;
    }

    auto BridgeClient::tick_connect() -> void
    {
        if (connected)
        {
            // A hello that never got an answer: drop the connection and let the sweep below try elsewhere.
            if (hello_sent_this_connection && !core_answered_ready &&
                std::chrono::steady_clock::now() - hello_sent_at > HELLO_ANSWER_TIMEOUT)
            {
                if (current_port >= base_port && current_port < base_port + BRIDGE_PORT_COUNT)
                {
                    busy_until[current_port - base_port] = std::chrono::steady_clock::now() + BUSY_PORT_COOLDOWN;
                }
                Output::send(STR("[MeshGhostPseudo] whatever is on port {} never answered our hello -- "
                                 "not a MeshGhost core we can use, trying another port.\n"),
                             current_port);
                close_socket();
            }
            else
            {
                return;
            }
        }

        auto now = std::chrono::steady_clock::now();
        if (now < relay_down_until)
        {
            // A core said the relay is unreachable: walking would mark every port busy and spawn cores nobody can use.
            return;
        }
        if (now - last_connect_attempt < RECONNECT_INTERVAL)
        {
            return;
        }
        last_connect_attempt = now;

        // The whole range per cooldown: each candidate costs at most the 2 ms select, so a sweep is well under a frame.
        have_spawnable_port = false;
        for (uint16_t i = 0; i < BRIDGE_PORT_COUNT; ++i)
        {
            if (busy_until[i] > now)
            {
                continue; // a core that told us it was busy, still inside its cooldown
            }

            uint16_t candidate = static_cast<uint16_t>(base_port + i);
            if (own_core_port != 0 && own_core_port != last_busy_port && candidate != own_core_port)
            {
                continue; // our own child is alive and not yet claimed by anyone: wait on it
            }
            bool refused = false;
            if (try_port(candidate, refused))
            {
                current_port = candidate;
                connected = true;
                hello_sent_this_connection = false;
                core_answered_ready = false;
                recv_buffer.clear(); // close_socket leaves it for a reject; a new connection starts fresh
                Output::send(STR("[MeshGhostPseudo] bridge connected on port {}.\n"), candidate);
                return;
            }
            if (!have_spawnable_port && (refused || port_is_bindable(candidate)))
            {
                // Nothing listening: remember the first such port, so cores start at the lowest free one. A closed
                // loopback port may never refuse (a firewall dropping the SYN), so a port we can bind is free too.
                spawnable = candidate;
                have_spawnable_port = true;
            }
        }
    }

    auto BridgeClient::port_is_bindable(uint16_t candidate) const -> bool
    {
        SOCKET probe = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (probe == INVALID_SOCKET)
        {
            return false;
        }

        // Without SO_EXCLUSIVEADDRUSE, Windows lets this bind succeed beside a socket that asked to share the address.
        BOOL exclusive = TRUE;
        setsockopt(probe, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, reinterpret_cast<const char*>(&exclusive), sizeof(exclusive));

        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(candidate);
        inet_pton(AF_INET, host.c_str(), &addr.sin_addr);

        const bool bindable = bind(probe, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0;
        // A question, not a reservation: if something else wins the bind, the core exits and the launcher moves on.
        closesocket(probe);
        return bindable;
    }

    auto BridgeClient::try_port(uint16_t candidate, bool& refused) -> bool
    {
        refused = false;
        ++counters.connect_attempts;

        SOCKET new_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (new_sock == INVALID_SOCKET)
        {
            return false;
        }

        u_long non_blocking = 1;
        ioctlsocket(new_sock, FIONBIO, &non_blocking);

        // TCP_NODELAY: one small JSON line per frame is the traffic Nagle coalesces, and against Linux's 40 ms
        // delayed-ACK minimum the bridge delivered in bunches every watcher saw as a stepping ghost.
        BOOL nodelay = TRUE;
        if (setsockopt(new_sock, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&nodelay), sizeof(nodelay)) != 0)
        {
            // Not fatal, it just batches; said, since a stepped ghost looks nothing like the cause.
            Output::send(STR("[MeshGhostPseudo] could not disable Nagle on the bridge socket (WSA {}) -- ghosts may look stepped.\n"),
                         WSAGetLastError());
        }

        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(candidate);
        inet_pton(AF_INET, host.c_str(), &addr.sin_addr);

        int result = connect(new_sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
        if (result == 0)
        {
            // Connected at once: unusual for a non-blocking socket, but valid on loopback.
            sock =static_cast<uintptr_t>(new_sock);
            return true;
        }

        int err = WSAGetLastError();
        if (err != WSAEWOULDBLOCK)
        {
            refused = (err == WSAECONNREFUSED);
            closesocket(new_sock);
            return false;
        }

        // In progress: settle it this tick with a 2 ms select, since a zero timeout can abort a loopback connect
        // microseconds from success. The except set is required: Winsock signals a failed non-blocking connect in
        // exceptfds and marks the socket writable only on success.
        fd_set write_set{};
        FD_ZERO(&write_set);
        FD_SET(new_sock, &write_set);
        fd_set except_set{};
        FD_ZERO(&except_set);
        FD_SET(new_sock, &except_set);
        timeval timeout{0, 2000};
        int select_result = select(0, nullptr, &write_set, &except_set, &timeout);
        if (select_result > 0)
        {
            int so_error = 0;
            int so_error_len = sizeof(so_error);
            getsockopt(new_sock, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&so_error), &so_error_len);
            if (FD_ISSET(new_sock, &write_set) && so_error == 0)
            {
                sock = static_cast<uintptr_t>(new_sock);
                return true;
            }
            // Finished and failed; SO_ERROR says how, and refused means nothing is listening.
            refused =(so_error == WSAECONNREFUSED);
        }

        closesocket(new_sock);
        return false;
    }

    // Serialises the two threads that write this socket: UE4SS's, and the game thread's player_frozen send, which
    // stays beside its pause read there. Interleaved sends tear a line, which NDJSON cannot resynchronise from.
    static std::mutex send_mutex;

    auto BridgeClient::send_line(const std::string& line) -> bool
    {
        bool dropped = false;
        return send_line_inner(line, dropped);
    }

    auto BridgeClient::send_edge_line(const std::string& line) -> bool
    {
        bool dropped = false;
        const bool ok = send_line_inner(line, dropped);
        return ok && !dropped;
    }

    auto BridgeClient::send_line_inner(const std::string& line, bool& dropped) -> bool
    {
        std::lock_guard<std::mutex> guard(send_mutex);
        dropped = false;
        if (!connected)
        {
            return false;
        }

        std::string with_newline = line + "\n";
        int sent = send(static_cast<SOCKET>(sock), with_newline.c_str(), static_cast<int>(with_newline.size()), 0);
        if (sent == SOCKET_ERROR)
        {
            int err = WSAGetLastError();
            if (err == WSAEWOULDBLOCK)
            {
                // Not a failure for state, which is resent next tick; reported as dropped for send_edge_line.
                dropped = true;
                return true;
            }
            ++counters.send_fail;
            close_socket();
            return false;
        }

        // A partial send leaves a truncated line with no newline, which corrupts NDJSON framing for the connection:
        // close and let tick_connect() reconnect, which costs a frame, not correctness.
        if (static_cast<size_t>(sent) < with_newline.size())
        {
            ++counters.send_fail;
            close_socket();
            return false;
        }

        ++counters.send_ok;
        return true;
    }

    auto BridgeClient::poll_lines() -> std::vector<std::string>
    {
        std::vector<std::string> lines;
        if (!connected)
        {
            return lines;
        }

        // Captured first: the EOF after a core's rejection runs close_socket(), which zeroes current_port, before the
        // parse loop below sees that rejection.
        const uint16_t source_port = current_port;

        // A per-call read budget, so a core that queued a lot is not read and parsed in one game-thread tick. An
        // ordinary tick still drains the socket; the rest waits in TCP, and the state plane is latest-wins.
        constexpr size_t MAX_RECV_PER_POLL = 64 * 1024;
        size_t received_this_poll = 0;

        char buf[4096];
        for (;;)
        {
            if (received_this_poll >= MAX_RECV_PER_POLL)
            {
                break; // the rest waits for the next tick
            }
            int received = recv(static_cast<SOCKET>(sock), buf, sizeof(buf), 0);
            if (received > 0)
            {
                recv_buffer.append(buf, static_cast<size_t>(received));
                received_this_poll += static_cast<size_t>(received);
                continue;
            }
            if (received == 0)
            {
                close_socket(); // the core closed the connection
                break;
            }
            int err = WSAGetLastError();
            if (err == WSAEWOULDBLOCK)
            {
                break; // no more data available right now
            }
            close_socket();
            break;
        }

        size_t start = 0;
        for (;;)
        {
            size_t newline_pos = recv_buffer.find('\n', start);
            if (newline_pos == std::string::npos)
            {
                break;
            }
            std::string line = recv_buffer.substr(start, newline_pos - start);
            if (!line.empty() && line.back() == '\r')
            {
                line.pop_back();
            }
            if (!line.empty())
            {
                ++counters.lines_received;
                if (line.front() != '{' || line.back() != '}')
                {
                    ++counters.lines_malformed;
                }
                // The core's answers to our hello stay here; Plugin only wants ghost messages. Read from the top-level
                // type field, never a substring: a render_remote carries a peer's raw orientation JSON.
                const std::string msg_type = json_top_level_string(line, "type");
                if (msg_type == "bridge_ready")
                {
                    core_answered_ready = true;
                    Output::send(STR("[MeshGhostPseudo] core on port {} accepted us.\n"), source_port);
                    start = newline_pos + 1;
                    continue;
                }
                if (msg_type == "reject")
                {
                    // busy or already_serving: this core has an adapter, so try the next port. Anything else: this core
                    // is fine and something upstream is not, so wait on it (it retries by itself) rather than walk on,
                    // mark every port busy and spawn cores. Branch on code, never the prose, which says "relay" in
                    // every permanent refusal; only an empty code (a core older than the field) leaves it to the prose.
                    const std::string reject_code = json_top_level_string(line, "code");
                    const bool walk_on = reject_code.empty()
                                             ? (line.find("relay") == std::string::npos)
                                             : (reject_code == "busy" || reject_code == "already_serving");
                    if (!walk_on)
                    {
                        if (!reject_code.empty() && !json_top_level_true(line, "retryable"))
                        {
                            // Said plainly: a refusal that will not fix itself by waiting.
                            Output::send(STR("[MeshGhostPseudo] core on port {} refused us permanently ({}) -- "
                                             "this will NOT fix itself by waiting; check the client's config.json.\n"),
                                         source_port,
                                         to_wide_ascii(line));
                        }
                        relay_down_until = std::chrono::steady_clock::now() + RELAY_DOWN_BACKOFF;
                        Output::send(STR("[MeshGhostPseudo] core on port {} refused us and is not busy ({}) -- "
                                         "waiting on this core rather than walking; it retries by itself.\n"),
                                     source_port,
                                     to_wide_ascii(line));
                        close_socket();
                        recv_buffer.clear();
                        return lines;
                    }
                    // Somebody else's core: skip this port for a while and let the next sweep find another.
                    if (source_port >= base_port && source_port < base_port + BRIDGE_PORT_COUNT)
                    {
                        busy_until[source_port - base_port] = std::chrono::steady_clock::now() + BUSY_PORT_COOLDOWN;
                    }
                    // The code where the core sends one; the substring only for a core older than the field.
                    if (reject_code.empty() ? (line.find("busy") != std::string::npos)
                                            : (reject_code == "busy"))
                    {
                        last_busy_port = source_port;
                    }
                    Output::send(STR("[MeshGhostPseudo] core on port {} refused us ({}) -- trying another port.\n"),
                                 source_port,
                                 to_wide_ascii(line));
                    close_socket();
                    recv_buffer.clear();
                    return lines;
                }
                lines.push_back(std::move(line));
            }
            start = newline_pos + 1;
        }
        recv_buffer.erase(0, start);

        // Checked after extracting every complete line: a burst of many complete lines must never trip this, only a
        // stream that never produces a newline.
        if (recv_buffer.size() > MAX_RECV_BUFFER_BYTES)
        {
            Output::send(STR("[MeshGhostPseudo] bridge recv buffer exceeded {} bytes with no newline -- reconnecting.\n"), MAX_RECV_BUFFER_BYTES);
            close_socket();
        }

        return lines;
    }
} // namespace MeshGhostPseudo
