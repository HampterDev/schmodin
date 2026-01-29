package main

import "core:math"
import "core:fmt"

// Lighting parameters for mesh generation
Ground_Lighting :: struct {
    ambient:   Vec3,
    diffuse:   Vec3,
    light_dir: Vec3,
    opacity:   f32,   // Light intensity multiplier (from RSW shadow_opacity)
}

// Calculate face normal for a cell from its 4 corner heights
calc_cell_normal :: proc(gnd: ^GND_Ground, cell_x, cell_y: i32) -> Vec3 {
    cell := gnd_get_cell(gnd, cell_x, cell_y)
    if cell == nil || cell.top_surface_id < 0 {
        return Vec3{0, 1, 0}  // Default up normal for invalid cells
    }

    base_x := f32(cell_x) * gnd.zoom
    base_z := f32(cell_y) * gnd.zoom

    // Corner positions
    p0 := Vec3{base_x, -cell.height[0], base_z}
    p1 := Vec3{base_x + gnd.zoom, -cell.height[1], base_z}
    p2 := Vec3{base_x, -cell.height[2], base_z + gnd.zoom}
    p3 := Vec3{base_x + gnd.zoom, -cell.height[3], base_z + gnd.zoom}

    // Cross product of diagonals
    diag1 := Vec3{p3.x - p0.x, p3.y - p0.y, p3.z - p0.z}
    diag2 := Vec3{p1.x - p2.x, p1.y - p2.y, p1.z - p2.z}
    return vec3_normalize(vec3_cross(diag1, diag2))
}

// Calculate smooth normal for a vertex by averaging adjacent cell normals
// corner: 0=bottom-left, 1=bottom-right, 2=top-left, 3=top-right of the current cell
calc_smooth_normal :: proc(gnd: ^GND_Ground, cell_x, cell_y: i32, corner: int) -> Vec3 {
    // Each corner is shared by up to 4 cells
    // Corner 0 (bottom-left of cell x,y) = top-right of (x-1,y-1), top-left of (x,y-1), bottom-right of (x-1,y)
    // Corner 1 (bottom-right of cell x,y) = top-left of (x+1,y-1), top-right of (x,y-1), bottom-left of (x+1,y)
    // Corner 2 (top-left of cell x,y) = bottom-right of (x-1,y+1), bottom-left of (x,y+1), top-right of (x-1,y)
    // Corner 3 (top-right of cell x,y) = bottom-left of (x+1,y+1), bottom-right of (x,y+1), top-left of (x+1,y)

    avg_normal := Vec3{0, 0, 0}
    count: f32 = 0

    // Offsets for cells that share each corner
    // For corner 0 (bottom-left): cells (x,y), (x-1,y), (x,y-1), (x-1,y-1)
    // For corner 1 (bottom-right): cells (x,y), (x+1,y), (x,y-1), (x+1,y-1)
    // For corner 2 (top-left): cells (x,y), (x-1,y), (x,y+1), (x-1,y+1)
    // For corner 3 (top-right): cells (x,y), (x+1,y), (x,y+1), (x+1,y+1)
    offsets: [4][4][2]i32 = {
        {{0, 0}, {-1, 0}, {0, -1}, {-1, -1}},  // corner 0
        {{0, 0}, {1, 0}, {0, -1}, {1, -1}},    // corner 1
        {{0, 0}, {-1, 0}, {0, 1}, {-1, 1}},    // corner 2
        {{0, 0}, {1, 0}, {0, 1}, {1, 1}},      // corner 3
    }

    for offset in offsets[corner] {
        nx := cell_x + offset[0]
        ny := cell_y + offset[1]
        neighbor := gnd_get_cell(gnd, nx, ny)
        if neighbor != nil && neighbor.top_surface_id >= 0 {
            n := calc_cell_normal(gnd, nx, ny)
            avg_normal.x += n.x
            avg_normal.y += n.y
            avg_normal.z += n.z
            count += 1
        }
    }

    if count > 0 {
        return vec3_normalize(avg_normal)
    }
    return Vec3{0, 1, 0}  // Default up
}

