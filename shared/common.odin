package shared

import "core:math"

MOVE_SPEED :: f32(200.0)

// === History Buffer Operations ===

history_write :: proc(buf: ^History_Buffer, frame: History_Frame) {
    idx := u32(frame.tick) % HISTORY_SIZE
    buf.frames[idx] = frame
}

history_read :: proc(buf: ^History_Buffer, tick: Tick_ID) -> (History_Frame, bool) {
    idx := u32(tick) % HISTORY_SIZE
    frame := buf.frames[idx]
    if frame.tick != tick {
        return {}, false
    }
    return frame, true
}

// === Deterministic Physics Step (shared by client & server) ===

physics_step :: proc(position: Vec3, input: Input_Payload) -> Vec3 {
    if input.moving == 0 do return position

    dx := input.target.x - position.x
    dz := input.target.z - position.z
    dist := math.sqrt(dx * dx + dz * dz)

    step := MOVE_SPEED * TICK_DT
    if dist <= step {
        return Vec3{input.target.x, input.target.y, input.target.z}
    }

    ratio := step / dist
    return Vec3{
        position.x + dx * ratio,
        position.y,
        position.z + dz * ratio,
    }
}

// === Utility ===

vec3_distance :: proc(a, b: Vec3) -> f32 {
    dx := a.x - b.x
    dy := a.y - b.y
    dz := a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
}
