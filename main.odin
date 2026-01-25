package main

// Modern Vulkan with:
// - Dynamic Rendering (no render pass objects)
// - Push Descriptors (no descriptor pools/sets)
// - Buffer Device Address (GPU pointers)
// - Extended Dynamic State (minimal pipeline variants)
// - Synchronization2 (cleaner barriers)
// - Bindless Descriptors (descriptor indexing)

import "core:os"
import vk "vendor:vulkan"
import "vendor:glfw"

main :: proc() {
    // Open log file for debugging
    log_file_handle, err := os.open("vulkan_log.txt", os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o644)
    log_file = log_file_handle if err == os.ERROR_NONE else os.INVALID_HANDLE
    defer if log_file != os.INVALID_HANDLE do os.close(log_file)

    log("Starting application...")

    ctx: Context

    if !init_window(&ctx) {
        log("Failed to initialize window")
        return
    }
    defer glfw.DestroyWindow(ctx.window)
    defer glfw.Terminate()

    log("Window created")

    if !init_vulkan(&ctx) {
        log("Failed to initialize Vulkan")
        return
    }
    defer cleanup_vulkan(&ctx)

    log("Entering main loop")
    main_loop(&ctx)
    log("Exiting")
}

init_window :: proc(ctx: ^Context) -> bool {
    if glfw.Init() != true {
        return false
    }

    glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
    glfw.WindowHint(glfw.RESIZABLE, glfw.FALSE)

    ctx.window = glfw.CreateWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "Modern Vulkan - Odin", nil, nil)
    return ctx.window != nil
}

init_vulkan :: proc(ctx: ^Context) -> bool {
    log("Loading Vulkan functions...")
    vk.load_proc_addresses_global(cast(rawptr)glfw.GetInstanceProcAddress)

    log("Creating instance...")
    if !create_instance(ctx)           { log("Failed: create_instance"); return false }
    log("Setting up debug messenger...")
    if !setup_debug_messenger(ctx)     { log("Failed: setup_debug_messenger"); return false }
    log("Creating surface...")
    if !create_surface(ctx)            { log("Failed: create_surface"); return false }
    log("Picking physical device...")
    if !pick_physical_device(ctx)      { log("Failed: pick_physical_device"); return false }
    log("Creating logical device...")
    if !create_logical_device(ctx)     { log("Failed: create_logical_device"); return false }
    log("Creating swapchain...")
    if !create_swapchain(ctx)          { log("Failed: create_swapchain"); return false }
    log("Creating depth resources...")
    if !create_depth_resources(ctx)    { log("Failed: create_depth_resources"); return false }
    log("Creating bindless resources...")
    if !create_bindless_resources(ctx) { log("Failed: create_bindless_resources"); return false }
    log("Creating pipeline...")
    if !create_pipeline(ctx)           { log("Failed: create_pipeline"); return false }
    log("Creating command resources...")
    if !create_command_resources(ctx)  { log("Failed: create_command_resources"); return false }
    log("Creating sync objects...")
    if !create_sync_objects(ctx)       { log("Failed: create_sync_objects"); return false }
    log("Creating vertex buffer...")
    if !create_vertex_buffer(ctx)      { log("Failed: create_vertex_buffer"); return false }

    log("Vulkan initialized successfully")
    return true
}
