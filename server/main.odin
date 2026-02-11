package main

import shared "app:shared"
import "core:net"
import "core:time"
import "core:fmt"
import "core:os"

// === Server-only constants ===

CORRECTION_THRESHOLD :: f32(0.1)

// === Server-only types ===

Sliding_Window_Min :: struct {
    deltas:  [shared.SLIDING_WINDOW_SIZE]i32,
    head:    u32,
    count:   u32,
    minimum: i32,
}

Player_State :: struct {
    endpoint:         net.Endpoint,
    active_offset:    i32,
    sliding_window:   Sliding_Window_Min,
    position:         shared.Vec3,
    history:          shared.History_Buffer,
    last_client_tick: shared.Tick_ID,
}

Server_State :: struct {
    socket:           net.UDP_Socket,
    server_tick:      shared.Tick_ID,
    tick_accumulator: f64,
    players:          [dynamic]Player_State,
}

// === Entry point ===

main :: proc() {
    port := shared.DEFAULT_PORT

    args := os.args
    for i := 1; i < len(args); i += 1 {
        if p, ok := shared.parse_port_string(args[i]); ok {
            port = p
        }
    }

    fmt.println("Starting server on port", port)

    state: Server_State

    socket, ok := shared.transport_init_server(port)
    if !ok {
        fmt.println("Failed to create server socket")
        return
    }
    state.socket = socket

    fmt.println("Server running. Waiting for connections...")

    last := time.tick_now()

    for {
        now := time.tick_now()
        elapsed := time.tick_diff(last, now)
        real_dt := time.duration_seconds(elapsed)
        last = now

        // Fixed tick accumulator
        state.tick_accumulator += real_dt
        tick_dt := f64(1.0 / f64(shared.TICK_RATE))
        ticks_run := 0
        for state.tick_accumulator >= tick_dt && ticks_run < shared.MAX_TICKS_PER_FRAME {
            state.tick_accumulator -= tick_dt
            state.server_tick += 1
            ticks_run += 1
        }
        if ticks_run >= shared.MAX_TICKS_PER_FRAME {
            state.tick_accumulator = 0
        }

        // Receive and process packets
        recv_packets(&state)

        time.sleep(time.Millisecond)
    }
}

// === Packet handling ===

recv_packets :: proc(state: ^Server_State) {
    buf: [512]u8
    for {
        bytes_read, remote, err := net.recv_udp(state.socket, buf[:])
        if err != nil || bytes_read == 0 do break

        if bytes_read < 1 do continue
        packet_type := (^shared.Packet_Type)(&buf[0])^

        switch packet_type {
        case .Input:
            if bytes_read >= size_of(shared.Input_Packet) {
                pkt := (^shared.Input_Packet)(&buf[0])^
                player := find_or_create_player(state, remote)
                process_input(state, player, pkt)
            }
        case .Handshake:
            player := find_or_create_player(state, remote)
            response := shared.Handshake_Packet{
                type        = .Handshake,
                server_tick = state.server_tick,
                tick_rate   = shared.TICK_RATE,
            }
            shared.send_packet(state.socket, remote, &response, size_of(shared.Handshake_Packet))
            fmt.println("Player connected from", remote.address, remote.port)
        case .Correction, .State_Update:
            // Server doesn't receive these
        }
    }
}

// === Input processing (authoritative) ===

process_input :: proc(state: ^Server_State, player: ^Player_State, pkt: shared.Input_Packet) {
    // 1. Calculate raw delta: ServerTick - ClientTick
    raw_delta := i32(state.server_tick) - i32(pkt.client_tick)

    // 2. Push into sliding window → update ActiveOffset
    sliding_window_push(&player.sliding_window, raw_delta)
    player.active_offset = player.sliding_window.minimum

    // 3. Apply authoritative physics
    player.position = shared.physics_step(player.position, pkt.input)
    player.last_client_tick = pkt.client_tick

    // 4. Store in server history
    shared.history_write(&player.history, shared.History_Frame{
        tick     = pkt.client_tick,
        position = player.position,
        input    = pkt.input,
    })

    // 5. Always send authoritative position back to client
    send_correction(state, player, pkt.client_tick, player.position)
}

// === Sliding window ===

sliding_window_push :: proc(sw: ^Sliding_Window_Min, delta: i32) {
    idx := sw.head % shared.SLIDING_WINDOW_SIZE
    sw.deltas[idx] = delta
    sw.head += 1
    if sw.count < shared.SLIDING_WINDOW_SIZE {
        sw.count += 1
    }

    sw.minimum = max(i32)
    for i in 0..<sw.count {
        if sw.deltas[i] < sw.minimum {
            sw.minimum = sw.deltas[i]
        }
    }
}

// === Player management ===

find_or_create_player :: proc(state: ^Server_State, endpoint: net.Endpoint) -> ^Player_State {
    for &player in state.players {
        if shared.endpoints_equal(player.endpoint, endpoint) {
            return &player
        }
    }
    append(&state.players, Player_State{
        endpoint = endpoint,
    })
    return &state.players[len(state.players) - 1]
}

// === Send correction ===

send_correction :: proc(state: ^Server_State, player: ^Player_State, corrected_tick: shared.Tick_ID, position: shared.Vec3) {
    correction := shared.Correction_Packet{
        type           = .Correction,
        server_tick    = state.server_tick,
        corrected_tick = corrected_tick,
        position       = position,
    }
    shared.send_packet(state.socket, player.endpoint, &correction, size_of(shared.Correction_Packet))
}
