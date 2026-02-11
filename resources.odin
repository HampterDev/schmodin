package main

import "core:math"
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

    // Store RSW lighting values (light_dir used for lighting atlas)
    ctx.light_dir = rsw.light_dir

    log_fmt("RSW light_dir: (%.2f, %.2f, %.2f)", rsw.light_dir.x, rsw.light_dir.y, rsw.light_dir.z)

    gnd := gnd_create()
    defer gnd_destroy(&gnd)

    if !gnd_load_from_grf(&gnd, &grf, rsw.gnd_file) {
        log("Failed to load GND")
        return false
    }

    // Extract walkability grid (must happen before gnd_destroy)
    walkability_destroy(&ctx.walkability)
    ctx.walkability = walkability_extract(&gnd)
    log_fmt("Walkability grid: %dx%d cells", ctx.walkability.width, ctx.walkability.height)

    // Generate mesh from GND with pre-computed lighting
    vertices := gnd_generate_mesh(&gnd, ctx.light_dir)
    if vertices == nil || len(vertices) == 0 {
        log("Failed to generate mesh")
        return false
    }
    defer delete(vertices)

    ctx.vertex_count = u32(len(vertices))
    log_fmt("Generated %d vertices", ctx.vertex_count)

    // Load ground textures and create map atlases
    if !load_ground_textures(ctx, &grf, &gnd, ctx.light_dir) {
        log("Warning: Failed to load ground textures")
    }

    // Create normal arrow debug geometry (before GND is destroyed)
    cleanup_normal_arrows(ctx)  // Clean up old arrows first
    if !create_normal_arrows(ctx, &gnd) {
        log("Warning: Failed to create normal arrows")
    }

    // Set camera position based on GND dimensions
    center_x := f32(gnd.width) * gnd.zoom * 0.5
    center_z := f32(gnd.height) * gnd.zoom * 0.5
    ctx.camera_pos = Vec3{center_x, 200, center_z - 300}
    ctx.camera_rot = quat_from_axis_angle(Vec3{1, 0, 0}, -0.3)

    // Store map center and radius for sun indicator
    ctx.map_center = Vec3{center_x, 0, center_z}
    map_width := f32(gnd.width) * gnd.zoom
    map_height := f32(gnd.height) * gnd.zoom
    ctx.map_radius = math.sqrt(map_width * map_width + map_height * map_height) * 0.6

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

    // Cleanup normal arrows
    cleanup_normal_arrows(ctx)

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

