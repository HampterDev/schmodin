package main

import "core:fmt"

// GND magic signature
GND_MAGIC :: "GRGN"

// Lightmap dimensions
LMAP_WIDTH :: 8
LMAP_HEIGHT :: 8
LMAP_INTENSITY_SIZE :: LMAP_WIDTH * LMAP_HEIGHT        // 64 bytes
LMAP_SPECULAR_SIZE :: LMAP_WIDTH * LMAP_HEIGHT * 3     // 192 bytes
LMAP_TOTAL_SIZE :: LMAP_INTENSITY_SIZE + LMAP_SPECULAR_SIZE  // 256 bytes

// Color in BGRA format (matches RO's COLOR struct)
Color_BGRA :: struct #packed {
    b, g, r, a: u8,
}

// Lightmap info - intensity and specular data
GND_Lightmap :: struct #packed {
    intensity: [LMAP_HEIGHT][LMAP_WIDTH]u8,       // 64 bytes
    specular:  [LMAP_HEIGHT][LMAP_WIDTH][3]u8,    // 192 bytes (RGB)
}

// Surface/tile data
GND_Surface :: struct #packed {
    u:           [4]f32,      // Texture U coordinates for 4 corners
    v:           [4]f32,      // Texture V coordinates for 4 corners
    texture_id:  i16,         // Texture index (-1 = no texture)
    lightmap_id: u16,         // Lightmap index
    color:       Color_BGRA,  // Vertex color (ARGB)
}

// Cell/tile data (version 1.7+)
GND_Cell :: struct #packed {
    height:           [4]f32,  // Height at 4 corners (bottom-left, bottom-right, top-left, top-right)
    top_surface_id:   i32,     // Top face surface index (-1 = none)
    front_surface_id: i32,     // Front face surface index (-1 = none)
    right_surface_id: i32,     // Right face surface index (-1 = none)
}

// GND Ground file
GND_Ground :: struct {
    // Version
    ver_major: u8,
    ver_minor: u8,

    // Dimensions
    width:  i32,
    height: i32,
    zoom:   f32,   // Cell size (usually 10.0)

    // Textures (paths are CP949 encoded)
    textures: [dynamic]string,

    // Lightmaps
    lightmaps: []GND_Lightmap,

    // Surfaces (tiles)
    surfaces: []GND_Surface,

    // Cells (grid)
    cells: []GND_Cell,

    // Raw data pointer (we keep this to avoid copying large arrays)
    _raw_data: []u8,
}

// Create a new GND ground
gnd_create :: proc() -> GND_Ground {
    return GND_Ground{
        zoom = 10.0,
    }
}

// Destroy GND ground and free resources
gnd_destroy :: proc(gnd: ^GND_Ground) {
    for tex in gnd.textures {
        delete(tex)
    }
    delete(gnd.textures)

    // These are slices into _raw_data, don't delete individually
    gnd.lightmaps = nil
    gnd.surfaces = nil
    gnd.cells = nil

    if gnd._raw_data != nil {
        delete(gnd._raw_data)
    }

    gnd^ = {}
}

// Helper to read typed data from buffer
@(private)
gnd_read :: proc(data: []u8, offset: ^int, $T: typeid) -> (T, bool) {
    size := size_of(T)
    if offset^ + size > len(data) {
        return {}, false
    }
    result := (cast(^T)&data[offset^])^
    offset^ += size
    return result, true
}

// Helper to read a fixed-size string
@(private)
gnd_read_string :: proc(data: []u8, offset: ^int, max_len: int) -> string {
    if offset^ + max_len > len(data) {
        return ""
    }

    bytes := data[offset^:offset^ + max_len]
    offset^ += max_len

    // Find null terminator
    end := 0
    for i := 0; i < max_len; i += 1 {
        if bytes[i] == 0 {
            break
        }
        end = i + 1
    }

    if end == 0 {
        return ""
    }

    // Clone the string
    result := make([]u8, end)
    copy(result, bytes[:end])
    return string(result)
}

