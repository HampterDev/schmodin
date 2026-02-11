package shared

import "core:net"
import "core:mem"

// === Packet sending ===

send_packet :: proc(socket: net.UDP_Socket, to: net.Endpoint, data: rawptr, size: int) {
    bytes := mem.byte_slice(data, size)
    net.send_udp(socket, bytes, to)
}

// === Socket initialization ===

transport_init_client :: proc(server_addr: net.IP4_Address, port: int) -> (net.UDP_Socket, net.Endpoint, bool) {
    socket, sock_err := net.make_unbound_udp_socket(.IP4)
    if sock_err != nil do return {}, {}, false

    block_err := net.set_blocking(socket, false)
    if block_err != nil do return {}, {}, false

    endpoint := net.Endpoint{
        address = net.Address(server_addr),
        port    = port,
    }

    return socket, endpoint, true
}

transport_init_server :: proc(port: int) -> (net.UDP_Socket, bool) {
    addr := net.IP4_Address{0, 0, 0, 0}
    socket, sock_err := net.make_bound_udp_socket(addr, port)
    if sock_err != nil do return {}, false

    block_err := net.set_blocking(socket, false)
    if block_err != nil do return {}, false

    return socket, true
}

// === Helpers ===

endpoints_equal :: proc(a, b: net.Endpoint) -> bool {
    if a.port != b.port do return false

    a4, a_ok := a.address.(net.IP4_Address)
    b4, b_ok := b.address.(net.IP4_Address)
    if a_ok && b_ok {
        return a4 == b4
    }

    a6, a6_ok := a.address.(net.IP6_Address)
    b6, b6_ok := b.address.(net.IP6_Address)
    if a6_ok && b6_ok {
        return a6 == b6
    }

    return false
}

// === Arg parsing ===

parse_ip4_string :: proc(s: string) -> (net.IP4_Address, bool) {
    parts: [4]u8
    part_idx := 0
    val: int = 0
    has_digit := false

    for c in s {
        if c == '.' {
            if !has_digit || part_idx >= 3 do return {}, false
            if val > 255 do return {}, false
            parts[part_idx] = u8(val)
            part_idx += 1
            val = 0
            has_digit = false
        } else if c >= '0' && c <= '9' {
            val = val * 10 + int(c - '0')
            has_digit = true
        } else {
            return {}, false
        }
    }

    if !has_digit || part_idx != 3 || val > 255 do return {}, false
    parts[3] = u8(val)

    return net.IP4_Address{parts[0], parts[1], parts[2], parts[3]}, true
}

parse_port_string :: proc(s: string) -> (int, bool) {
    val := 0
    if len(s) == 0 do return 0, false
    for c in s {
        if c < '0' || c > '9' do return 0, false
        val = val * 10 + int(c - '0')
    }
    if val == 0 || val > 65535 do return 0, false
    return val, true
}
