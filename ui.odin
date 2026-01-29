package main

import "core:fmt"
import "core:mem"
import mu "vendor:microui"
import vk "vendor:vulkan"
import "vendor:glfw"

// UI Vertex for rendering
UI_Vertex :: struct {
    pos:   [2]f32,
    uv:    [2]f32,
    color: u32,
}

// UI Push constants
UI_Push_Constants :: struct {
    vertices:    vk.DeviceAddress,
    screen_size: [2]f32,
}

// Maximum vertices/indices per frame
UI_MAX_VERTICES :: 65536
UI_MAX_INDICES  :: 65536 * 3

// Global microui context
g_mu_ctx: mu.Context

// Mouse button state for edge detection
g_ui_lmb_was_pressed: bool
g_ui_rmb_was_pressed: bool

// Initialize microui
ui_init :: proc(ctx: ^Context) -> bool {
    mu.init(&g_mu_ctx)
    g_mu_ctx.text_width = mu.default_atlas_text_width
    g_mu_ctx.text_height = mu.default_atlas_text_height

    // Create atlas texture (R8 format for alpha)
    if !create_ui_atlas(ctx) {
        fmt.eprintln("Failed to create UI atlas texture")
        return false
    }

    // Create vertex buffer (dynamic, host-visible)
    if !create_ui_buffers(ctx) {
        fmt.eprintln("Failed to create UI buffers")
        return false
    }

    // Create descriptor set layout and buffer for atlas texture
    if !create_ui_descriptors(ctx) {
        fmt.eprintln("Failed to create UI descriptors")
        return false
    }

    // Create pipeline layout
    if !create_ui_pipeline_layout(ctx) {
        fmt.eprintln("Failed to create UI pipeline layout")
        return false
    }

    // Create shader objects
    if !create_ui_shaders(ctx) {
        fmt.eprintln("Failed to create UI shaders")
        return false
    }

    return true
}