// Load GND from raw data (typically read from GRF)
gnd_load :: proc(gnd: ^GND_Ground, data: []u8) -> bool {
    if len(data) < 14 {
        fmt.eprintln("GND data too small")
        return false
    }

    offset := 0

    // Check magic "GRGN"
    if data[0] != 'G' || data[1] != 'R' || data[2] != 'G' || data[3] != 'N' {
        fmt.eprintln("Invalid GND magic")
        return false
    }
    offset = 4

    // Version
    gnd.ver_major = data[offset]
    gnd.ver_minor = data[offset + 1]
    offset += 2

    // Only support version 1.7+
    if gnd.ver_major != 1 || gnd.ver_minor < 7 {
        fmt.eprintln("Unsupported GND version:", gnd.ver_major, ".", gnd.ver_minor, "- need 1.7+")
        return false
    }

    // Dimensions
    gnd.width, _ = gnd_read(data, &offset, i32)
    gnd.height, _ = gnd_read(data, &offset, i32)
    gnd.zoom, _ = gnd_read(data, &offset, f32)

    // Texture count and max name length
    num_textures, _ := gnd_read(data, &offset, i32)
    max_tex_name, _ := gnd_read(data, &offset, i32)

    // Read texture names
    gnd.textures = make([dynamic]string, num_textures)
    for i: i32 = 0; i < num_textures; i += 1 {
        gnd.textures[i] = gnd_read_string(data, &offset, int(max_tex_name))
    }

    // Lightmap info
    num_lightmaps, _ := gnd_read(data, &offset, i32)
    lmap_width, _ := gnd_read(data, &offset, i32)
    lmap_height, _ := gnd_read(data, &offset, i32)
    lmap_pf, _ := gnd_read(data, &offset, i32)  // Pixel format (unused)
    _ = lmap_width
    _ = lmap_height
    _ = lmap_pf

    // Keep raw data reference for slicing
    gnd._raw_data = make([]u8, len(data))
    copy(gnd._raw_data, data)

    // Lightmap data - slice directly into raw data
    lightmap_data_size := int(num_lightmaps) * LMAP_TOTAL_SIZE
    if offset + lightmap_data_size > len(data) {
        fmt.eprintln("GND data truncated at lightmaps")
        return false
    }
    gnd.lightmaps = (cast([^]GND_Lightmap)&gnd._raw_data[offset])[:num_lightmaps]
    offset += lightmap_data_size

    // Surface count and data
    num_surfaces, _ := gnd_read(data, &offset, i32)
    surface_data_size := int(num_surfaces) * size_of(GND_Surface)
    if offset + surface_data_size > len(data) {
        fmt.eprintln("GND data truncated at surfaces")
        return false
    }
    gnd.surfaces = (cast([^]GND_Surface)&gnd._raw_data[offset])[:num_surfaces]
    offset += surface_data_size

    // Cell data
    num_cells := gnd.width * gnd.height
    cell_data_size := int(num_cells) * size_of(GND_Cell)
    if offset + cell_data_size > len(data) {
        fmt.eprintln("GND data truncated at cells")
        return false
    }
    gnd.cells = (cast([^]GND_Cell)&gnd._raw_data[offset])[:num_cells]

    return true
}

// Load GND from GRF using the path from RSW
gnd_load_from_grf :: proc(gnd: ^GND_Ground, grf: ^Grf, rsw_gnd_path: string) -> bool {
    // The RSW stores just the filename (e.g., "prontera.gnd")
    // We need to prepend "data\" to get the full path
    full_path := fmt.tprintf("data\\%s", rsw_gnd_path)

    data, ok := grf_get_data(grf, full_path)
    if !ok {
        fmt.eprintln("Failed to load GND from GRF:", full_path)
        return false
    }
    defer delete(data)

    return gnd_load(gnd, data)
}

// Get cell at grid position
gnd_get_cell :: proc(gnd: ^GND_Ground, x, y: i32) -> ^GND_Cell {
    if x < 0 || x >= gnd.width || y < 0 || y >= gnd.height {
        return nil
    }
    return &gnd.cells[y * gnd.width + x]
}

// Get surface by index
gnd_get_surface :: proc(gnd: ^GND_Ground, index: i32) -> ^GND_Surface {
    if index < 0 || index >= i32(len(gnd.surfaces)) {
        return nil
    }
    return &gnd.surfaces[index]
}