// Generate mesh vertices from GND data with per-vertex lighting
// Returns a slice of vertices that should be freed by the caller
gnd_generate_mesh :: proc(gnd: ^GND_Ground, lighting: ^Ground_Lighting = nil) -> []Vertex {
    // Count how many vertices we need
    // Each surface generates 2 triangles (6 vertices)
    vertex_count := 0
    for cell_y: i32 = 0; cell_y < gnd.height; cell_y += 1 {
        for cell_x: i32 = 0; cell_x < gnd.width; cell_x += 1 {
            cell := gnd_get_cell(gnd, cell_x, cell_y)
            if cell == nil {
                continue
            }
            if cell.top_surface_id >= 0 {
                vertex_count += 6
            }
            if cell.front_surface_id >= 0 {
                vertex_count += 6
            }
            if cell.right_surface_id >= 0 {
                vertex_count += 6
            }
        }
    }

    if vertex_count == 0 {
        return nil
    }

    // Calculate lightmap atlas dimensions for UV calculation
    atlas_width, atlas_height, cells_per_row := calc_atlas_size(len(gnd.lightmaps))
    atlas_w := f32(atlas_width)
    atlas_h := f32(atlas_height)

    vertices := make([]Vertex, vertex_count)
    idx := 0

    // Generate triangles for each cell
    for cell_y: i32 = 0; cell_y < gnd.height; cell_y += 1 {
        for cell_x: i32 = 0; cell_x < gnd.width; cell_x += 1 {
            cell := gnd_get_cell(gnd, cell_x, cell_y)
            if cell == nil {
                continue
            }

            // Base world position for this cell
            base_x := f32(cell_x) * gnd.zoom
            base_z := f32(cell_y) * gnd.zoom

            // === TOP SURFACE (horizontal ground) ===
            if cell.top_surface_id >= 0 {
                surface := gnd_get_surface(gnd, cell.top_surface_id)
                if surface != nil {
                    // Positions for each corner (Y is height, negated because RO uses negative heights)
                    p0 := [3]f32{base_x, -cell.height[0], base_z}                         // bottom-left
                    p1 := [3]f32{base_x + gnd.zoom, -cell.height[1], base_z}              // bottom-right
                    p2 := [3]f32{base_x, -cell.height[2], base_z + gnd.zoom}              // top-left
                    p3 := [3]f32{base_x + gnd.zoom, -cell.height[3], base_z + gnd.zoom}   // top-right

                    // UVs from surface (0-1 range for the texture)
                    uv0 := [2]f32{surface.u[0], surface.v[0]}
                    uv1 := [2]f32{surface.u[1], surface.v[1]}
                    uv2 := [2]f32{surface.u[2], surface.v[2]}
                    uv3 := [2]f32{surface.u[3], surface.v[3]}

                    // Lightmap UVs - calculate position in atlas
                    lm_id := surface.lightmap_id
                    lm_cell_x := u32(lm_id) % cells_per_row
                    lm_cell_y := u32(lm_id) / cells_per_row

                    lm_u_min := (f32(lm_cell_x) * f32(LMAP_CELL_SIZE) + 1.0) / atlas_w
                    lm_v_min := (f32(lm_cell_y) * f32(LMAP_CELL_SIZE) + 1.0) / atlas_h
                    lm_u_max := (f32(lm_cell_x + 1) * f32(LMAP_CELL_SIZE) - 1.0) / atlas_w
                    lm_v_max := (f32(lm_cell_y + 1) * f32(LMAP_CELL_SIZE) - 1.0) / atlas_h

                    lm_uv0 := [2]f32{lm_u_min, lm_v_min}
                    lm_uv1 := [2]f32{lm_u_max, lm_v_min}
                    lm_uv2 := [2]f32{lm_u_min, lm_v_max}
                    lm_uv3 := [2]f32{lm_u_max, lm_v_max}

                    // Helper to get tile color from a cell's top surface
                    get_tile_color :: proc(gnd: ^GND_Ground, c: ^GND_Cell) -> (r, g, b, a: u8) {
                        if c == nil {
                            return 255, 255, 255, 255
                        }
                        if c.top_surface_id < 0 {
                            return 255, 255, 255, 255
                        }
                        s := gnd_get_surface(gnd, c.top_surface_id)
                        if s == nil {
                            return 255, 255, 255, 255
                        }
                        return s.color.r, s.color.g, s.color.b, s.color.a
                    }

                    // Get neighboring cells for tile colors
                    cell_top    := gnd_get_cell(gnd, cell_x, cell_y + 1)
                    cell_right  := gnd_get_cell(gnd, cell_x + 1, cell_y)
                    cell_diag   := gnd_get_cell(gnd, cell_x + 1, cell_y + 1)

                    r0, g0, b0, _ := get_tile_color(gnd, cell)
                    r1, g1, b1, _ := get_tile_color(gnd, cell_right)
                    r2, g2, b2, _ := get_tile_color(gnd, cell_top)
                    r3, g3, b3, _ := get_tile_color(gnd, cell_diag)

                    color0 := [3]f32{f32(r0) / 255.0, f32(g0) / 255.0, f32(b0) / 255.0}
                    color1 := [3]f32{f32(r1) / 255.0, f32(g1) / 255.0, f32(b1) / 255.0}
                    color2 := [3]f32{f32(r2) / 255.0, f32(g2) / 255.0, f32(b2) / 255.0}
                    color3 := [3]f32{f32(r3) / 255.0, f32(g3) / 255.0, f32(b3) / 255.0}

                    // Calculate smooth normals for each corner
                    n0 := calc_smooth_normal(gnd, cell_x, cell_y, 0)
                    n1 := calc_smooth_normal(gnd, cell_x, cell_y, 1)
                    n2 := calc_smooth_normal(gnd, cell_x, cell_y, 2)
                    n3 := calc_smooth_normal(gnd, cell_x, cell_y, 3)

                    normal0 := [3]f32{n0.x, n0.y, n0.z}
                    normal1 := [3]f32{n1.x, n1.y, n1.z}
                    normal2 := [3]f32{n2.x, n2.y, n2.z}
                    normal3 := [3]f32{n3.x, n3.y, n3.z}

                    tex_idx := u32(max(0, surface.texture_id))

                    // Triangle 1: bottom-left, bottom-right, top-left (0, 1, 2)
                    vertices[idx] = Vertex{pos = p0, normal = normal0, color = color0, uv = uv0, lm_uv = lm_uv0, tex_index = tex_idx}
                    vertices[idx + 1] = Vertex{pos = p1, normal = normal1, color = color1, uv = uv1, lm_uv = lm_uv1, tex_index = tex_idx}
                    vertices[idx + 2] = Vertex{pos = p2, normal = normal2, color = color2, uv = uv2, lm_uv = lm_uv2, tex_index = tex_idx}

                    // Triangle 2: bottom-right, top-right, top-left (1, 3, 2)
                    vertices[idx + 3] = Vertex{pos = p1, normal = normal1, color = color1, uv = uv1, lm_uv = lm_uv1, tex_index = tex_idx}
                    vertices[idx + 4] = Vertex{pos = p3, normal = normal3, color = color3, uv = uv3, lm_uv = lm_uv3, tex_index = tex_idx}
                    vertices[idx + 5] = Vertex{pos = p2, normal = normal2, color = color2, uv = uv2, lm_uv = lm_uv2, tex_index = tex_idx}

                    idx += 6
                }
            }

            // === FRONT WALL ===
            // Connects TOP edge of this cell (corners 2,3) to BOTTOM edge of cell at (x, y+1) (corners 0,1)
            // Wall is at Z = base_z + zoom (the shared edge)
            if cell.front_surface_id >= 0 && cell_y < gnd.height - 1 {
                front_surface := gnd_get_surface(gnd, cell.front_surface_id)
                if front_surface != nil {
                    neighbor := gnd_get_cell(gnd, cell_x, cell_y + 1)

                    // Get neighbor's bottom edge heights (corners 0,1)
                    neighbor_h0 := cell.height[2]  // Default to same height
                    neighbor_h1 := cell.height[3]
                    if neighbor != nil {
                        neighbor_h0 = neighbor.height[0]
                        neighbor_h1 = neighbor.height[1]
                    }

                    // Wall at Z = base_z + zoom (top edge of current cell)
                    wall_z := base_z + gnd.zoom
                    w0 := [3]f32{base_x, -cell.height[2], wall_z}              // this cell corner 2 (top-left)
                    w1 := [3]f32{base_x + gnd.zoom, -cell.height[3], wall_z}   // this cell corner 3 (top-right)
                    w2 := [3]f32{base_x, -neighbor_h0, wall_z}                 // neighbor corner 0
                    w3 := [3]f32{base_x + gnd.zoom, -neighbor_h1, wall_z}      // neighbor corner 1

                    // Compute normal from geometry (cross product of edges)
                    // This ensures the normal points toward the higher cell
                    edge1 := Vec3{w1[0] - w0[0], w1[1] - w0[1], w1[2] - w0[2]}
                    edge2 := Vec3{w2[0] - w0[0], w2[1] - w0[1], w2[2] - w0[2]}
                    normal := vec3_normalize(vec3_cross(edge1, edge2))
                    wall_normal := [3]f32{normal.x, normal.y, normal.z}

                    // UVs from front surface
                    wuv0 := [2]f32{front_surface.u[0], front_surface.v[0]}
                    wuv1 := [2]f32{front_surface.u[1], front_surface.v[1]}
                    wuv2 := [2]f32{front_surface.u[2], front_surface.v[2]}
                    wuv3 := [2]f32{front_surface.u[3], front_surface.v[3]}

                    // Lightmap UVs for wall
                    wlm_id := front_surface.lightmap_id
                    wlm_cell_x := u32(wlm_id) % cells_per_row
                    wlm_cell_y := u32(wlm_id) / cells_per_row
                    wlm_u_min := (f32(wlm_cell_x) * f32(LMAP_CELL_SIZE) + 1.0) / atlas_w
                    wlm_v_min := (f32(wlm_cell_y) * f32(LMAP_CELL_SIZE) + 1.0) / atlas_h
                    wlm_u_max := (f32(wlm_cell_x + 1) * f32(LMAP_CELL_SIZE) - 1.0) / atlas_w
                    wlm_v_max := (f32(wlm_cell_y + 1) * f32(LMAP_CELL_SIZE) - 1.0) / atlas_h

                    wlm_uv0 := [2]f32{wlm_u_min, wlm_v_min}
                    wlm_uv1 := [2]f32{wlm_u_max, wlm_v_min}
                    wlm_uv2 := [2]f32{wlm_u_min, wlm_v_max}
                    wlm_uv3 := [2]f32{wlm_u_max, wlm_v_max}

                    // Wall color (use surface color)
                    wall_color := [3]f32{f32(front_surface.color.r) / 255.0, f32(front_surface.color.g) / 255.0, f32(front_surface.color.b) / 255.0}

                    wall_tex_idx := u32(max(0, front_surface.texture_id))

                    // Two triangles forming a quad: w0-w1-w3 and w0-w3-w2
                    vertices[idx] = Vertex{pos = w0, normal = wall_normal, color = wall_color, uv = wuv0, lm_uv = wlm_uv0, tex_index = wall_tex_idx}
                    vertices[idx + 1] = Vertex{pos = w1, normal = wall_normal, color = wall_color, uv = wuv1, lm_uv = wlm_uv1, tex_index = wall_tex_idx}
                    vertices[idx + 2] = Vertex{pos = w3, normal = wall_normal, color = wall_color, uv = wuv3, lm_uv = wlm_uv3, tex_index = wall_tex_idx}

                    vertices[idx + 3] = Vertex{pos = w0, normal = wall_normal, color = wall_color, uv = wuv0, lm_uv = wlm_uv0, tex_index = wall_tex_idx}
                    vertices[idx + 4] = Vertex{pos = w3, normal = wall_normal, color = wall_color, uv = wuv3, lm_uv = wlm_uv3, tex_index = wall_tex_idx}
                    vertices[idx + 5] = Vertex{pos = w2, normal = wall_normal, color = wall_color, uv = wuv2, lm_uv = wlm_uv2, tex_index = wall_tex_idx}

                    idx += 6
                }
            }

            // === RIGHT WALL ===
            // Connects RIGHT edge of this cell (corners 1,3) to LEFT edge of cell at (x+1, y) (corners 0,2)
            // Wall is at X = base_x + zoom (the shared edge)
            if cell.right_surface_id >= 0 && cell_x < gnd.width - 1 {
                right_surface := gnd_get_surface(gnd, cell.right_surface_id)
                if right_surface != nil {
                    neighbor := gnd_get_cell(gnd, cell_x + 1, cell_y)

                    // Get neighbor's left edge heights (corners 0,2)
                    neighbor_h0 := cell.height[1]  // Default to same height
                    neighbor_h2 := cell.height[3]
                    if neighbor != nil {
                        neighbor_h0 = neighbor.height[0]
                        neighbor_h2 = neighbor.height[2]
                    }

                    // Wall at X = base_x + zoom (right edge of current cell)
                    // Vertex order from dhxj: corner 3, corner 1, neighbor 2, neighbor 0
                    wall_x := base_x + gnd.zoom
                    w0 := [3]f32{wall_x, -cell.height[3], base_z + gnd.zoom}   // this cell corner 3 (top-right)
                    w1 := [3]f32{wall_x, -cell.height[1], base_z}              // this cell corner 1 (bottom-right)
                    w2 := [3]f32{wall_x, -neighbor_h2, base_z + gnd.zoom}      // neighbor corner 2 (top-left)
                    w3 := [3]f32{wall_x, -neighbor_h0, base_z}                 // neighbor corner 0 (bottom-left)

                    // Compute normal from geometry
                    edge1 := Vec3{w1[0] - w0[0], w1[1] - w0[1], w1[2] - w0[2]}
                    edge2 := Vec3{w2[0] - w0[0], w2[1] - w0[1], w2[2] - w0[2]}
                    normal := vec3_normalize(vec3_cross(edge1, edge2))
                    wall_normal := [3]f32{normal.x, normal.y, normal.z}

                    // UVs from right surface
                    wuv0 := [2]f32{right_surface.u[0], right_surface.v[0]}
                    wuv1 := [2]f32{right_surface.u[1], right_surface.v[1]}
                    wuv2 := [2]f32{right_surface.u[2], right_surface.v[2]}
                    wuv3 := [2]f32{right_surface.u[3], right_surface.v[3]}

                    // Lightmap UVs for wall
                    wlm_id := right_surface.lightmap_id
                    wlm_cell_x := u32(wlm_id) % cells_per_row
                    wlm_cell_y := u32(wlm_id) / cells_per_row
                    wlm_u_min := (f32(wlm_cell_x) * f32(LMAP_CELL_SIZE) + 1.0) / atlas_w
                    wlm_v_min := (f32(wlm_cell_y) * f32(LMAP_CELL_SIZE) + 1.0) / atlas_h
                    wlm_u_max := (f32(wlm_cell_x + 1) * f32(LMAP_CELL_SIZE) - 1.0) / atlas_w
                    wlm_v_max := (f32(wlm_cell_y + 1) * f32(LMAP_CELL_SIZE) - 1.0) / atlas_h

                    wlm_uv0 := [2]f32{wlm_u_min, wlm_v_min}
                    wlm_uv1 := [2]f32{wlm_u_max, wlm_v_min}
                    wlm_uv2 := [2]f32{wlm_u_min, wlm_v_max}
                    wlm_uv3 := [2]f32{wlm_u_max, wlm_v_max}

                    // Wall color (use surface color)
                    wall_color := [3]f32{f32(right_surface.color.r) / 255.0, f32(right_surface.color.g) / 255.0, f32(right_surface.color.b) / 255.0}

                    wall_tex_idx := u32(max(0, right_surface.texture_id))

                    // Two triangles forming a quad: w0-w1-w3 and w0-w3-w2
                    vertices[idx] = Vertex{pos = w0, normal = wall_normal, color = wall_color, uv = wuv0, lm_uv = wlm_uv0, tex_index = wall_tex_idx}
                    vertices[idx + 1] = Vertex{pos = w1, normal = wall_normal, color = wall_color, uv = wuv1, lm_uv = wlm_uv1, tex_index = wall_tex_idx}
                    vertices[idx + 2] = Vertex{pos = w3, normal = wall_normal, color = wall_color, uv = wuv3, lm_uv = wlm_uv3, tex_index = wall_tex_idx}

                    vertices[idx + 3] = Vertex{pos = w0, normal = wall_normal, color = wall_color, uv = wuv0, lm_uv = wlm_uv0, tex_index = wall_tex_idx}
                    vertices[idx + 4] = Vertex{pos = w3, normal = wall_normal, color = wall_color, uv = wuv3, lm_uv = wlm_uv3, tex_index = wall_tex_idx}
                    vertices[idx + 5] = Vertex{pos = w2, normal = wall_normal, color = wall_color, uv = wuv2, lm_uv = wlm_uv2, tex_index = wall_tex_idx}

                    idx += 6
                }
            }
        }
    }

    fmt.printf("Generated %d vertices for GND mesh (%d triangles)\n",
               vertex_count, vertex_count / 3)
    return vertices
}

