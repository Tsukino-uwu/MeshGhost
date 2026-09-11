#include <BridgeClient.hpp>
#include <PeerJson.hpp>

#include <DynamicOutput/DynamicOutput.hpp>

// winsock2.h must come before windows.h (WIN32_LEAN_AND_MEAN keeps windows.h from pulling in
// winsock1 first, which conflicts with winsock2 -- standard, well-known Winsock gotcha, not
// project-specific).
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>

namespace MeshGhostPseudo
{
// json_top_level_string and json_top_level_true live in PeerJson.hpp, with every other
// reader that touches bytes a stranger wrote -- that is what makes them testable without a
// game (MeshGhostPseudo.Tests, and .github/workflows/pseudoregalia.yml runs it).

    using namespace RC;

    namespace
    {
        // WSAStartup/WSACleanup are process-global and reference-counted by Winsock itself;
        // one static guard per process is the standard pattern, not something that needs to
        // track per-BridgeClient lifetime.
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

        // The core's reject reasons are plain ASCII, written by internal/core, never user text --
        // a byte-widen is safe here and avoids pulling in a UTF-8 decoder for one log line. Same
        // reasoning (and same shape) as Plugin.cpp's own to_wide_ascii.
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
        // recv_buffer is DELIBERATELY NOT CLEARED HERE, and clearing it was a real bug.
        //
        // A core that refuses us writes its reject and then closes. poll_lines reads the reject
        // into recv_buffer, the next recv returns 0 for the close, and this function used to run
        // and wipe the buffer -- so the parse loop immediately below the recv loop found nothing.
        // The refusal arrived and was destroyed on the same call, every time.
        //
        // What that cost: the mod never saw ANY rejection, so it never marked a busy port, never
        // distinguished a downed relay, and re-dialled the same core every two seconds forever.
        // Measured 2026-08-28 with two real instances -- the second reported
        // connect_attempts=127, send_ok=127, lines_received=0 while the first core's log showed
        // 202 refusals sent. It also means every "never answered our hello" this mod has ever
        // logged may have been a refusal it threw away rather than a silent port.
        //
        // The buffer is cleared when a connection is ESTABLISHED instead (see the sweep), which is
        // the correct lifecycle: leftovers from a previous connection must not contaminate a new
        // one, but data already delivered by the old one must still be readable.
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
        // Only an explicit bridge_ready counts. Silence is NOT acceptance: something that
        // accepts a connection and then never answers is far more likely an unrelated program
        // holding a port in our range than a MeshGhost core, and committing to it strands this
        // adapter with no ghosts and no explanation -- the exact silent failure the handshake
        // exists to remove.
        //
        // This was the other way round for one build, treating silence as an older core and
        // carrying on. A test that squats a port with a listener that never speaks
        // (internal/e2e's TestPortWalkFindsAFreeCore) showed that trade is backwards: skipping an
        // old core costs nothing, because the walk just starts its own on a free port and
        // everything works, while committing to a squatter costs the whole session.
        return core_answered_ready;
    }

