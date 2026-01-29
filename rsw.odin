package main

import "core:fmt"
import "core:math"

// RSW magic signature
RSW_MAGIC :: "GRSW"

// Object types in RSW
RSW_Object_Type :: enum i32 {
    Virtual   = 0,
    Model     = 1,
    LightSrc  = 2,
    SoundSrc  = 3,
    EffectSrc = 4,
}

// Vector3 for RSW data (matches C++ vector3d)
Vec3 :: struct #packed {
    x, y, z: f32,
}

// Actor/Model info
RSW_Actor :: struct {
    name:       [40]u8,
    model_name: [80]u8,
    node_name:  [80]u8,
    pos:        Vec3,
    rot:        Vec3,
    scale:      Vec3,
    anim_type:  i32,
    anim_speed: f32,
    block_type: i32,
}

// Light source info
RSW_Light :: struct {
    name:  [80]u8,
    pos:   Vec3,
    red:   i32,
    green: i32,
    blue:  i32,
    range: f32,
}

// Effect source info (torches, etc.)
RSW_Effect :: struct {
    name:       [80]u8,
    pos:        Vec3,
    type:       i32,
    emit_speed: f32,
    param:      [4]f32,
}

// Sound source info
RSW_Sound :: struct {
    name:      [80]u8,
    wave_name: [80]u8,
    pos:       Vec3,
    vol:       f32,
    width:     i32,
    height:    i32,
    range:     f32,
    cycle:     f32,  // Only in version 2.0+
}

// RSW World file
RSW_World :: struct {
    // Version
    ver_major: u8,
    ver_minor: u8,

    // Referenced files (CP949 encoded)
    ini_file:  string,
    gnd_file:  string,
    attr_file: string,
    scr_file:  string,

    // Water settings
    water_level:      f32,
    water_type:       i32,
    wave_height:      f32,
    wave_speed:       f32,
    wave_pitch:       f32,
    water_anim_speed: i32,

    // Lighting
    light_longitude: i32,
    light_latitude:  i32,
    diffuse_col:     Vec3,
    ambient_col:     Vec3,
    light_dir:       Vec3,
    shadow_opacity:  f32,

    // Ground bounds
    ground_top:    i32,
    ground_bottom: i32,
    ground_left:   i32,
    ground_right:  i32,

    // Objects
    actors:  [dynamic]RSW_Actor,
    lights:  [dynamic]RSW_Light,
    effects: [dynamic]RSW_Effect,
    sounds:  [dynamic]RSW_Sound,
}

// Create a new RSW world
rsw_create :: proc() -> RSW_World {
    return RSW_World{
        water_level      = 0.0,
        water_type       = 0,
        wave_height      = 1.0,
        wave_speed       = 2.0,
        wave_pitch       = 50.0,
        water_anim_speed = 3,
        light_latitude   = 45,
        light_longitude  = 45,
        diffuse_col      = Vec3{1, 1, 1},
        ambient_col      = Vec3{0, 0, 0},
        shadow_opacity   = 1.0,
        ground_top       = -500,
        ground_bottom    = 500,
        ground_left      = -500,
        ground_right     = 500,
    }
}

// Destroy RSW world and free resources
rsw_destroy :: proc(rsw: ^RSW_World) {
    if rsw.ini_file != "" do delete(rsw.ini_file)
    if rsw.gnd_file != "" do delete(rsw.gnd_file)
    if rsw.attr_file != "" do delete(rsw.attr_file)
    if rsw.scr_file != "" do delete(rsw.scr_file)
    delete(rsw.actors)
    delete(rsw.lights)
    delete(rsw.effects)
    delete(rsw.sounds)
    rsw^ = {}
}

