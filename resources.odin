package main

import "core:mem"
import "core:strings"
import "core:slice"
import vk "vendor:vulkan"

create_depth_resources :: proc(ctx: ^Context) -> bool {
    ctx.depth_format = .D32_SFLOAT

    image_info := vk.ImageCreateInfo{
        sType       = .IMAGE_CREATE_INFO,
        imageType   = .D2,
        format      = ctx.depth_format,
        extent      = vk.Extent3D{ctx.swapchain_extent.width, ctx.swapchain_extent.height, 1},
        mipLevels   = 1,
        arrayLayers = 1,
        samples     = {._1},
        tiling      = .OPTIMAL,
        usage       = {.DEPTH_STENCIL_ATTACHMENT},
    }

    if vk.CreateImage(ctx.device, &image_info, nil, &ctx.depth_image) != .SUCCESS {
        return false
    }

    // Allocate memory
    mem_requirements: vk.MemoryRequirements
    vk.GetImageMemoryRequirements(ctx.device, ctx.depth_image, &mem_requirements)

    alloc_info := vk.MemoryAllocateInfo{
        sType           = .MEMORY_ALLOCATE_INFO,
        allocationSize  = mem_requirements.size,
        memoryTypeIndex = find_memory_type(ctx, mem_requirements.memoryTypeBits, {.DEVICE_LOCAL}),
    }

    if vk.AllocateMemory(ctx.device, &alloc_info, nil, &ctx.depth_memory) != .SUCCESS {
        return false
    }
    vk.BindImageMemory(ctx.device, ctx.depth_image, ctx.depth_memory, 0)

    // Create view
    view_info := vk.ImageViewCreateInfo{
        sType    = .IMAGE_VIEW_CREATE_INFO,
        image    = ctx.depth_image,
        viewType = .D2,
        format   = ctx.depth_format,
        subresourceRange = vk.ImageSubresourceRange{
            aspectMask     = {.DEPTH},
            baseMipLevel   = 0,
            levelCount     = 1,
            baseArrayLayer = 0,
            layerCount     = 1,
        },
    }

    if vk.CreateImageView(ctx.device, &view_info, nil, &ctx.depth_view) != .SUCCESS {
        return false
    }

    return true
}

// Initialize map list from GRF
init_map_list :: proc(ctx: ^Context) -> bool {
    grf := grf_create()
    defer grf_close(&grf)

    if !grf_open(&grf, "ragnarok/data.grf") {
        log("Failed to open GRF for map list")
        return false
    }

    // Get all RSW files
    rsw_files := grf_list_files(&grf, ".rsw")

    // Sort alphabetically
    slice.sort_by(rsw_files, proc(a, b: string) -> bool {
        return a < b
    })

    ctx.available_maps = rsw_files
    log_fmt("Found %d maps", len(ctx.available_maps))

    return len(ctx.available_maps) > 0
}