// Create sun indicator sphere geometry (icosahedron)
create_sun_indicator :: proc(ctx: ^Context) -> bool {
    // Icosahedron vertices (golden ratio based)
    phi := (1.0 + math.sqrt(f32(5.0))) / 2.0
    ico_verts := [12]Vec3{
        {-1,  phi, 0}, { 1,  phi, 0}, {-1, -phi, 0}, { 1, -phi, 0},
        { 0, -1,  phi}, { 0,  1,  phi}, { 0, -1, -phi}, { 0,  1, -phi},
        { phi, 0, -1}, { phi, 0,  1}, {-phi, 0, -1}, {-phi, 0,  1},
    }

    // Normalize to unit sphere
    for i in 0..<12 {
        ico_verts[i] = vec3_normalize(ico_verts[i])
    }

    // Icosahedron faces (20 triangles)
    ico_faces := [20][3]int{
        {0, 11, 5}, {0, 5, 1}, {0, 1, 7}, {0, 7, 10}, {0, 10, 11},
        {1, 5, 9}, {5, 11, 4}, {11, 10, 2}, {10, 7, 6}, {7, 1, 8},
        {3, 9, 4}, {3, 4, 2}, {3, 2, 6}, {3, 6, 8}, {3, 8, 9},
        {4, 9, 5}, {2, 4, 11}, {6, 2, 10}, {8, 6, 7}, {9, 8, 1},
    }

    // Sun radius and color (bright yellow)
    sun_radius: f32 = 30.0
    sun_color := Vec3{1.0, 0.9, 0.3}  // Yellow

    // Generate vertices (60 vertices = 20 triangles * 3)
    vertices := make([]Vertex, 60)
    defer delete(vertices)

    for face, fi in ico_faces {
        for vi in 0..<3 {
            v := ico_verts[face[vi]]
            idx := fi * 3 + vi

            vertices[idx] = Vertex{
                pos       = {v.x * sun_radius, v.y * sun_radius, v.z * sun_radius},
                normal    = {v.x, v.y, v.z},
                color     = {sun_color.x, sun_color.y, sun_color.z},
                uv        = {0, 0},
                lm_uv     = {0, 0},
                tex_index = 0xFFFFFFFF,  // Special marker: no texture
                prelit    = 1.0,         // Full brightness for sun
            }
        }
    }

    ctx.sun_vertex_count = 60

    // Create buffer
    buffer_size := vk.DeviceSize(len(vertices) * size_of(Vertex))

    buffer_info := vk.BufferCreateInfo{
        sType = .BUFFER_CREATE_INFO,
        size  = buffer_size,
        usage = {.VERTEX_BUFFER, .SHADER_DEVICE_ADDRESS},
    }

    if vk.CreateBuffer(ctx.device, &buffer_info, nil, &ctx.sun_vertex_buffer) != .SUCCESS {
        log("Failed to create sun vertex buffer")
        return false
    }

    mem_requirements: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(ctx.device, ctx.sun_vertex_buffer, &mem_requirements)

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

    if vk.AllocateMemory(ctx.device, &alloc_info, nil, &ctx.sun_vertex_memory) != .SUCCESS {
        log("Failed to allocate sun vertex memory")
        return false
    }

    vk.BindBufferMemory(ctx.device, ctx.sun_vertex_buffer, ctx.sun_vertex_memory, 0)

    // Copy data
    data: rawptr
    vk.MapMemory(ctx.device, ctx.sun_vertex_memory, 0, buffer_size, {}, &data)
    mem.copy(data, raw_data(vertices), int(buffer_size))
    vk.UnmapMemory(ctx.device, ctx.sun_vertex_memory)

    // Get buffer device address
    address_info := vk.BufferDeviceAddressInfo{
        sType  = .BUFFER_DEVICE_ADDRESS_INFO,
        buffer = ctx.sun_vertex_buffer,
    }
    ctx.sun_vertex_address = vk.GetBufferDeviceAddress(ctx.device, &address_info)

    log("Sun indicator created (60 vertices)")
    return true
}

// Cleanup sun indicator
cleanup_sun_indicator :: proc(ctx: ^Context) {
    if ctx.sun_vertex_buffer != 0 {
        vk.DestroyBuffer(ctx.device, ctx.sun_vertex_buffer, nil)
        ctx.sun_vertex_buffer = 0
    }
    if ctx.sun_vertex_memory != 0 {
        vk.FreeMemory(ctx.device, ctx.sun_vertex_memory, nil)
        ctx.sun_vertex_memory = 0
    }
}