// Create the atlas texture from microui's default atlas
create_ui_atlas :: proc(ctx: ^Context) -> bool {
    width  := u32(mu.DEFAULT_ATLAS_WIDTH)
    height := u32(mu.DEFAULT_ATLAS_HEIGHT)

    // Create image
    image_info := vk.ImageCreateInfo{
        sType = .IMAGE_CREATE_INFO,
        imageType = .D2,
        format = .R8_UNORM,
        extent = {width, height, 1},
        mipLevels = 1,
        arrayLayers = 1,
        samples = {._1},
        tiling = .OPTIMAL,
        usage = {.SAMPLED, .TRANSFER_DST},
        sharingMode = .EXCLUSIVE,
        initialLayout = .UNDEFINED,
    }

    if vk.CreateImage(ctx.device, &image_info, nil, &ctx.ui_atlas_texture.image) != .SUCCESS {
        return false
    }

    // Allocate memory
    mem_reqs: vk.MemoryRequirements
    vk.GetImageMemoryRequirements(ctx.device, ctx.ui_atlas_texture.image, &mem_reqs)

    alloc_info := vk.MemoryAllocateInfo{
        sType = .MEMORY_ALLOCATE_INFO,
        allocationSize = mem_reqs.size,
        memoryTypeIndex = find_memory_type(ctx, mem_reqs.memoryTypeBits, {.DEVICE_LOCAL}),
    }

    if vk.AllocateMemory(ctx.device, &alloc_info, nil, &ctx.ui_atlas_texture.memory) != .SUCCESS {
        return false
    }
    vk.BindImageMemory(ctx.device, ctx.ui_atlas_texture.image, ctx.ui_atlas_texture.memory, 0)

    // Create staging buffer
    staging_size := vk.DeviceSize(width * height)
    staging_buffer: vk.Buffer
    staging_memory: vk.DeviceMemory

    buffer_info := vk.BufferCreateInfo{
        sType = .BUFFER_CREATE_INFO,
        size = staging_size,
        usage = {.TRANSFER_SRC},
        sharingMode = .EXCLUSIVE,
    }
    vk.CreateBuffer(ctx.device, &buffer_info, nil, &staging_buffer)

    vk.GetBufferMemoryRequirements(ctx.device, staging_buffer, &mem_reqs)
    staging_alloc := vk.MemoryAllocateInfo{
        sType = .MEMORY_ALLOCATE_INFO,
        allocationSize = mem_reqs.size,
        memoryTypeIndex = find_memory_type(ctx, mem_reqs.memoryTypeBits, {.HOST_VISIBLE, .HOST_COHERENT}),
    }
    vk.AllocateMemory(ctx.device, &staging_alloc, nil, &staging_memory)
    vk.BindBufferMemory(ctx.device, staging_buffer, staging_memory, 0)

    // Copy atlas data to staging buffer
    data: rawptr
    vk.MapMemory(ctx.device, staging_memory, 0, staging_size, {}, &data)
    mem.copy(data, &mu.default_atlas_alpha[0], int(staging_size))
    vk.UnmapMemory(ctx.device, staging_memory)

    // Transition and copy
    cmd := begin_single_command(ctx)

    // Transition to TRANSFER_DST
    barrier := vk.ImageMemoryBarrier{
        sType = .IMAGE_MEMORY_BARRIER,
        srcAccessMask = {},
        dstAccessMask = {.TRANSFER_WRITE},
        oldLayout = .UNDEFINED,
        newLayout = .TRANSFER_DST_OPTIMAL,
        image = ctx.ui_atlas_texture.image,
        subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
    }
    vk.CmdPipelineBarrier(cmd, {.TOP_OF_PIPE}, {.TRANSFER}, {}, 0, nil, 0, nil, 1, &barrier)

    // Copy buffer to image
    region := vk.BufferImageCopy{
        imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
        imageExtent = {width, height, 1},
    }
    vk.CmdCopyBufferToImage(cmd, staging_buffer, ctx.ui_atlas_texture.image, .TRANSFER_DST_OPTIMAL, 1, &region)

    // Transition to SHADER_READ
    barrier.srcAccessMask = {.TRANSFER_WRITE}
    barrier.dstAccessMask = {.SHADER_READ}
    barrier.oldLayout = .TRANSFER_DST_OPTIMAL
    barrier.newLayout = .SHADER_READ_ONLY_OPTIMAL
    vk.CmdPipelineBarrier(cmd, {.TRANSFER}, {.FRAGMENT_SHADER}, {}, 0, nil, 0, nil, 1, &barrier)

    end_single_command(ctx, cmd)

    // Cleanup staging
    vk.DestroyBuffer(ctx.device, staging_buffer, nil)
    vk.FreeMemory(ctx.device, staging_memory, nil)

    // Create image view
    view_info := vk.ImageViewCreateInfo{
        sType = .IMAGE_VIEW_CREATE_INFO,
        image = ctx.ui_atlas_texture.image,
        viewType = .D2,
        format = .R8_UNORM,
        subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
    }
    if vk.CreateImageView(ctx.device, &view_info, nil, &ctx.ui_atlas_texture.view) != .SUCCESS {
        return false
    }

    ctx.ui_atlas_texture.width = width
    ctx.ui_atlas_texture.height = height

    return true
}

