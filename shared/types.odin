package shared

// === Vec3 (canonical definition, used by all packages) ===

Vec3 :: struct #packed {
    x, y, z: f32,
}

// === Constants ===

TICK_RATE           :: 64
TICK_DT             :: f32(1.0 / f64(TICK_RATE))
HISTORY_SIZE        :: 256
SLIDING_WINDOW_SIZE :: 128
MAX_TICKS_PER_FRAME :: 4
DEFAULT_PORT        :: 7777

// === Core Tick Type ===

Tick_ID :: distinct u32

// === Input ===

Input_Payload :: struct #packed {
    target: Vec3,    // World-space destination
    moving: u8,      // 1 = moving toward target, 0 = stopped
}

// === History ===

History_Frame :: struct {
    tick:     Tick_ID,
    position: Vec3,
    input:    Input_Payload,
}

History_Buffer :: struct {
    frames: [HISTORY_SIZE]History_Frame,
}

// === Packets (wire format) ===

Packet_Type :: enum u8 {
    Input        = 1,
    State_Update = 2,
    Correction   = 3,
    Handshake    = 4,
}

Input_Packet :: struct #packed {
    type:        Packet_Type,
    client_tick: Tick_ID,
    input:       Input_Payload,
}

Correction_Packet :: struct #packed {
    type:           Packet_Type,
    server_tick:    Tick_ID,
    corrected_tick: Tick_ID,
    position:       Vec3,
}

State_Packet :: struct #packed {
    type:        Packet_Type,
    server_tick: Tick_ID,
    position:    Vec3,
}

Handshake_Packet :: struct #packed {
    type:        Packet_Type,
    server_tick: Tick_ID,
    tick_rate:   u16,
}
