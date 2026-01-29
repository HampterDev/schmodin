package main

import "core:math"

// Quaternion type (x, y, z, w)
Quat :: struct {
    x, y, z, w: f32,
}

// Identity quaternion (no rotation)
quat_identity :: proc() -> Quat {
    return Quat{0, 0, 0, 1}
}

// Create quaternion from axis-angle
quat_from_axis_angle :: proc(axis: Vec3, angle: f32) -> Quat {
    half_angle := angle * 0.5
    s := math.sin(half_angle)
    return Quat{
        axis.x * s,
        axis.y * s,
        axis.z * s,
        math.cos(half_angle),
    }
}

// Quaternion multiplication
quat_mul :: proc(a: Quat, b: Quat) -> Quat {
    return Quat{
        a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    }
}

// Normalize quaternion
quat_normalize :: proc(q: Quat) -> Quat {
    len := math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
    if len < 0.0001 {
        return quat_identity()
    }
    return Quat{q.x / len, q.y / len, q.z / len, q.w / len}
}

// Rotate vector by quaternion
quat_rotate_vec3 :: proc(q: Quat, v: Vec3) -> Vec3 {
    // q * v * q^-1 (for unit quaternion, q^-1 = conjugate)
    qv := Quat{v.x, v.y, v.z, 0}
    q_conj := Quat{-q.x, -q.y, -q.z, q.w}
    result := quat_mul(quat_mul(q, qv), q_conj)
    return Vec3{result.x, result.y, result.z}
}

// Convert quaternion to rotation matrix
quat_to_mat4 :: proc(q: Quat) -> Mat4 {
    xx := q.x * q.x
    yy := q.y * q.y
    zz := q.z * q.z
    xy := q.x * q.y
    xz := q.x * q.z
    yz := q.y * q.z
    wx := q.w * q.x
    wy := q.w * q.y
    wz := q.w * q.z

    return Mat4{
        {1 - 2*(yy + zz), 2*(xy + wz), 2*(xz - wy), 0},
        {2*(xy - wz), 1 - 2*(xx + zz), 2*(yz + wx), 0},
        {2*(xz + wy), 2*(yz - wx), 1 - 2*(xx + yy), 0},
        {0, 0, 0, 1},
    }
}

// Get forward vector from quaternion (positive Z in local space)
quat_forward :: proc(q: Quat) -> Vec3 {
    return quat_rotate_vec3(q, Vec3{0, 0, 1})
}

// Get right vector from quaternion
quat_right :: proc(q: Quat) -> Vec3 {
    return quat_rotate_vec3(q, Vec3{1, 0, 0})
}

// Get up vector from quaternion
quat_up :: proc(q: Quat) -> Vec3 {
    return quat_rotate_vec3(q, Vec3{0, 1, 0})
}

// Create view matrix from position and quaternion rotation
mat4_from_quat_pos :: proc(q: Quat, pos: Vec3) -> Mat4 {
    // Get basis vectors from quaternion
    forward := quat_forward(q)
    right := quat_right(q)
    up := quat_up(q)

    // Build view matrix (inverse of camera transform)
    return Mat4{
        {right.x, up.x, -forward.x, 0},
        {right.y, up.y, -forward.y, 0},
        {right.z, up.z, -forward.z, 0},
        {-vec3_dot(right, pos), -vec3_dot(up, pos), vec3_dot(forward, pos), 1},
    }
}

// Create camera view-projection matrix
camera_get_vp_matrix :: proc(ctx: ^Context) -> Mat4 {
    // View matrix from quaternion
    view := mat4_from_quat_pos(ctx.camera_rot, ctx.camera_pos)

    // Projection matrix
    aspect := f32(ctx.swapchain_extent.width) / f32(ctx.swapchain_extent.height)
    proj := mat4_perspective(math.to_radians(f32(15.0)), aspect, 0.1, 10000.0)

    // Return view-projection matrix
    return mat4_mul(proj, view)
}