// Create dynamic vertex/index buffers
create_ui_buffers :: proc(ctx: ^Context) -> bool {
    // Vertex buffer
    vertex_size := vk.DeviceSize(size_of(UI_Vertex) * UI_MAX_VERTICES)
    buffer_info := vk.BufferCreateInfo{
        sType = .BUFFER_CREATE_INFO,
        size = vertex_size,
        usage = {.VERTEX_BUFFER, .SHADER_DEVICE_ADDRESS},
        sharingMode = .EXCLUSIVE,
    }

    if vk.CreateBuffer(ctx.device, &buffer_info, nil, &ctx.ui_vertex_buffer) != .SUCCESS {
        return false
    }

    mem_reqs: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(ctx.device, ctx.ui_vertex_buffer, &mem_reqs)

    alloc_flags := vk.MemoryAllocateFlagsInfo{
        sType = .MEMORY_ALLOCATE_FLAGS_INFO,
        flags = {.DEVICE_ADDRESS},
    }
    alloc_info := vk.MemoryAllocateInfo{
        sType = .MEMORY_ALLOCATE_INFO,
        pNext = &alloc_flags,
        allocationSize = mem_reqs.size,
        memoryTypeIndex = find_memory_type(ctx, mem_reqs.memoryTypeBits, {.HOST_VISIBLE, .HOST_COHERENT}),
    }

    if vk.AllocateMemory(ctx.device, &alloc_info, nil, &ctx.ui_vertex_memory) != .SUCCESS {
        return false
    }
    vk.BindBufferMemory(ctx.device, ctx.ui_vertex_buffer, ctx.ui_vertex_memory, 0)

    // Get buffer device address
    addr_info := vk.BufferDeviceAddressInfo{
        sType = .BUFFER_DEVICE_ADDRESS_INFO,
        buffer = ctx.ui_vertex_buffer,
    }
    ctx.ui_vertex_buffer_address = vk.GetBufferDeviceAddress(ctx.device, &addr_info)

    // Index buffer
    index_size := vk.DeviceSize(size_of(u32) * UI_MAX_INDICES)
    buffer_info.size = index_size
    buffer_info.usage = {.INDEX_BUFFER}

    if vk.CreateBuffer(ctx.device, &buffer_info, nil, &ctx.ui_index_buffer) != .SUCCESS {
        return false
    }

    vk.GetBufferMemoryRequirements(ctx.device, ctx.ui_index_buffer, &mem_reqs)
    alloc_info.pNext = nil
    alloc_info.allocationSize = mem_reqs.size

    if vk.AllocateMemory(ctx.device, &alloc_info, nil, &ctx.ui_index_memory) != .SUCCESS {
        return false
    }
    vk.BindBufferMemory(ctx.device, ctx.ui_index_buffer, ctx.ui_index_memory, 0)

    return true
}

// Create descriptor set layout and buffer for atlas
create_ui_descriptors :: proc(ctx: ^Context) -> bool {
    // Descriptor set layout with combined image sampler
    binding := vk.DescriptorSetLayoutBinding{
        binding = 0,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        descriptorCount = 1,
        stageFlags = {.FRAGMENT},
    }

    layout_info := vk.DescriptorSetLayoutCreateInfo{
        sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        flags = {.DESCRIPTOR_BUFFER_EXT},
        bindingCount = 1,
        pBindings = &binding,
    }

    if vk.CreateDescriptorSetLayout(ctx.device, &layout_info, nil, &ctx.ui_descriptor_layout) != .SUCCESS {
        return false
    }

    // Get layout size
    vk.GetDescriptorSetLayoutSizeEXT(ctx.device, ctx.ui_descriptor_layout, &ctx.ui_descriptor_buffer_size)

    // Create descriptor buffer
    buffer_info := vk.BufferCreateInfo{
        sType = .BUFFER_CREATE_INFO,
        size = ctx.ui_descriptor_buffer_size,
        usage = {.RESOURCE_DESCRIPTOR_BUFFER_EXT, .SHADER_DEVICE_ADDRESS},
        sharingMode = .EXCLUSIVE,
    }

    if vk.CreateBuffer(ctx.device, &buffer_info, nil, &ctx.ui_descriptor_buffer) != .SUCCESS {
        return false
    }

    mem_reqs: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(ctx.device, ctx.ui_descriptor_buffer, &mem_reqs)

    alloc_flags := vk.MemoryAllocateFlagsInfo{
        sType = .MEMORY_ALLOCATE_FLAGS_INFO,
        flags = {.DEVICE_ADDRESS},
    }
    alloc_info := vk.MemoryAllocateInfo{
        sType = .MEMORY_ALLOCATE_INFO,
        pNext = &alloc_flags,
        allocationSize = mem_reqs.size,
        memoryTypeIndex = find_memory_type(ctx, mem_reqs.memoryTypeBits, {.HOST_VISIBLE, .HOST_COHERENT}),
    }

    if vk.AllocateMemory(ctx.device, &alloc_info, nil, &ctx.ui_descriptor_buffer_memory) != .SUCCESS {
        return false
    }
    vk.BindBufferMemory(ctx.device, ctx.ui_descriptor_buffer, ctx.ui_descriptor_buffer_memory, 0)

    addr_info := vk.BufferDeviceAddressInfo{
        sType = .BUFFER_DEVICE_ADDRESS_INFO,
        buffer = ctx.ui_descriptor_buffer,
    }
    ctx.ui_descriptor_buffer_address = vk.GetBufferDeviceAddress(ctx.device, &addr_info)

    // Write descriptor with atlas texture
    data: rawptr
    vk.MapMemory(ctx.device, ctx.ui_descriptor_buffer_memory, 0, ctx.ui_descriptor_buffer_size, {}, &data)

    image_info := vk.DescriptorImageInfo{
        sampler = ctx.sampler,  // Reuse existing sampler
        imageView = ctx.ui_atlas_texture.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    }

    descriptor_info := vk.DescriptorGetInfoEXT{
        sType = .DESCRIPTOR_GET_INFO_EXT,
        type = .COMBINED_IMAGE_SAMPLER,
        data = {pCombinedImageSampler = &image_info},
    }

    props: vk.PhysicalDeviceDescriptorBufferPropertiesEXT
    props.sType = .PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT
    props2 := vk.PhysicalDeviceProperties2{sType = .PHYSICAL_DEVICE_PROPERTIES_2, pNext = &props}
    vk.GetPhysicalDeviceProperties2(ctx.physical_device, &props2)

    vk.GetDescriptorEXT(ctx.device, &descriptor_info, props.combinedImageSamplerDescriptorSize, data)

    vk.UnmapMemory(ctx.device, ctx.ui_descriptor_buffer_memory)

    return true
}

