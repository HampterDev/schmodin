package main

import "core:math"

// 4x4 matrix inverse via cofactor expansion
mat4_inverse :: proc(m: Mat4) -> Mat4 {
    // Flatten to column-major access: m[col][row]
    a00 := m[0][0]; a01 := m[0][1]; a02 := m[0][2]; a03 := m[0][3]
    a10 := m[1][0]; a11 := m[1][1]; a12 := m[1][2]; a13 := m[1][3]
    a20 := m[2][0]; a21 := m[2][1]; a22 := m[2][2]; a23 := m[2][3]
    a30 := m[3][0]; a31 := m[3][1]; a32 := m[3][2]; a33 := m[3][3]

    b00 := a00 * a11 - a01 * a10
    b01 := a00 * a12 - a02 * a10
    b02 := a00 * a13 - a03 * a10
    b03 := a01 * a12 - a02 * a11
    b04 := a01 * a13 - a03 * a11
    b05 := a02 * a13 - a03 * a12
    b06 := a20 * a31 - a21 * a30
    b07 := a20 * a32 - a22 * a30
    b08 := a20 * a33 - a23 * a30
    b09 := a21 * a32 - a22 * a31
    b10 := a21 * a33 - a23 * a31
    b11 := a22 * a33 - a23 * a32

    det := b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06
    if math.abs(det) < 1e-10 {
        return mat4_identity()
    }

    inv_det := 1.0 / det

    return Mat4{
        {
            ( a11 * b11 - a12 * b10 + a13 * b09) * inv_det,
            (-a01 * b11 + a02 * b10 - a03 * b09) * inv_det,
            ( a31 * b05 - a32 * b04 + a33 * b03) * inv_det,
            (-a21 * b05 + a22 * b04 - a23 * b03) * inv_det,
        },
        {
            (-a10 * b11 + a12 * b08 - a13 * b07) * inv_det,
            ( a00 * b11 - a02 * b08 + a03 * b07) * inv_det,
            (-a30 * b05 + a32 * b02 - a33 * b01) * inv_det,
            ( a20 * b05 - a22 * b02 + a23 * b01) * inv_det,
        },
        {
            ( a10 * b10 - a11 * b08 + a13 * b06) * inv_det,
            (-a00 * b10 + a01 * b08 - a03 * b06) * inv_det,
            ( a30 * b04 - a31 * b02 + a33 * b00) * inv_det,
            (-a20 * b04 + a21 * b02 - a23 * b00) * inv_det,
        },
        {
            (-a10 * b09 + a11 * b07 - a12 * b06) * inv_det,
            ( a00 * b09 - a01 * b07 + a02 * b06) * inv_det,
            (-a30 * b03 + a31 * b01 - a32 * b00) * inv_det,
            ( a20 * b03 - a21 * b01 + a22 * b00) * inv_det,
        },
    }
}

// Multiply 4x4 matrix by 4-component vector
mat4_mul_vec4 :: proc(m: Mat4, v: [4]f32) -> [4]f32 {
    return [4]f32{
        m[0][0]*v[0] + m[1][0]*v[1] + m[2][0]*v[2] + m[3][0]*v[3],
        m[0][1]*v[0] + m[1][1]*v[1] + m[2][1]*v[2] + m[3][1]*v[3],
        m[0][2]*v[0] + m[1][2]*v[1] + m[2][2]*v[2] + m[3][2]*v[3],
        m[0][3]*v[0] + m[1][3]*v[1] + m[2][3]*v[2] + m[3][3]*v[3],
    }
}

// Convert screen pixel coordinates to a world-space ray
screen_to_world_ray :: proc(ctx: ^Context, screen_x, screen_y: f64) -> (origin: Vec3, dir: Vec3) {
    w := f64(ctx.swapchain_extent.width)
    h := f64(ctx.swapchain_extent.height)

    // Pixel to NDC (Vulkan viewport: Y=0 at top, projection already flips Y)
    ndc_x := f32(2.0 * screen_x / w - 1.0)
    ndc_y := f32(2.0 * screen_y / h - 1.0)

    inv_vp := mat4_inverse(camera_get_vp_matrix(ctx))

    // Near and far points in clip space
    near_clip := [4]f32{ndc_x, ndc_y, 0.0, 1.0}
    far_clip  := [4]f32{ndc_x, ndc_y, 1.0, 1.0}

    near_world := mat4_mul_vec4(inv_vp, near_clip)
    far_world  := mat4_mul_vec4(inv_vp, far_clip)

    // Perspective divide
    if math.abs(near_world[3]) < 1e-10 || math.abs(far_world[3]) < 1e-10 {
        return {}, {}
    }

    near_pos := Vec3{
        near_world[0] / near_world[3],
        near_world[1] / near_world[3],
        near_world[2] / near_world[3],
    }
    far_pos := Vec3{
        far_world[0] / far_world[3],
        far_world[1] / far_world[3],
        far_world[2] / far_world[3],
    }

    direction := vec3_normalize(Vec3{
        far_pos.x - near_pos.x,
        far_pos.y - near_pos.y,
        far_pos.z - near_pos.z,
    })

    return near_pos, direction
}

// Ray-plane intersection at Y = ground_y
ray_ground_intersect :: proc(origin, dir: Vec3, ground_y: f32) -> (Vec3, bool) {
    if math.abs(dir.y) < 1e-6 do return {}, false

    t := (ground_y - origin.y) / dir.y
    if t < 0 do return {}, false

    return Vec3{
        origin.x + dir.x * t,
        ground_y,
        origin.z + dir.z * t,
    }, true
}