// Matrix math helpers

// Create identity matrix
mat4_identity :: proc() -> Mat4 {
    return Mat4{
        {1, 0, 0, 0},
        {0, 1, 0, 0},
        {0, 0, 1, 0},
        {0, 0, 0, 1},
    }
}

// Create perspective projection matrix
// fov_y is in radians
mat4_perspective :: proc(fov_y: f32, aspect: f32, near: f32, far: f32) -> Mat4 {
    tan_half_fov := math.tan(fov_y / 2.0)

    result := Mat4{}
    result[0][0] = 1.0 / (aspect * tan_half_fov)
    result[1][1] = -1.0 / tan_half_fov  // Flip Y for Vulkan
    result[2][2] = far / (near - far)
    result[2][3] = -1.0
    result[3][2] = (near * far) / (near - far)
    return result
}

// Create look-at view matrix
mat4_look_at :: proc(eye: Vec3, target: Vec3, up: Vec3) -> Mat4 {
    // Forward vector (from eye to target)
    f := vec3_normalize(Vec3{target.x - eye.x, target.y - eye.y, target.z - eye.z})

    // Right vector
    r := vec3_normalize(vec3_cross(f, up))

    // Recalculate up
    u := vec3_cross(r, f)

    result := Mat4{
        {r.x, u.x, -f.x, 0},
        {r.y, u.y, -f.y, 0},
        {r.z, u.z, -f.z, 0},
        {-vec3_dot(r, eye), -vec3_dot(u, eye), vec3_dot(f, eye), 1},
    }
    return result
}

// Create translation matrix
mat4_translate :: proc(v: Vec3) -> Mat4 {
    result := mat4_identity()
    result[3][0] = v.x
    result[3][1] = v.y
    result[3][2] = v.z
    return result
}

// Matrix multiplication
mat4_mul :: proc(a: Mat4, b: Mat4) -> Mat4 {
    result := Mat4{}
    for col in 0..<4 {
        for row in 0..<4 {
            sum: f32 = 0
            for k in 0..<4 {
                sum += a[k][row] * b[col][k]
            }
            result[col][row] = sum
        }
    }
    return result
}

// Vector helpers
vec3_dot :: proc(a: Vec3, b: Vec3) -> f32 {
    return a.x * b.x + a.y * b.y + a.z * b.z
}

vec3_cross :: proc(a: Vec3, b: Vec3) -> Vec3 {
    return Vec3{
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x,
    }
}

vec3_length :: proc(v: Vec3) -> f32 {
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
}

vec3_normalize :: proc(v: Vec3) -> Vec3 {
    len := vec3_length(v)
    if len < 0.0001 {
        return Vec3{0, 1, 0}
    }
    return Vec3{v.x / len, v.y / len, v.z / len}
}