// Create pipeline layout for UI rendering
create_ui_pipeline_layout :: proc(ctx: ^Context) -> bool {
    push_constant_range := vk.PushConstantRange{
        stageFlags = {.VERTEX},
        offset = 0,
        size = size_of(UI_Push_Constants),
    }

    layout_info := vk.PipelineLayoutCreateInfo{
        sType = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = 1,
        pSetLayouts = &ctx.ui_descriptor_layout,
        pushConstantRangeCount = 1,
        pPushConstantRanges = &push_constant_range,
    }

    return vk.CreatePipelineLayout(ctx.device, &layout_info, nil, &ctx.ui_pipeline_layout) == .SUCCESS
}

// Raw shader bytes for UI (will be copied to aligned memory)
UI_VERT_SPV_RAW := #load("shaders/ui_vert.spv")
UI_FRAG_SPV_RAW := #load("shaders/ui_frag.spv")

// Create shader objects for UI
create_ui_shaders :: proc(ctx: ^Context) -> bool {
    // Copy SPIRV to aligned memory (must be 4-byte aligned)
    vert_aligned := make([]u32, (len(UI_VERT_SPV_RAW) + 3) / 4)
    frag_aligned := make([]u32, (len(UI_FRAG_SPV_RAW) + 3) / 4)
    defer delete(vert_aligned)
    defer delete(frag_aligned)

    mem.copy(raw_data(vert_aligned), raw_data(UI_VERT_SPV_RAW), len(UI_VERT_SPV_RAW))
    mem.copy(raw_data(frag_aligned), raw_data(UI_FRAG_SPV_RAW), len(UI_FRAG_SPV_RAW))

    // Push constant range (must match for both shaders when bound together)
    push_range := vk.PushConstantRange{
        stageFlags = {.VERTEX},
        offset = 0,
        size = size_of(UI_Push_Constants),
    }

    // Create vertex shader
    vert_info := vk.ShaderCreateInfoEXT{
        sType = .SHADER_CREATE_INFO_EXT,
        stage = {.VERTEX},
        nextStage = {.FRAGMENT},
        codeType = .SPIRV,
        codeSize = len(UI_VERT_SPV_RAW),
        pCode = raw_data(vert_aligned),
        pName = "main",
        setLayoutCount = 1,
        pSetLayouts = &ctx.ui_descriptor_layout,
        pushConstantRangeCount = 1,
        pPushConstantRanges = &push_range,
    }

    if vk.CreateShadersEXT(ctx.device, 1, &vert_info, nil, &ctx.ui_vertex_shader) != .SUCCESS {
        return false
    }

    // Create fragment shader (must have same push constant layout as vertex)
    frag_info := vk.ShaderCreateInfoEXT{
        sType = .SHADER_CREATE_INFO_EXT,
        stage = {.FRAGMENT},
        codeType = .SPIRV,
        codeSize = len(UI_FRAG_SPV_RAW),
        pCode = raw_data(frag_aligned),
        pName = "main",
        setLayoutCount = 1,
        pSetLayouts = &ctx.ui_descriptor_layout,
        pushConstantRangeCount = 1,
        pPushConstantRanges = &push_range,
    }

    if vk.CreateShadersEXT(ctx.device, 1, &frag_info, nil, &ctx.ui_fragment_shader) != .SUCCESS {
        return false
    }

    return true
}

