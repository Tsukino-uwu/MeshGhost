#include <BridgeClient.hpp>

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
    } // namespace

    BridgeClient::BridgeClient(std::string host_, uint16_t port_) : host(std::move(host_)), port(port_), sock(static_cast<uintptr_t>(INVALID_SOCKET))
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
        recv_buffer.clear();
    }

    auto BridgeClient::tick_connect() -> void
    {
        if (connected)
        {
            return;
        }

        ++counters.connect_attempts;

        SOCKET new_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (new_sock == INVALID_SOCKET)
        {
            return;
        }

        // Non-blocking mode: connect() below returns immediately with WSAEWOULDBLOCK, and we
        // just retry the whole attempt next tick rather than track connect-in-progress state --
        // matches PROTOCOL.md's tick loop ("try to connect, non-blocking, retry next frame on
        // failure") and the Lua adapter's own settimeout(0) shape.
        u_long non_blocking = 1;
        ioctlsocket(new_sock, FIONBIO, &non_blocking);

        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(port);
        inet_pton(AF_INET, host.c_str(), &addr.sin_addr);

        int result = connect(new_sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
        if (result == 0)
        {
            // Connected immediately -- unusual for a non-blocking socket but valid (e.g. loopback).
            sock = static_cast<uintptr_t>(new_sock);
            connected = true;
            hello_sent_this_connection = false;
            Output::send(STR("[MeshGhostPseudo] bridge connected (immediate).\n"));
            return;
        }

        int err = WSAGetLastError();
        if (err != WSAEWOULDBLOCK)
        {
            closesocket(new_sock);
            return;
        }

        // In progress -- use select() with a short timeout to check for completion this same
        // tick rather than tracking a separate "connecting" state across ticks, since a loopback
        // connect resolves in well under a frame in practice.
        fd_set write_set{};
        FD_ZERO(&write_set);
        FD_SET(new_sock, &write_set);
        timeval timeout{0, 0};
        int select_result = select(0, nullptr, &write_set, nullptr, &timeout);
        if (select_result > 0 && FD_ISSET(new_sock, &write_set))
        {
            int so_error = 0;
            int so_error_len = sizeof(so_error);
            getsockopt(new_sock, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&so_error), &so_error_len);
            if (so_error == 0)
            {
                sock = static_cast<uintptr_t>(new_sock);
                connected = true;
                hello_sent_this_connection = false;
                Output::send(STR("[MeshGhostPseudo] bridge connected.\n"));
                return;
            }
        }

        closesocket(new_sock);
    }

    auto BridgeClient::send_line(const std::string& line) -> bool
    {
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
                return true;
            }
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
                lines.push_back(std::move(line));
            }
            start = newline_pos + 1;
        }
        recv_buffer.erase(0, start);

        return lines;
    }
} // namespace MeshGhostPseudo