    auto BridgeClient::tick_connect() -> void
    {
        if (connected)
        {
            // A connection that never got an answer is not a connection worth keeping: drop it
            // and let the sweep below try somewhere else. Without this the adapter would sit
            // attached to a silent port forever, which is what a squatting program looks like.
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

        // RECONNECT_INTERVAL cooldown -- found in a review pass. Without this, a caller ticking
        // every real engine frame (or UE4SS's own ~5ms polling cadence) attempted a fresh
        // connect every single call while the core was down, on the order of 200 socket
        // create/connect/abort cycles per second.
        auto now = std::chrono::steady_clock::now();
        if (now < relay_down_until)
        {
            // A core told us the relay is unreachable. Do not sweep: there is nothing to walk to,
            // and walking marks every port busy and then spawns cores nobody can use.
            return;
        }
        if (now - last_connect_attempt < RECONNECT_INTERVAL)
        {
            return;
        }
        last_connect_attempt = now;

        // One sweep across the whole range per cooldown, not one port. Each candidate costs at
        // most the 2ms select() below, so a sweep is still well under a frame -- whereas one port
        // per 2s would take 16 seconds to discover a free core eight ports up.
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
                // A fresh connection starts with a fresh buffer. This is where the clearing that
                // used to live in close_socket belongs -- see the comment there for what it cost.
                recv_buffer.clear();
                Output::send(STR("[MeshGhostPseudo] bridge connected on port {}.\n"), candidate);
                return;
            }
            if (!have_spawnable_port && (refused || port_is_bindable(candidate)))
            {
                // Nothing listening here at all. Remember the FIRST such port: starting a core on
                // the lowest free one keeps a machine's ports predictable instead of drifting
                // upward over a session. A port that answered and said "busy" is deliberately not
                // a candidate -- that is someone else's core, and contract.md says an adapter only
                // ever stops a core it started itself.
                //
                // **`refused` alone was the bug that broke autostart, and the fix is the second
                // test, not a longer timeout (measured 2026-08-27).** A refusal is what a closed
                // port is SUPPOSED to answer, and on this machine it never does: a connect to a
                // closed loopback port sits in SYN_SENT and is still neither writable nor in the
                // exception set after **500ms** — the SYN is being dropped, not rejected, which is
                // what a firewall in "block" mode does. A connect to a port that IS listening
                // completes in ~4ms, so the sweep was correctly finding cores and could never
                // find a free port. Waiting longer cannot fix that; nothing was ever coming.
                //
                // So the question is asked of the OS directly instead of inferred from the
                // network: **a free port is one we can BIND.** That is instant, deterministic, and
                // immune to whatever a firewall does to traffic — and it is the same question the
                // core itself will ask a moment later when it binds its listener. A port with a
                // core on it fails to bind, so this excludes our own and other games' cores for
                // free, exactly as the refusal test was meant to.
                //
                // `refused` is kept as the first test because when it does arrive it is
                // unambiguous and costs nothing; bindability is the answer when it does not.
                spawnable = candidate;
                have_spawnable_port = true;
            }
        }
    }

    auto BridgeClient::port_is_bindable(uint16_t candidate) const -> bool
    {
        // "Is this port free?" asked of the OS rather than of the network. See the call site for
        // why the connect-refusal answer cannot be relied on.
        SOCKET probe = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (probe == INVALID_SOCKET)
        {
            return false;
        }

        // SO_EXCLUSIVEADDRUSE, not SO_REUSEADDR: without it Windows will happily let this bind
        // succeed alongside another socket that asked to share the address, and the answer would
        // be "free" for a port that is anything but. This asks the strict question.
        BOOL exclusive = TRUE;
        setsockopt(probe, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, reinterpret_cast<const char*>(&exclusive), sizeof(exclusive));

        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(candidate);
        inet_pton(AF_INET, host.c_str(), &addr.sin_addr);

        const bool bindable = bind(probe, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0;
        // Closed immediately: this is a question, not a reservation. The core will bind it for
        // real a moment later, and if something else wins that race the core exits and the
        // launcher's per-port cooldown moves the sweep on -- which is the case that path already
        // exists for (two games starting at once).
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

        // Non-blocking mode: connect() below returns immediately with WSAEWOULDBLOCK, and we
        // just retry the whole attempt next tick rather than track connect-in-progress state --
        // matches PROTOCOL.md's tick loop ("try to connect, non-blocking, retry next frame on
        // failure") and the Lua adapter's own settimeout(0) shape.
        u_long non_blocking = 1;
        ioctlsocket(new_sock, FIONBIO, &non_blocking);

        // **TCP_NODELAY, and it is not a micro-optimisation: without it this bridge delivers
        // in ~46 ms bunches on Linux.** This socket writes one small JSON line per frame, which
        // is exactly the traffic Nagle's algorithm exists to coalesce -- it holds a small write
        // until the previous segment is acknowledged, and the receiver's delayed-ACK timer sets
        // how long that is. Linux's delayed-ACK MINIMUM is 40 ms.
        //
        // Measured 2026-09-06 in two replay files recorded by a Linux/Proton tester, half an
        // hour apart: their frames reach the core in bursts of a few milliseconds separated by
        // stalls with a hard floor at exactly 40 ms and a peak at 46, covering 27-30% of all
        // updates. It is not their frame rate -- the character moves the same distance per
        // sample whether the gap is 5 ms or 50, so the frames were produced steadily and only
        // their DELIVERY was bunched. A Windows session recorded the same day sits at 0.6%.
        //
        // The cost of that is not only stuttery replays: a player's own state reaches their
        // core in 46 ms steps, so everyone watching them live sees the same stepping whatever
        // the relay's rate is. Setting the option is the standard fix for a latency-sensitive
        // stream of small writes and costs one syscall per connection.
        BOOL nodelay = TRUE;
        if (setsockopt(new_sock, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&nodelay), sizeof(nodelay)) != 0)
        {
            // Not fatal: the bridge still works, it just batches. Say so rather than leaving a
            // silent performance cliff, because the symptom (a stuttery ghost) looks nothing
            // like the cause.
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
            // Connected immediately -- unusual for a non-blocking socket but valid (e.g. loopback).
            sock = static_cast<uintptr_t>(new_sock);
            return true;
        }

        int err = WSAGetLastError();
        if (err != WSAEWOULDBLOCK)
        {
            refused = (err == WSAECONNREFUSED);
            closesocket(new_sock);
            return false;
        }

        // In progress -- use select() with a short timeout to check for completion this same
        // tick rather than tracking a separate "connecting" state across ticks, since a loopback
        // connect resolves in well under a frame in practice. A zero timeout was found in a
        // review pass to risk a real false negative: a loopback connect that would have
        // succeeded within microseconds could be reported "not yet writable" and the socket
        // aborted right as it was about to work. 2ms is still a bounded, negligible stall and
        // comfortably covers a same-machine loopback handshake.
        //
        // **The except set is not optional on Winsock, and leaving it out was a real bug (found
        // and fixed 2026-08-27).** Windows signals a FAILED non-blocking connect in `exceptfds`,
        // and marks the socket writable only on SUCCESS -- so with `nullptr` passed for the
        // exception set, a refused port never became writable, `select` simply timed out, and
        // `refused` stayed false. That flowed straight through: no refusal meant
        // `have_spawnable_port` was never set, `spawnable_port()` returned false, and
        // `CoreLauncher::tick_disconnected` was therefore NEVER CALLED -- which is exactly the
        // reported autostart failure, right down to its most distinctive feature, that the
        // launcher logged absolutely nothing while `connect_attempts` climbed forever.
        //
        // The nastiness of it is that the code was not wrong about anything it said: it connected
        // correctly, it retried correctly, and it detected an *immediate* refusal (the
        // `err != WSAEWOULDBLOCK` branch above) correctly. Only the in-progress path was blind,
        // and on loopback that is the path a closed port always takes.
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
            // Writable-but-errored and in-the-except-set are the same answer here: the connect
            // finished and did not succeed. SO_ERROR is what says which failure it was, and
            // "connection refused" is the one that means nothing is listening -- i.e. a port a
            // core could be started on.
            refused = (so_error == WSAECONNREFUSED);
        }

        closesocket(new_sock);
        return false;
    }

    // send_mutex serialises the two threads that write this socket.
    //
    // THIRTEEN of the fourteen `bridge->` uses in this mod are on the UE4SS thread; the
    // fourteenth -- player_frozen -- is inside game_thread_tick, and nothing here was
    // synchronised (review I6). Two threads interleaving inside one send() on a non-blocking
    // socket is a torn line on the wire, which NDJSON cannot resynchronise from: the core's
    // scanner grows the malformed line to its limit and dies. The counters were racing too.
    //
    // A mutex rather than moving the caller: the read of WorldSettings.PauserPlayerState has to
    // happen on the game thread and before the paused early-return (Plugin.cpp says why), so the
    // send genuinely belongs there. One uncontended lock per line is nothing next to the syscall
    // it guards.
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
                // Not a real failure -- PROTOCOL.md's tick loop resends fresh state next tick
                // regardless, so a dropped send here just means this tick's frame is skipped.
                // Reported as DROPPED all the same, because that reasoning holds only for a
                // message that gets restated: send_edge_line is the caller that cannot.
                dropped = true;
                return true;
            }
            ++counters.send_fail;
            close_socket();
            return false;
        }

        // A partial send (0 < sent < size) previously went uncounted as success -- found in a
        // review pass. On a non-blocking socket this means the OS send buffer filled mid-write;
        // the remainder is gone, and treating it as success would deliver a truncated line with
        // no terminating newline to the core, corrupting NDJSON framing for the rest of this
        // connection (the core would concatenate it with whatever line comes next). Closing and
        // letting tick_connect() reconnect is the same "when in doubt, drop and reconnect
        // cleanly" posture already used for a real socket error above, and PROTOCOL.md's tick
        // loop already tolerates a dropped frame -- reconnecting costs one frame, not
        // correctness.
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

        // The port these bytes came from, captured before anything can close the socket.
        //
        // close_socket() sets current_port to 0, and the EOF that follows a core's rejection runs
        // it BEFORE the parse loop below sees that rejection -- so reading current_port down there
        // gave 0, the "core on port 0 refused us" line, and a busy-marking guarded by
        // current_port >= base_port that could never fire. The port was never cooled, the sweep
        // re-dialled the same core every two seconds, and because the sweep RETURNS as soon as a
        // port answers it never reached the free port beyond it -- so autostart also reported "NO
        // free port to start a core on" forever. One cause, both symptoms.
        //
        // Found 2026-08-28 with two real Pseudoregalia instances, immediately after the fix that
        // stopped close_socket() destroying the rejection itself.
        const uint16_t source_port = current_port;

        char buf[4096];
        for (;;)
        {
            int received = recv(static_cast<SOCKET>(sock), buf, sizeof(buf), 0);
            if (received > 0)
            {
                recv_buffer.append(buf, static_cast<size_t>(received));
                continue;
            }
            if (received == 0)
            {
                // Peer closed the connection.
                close_socket();
                break;
            }
            int err = WSAGetLastError();
            if (err == WSAEWOULDBLOCK)
            {
                break; // no more data available right now
            }
            // Real error.
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
                // The core's two answers to our hello are handled here rather than handed
                // upward: they are about which core we are talking to, which is this class's
                // job, and Plugin only ever wants ghost messages.
                //
                // READ FROM THE TOP-LEVEL "type" FIELD, not searched for anywhere in the line.
                // The substring form this replaced ran over render_remote lines too, and a
                // render_remote carries a peer's orientation blob as raw JSON -- so a peer
                // could close this player's bridge by naming our own control words inside it
                // (json_top_level_string has the eighteen-byte version).
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
                    // ONE rejection means something different from the others, and treating them
                    // alike is what cost a 0.9.9 user their session. "busy" means this core has an
                    // adapter, so the answer is to try the next port. Anything else means this core
                    // is FINE and something upstream is not -- walking on finds nothing, every port
                    // gets marked busy in turn, and the adapter then starts spawning fresh cores at
                    // the retry cadence. Wait on the same core instead: it retries by itself.
                    //
                    // BRANCHED ON "code", NOT ON THE PROSE (ADR 0058, review D4/N2). Until
                    // 2026-09-11 all four adapters searched the REASON for the substring "relay",
                    // and that heuristic is inverted: every PERMANENT refusal contains that word,
                    // because the core renders relay refusals as "core: relay refused connection:
                    // %s", while the one refusal that means "try the next port" -- busy -- does
                    // not. So a wrong room code read as "the relay is briefly down" and was retried
                    // forever, with the player never told. bridge.Reject has carried a frozen code
                    // since 2026-09-08; the prose stays a sentence for this log.
                    //
                    // An EMPTY code is a core older than that field, and only then does the old
                    // substring rule run -- which is what keeps a new adapter working against a
                    // core a player has not updated.
                    const std::string reject_code = json_top_level_string(line, "code");
                    const bool walk_on = reject_code.empty()
                                             ? (line.find("relay") == std::string::npos)
                                             : (reject_code == "busy" || reject_code == "already_serving");
                    if (!walk_on)
                    {
                        if (!reject_code.empty() && !json_top_level_true(line, "retryable"))
                        {
                            // Said plainly, because this is the case the old heuristic hid: a
                            // refusal that will not fix itself, retried silently forever.
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
                    // Somebody else's core. Skip this port for a while and let the next sweep
                    // find another -- without the cooldown we would reconnect immediately, make
                    // it log another refusal, and hang up, forever.
                    if (source_port >= base_port && source_port < base_port + BRIDGE_PORT_COUNT)
                    {
                        busy_until[source_port - base_port] = std::chrono::steady_clock::now() + BUSY_PORT_COOLDOWN;
                    }
                    // The code where the core sends one; the old substring only as the
                    // fallback for a core older than the field.
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

        // Bounds the buffered partial-line remainder -- previously unbounded, so a stream that
        // never produced a newline (a malformed/desynced core, or a connection stuck mid-line)
        // could grow memory without limit. Checked only here, after extracting every complete
        // line above, not against the raw total the read loop appended: a legitimate burst of
        // many small complete lines arriving in one recv() must never trip this, only a single
        // pathologically long or newline-less line should. Found in a review pass.
        if (recv_buffer.size() > MAX_RECV_BUFFER_BYTES)
        {
            Output::send(STR("[MeshGhostPseudo] bridge recv buffer exceeded {} bytes with no newline -- reconnecting.\n"), MAX_RECV_BUFFER_BYTES);
            close_socket();
        }

        return lines;
    }
} // namespace MeshGhostPseudo
