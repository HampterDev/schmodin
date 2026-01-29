package main

import "core:os"
import "core:mem"

CONFIG_FILE :: "schmodin.cfg"
CONFIG_MAGIC :: u32(0x534D4F44)  // "SMOD"
CONFIG_VERSION :: u32(2)

// Persisted application configuration
App_Config :: struct {
    magic:              u32,
    version:            u32,

    // Window state
    window_pos_x:       i32,
    window_pos_y:       i32,
    window_width:       i32,
    window_height:      i32,
    fullscreen:         b32,

    // Rendering toggles
    polygon_mode:       u32,    // 0=FILL, 1=LINE, 2=POINT
    height_factor:      f32,    // 0=flat, 1=normal height
    texture_enabled:    b32,
    tile_color_enabled: b32,
    ambient_enabled:    b32,
    shadowmap_enabled:  b32,
    colormap_enabled:   b32,
    lighting_enabled:   b32,
    lightmap_posterize: b32,
    fog_enabled:        b32,
}

// Default configuration values
default_config :: proc() -> App_Config {
    return App_Config{
        magic              = CONFIG_MAGIC,
        version            = CONFIG_VERSION,

        // Window defaults
        window_pos_x       = 100,
        window_pos_y       = 100,
        window_width       = WINDOW_WIDTH,
        window_height      = WINDOW_HEIGHT,
        fullscreen         = false,

        // Rendering defaults
        polygon_mode       = 0,     // FILL
        height_factor      = 1.0,   // Normal height
        texture_enabled    = true,
        tile_color_enabled = true,
        ambient_enabled    = true,
        shadowmap_enabled  = true,
        colormap_enabled   = true,
        lighting_enabled   = false, // Directional lighting off by default
        lightmap_posterize = true,  // Posterize for D3D7 look
        fog_enabled        = true,
    }
}

// Load config from file, returns defaults if file doesn't exist or is invalid
load_config :: proc() -> App_Config {
    data, ok := os.read_entire_file(CONFIG_FILE)
    if !ok || len(data) != size_of(App_Config) {
        return default_config()
    }
    defer delete(data)

    config := (^App_Config)(raw_data(data))^

    // Validate magic and version
    if config.magic != CONFIG_MAGIC || config.version != CONFIG_VERSION {
        return default_config()
    }

    // Validate window dimensions
    if config.window_width < 100 || config.window_height < 100 ||
       config.window_width > 8192 || config.window_height > 8192 {
        config.window_width = WINDOW_WIDTH
        config.window_height = WINDOW_HEIGHT
    }

    // Validate window position
    if config.window_pos_x < -4096 || config.window_pos_x > 8192 ||
       config.window_pos_y < -4096 || config.window_pos_y > 8192 {
        config.window_pos_x = 100
        config.window_pos_y = 100
    }

    // Validate polygon mode
    if config.polygon_mode > 2 {
        config.polygon_mode = 0
    }

    // Validate height factor
    if config.height_factor < 0.0 || config.height_factor > 2.0 {
        config.height_factor = 1.0
    }

    return config
}

// Save config to file
save_config :: proc(config: App_Config) {
    config_copy := config
    config_copy.magic = CONFIG_MAGIC
    config_copy.version = CONFIG_VERSION

    data := mem.byte_slice(&config_copy, size_of(App_Config))
    os.write_entire_file(CONFIG_FILE, data)
}

// Apply config to context (for rendering state)
apply_config_to_context :: proc(ctx: ^Context, config: App_Config) {
    ctx.polygon_mode = config.polygon_mode
    ctx.height_factor = config.height_factor
    ctx.texture_enabled = bool(config.texture_enabled)
    ctx.tile_color_enabled = bool(config.tile_color_enabled)
    ctx.ambient_enabled = bool(config.ambient_enabled)
    ctx.shadowmap_enabled = bool(config.shadowmap_enabled)
    ctx.colormap_enabled = bool(config.colormap_enabled)
    ctx.lighting_enabled = bool(config.lighting_enabled)
    ctx.lightmap_posterize = bool(config.lightmap_posterize)
    ctx.fog_enabled = bool(config.fog_enabled)
}

// Extract config from context (for saving)
extract_config_from_context :: proc(ctx: ^Context) -> App_Config {
    config: App_Config

    // Rendering state
    config.polygon_mode = ctx.polygon_mode
    config.height_factor = ctx.height_factor
    config.texture_enabled = b32(ctx.texture_enabled)
    config.tile_color_enabled = b32(ctx.tile_color_enabled)
    config.ambient_enabled = b32(ctx.ambient_enabled)
    config.shadowmap_enabled = b32(ctx.shadowmap_enabled)
    config.colormap_enabled = b32(ctx.colormap_enabled)
    config.lighting_enabled = b32(ctx.lighting_enabled)
    config.lightmap_posterize = b32(ctx.lightmap_posterize)
    config.fog_enabled = b32(ctx.fog_enabled)

    return config
}