// Helper to read a fixed-size string from data
@(private)
read_fixed_string :: proc(data: []u8, offset: ^int, size: int) -> string {
    if offset^ + size > len(data) {
        return ""
    }
    bytes := data[offset^:offset^ + size]
    offset^ += size

    // Find null terminator
    end := 0
    for i := 0; i < size; i += 1 {
        if bytes[i] == 0 {
            break
        }
        end = i + 1
    }

    if end == 0 {
        return ""
    }

    // Clone the string (it's CP949 encoded from the GRF)
    result := make([]u8, end)
    copy(result, bytes[:end])
    return string(result)
}

// Helper to read typed data
@(private)
read_data :: proc(data: []u8, offset: ^int, $T: typeid) -> (T, bool) {
    size := size_of(T)
    if offset^ + size > len(data) {
        return {}, false
    }
    result := (cast(^T)&data[offset^])^
    offset^ += size
    return result, true
}

// Load RSW from raw data (typically read from GRF)
rsw_load :: proc(rsw: ^RSW_World, data: []u8) -> bool {
    if len(data) < 10 {
        fmt.eprintln("RSW data too small")
        return false
    }

    offset := 0

    // Check magic "GRSW"
    if data[0] != 'G' || data[1] != 'R' || data[2] != 'S' || data[3] != 'W' {
        fmt.eprintln("Invalid RSW magic")
        return false
    }
    offset = 4

    // Version
    rsw.ver_major = data[offset]
    rsw.ver_minor = data[offset + 1]
    offset += 2

    // Check version (support up to 2.1)
    if (rsw.ver_major == 2 && rsw.ver_minor > 1) || rsw.ver_major > 2 {
        fmt.eprintln("Unsupported RSW version:", rsw.ver_major, ".", rsw.ver_minor)
        return false
    }

    // INI file name (40 bytes) - usually empty/unused
    rsw.ini_file = read_fixed_string(data, &offset, 40)

    // GND file name (40 bytes)
    rsw.gnd_file = read_fixed_string(data, &offset, 40)

    // GAT/Attr file (version 1.4+)
    if (rsw.ver_major == 1 && rsw.ver_minor >= 4) || rsw.ver_major >= 2 {
        rsw.attr_file = read_fixed_string(data, &offset, 40)
    }

    // SCR file name (40 bytes)
    rsw.scr_file = read_fixed_string(data, &offset, 40)

    // Water level (version 1.3+)
    if (rsw.ver_major == 1 && rsw.ver_minor >= 3) || rsw.ver_major >= 2 {
        rsw.water_level, _ = read_data(data, &offset, f32)
    }

    // Water settings (version 1.8+)
    if (rsw.ver_major == 1 && rsw.ver_minor >= 8) || rsw.ver_major >= 2 {
        rsw.water_type, _ = read_data(data, &offset, i32)
        rsw.wave_height, _ = read_data(data, &offset, f32)
        rsw.wave_speed, _ = read_data(data, &offset, f32)
        rsw.wave_pitch, _ = read_data(data, &offset, f32)
    }

    // Water anim speed (version 1.9+)
    if (rsw.ver_major == 1 && rsw.ver_minor >= 9) || rsw.ver_major >= 2 {
        rsw.water_anim_speed, _ = read_data(data, &offset, i32)
    }

    // Lighting (version 1.5+)
    if (rsw.ver_major == 1 && rsw.ver_minor >= 5) || rsw.ver_major >= 2 {
        rsw.light_longitude, _ = read_data(data, &offset, i32)
        rsw.light_latitude, _ = read_data(data, &offset, i32)
        rsw.diffuse_col, _ = read_data(data, &offset, Vec3)
        rsw.ambient_col, _ = read_data(data, &offset, Vec3)
    }

    // Calculate light direction from latitude/longitude
    // Latitude: angle from horizontal (0=horizontal, 90=straight down from above)
    // Longitude: rotation around vertical axis
    lat_rad := f32(rsw.light_latitude) * math.PI / 180.0
    lon_rad := f32(rsw.light_longitude) * math.PI / 180.0

    // Rotation: start with (0, 1, 0), rotate by latitude around X, then longitude around Y
    // After X rotation by lat: (0, cos(lat), -sin(lat))
    // After Y rotation by lon: (-sin(lat)*sin(lon), cos(lat), -sin(lat)*cos(lon))
    cos_lat := math.cos(lat_rad)
    sin_lat := math.sin(lat_rad)
    cos_lon := math.cos(lon_rad)
    sin_lon := math.sin(lon_rad)

    // DHXJ: start with (0,1,0), rotate X by lat, then Y by lon
    // Negate Z because we negate heights which flips Z in our normals
    rsw.light_dir = Vec3{
        sin_lat * sin_lon,
        cos_lat,
        -sin_lat * cos_lon,
    }

    // Shadow opacity (version 1.7+)
    if (rsw.ver_major == 1 && rsw.ver_minor >= 7) || rsw.ver_major >= 2 {
        rsw.shadow_opacity, _ = read_data(data, &offset, f32)
    }

    // Ground bounds (version 1.6+)
    if (rsw.ver_major == 1 && rsw.ver_minor >= 6) || rsw.ver_major >= 2 {
        rsw.ground_top, _ = read_data(data, &offset, i32)
        rsw.ground_bottom, _ = read_data(data, &offset, i32)
        rsw.ground_left, _ = read_data(data, &offset, i32)
        rsw.ground_right, _ = read_data(data, &offset, i32)
    }

    // Object count
    obj_count, ok := read_data(data, &offset, i32)
    if !ok {
        fmt.eprintln("Failed to read object count")
        return false
    }

    // Temporary struct matching file layout for model reading
    Tmp_Actor_Info :: struct #packed {
        model_name: [80]u8,
        node_name:  [80]u8,
        pos:        Vec3,
        rot:        Vec3,
        scale:      Vec3,
    }

    // Parse objects
    for i: i32 = 0; i < obj_count; i += 1 {
        obj_type, type_ok := read_data(data, &offset, i32)
        if !type_ok {
            break
        }

        switch RSW_Object_Type(obj_type) {
        case .Model:
            actor: RSW_Actor

            // Name and animation info (version 1.3+)
            if (rsw.ver_major == 1 && rsw.ver_minor >= 3) || rsw.ver_major >= 2 {
                // Read name (40 bytes)
                name_bytes := data[offset:offset + 40]
                copy(actor.name[:], name_bytes)
                offset += 40

                actor.anim_type, _ = read_data(data, &offset, i32)
                actor.anim_speed, _ = read_data(data, &offset, f32)
                actor.block_type, _ = read_data(data, &offset, i32)
            } else {
                actor.anim_type = 0
                actor.anim_speed = 1.0
                actor.block_type = 0
            }

            // Clamp anim speed
            if actor.anim_speed > 100 || actor.anim_speed <= 0 {
                actor.anim_speed = 1.0
            }

            // Read transform data
            tmp_info, tmp_ok := read_data(data, &offset, Tmp_Actor_Info)
            if !tmp_ok {
                break
            }

            copy(actor.model_name[:], tmp_info.model_name[:])
            copy(actor.node_name[:], tmp_info.node_name[:])
            actor.pos = tmp_info.pos
            actor.rot = tmp_info.rot
            actor.scale = tmp_info.scale

            append(&rsw.actors, actor)

        case .LightSrc:
            light: RSW_Light
            light_data, light_ok := read_data(data, &offset, RSW_Light)
            if light_ok {
                append(&rsw.lights, light_data)
            }

        case .EffectSrc:
            effect: RSW_Effect
            effect_data, effect_ok := read_data(data, &offset, RSW_Effect)
            if effect_ok {
                append(&rsw.effects, effect_data)
            }

        case .SoundSrc:
            if rsw.ver_major >= 2 {
                // Version 2.0+ has cycle field
                sound, sound_ok := read_data(data, &offset, RSW_Sound)
                if sound_ok {
                    append(&rsw.sounds, sound)
                }
            } else {
                // Version 1.x doesn't have cycle field
                Sound_V19 :: struct #packed {
                    name:      [80]u8,
                    wave_name: [80]u8,
                    pos:       Vec3,
                    vol:       f32,
                    width:     i32,
                    height:    i32,
                    range:     f32,
                }
                sound_v19, sound_ok := read_data(data, &offset, Sound_V19)
                if sound_ok {
                    sound: RSW_Sound
                    copy(sound.name[:], sound_v19.name[:])
                    copy(sound.wave_name[:], sound_v19.wave_name[:])
                    sound.pos = sound_v19.pos
                    sound.vol = sound_v19.vol
                    sound.width = sound_v19.width
                    sound.height = sound_v19.height
                    sound.range = sound_v19.range
                    sound.cycle = 0
                    append(&rsw.sounds, sound)
                }
            }

        case .Virtual:
            // Skip virtual objects (no data)
        }
    }

    return true
}