// Get lightmap by index
gnd_get_lightmap :: proc(gnd: ^GND_Ground, index: u16) -> ^GND_Lightmap {
    if int(index) >= len(gnd.lightmaps) {
        return nil
    }
    return &gnd.lightmaps[index]
}

// Get texture name by index
gnd_get_texture :: proc(gnd: ^GND_Ground, index: i16) -> string {
    if index < 0 || int(index) >= len(gnd.textures) {
        return ""
    }
    return gnd.textures[index]
}

// Calculate world position for a cell corner
// corner: 0=bottom-left, 1=bottom-right, 2=top-left, 3=top-right
gnd_get_world_pos :: proc(gnd: ^GND_Ground, cell_x, cell_y: i32, corner: int) -> Vec3 {
    cell := gnd_get_cell(gnd, cell_x, cell_y)
    if cell == nil {
        return {}
    }

    // Grid coordinates to world coordinates
    // X increases to the right, Z increases upward (in grid), Y is height
    base_x := f32(cell_x) * gnd.zoom
    base_z := f32(cell_y) * gnd.zoom

    switch corner {
    case 0: return Vec3{base_x, cell.height[0], base_z}                     // bottom-left
    case 1: return Vec3{base_x + gnd.zoom, cell.height[1], base_z}          // bottom-right
    case 2: return Vec3{base_x, cell.height[2], base_z + gnd.zoom}          // top-left
    case 3: return Vec3{base_x + gnd.zoom, cell.height[3], base_z + gnd.zoom} // top-right
    }

    return {}
}

// Test GND loading
test_gnd :: proc() {
    fmt.println("=== GND Test ===")

    grf := grf_create()
    defer grf_close(&grf)

    if !grf_open(&grf, "ragnarok/data.grf") {
        fmt.println("Could not open GRF - skipping GND test")
        return
    }

    // First load RSW to get GND filename
    rsw := rsw_create()
    defer rsw_destroy(&rsw)

    if !rsw_load_from_grf(&rsw, &grf, "data\\prontera.rsw") {
        fmt.println("Failed to load RSW - skipping GND test")
        return
    }

    fmt.printf("RSW references GND: %s\n", rsw.gnd_file)

    // Now load GND
    gnd := gnd_create()
    defer gnd_destroy(&gnd)

    if gnd_load_from_grf(&gnd, &grf, rsw.gnd_file) {
        fmt.printf("Loaded GND version %d.%d\n", gnd.ver_major, gnd.ver_minor)
        fmt.printf("  Size: %dx%d cells (zoom=%.1f)\n", gnd.width, gnd.height, gnd.zoom)
        fmt.printf("  Textures: %d\n", len(gnd.textures))
        fmt.printf("  Lightmaps: %d\n", len(gnd.lightmaps))
        fmt.printf("  Surfaces: %d\n", len(gnd.surfaces))
        fmt.printf("  Cells: %d\n", len(gnd.cells))

        // Show first few textures
        fmt.println("  First textures:")
        for tex, i in gnd.textures {
            if i >= 5 do break
            // Convert to UTF-8 for display
            utf8_name, ok := cp949_to_utf8(transmute([]u8)tex)
            if ok {
                fmt.printf("    [%d] %s\n", i, utf8_name)
                delete(utf8_name)
            }
        }

        // Show a sample cell
        if gnd.width > 0 && gnd.height > 0 {
            center_x := gnd.width / 2
            center_y := gnd.height / 2
            cell := gnd_get_cell(&gnd, center_x, center_y)
            if cell != nil {
                fmt.printf("  Center cell [%d,%d]:\n", center_x, center_y)
                fmt.printf("    Heights: %.1f, %.1f, %.1f, %.1f\n",
                           cell.height[0], cell.height[1], cell.height[2], cell.height[3])
                fmt.printf("    Surfaces: top=%d, front=%d, right=%d\n",
                           cell.top_surface_id, cell.front_surface_id, cell.right_surface_id)
            }
        }
    } else {
        fmt.println("Failed to load GND")
    }

    fmt.println("=== GND Test Complete ===")
}