// Load a specific map by RSW path
load_map :: proc(ctx: ^Context, rsw_path: string) -> bool {
    log_fmt("Loading map: %s", rsw_path)

    grf := grf_create()
    defer grf_close(&grf)

    if !grf_open(&grf, "ragnarok/data.grf") {
        log("Failed to open GRF")
        return false
    }

    rsw := rsw_create()
    defer rsw_destroy(&rsw)

    if !rsw_load_from_grf(&rsw, &grf, rsw_path) {
        log_fmt("Failed to load RSW: %s", rsw_path)
        return false
    }

    // Store RSW lighting values
    ctx.ambient_color = rsw.ambient_col
    ctx.diffuse_color = rsw.diffuse_col
    ctx.light_dir = rsw.light_dir
    ctx.shadow_opacity = rsw.shadow_opacity

    // Compute envdiff: 1 - (1-diffuse)*(1-ambient)
    ctx.envdiff = Vec3{
        1.0 - (1.0 - rsw.diffuse_col.x) * (1.0 - rsw.ambient_col.x),
        1.0 - (1.0 - rsw.diffuse_col.y) * (1.0 - rsw.ambient_col.y),
        1.0 - (1.0 - rsw.diffuse_col.z) * (1.0 - rsw.ambient_col.z),
    }

    log_fmt("RSW ambient: (%.2f, %.2f, %.2f)", rsw.ambient_col.x, rsw.ambient_col.y, rsw.ambient_col.z)
    log_fmt("RSW diffuse: (%.2f, %.2f, %.2f)", rsw.diffuse_col.x, rsw.diffuse_col.y, rsw.diffuse_col.z)

    gnd := gnd_create()
    defer gnd_destroy(&gnd)

    if !gnd_load_from_grf(&gnd, &grf, rsw.gnd_file) {
        log("Failed to load GND")
        return false
    }

    // Generate mesh from GND
    vertices := gnd_generate_mesh(&gnd, nil)
    if vertices == nil || len(vertices) == 0 {
        log("Failed to generate mesh")
        return false
    }
    defer delete(vertices)

    ctx.vertex_count = u32(len(vertices))
    log_fmt("Generated %d vertices", ctx.vertex_count)

    // Load ground textures from GRF
    if !load_ground_textures(ctx, &grf, &gnd) {
        log("Warning: Failed to load ground textures")
    }

    // Set camera position based on GND dimensions
    center_x := f32(gnd.width) * gnd.zoom * 0.5
    center_z := f32(gnd.height) * gnd.zoom * 0.5
    ctx.camera_pos = Vec3{center_x, 200, center_z - 300}
    ctx.camera_rot = quat_from_axis_angle(Vec3{1, 0, 0}, -0.3)

    // Fog parameters
    ctx.fog_color = Vec3{4.0/255.0, 12.0/255.0, 154.0/255.0}
    ctx.fog_start = 161.468
    ctx.fog_end = 1416.0

    // Create/recreate vertex buffer
    buffer_size := vk.DeviceSize(len(vertices) * size_of(Vertex))

    buffer_info := vk.BufferCreateInfo{
        sType = .BUFFER_CREATE_INFO,
        size  = buffer_size,
        usage = {.VERTEX_BUFFER, .SHADER_DEVICE_ADDRESS},
    }

    if vk.CreateBuffer(ctx.device, &buffer_info, nil, &ctx.vertex_buffer) != .SUCCESS {
        return false
    }

    mem_requirements: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(ctx.device, ctx.vertex_buffer, &mem_requirements)

    flags_info := vk.MemoryAllocateFlagsInfo{
        sType = .MEMORY_ALLOCATE_FLAGS_INFO,
        flags = {.DEVICE_ADDRESS},
    }

    alloc_info := vk.MemoryAllocateInfo{
        sType           = .MEMORY_ALLOCATE_INFO,
        pNext           = &flags_info,
        allocationSize  = mem_requirements.size,
        memoryTypeIndex = find_memory_type(ctx, mem_requirements.memoryTypeBits, {.HOST_VISIBLE, .HOST_COHERENT}),
    }

    if vk.AllocateMemory(ctx.device, &alloc_info, nil, &ctx.vertex_memory) != .SUCCESS {
        return false
    }

    vk.BindBufferMemory(ctx.device, ctx.vertex_buffer, ctx.vertex_memory, 0)

    // Copy data
    data: rawptr
    vk.MapMemory(ctx.device, ctx.vertex_memory, 0, buffer_size, {}, &data)
    mem.copy(data, raw_data(vertices), int(buffer_size))
    vk.UnmapMemory(ctx.device, ctx.vertex_memory)

    // Get buffer device address
    address_info := vk.BufferDeviceAddressInfo{
        sType  = .BUFFER_DEVICE_ADDRESS_INFO,
        buffer = ctx.vertex_buffer,
    }
    ctx.vertex_buffer_address = vk.GetBufferDeviceAddress(ctx.device, &address_info)

    // Store current map name
    ctx.current_map_name = rsw_path

    return true
}

// Cleanup map resources before loading a new map
cleanup_map_resources :: proc(ctx: ^Context) {
    vk.DeviceWaitIdle(ctx.device)

    // Cleanup vertex buffer
    if ctx.vertex_buffer != 0 {
        vk.DestroyBuffer(ctx.device, ctx.vertex_buffer, nil)
        ctx.vertex_buffer = 0
    }
    if ctx.vertex_memory != 0 {
        vk.FreeMemory(ctx.device, ctx.vertex_memory, nil)
        ctx.vertex_memory = 0
    }

    // Cleanup textures
    cleanup_textures(ctx)
}

// Reload map (cleanup + load)
reload_map :: proc(ctx: ^Context, rsw_path: string) -> bool {
    cleanup_map_resources(ctx)
    return load_map(ctx, rsw_path)
}

// Original create_vertex_buffer - now uses load_map with default map
create_vertex_buffer :: proc(ctx: ^Context) -> bool {
    // Initialize map list first
    if !init_map_list(ctx) {
        log("Failed to initialize map list")
        return false
    }

    // Find default map or use first available
    default_map := "data\\pay_dun00.rsw"
    ctx.current_map_index = 0

    for map_name, i in ctx.available_maps {
        if strings.contains(map_name, "pay_dun00") {
            default_map = map_name
            ctx.current_map_index = i
            break
        }
    }

    // If default not found, use first map
    if ctx.current_map_index == 0 && len(ctx.available_maps) > 0 {
        default_map = ctx.available_maps[0]
    }

    return load_map(ctx, default_map)
}

find_memory_type :: proc(ctx: ^Context, type_filter: u32, properties: vk.MemoryPropertyFlags) -> u32 {
    mem_properties: vk.PhysicalDeviceMemoryProperties
    vk.GetPhysicalDeviceMemoryProperties(ctx.physical_device, &mem_properties)

    for i in 0..<mem_properties.memoryTypeCount {
        if (type_filter & (1 << i)) != 0 &&
           (mem_properties.memoryTypes[i].propertyFlags & properties) == properties {
            return i
        }
    }

    return 0
}
