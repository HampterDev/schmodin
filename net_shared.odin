package main

// Type aliases from the shared networking package.
// Vec3 alias ensures all existing code (rsw, gnd, view, render, etc.) is unchanged.

import shared "app:shared"
import "core:net"

Vec3 :: shared.Vec3

// Client-only types

Net_Mode :: enum {
    Offline,
    Client,
}

Client_Net_State :: struct {
    socket:           net.UDP_Socket,
    server_endpoint:  net.Endpoint,
    connected:        bool,

    local_tick:       shared.Tick_ID,
    tick_accumulator: f64,

    logical_position: Vec3,
    visual_offset:    Vec3,

    history:          shared.History_Buffer,
    last_server_tick: shared.Tick_ID,

    // Path following (click-to-move)
    path:             []Cell_Pos,
    path_index:       int,
    move_target:      Vec3,
    has_path:         bool,
}