// Check if mouse is over any UI element (use to block camera input)
ui_wants_mouse :: proc() -> bool {
    return g_mu_ctx.hover_root != nil
}

// Process GLFW input for microui
ui_process_input :: proc(ctx: ^Context) {
    // Mouse position
    mx, my := glfw.GetCursorPos(ctx.window)
    mu.input_mouse_move(&g_mu_ctx, i32(mx), i32(my))

    // Mouse buttons - use edge detection (only send on state change)
    lmb_pressed := glfw.GetMouseButton(ctx.window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS
    if lmb_pressed && !g_ui_lmb_was_pressed {
        mu.input_mouse_down(&g_mu_ctx, i32(mx), i32(my), .LEFT)
    } else if !lmb_pressed && g_ui_lmb_was_pressed {
        mu.input_mouse_up(&g_mu_ctx, i32(mx), i32(my), .LEFT)
    }
    g_ui_lmb_was_pressed = lmb_pressed

    rmb_pressed := glfw.GetMouseButton(ctx.window, glfw.MOUSE_BUTTON_RIGHT) == glfw.PRESS
    if rmb_pressed && !g_ui_rmb_was_pressed {
        mu.input_mouse_down(&g_mu_ctx, i32(mx), i32(my), .RIGHT)
    } else if !rmb_pressed && g_ui_rmb_was_pressed {
        mu.input_mouse_up(&g_mu_ctx, i32(mx), i32(my), .RIGHT)
    }
    g_ui_rmb_was_pressed = rmb_pressed

    // Scroll
    if ctx.scroll_delta != 0 {
        mu.input_scroll(&g_mu_ctx, 0, i32(ctx.scroll_delta * -30))
    }
}

import "core:strings"

// Extract just the map name from the full path (e.g., "data\pay_dun00.rsw" -> "pay_dun00")
get_map_display_name :: proc(path: string) -> string {
    // Find last backslash or forward slash
    last_slash := -1
    for i := len(path) - 1; i >= 0; i -= 1 {
        if path[i] == '\\' || path[i] == '/' {
            last_slash = i
            break
        }
    }

    name := path[last_slash + 1:]

    // Remove .rsw extension
    if strings.has_suffix(name, ".rsw") {
        name = name[:len(name) - 4]
    }

    return name
}

// Build UI for current frame
ui_build :: proc(ctx: ^Context) {
    mu.begin(&g_mu_ctx)

    if mu.begin_window(&g_mu_ctx, "Ground Rendering", {10, 10, 220, 360}) {
        mu.layout_row(&g_mu_ctx, {-1}, 0)

        // Map selector
        mu.label(&g_mu_ctx, "Map Selection")
        if len(ctx.available_maps) > 0 {
            // Button showing current map name - opens popup when clicked
            display_name := get_map_display_name(ctx.current_map_name)
            if .SUBMIT in mu.button(&g_mu_ctx, display_name) {
                mu.open_popup(&g_mu_ctx, "map_select")
            }

            // Popup with scrollable map list
            if mu.begin_popup(&g_mu_ctx, "map_select") {
                // Create a scrollable panel for the map list
                mu.layout_row(&g_mu_ctx, {180}, 300)
                mu.begin_panel(&g_mu_ctx, "map_list")
                mu.layout_row(&g_mu_ctx, {-1}, 0)

                for map_path, i in ctx.available_maps {
                    map_name := get_map_display_name(map_path)
                    if .SUBMIT in mu.button(&g_mu_ctx, map_name) {
                        ctx.current_map_index = i
                        ctx.map_needs_reload = true
                    }
                }

                mu.end_panel(&g_mu_ctx)
                mu.end_popup(&g_mu_ctx)
            }
        }

        mu.layout_row(&g_mu_ctx, {-1}, 0)

        // Height factor slider
        mu.label(&g_mu_ctx, "Height Factor")
        mu.slider(&g_mu_ctx, &ctx.height_factor, 0.0, 1.0, 0.01)

        // Rendering components
        mu.label(&g_mu_ctx, "Components:")
        mu.checkbox(&g_mu_ctx, "Texture", &ctx.texture_enabled)
        mu.checkbox(&g_mu_ctx, "Tile Color", &ctx.tile_color_enabled)
        mu.checkbox(&g_mu_ctx, "Ambient", &ctx.ambient_enabled)
        mu.checkbox(&g_mu_ctx, "Lighting", &ctx.lighting_enabled)
        mu.checkbox(&g_mu_ctx, "Shadow Map", &ctx.shadowmap_enabled)
        mu.checkbox(&g_mu_ctx, "Color Lightmap", &ctx.colormap_enabled)
        mu.checkbox(&g_mu_ctx, "LM Posterize", &ctx.lightmap_posterize)
        mu.checkbox(&g_mu_ctx, "Fog (F)", &ctx.fog_enabled)

        // Polygon mode buttons
        mu.label(&g_mu_ctx, "Polygon Mode (V)")
        mu.layout_row(&g_mu_ctx, {60, 60, 60}, 0)
        if .SUBMIT in mu.button(&g_mu_ctx, "Fill") {
            ctx.polygon_mode = 0
        }
        if .SUBMIT in mu.button(&g_mu_ctx, "Line") {
            ctx.polygon_mode = 1
        }
        if .SUBMIT in mu.button(&g_mu_ctx, "Point") {
            ctx.polygon_mode = 2
        }

        mu.end_window(&g_mu_ctx)
    }

    mu.end(&g_mu_ctx)
}

// Render microui commands
ui_render :: proc(ctx: ^Context, cmd: vk.CommandBuffer) {
    // Build vertex data from microui commands
    vertices: [dynamic]UI_Vertex
    indices: [dynamic]u32
    defer delete(vertices)
    defer delete(indices)

    atlas_w := f32(mu.DEFAULT_ATLAS_WIDTH)
    atlas_h := f32(mu.DEFAULT_ATLAS_HEIGHT)

    mu_cmd: ^mu.Command
    for mu.next_command(&g_mu_ctx, &mu_cmd) {
        switch v in mu_cmd.variant {
        case ^mu.Command_Clip:
            // We'll handle clipping via scissor in a simplified way
            // For now, just continue

        case ^mu.Command_Rect:
            // Get white pixel UV from atlas
            white := mu.default_atlas[mu.DEFAULT_ATLAS_WHITE]
            u0 := (f32(white.x) + 0.5) / atlas_w
            v0 := (f32(white.y) + 0.5) / atlas_h
            u1 := (f32(white.x + white.w) - 0.5) / atlas_w
            v1 := (f32(white.y + white.h) - 0.5) / atlas_h

            color := pack_color(v.color)
            base := u32(len(vertices))

            x0, y0 := f32(v.rect.x), f32(v.rect.y)
            x1, y1 := x0 + f32(v.rect.w), y0 + f32(v.rect.h)

            append(&vertices, UI_Vertex{{x0, y0}, {u0, v0}, color})
            append(&vertices, UI_Vertex{{x1, y0}, {u1, v0}, color})
            append(&vertices, UI_Vertex{{x1, y1}, {u1, v1}, color})
            append(&vertices, UI_Vertex{{x0, y1}, {u0, v1}, color})

            append(&indices, base+0, base+1, base+2)
            append(&indices, base+0, base+2, base+3)

        case ^mu.Command_Text:
            color := pack_color(v.color)
            x := f32(v.pos.x)
            y := f32(v.pos.y)

            // Get text from command
            text := v.str

            for ch in text {
                if ch & 0xc0 == 0x80 do continue
                r := min(int(ch), 127)
                src := mu.default_atlas[mu.DEFAULT_ATLAS_FONT + r]

                if src.w > 0 && src.h > 0 {
                    u0 := f32(src.x) / atlas_w
                    v0 := f32(src.y) / atlas_h
                    u1 := f32(src.x + src.w) / atlas_w
                    v1 := f32(src.y + src.h) / atlas_h

                    base := u32(len(vertices))
                    x1, y1 := x + f32(src.w), y + f32(src.h)

                    append(&vertices, UI_Vertex{{x, y}, {u0, v0}, color})
                    append(&vertices, UI_Vertex{{x1, y}, {u1, v0}, color})
                    append(&vertices, UI_Vertex{{x1, y1}, {u1, v1}, color})
                    append(&vertices, UI_Vertex{{x, y1}, {u0, v1}, color})

                    append(&indices, base+0, base+1, base+2)
                    append(&indices, base+0, base+2, base+3)
                }

                x += f32(src.w)
            }

        case ^mu.Command_Icon:
            src := mu.default_atlas[int(v.id)]
            if src.w == 0 || src.h == 0 do continue

            u0 := f32(src.x) / atlas_w
            v0 := f32(src.y) / atlas_h
            u1 := f32(src.x + src.w) / atlas_w
            v1 := f32(src.y + src.h) / atlas_h

            color := pack_color(v.color)
            base := u32(len(vertices))

            // Center icon in rect
            x := f32(v.rect.x) + (f32(v.rect.w) - f32(src.w)) / 2
            y := f32(v.rect.y) + (f32(v.rect.h) - f32(src.h)) / 2
            x1, y1 := x + f32(src.w), y + f32(src.h)

            append(&vertices, UI_Vertex{{x, y}, {u0, v0}, color})
            append(&vertices, UI_Vertex{{x1, y}, {u1, v0}, color})
            append(&vertices, UI_Vertex{{x1, y1}, {u1, v1}, color})
            append(&vertices, UI_Vertex{{x, y1}, {u0, v1}, color})

            append(&indices, base+0, base+1, base+2)
            append(&indices, base+0, base+2, base+3)

        case ^mu.Command_Jump:
            // Internal command, skip
        }
    }

    if len(vertices) == 0 do return

    // Upload vertices
    data: rawptr
    vk.MapMemory(ctx.device, ctx.ui_vertex_memory, 0, vk.DeviceSize(len(vertices) * size_of(UI_Vertex)), {}, &data)
    mem.copy(data, raw_data(vertices[:]), len(vertices) * size_of(UI_Vertex))
    vk.UnmapMemory(ctx.device, ctx.ui_vertex_memory)

    // Upload indices
    vk.MapMemory(ctx.device, ctx.ui_index_memory, 0, vk.DeviceSize(len(indices) * size_of(u32)), {}, &data)
    mem.copy(data, raw_data(indices[:]), len(indices) * size_of(u32))
    vk.UnmapMemory(ctx.device, ctx.ui_index_memory)

    // Bind UI shaders
    stages := [2]vk.ShaderStageFlags{{.VERTEX}, {.FRAGMENT}}
    shaders := [2]vk.ShaderEXT{ctx.ui_vertex_shader, ctx.ui_fragment_shader}
    vk.CmdBindShadersEXT(cmd, 2, &stages[0], &shaders[0])

    // Set dynamic state for 2D rendering
    vk.CmdSetDepthTestEnable(cmd, false)
    vk.CmdSetDepthWriteEnable(cmd, false)
    vk.CmdSetCullMode(cmd, {})

    // Enable blending for UI
    blend_enable: b32 = true
    vk.CmdSetColorBlendEnableEXT(cmd, 0, 1, &blend_enable)
    blend_eq := vk.ColorBlendEquationEXT{
        srcColorBlendFactor = .SRC_ALPHA,
        dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
        colorBlendOp = .ADD,
        srcAlphaBlendFactor = .ONE,
        dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
        alphaBlendOp = .ADD,
    }
    vk.CmdSetColorBlendEquationEXT(cmd, 0, 1, &blend_eq)

    // Bind descriptor buffer
    buffer_binding := vk.DescriptorBufferBindingInfoEXT{
        sType = .DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
        address = ctx.ui_descriptor_buffer_address,
        usage = {.RESOURCE_DESCRIPTOR_BUFFER_EXT},
    }
    vk.CmdBindDescriptorBuffersEXT(cmd, 1, &buffer_binding)

    buffer_index: u32 = 0
    offset: vk.DeviceSize = 0
    vk.CmdSetDescriptorBufferOffsetsEXT(cmd, .GRAPHICS, ctx.ui_pipeline_layout, 0, 1, &buffer_index, &offset)

    // Push constants
    pc := UI_Push_Constants{
        vertices = ctx.ui_vertex_buffer_address,
        screen_size = {f32(ctx.swapchain_extent.width), f32(ctx.swapchain_extent.height)},
    }
    vk.CmdPushConstants(cmd, ctx.ui_pipeline_layout, {.VERTEX}, 0, size_of(UI_Push_Constants), &pc)

    // Bind index buffer and draw
    vk.CmdBindIndexBuffer(cmd, ctx.ui_index_buffer, 0, .UINT32)
    vk.CmdDrawIndexed(cmd, u32(len(indices)), 1, 0, 0, 0)
}

// Pack RGBA color to u32
pack_color :: proc(c: mu.Color) -> u32 {
    return u32(c.r) | (u32(c.g) << 8) | (u32(c.b) << 16) | (u32(c.a) << 24)
}

// Cleanup UI resources
ui_cleanup :: proc(ctx: ^Context) {
    vk.DeviceWaitIdle(ctx.device)

    if ctx.ui_vertex_shader != 0 do vk.DestroyShaderEXT(ctx.device, ctx.ui_vertex_shader, nil)
    if ctx.ui_fragment_shader != 0 do vk.DestroyShaderEXT(ctx.device, ctx.ui_fragment_shader, nil)
    if ctx.ui_pipeline_layout != 0 do vk.DestroyPipelineLayout(ctx.device, ctx.ui_pipeline_layout, nil)
    if ctx.ui_descriptor_layout != 0 do vk.DestroyDescriptorSetLayout(ctx.device, ctx.ui_descriptor_layout, nil)
    if ctx.ui_descriptor_buffer != 0 do vk.DestroyBuffer(ctx.device, ctx.ui_descriptor_buffer, nil)
    if ctx.ui_descriptor_buffer_memory != 0 do vk.FreeMemory(ctx.device, ctx.ui_descriptor_buffer_memory, nil)
    if ctx.ui_vertex_buffer != 0 do vk.DestroyBuffer(ctx.device, ctx.ui_vertex_buffer, nil)
    if ctx.ui_vertex_memory != 0 do vk.FreeMemory(ctx.device, ctx.ui_vertex_memory, nil)
    if ctx.ui_index_buffer != 0 do vk.DestroyBuffer(ctx.device, ctx.ui_index_buffer, nil)
    if ctx.ui_index_memory != 0 do vk.FreeMemory(ctx.device, ctx.ui_index_memory, nil)
    if ctx.ui_atlas_texture.view != 0 do vk.DestroyImageView(ctx.device, ctx.ui_atlas_texture.view, nil)
    if ctx.ui_atlas_texture.image != 0 do vk.DestroyImage(ctx.device, ctx.ui_atlas_texture.image, nil)
    if ctx.ui_atlas_texture.memory != 0 do vk.FreeMemory(ctx.device, ctx.ui_atlas_texture.memory, nil)
}
