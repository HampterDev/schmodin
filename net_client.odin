package main

import shared "app:shared"
import "core:net"
import "vendor:glfw"

VISUAL_DECAY :: f32(0.9)
WAYPOINT_ARRIVE_DIST :: f32(1.0)

// === Client initialization ===

client_init :: proc(ctx: ^Context, server_addr: net.IP4_Address, port: int) -> bool {
    socket, endpoint, ok := shared.transport_init_client(server_addr, port)
    if !ok do return false

    ctx.client_net.socket = socket
    ctx.client_net.server_endpoint = endpoint
    ctx.client_net.connected = false
    ctx.client_net.local_tick = 0
    ctx.client_net.tick_accumulator = 0
    ctx.client_net.logical_position = ctx.player_pos
    ctx.client_net.visual_offset = Vec3{0, 0, 0}
    ctx.client_net.has_path = false

    // Send handshake
    pkt := shared.Handshake_Packet{
        type        = .Handshake,
        server_tick = 0,
        tick_rate   = shared.TICK_RATE,
    }
    shared.send_packet(ctx.client_net.socket, ctx.client_net.server_endpoint, &pkt, size_of(shared.Handshake_Packet))

    log("Client initialized, handshake sent")
    return true
}

// === Handle mouse click for movement ===

client_handle_click :: proc(ctx: ^Context) {
    ui_active := ui_wants_mouse()
    lmb_pressed := glfw.GetMouseButton(ctx.window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS

    // Edge detection: only trigger on press, not hold
    if lmb_pressed && !ctx.lmb_was_pressed && !ui_active {
        mouse_x, mouse_y := glfw.GetCursorPos(ctx.window)
        origin, dir := screen_to_world_ray(ctx, mouse_x, mouse_y)

        // Intersect with ground plane at y=0
        hit_pos, hit := ray_ground_intersect(origin, dir, 0)
        if hit {
            // Convert to cell coordinates
            cx, cy := world_to_cell(&ctx.walkability, hit_pos.x, hit_pos.z)

            if walkability_is_walkable(&ctx.walkability, cx, cy) {
                // Get current cell
                cur_x, cur_y := world_to_cell(
                    &ctx.walkability,
                    ctx.client_net.logical_position.x,
                    ctx.client_net.logical_position.z,
                )

                start := Cell_Pos{cur_x, cur_y}
                goal := Cell_Pos{cx, cy}

                // Run A*
                path := pathfind(&ctx.walkability, start, goal)
                if path != nil {
                    // Free old path
                    if ctx.client_net.path != nil {
                        delete(ctx.client_net.path)
                    }
                    ctx.client_net.path = path
                    ctx.client_net.path_index = 1  // Skip index 0 (current cell)
                    ctx.client_net.has_path = true

                    if ctx.client_net.path_index < len(path) {
                        wp := path[ctx.client_net.path_index]
                        ctx.client_net.move_target = cell_to_world(&ctx.walkability, wp.x, wp.y)
                    }
                }
            }
        }
    }
    ctx.lmb_was_pressed = lmb_pressed
}

// === Build input from path state ===

client_build_input :: proc(ctx: ^Context) -> shared.Input_Payload {
    if ctx.client_net.has_path {
        return shared.Input_Payload{
            target = ctx.client_net.move_target,
            moving = 1,
        }
    }
    return shared.Input_Payload{
        target = ctx.client_net.logical_position,
        moving = 0,
    }
}

// === Advance to next waypoint if arrived ===

client_advance_waypoint :: proc(ctx: ^Context) {
    if !ctx.client_net.has_path do return

    dx := ctx.client_net.move_target.x - ctx.client_net.logical_position.x
    dz := ctx.client_net.move_target.z - ctx.client_net.logical_position.z
    dist_sq := dx * dx + dz * dz

    if dist_sq <= WAYPOINT_ARRIVE_DIST * WAYPOINT_ARRIVE_DIST {
        ctx.client_net.path_index += 1
        if ctx.client_net.path_index >= len(ctx.client_net.path) {
            // Path complete
            ctx.client_net.has_path = false
        } else {
            wp := ctx.client_net.path[ctx.client_net.path_index]
            ctx.client_net.move_target = cell_to_world(&ctx.walkability, wp.x, wp.y)
        }
    }
}

// === Single client tick (called at fixed 64Hz) ===

client_tick :: proc(ctx: ^Context) {
    input := client_build_input(ctx)

    ctx.client_net.local_tick += 1
    tick := ctx.client_net.local_tick

    ctx.client_net.logical_position = shared.physics_step(ctx.client_net.logical_position, input)

    shared.history_write(&ctx.client_net.history, shared.History_Frame{
        tick     = tick,
        position = ctx.client_net.logical_position,
        input    = input,
    })

    // Advance waypoint after physics
    client_advance_waypoint(ctx)

    ctx.client_net.visual_offset.x *= VISUAL_DECAY
    ctx.client_net.visual_offset.y *= VISUAL_DECAY
    ctx.client_net.visual_offset.z *= VISUAL_DECAY

    if ctx.client_net.connected {
        pkt := shared.Input_Packet{
            type        = .Input,
            client_tick = tick,
            input       = input,
        }
        shared.send_packet(ctx.client_net.socket, ctx.client_net.server_endpoint, &pkt, size_of(shared.Input_Packet))
    }
}

// === Reconciliation: handle server correction ===

client_reconcile :: proc(ctx: ^Context, correction: shared.Correction_Packet) {
    old_visual_pos := Vec3{
        ctx.client_net.logical_position.x + ctx.client_net.visual_offset.x,
        ctx.client_net.logical_position.y + ctx.client_net.visual_offset.y,
        ctx.client_net.logical_position.z + ctx.client_net.visual_offset.z,
    }

    ctx.client_net.logical_position = correction.position

    for t: shared.Tick_ID = correction.corrected_tick + 1; t <= ctx.client_net.local_tick; t += 1 {
        frame, ok := shared.history_read(&ctx.client_net.history, t)
        if ok {
            ctx.client_net.logical_position = shared.physics_step(ctx.client_net.logical_position, frame.input)
            shared.history_write(&ctx.client_net.history, shared.History_Frame{
                tick     = t,
                position = ctx.client_net.logical_position,
                input    = frame.input,
            })
        }
    }

    ctx.client_net.visual_offset = Vec3{
        old_visual_pos.x - ctx.client_net.logical_position.x,
        old_visual_pos.y - ctx.client_net.logical_position.y,
        old_visual_pos.z - ctx.client_net.logical_position.z,
    }
}

// === Main client frame update (called once per render frame) ===

client_frame_update :: proc(ctx: ^Context, real_dt: f64) {
    ctx.client_net.tick_accumulator += real_dt

    tick_dt := f64(1.0 / f64(shared.TICK_RATE))
    ticks_run := 0
    for ctx.client_net.tick_accumulator >= tick_dt && ticks_run < shared.MAX_TICKS_PER_FRAME {
        ctx.client_net.tick_accumulator -= tick_dt
        client_tick(ctx)
        ticks_run += 1
    }

    if ticks_run >= shared.MAX_TICKS_PER_FRAME {
        ctx.client_net.tick_accumulator = 0
    }

    client_recv_packets(ctx)

    // Update player position (camera follows via update_camera_follow)
    ctx.player_pos = Vec3{
        ctx.client_net.logical_position.x + ctx.client_net.visual_offset.x,
        ctx.client_net.logical_position.y + ctx.client_net.visual_offset.y,
        ctx.client_net.logical_position.z + ctx.client_net.visual_offset.z,
    }
}

// === Receive and process server packets ===

client_recv_packets :: proc(ctx: ^Context) {
    buf: [512]u8
    for {
        bytes_read, remote, err := net.recv_udp(ctx.client_net.socket, buf[:])
        if err != nil || bytes_read == 0 do break

        if bytes_read < 1 do continue
        packet_type := (^shared.Packet_Type)(&buf[0])^

        switch packet_type {
        case .Correction:
            if bytes_read >= size_of(shared.Correction_Packet) {
                pkt := (^shared.Correction_Packet)(&buf[0])^
                client_reconcile(ctx, pkt)
            }
        case .State_Update:
            if bytes_read >= size_of(shared.State_Packet) {
                pkt := (^shared.State_Packet)(&buf[0])^
                ctx.client_net.last_server_tick = pkt.server_tick
            }
        case .Handshake:
            if bytes_read >= size_of(shared.Handshake_Packet) {
                pkt := (^shared.Handshake_Packet)(&buf[0])^
                ctx.client_net.connected = true
                ctx.client_net.last_server_tick = pkt.server_tick
                log("Client connected to server")
            }
        case .Input:
            // Clients don't receive input packets
        }
    }
}