// Create normal arrow geometry - one arrow per tile pointing in normal direction
create_normal_arrows :: proc(ctx: ^Context, gnd: ^GND_Ground) -> bool {
    // Count valid cells (with top surface)
    arrow_count := 0
    for cell_y: i32 = 0; cell_y < gnd.height; cell_y += 1 {
        for cell_x: i32 = 0; cell_x < gnd.width; cell_x += 1 {
            cell := gnd_get_cell(gnd, cell_x, cell_y)
            if cell != nil && cell.top_surface_id >= 0 {
                arrow_count += 1
            }
        }
    }

    if arrow_count == 0 {
        log("No cells for normal arrows")
        return true
    }

    // Each arrow = 2 vertices (line from center to center+normal)
    vertices := make([]Vertex, arrow_count * 2)
    defer delete(vertices)

    arrow_length: f32 = 5.0  // Length of normal arrow
    arrow_color := Vec3{0.0, 1.0, 0.0}  // Green arrows

    idx := 0
    for cell_y: i32 = 0; cell_y < gnd.height; cell_y += 1 {
        for cell_x: i32 = 0; cell_x < gnd.width; cell_x += 1 {
            cell := gnd_get_cell(gnd, cell_x, cell_y)
            if cell == nil || cell.top_surface_id < 0 {
                continue
            }

            // Get cell center position (in world coords)
            // GND uses zoom scale and Y is height
            center_x := (f32(cell_x) + 0.5) * gnd.zoom
            center_z := (f32(cell_y) + 0.5) * gnd.zoom

            // Average height of 4 corners for center height
            center_y := -(cell.height[0] + cell.height[1] + cell.height[2] + cell.height[3]) / 4.0

            // Get average normal for the cell (average of 4 corner normals)
            n0 := calc_smooth_normal(gnd, cell_x, cell_y, 0)
            n1 := calc_smooth_normal(gnd, cell_x, cell_y, 1)
            n2 := calc_smooth_normal(gnd, cell_x, cell_y, 2)
            n3 := calc_smooth_normal(gnd, cell_x, cell_y, 3)
            normal := Vec3{
                (n0.x + n1.x + n2.x + n3.x) / 4.0,
                (n0.y + n1.y + n2.y + n3.y) / 4.0,
                (n0.z + n1.z + n2.z + n3.z) / 4.0,
            }
            normal = vec3_normalize(normal)

            // Start vertex (at cell center)
            vertices[idx] = Vertex{
                pos       = {center_x, center_y, center_z},
                normal    = {normal.x, normal.y, normal.z},
                color     = {arrow_color.x, arrow_color.y, arrow_color.z},
                uv        = {0, 0},
                lm_uv     = {0, 0},
                tex_index = 0xFFFFFFFF,  // No texture
                prelit    = 1.0,         // Full brightness for debug arrows
            }
            idx += 1

            // End vertex (center + normal * length)
            end_x := center_x + normal.x * arrow_length
            end_y := center_y + normal.y * arrow_length
            end_z := center_z + normal.z * arrow_length

            vertices[idx] = Vertex{
                pos       = {end_x, end_y, end_z},
                normal    = {normal.x, normal.y, normal.z},
                color     = {arrow_color.x, arrow_color.y, arrow_color.z},
                uv        = {0, 0},
                lm_uv     = {0, 0},
                tex_index = 0xFFFFFFFF,
                prelit    = 1.0,         // Full brightness for debug arrows
            }
            idx += 1
        }
    }

    ctx.normal_arrow_count = u32(idx)

    // Create buffer
    buffer_size := vk.DeviceSize(idx * size_of(Vertex))

    buffer_info := vk.BufferCreateInfo{
        sType = .BUFFER_CREATE_INFO,
        size  = buffer_size,
        usage = {.VERTEX_BUFFER, .SHADER_DEVICE_ADDRESS},
    }

    if vk.CreateBuffer(ctx.device, &buffer_info, nil, &ctx.normal_arrow_buffer) != .SUCCESS {
        log("Failed to create normal arrow buffer")
        return false
    }

    mem_requirements: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(ctx.device, ctx.normal_arrow_buffer, &mem_requirements)

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

    if vk.AllocateMemory(ctx.device, &alloc_info, nil, &ctx.normal_arrow_memory) != .SUCCESS {
        log("Failed to allocate normal arrow memory")
        return false
    }

    vk.BindBufferMemory(ctx.device, ctx.normal_arrow_buffer, ctx.normal_arrow_memory, 0)

    // Copy data
    data: rawptr
    vk.MapMemory(ctx.device, ctx.normal_arrow_memory, 0, buffer_size, {}, &data)
    mem.copy(data, raw_data(vertices), int(buffer_size))
    vk.UnmapMemory(ctx.device, ctx.normal_arrow_memory)

    // Get buffer device address
    address_info := vk.BufferDeviceAddressInfo{
        sType  = .BUFFER_DEVICE_ADDRESS_INFO,
        buffer = ctx.normal_arrow_buffer,
    }
    ctx.normal_arrow_address = vk.GetBufferDeviceAddress(ctx.device, &address_info)

    log_fmt("Normal arrows created (%d arrows, %d vertices)", arrow_count, idx)
    return true
}