// Load RSW from GRF
rsw_load_from_grf :: proc(rsw: ^RSW_World, grf: ^Grf, path: string) -> bool {
    data, ok := grf_get_data(grf, path)
    if !ok {
        fmt.eprintln("Failed to load RSW from GRF:", path)
        return false
    }
    defer delete(data)

    return rsw_load(rsw, data)
}

// Get a null-terminated string from a fixed-size array (for model names, etc.)
rsw_get_string :: proc(arr: []u8) -> string {
    end := 0
    for i := 0; i < len(arr); i += 1 {
        if arr[i] == 0 {
            break
        }
        end = i + 1
    }
    if end == 0 {
        return ""
    }
    return string(arr[:end])
}

// Test RSW loading
test_rsw :: proc() {
    fmt.println("=== RSW Test ===")

    grf := grf_create()
    defer grf_close(&grf)

    if !grf_open(&grf, "ragnarok/data.grf") {
        fmt.println("Could not open GRF - skipping RSW test")
        return
    }

    rsw := rsw_create()
    defer rsw_destroy(&rsw)

    // Try to load prontera
    if rsw_load_from_grf(&rsw, &grf, "data\\prontera.rsw") {
        fmt.printf("Loaded RSW version %d.%d\n", rsw.ver_major, rsw.ver_minor)
        fmt.printf("  GND file: %s\n", rsw.gnd_file)
        fmt.printf("  GAT file: %s\n", rsw.attr_file)
        fmt.printf("  Water level: %.2f\n", rsw.water_level)
        fmt.printf("  Light: lat=%d lon=%d\n", rsw.light_latitude, rsw.light_longitude)
        fmt.printf("  Diffuse: (%.2f, %.2f, %.2f)\n",
                   rsw.diffuse_col.x, rsw.diffuse_col.y, rsw.diffuse_col.z)
        fmt.printf("  Ambient: (%.2f, %.2f, %.2f)\n",
                   rsw.ambient_col.x, rsw.ambient_col.y, rsw.ambient_col.z)
        fmt.printf("  Models: %d, Lights: %d, Effects: %d, Sounds: %d\n",
                   len(rsw.actors), len(rsw.lights), len(rsw.effects), len(rsw.sounds))

        // Show first few models
        for &actor, i in rsw.actors {
            if i >= 3 do break
            model_name := rsw_get_string(actor.model_name[:])
            // Convert to UTF-8 for display
            utf8_name, ok := cp949_to_utf8(transmute([]u8)model_name)
            if ok {
                fmt.printf("  Model %d: %s at (%.1f, %.1f, %.1f)\n",
                           i, utf8_name, actor.pos.x, actor.pos.y, actor.pos.z)
                delete(utf8_name)
            }
        }
    } else {
        fmt.println("Failed to load prontera.rsw")
    }

    fmt.println("=== RSW Test Complete ===")
}
