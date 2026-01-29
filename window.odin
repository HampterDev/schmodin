package main

import "base:runtime"
import "vendor:glfw"

// Global context pointer for GLFW callbacks
g_ctx: ^Context

// Scroll callback for zoom
scroll_callback :: proc "c" (window: glfw.WindowHandle, xoffset: f64, yoffset: f64) {
    context = runtime.default_context()
    if g_ctx != nil {
        g_ctx.scroll_delta += f32(yoffset)
    }
}

// Framebuffer resize callback
framebuffer_resize_callback :: proc "c" (window: glfw.WindowHandle, width: i32, height: i32) {
    context = runtime.default_context()
    if g_ctx != nil {
        g_ctx.framebuffer_resized = true
    }
}

// Toggle fullscreen mode
toggle_fullscreen :: proc(ctx: ^Context) {
    if ctx.is_fullscreen {
        // Return to windowed mode
        glfw.SetWindowMonitor(ctx.window, nil,
            ctx.windowed_pos.x, ctx.windowed_pos.y,
            ctx.windowed_size.x, ctx.windowed_size.y, 0)
        ctx.is_fullscreen = false
    } else {
        // Store current window position and size
        pos_x, pos_y := glfw.GetWindowPos(ctx.window)
        ctx.windowed_pos = {pos_x, pos_y}
        size_x, size_y := glfw.GetWindowSize(ctx.window)
        ctx.windowed_size = {size_x, size_y}

        // Get primary monitor and its video mode
        monitor := glfw.GetPrimaryMonitor()
        mode := glfw.GetVideoMode(monitor)

        // Switch to fullscreen
        glfw.SetWindowMonitor(ctx.window, monitor, 0, 0, mode.width, mode.height, mode.refresh_rate)
        ctx.is_fullscreen = true
    }
    ctx.framebuffer_resized = true
}

init_window :: proc(ctx: ^Context) -> bool {
    if glfw.Init() != true {
        return false
    }

    // Load saved config
    config := load_config()
    log_fmt("Config: pos=(%d,%d) size=(%d,%d) fullscreen=%v",
        config.window_pos_x, config.window_pos_y, config.window_width, config.window_height, config.fullscreen)

    glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
    glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)

    ctx.window = glfw.CreateWindow(config.window_width, config.window_height, "Schmodin", nil, nil)
    if ctx.window == nil {
        return false
    }

    // Apply saved position (only if not default, to avoid triggering resize on fresh start)
    if config.window_pos_x != 100 || config.window_pos_y != 100 {
        glfw.SetWindowPos(ctx.window, config.window_pos_x, config.window_pos_y)
    }

    // Store windowed state for fullscreen toggle
    ctx.windowed_pos = {config.window_pos_x, config.window_pos_y}
    ctx.windowed_size = {config.window_width, config.window_height}

    // Set up callbacks
    g_ctx = ctx
    glfw.SetScrollCallback(ctx.window, scroll_callback)
    glfw.SetFramebufferSizeCallback(ctx.window, framebuffer_resize_callback)

    // Store whether we should start fullscreen (applied after Vulkan init)
    ctx.start_fullscreen = bool(config.fullscreen)

    // Apply UI/rendering state from config
    apply_config_to_context(ctx, config)

    return true
}

// Save current application state to config file
save_app_state :: proc(ctx: ^Context) {
    // Start with rendering state from context
    config := extract_config_from_context(ctx)

    // Add window state
    if ctx.is_fullscreen {
        // Save the windowed state (not fullscreen dimensions)
        config.window_pos_x = ctx.windowed_pos.x
        config.window_pos_y = ctx.windowed_pos.y
        config.window_width = ctx.windowed_size.x
        config.window_height = ctx.windowed_size.y
    } else {
        // Get current window state
        pos_x, pos_y := glfw.GetWindowPos(ctx.window)
        size_x, size_y := glfw.GetWindowSize(ctx.window)
        config.window_pos_x = pos_x
        config.window_pos_y = pos_y
        config.window_width = size_x
        config.window_height = size_y
    }
    config.fullscreen = b32(ctx.is_fullscreen)

    log_fmt("Saving config: pos=(%d,%d) size=(%d,%d) fullscreen=%v",
        config.window_pos_x, config.window_pos_y, config.window_width, config.window_height, config.fullscreen)
    save_config(config)
}