// Create player marker geometry (small octahedron/diamond)
create_player_marker :: proc(ctx: ^Context) -> bool {
    // Octahedron vertices: top, bottom, and 4 equatorial points
    top    := Vec3{0, 1, 0}
    bottom := Vec3{0, -1, 0}
    front  := Vec3{0, 0, 1}
    back   := Vec3{0, 0, -1}
    left   := Vec3{-1, 0, 0}
    right  := Vec3{1, 0, 0}

    // 8 triangular faces, 24 vertices
    marker_radius: f32 = 5.0
    marker_color := Vec3{0.0, 1.0, 0.8}  // Cyan-ish

    faces := [8][3]Vec3{
        {top, front, right},
        {top, right, back},
        {top, back, left},
        {top, left, front},
        {bottom, right, front},
        {bottom, back, right},
        {bottom, left, back},
        {bottom, front, left},
    }

    vertices := make([]Vertex, 24)
    defer delete(vertices)

    for face, fi in faces {
        // Compute face normal
        e1 := Vec3{face[1].x - face[0].x, face[1].y - face[0].y, face[1].z - face[0].z}
        e2 := Vec3{face[2].x - face[0].x, face[2].y - face[0].y, face[2].z - face[0].z}
        n := vec3_normalize(vec3_cross(e1, e2))

        for vi in 0..<3 {
            v := face[vi]
            idx := fi * 3 + vi
            vertices[idx] = Vertex{
                pos       = {v.x * marker_radius, v.y * marker_radius, v.z * marker_radius},
                normal    = {n.x, n.y, n.z},
                color     = {marker_color.x, marker_color.y, marker_color.z},
                uv        = {0, 0},
                lm_uv     = {0, 0},
                tex_index = 0xFFFFFFFF,
                prelit    = 1.0,
            }
        }
    }

    ctx.player_marker_count = 24

    buffer_size := vk.DeviceSize(len(vertices) * size_of(Vertex))

    buffer_info := vk.BufferCreateInfo{
        sType = .BUFFER_CREATE_INFO,
        size  = buffer_size,
        usage = {.VERTEX_BUFFER, .SHADER_DEVICE_ADDRESS},
    }

    if vk.CreateBuffer(ctx.device, &buffer_info, nil, &ctx.player_marker_buffer) != .SUCCESS {
        log("Failed to create player marker buffer")
        return false
    }

    mem_requirements: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(ctx.device, ctx.player_marker_buffer, &mem_requirements)

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

    if vk.AllocateMemory(ctx.device, &alloc_info, nil, &ctx.player_marker_memory) != .SUCCESS {
        log("Failed to allocate player marker memory")
        return false
    }

    vk.BindBufferMemory(ctx.device, ctx.player_marker_buffer, ctx.player_marker_memory, 0)

    data: rawptr
    vk.MapMemory(ctx.device, ctx.player_marker_memory, 0, buffer_size, {}, &data)
    mem.copy(data, raw_data(vertices), int(buffer_size))
    vk.UnmapMemory(ctx.device, ctx.player_marker_memory)

    address_info := vk.BufferDeviceAddressInfo{
        sType  = .BUFFER_DEVICE_ADDRESS_INFO,
        buffer = ctx.player_marker_buffer,
    }
    ctx.player_marker_address = vk.GetBufferDeviceAddress(ctx.device, &address_info)

    log("Player marker created (24 vertices)")
    return true
}

// Cleanup player marker
cleanup_player_marker :: proc(ctx: ^Context) {
    if ctx.player_marker_buffer != 0 {
        vk.DestroyBuffer(ctx.device, ctx.player_marker_buffer, nil)
        ctx.player_marker_buffer = 0
    }
    if ctx.player_marker_memory != 0 {
        vk.FreeMemory(ctx.device, ctx.player_marker_memory, nil)
        ctx.player_marker_memory = 0
    }
}

// Cleanup normal arrows
cleanup_normal_arrows :: proc(ctx: ^Context) {
    if ctx.normal_arrow_buffer != 0 {
        vk.DestroyBuffer(ctx.device, ctx.normal_arrow_buffer, nil)
        ctx.normal_arrow_buffer = 0
    }
    if ctx.normal_arrow_memory != 0 {
        vk.FreeMemory(ctx.device, ctx.normal_arrow_memory, nil)
        ctx.normal_arrow_memory = 0
    }
    ctx.normal_arrow_count = 0
}
